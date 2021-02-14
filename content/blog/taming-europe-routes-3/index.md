---
title: Taming Europe routes, part 3
date: "2021-02-14T14:30:00.284Z"
description: "How to parse almost 500 million routes with graphhopper server app and python scripts, part 3, actual parsing, redis and python optimizations, parsing speed up"
---

## TL:DR previous parts

I was approached by one of my clients with a work that required to parse almost 500 million European routes to see what routes can be traveled by land transport. After some research, i decided to use graphhopper server application and python celery library, the server was found, scripts were written and i was ready to start the parsing.

## Celery configuration and tweaks

I decided to use celery because of its flexibility and simpleness of configuration. The task was to query graphhopper server, wait for the response, then write the response from workers into the file. http request is a blocking operation that python can greatly optimize. Python does not have full concurrency support because of the [gil](https://wiki.python.org/moin/GlobalInterpreterLock) but blocking operations such as this can run simultaneously: when we have http socket waiting for the response python can skip the waiting in the current thread and move the next thread, this way we can have almost the full concurrency. This mechanic will eventually slow down on a large scale because of the CPU load and also slower as the process concurrency model. This is the part where celery flexibility comes in place. We can start celery in multiprocess mode by supplying `-c`(concurrency) flag and supply the number of processes to spawn, that way we will utilize the whole number of server cores. By default, celery will start workers with the process number equal to the number of server` cores. Because i wanted to also utilize the thread concurrency model i started workers a little bit different:

```shell
$: for i in {1..16}; do; celery multi start $i -A proj -l INFO -c 3 -P threads; done
```

This command creates 16 celery workers(that's the number of cores on my server) each with a `thread` concurrency model and 3 worker threads each. Flag `-P` tells celery what concurrency model to use, available options are: prefork (default), eventlet, gevent, solo or threads. I have not tested `eventlet` or `gevent` options because the process -> threads model was known to me before, many web servers use this implementation and it's great for blocking operations.

Celery can store the task call inside the broker and retrieve it by call, its not so effective in async processing but perfect for batch data processing with `celery.group` method. This method can accept task name and list of args to call with. Here is the example of processing a list of coordinates with `celery.group`:

```python
def flush_batch_main(batch):
  execution_result = celery.group(lookup_directions.s(
      row[0], row[1]) for row in batch)().get()
  return [[], execution_result]
```

And in the main script i added the following code:

```python
CONCURENCY = 500

for row_1 in terms[START_POINT:]:
  for row_2 in terms:
    ...
    row_batch.append([start_point, end_point])
    if len(row_batch) >= CONCURENCY:
      row_batch, execution_result = flush_batch(row_batch)
      result_batch.extend(execution_result)

    if len(result_batch) >= max_result_batch:
      print('Flushed')
      writer.writerows(result_batch)
      for entry in result_batch:
        hasher.memorize_route(entry['merged_term'])
      result_batch = []
```

This code store coordinates inside `row_batch` accumulator until the size of this accumulator surpasses `CONCURENCY` number, after that, it submits the `row_batch` list into the worker pool after all workers complete the tasks it returns the result combined in one list.

After we process the coordinates batch we need to store this result. This is a blocking operation and if we need to call it often that can lead to a performance decrease. That's why i decided to first store the results in variable and after that exceeds some number(i decided to go with 10_000) write it into the result file:

```python
if len(result_batch) >= max_result_batch:
  print('Flushed')
  writer.writerows(result_batch)
  for entry in result_batch:
    hasher.memorize_route(entry['merged_term'])
  result_batch = []
```

## Hungry redis

The code was written and optimized, at test runs the server cpu utilization was almost at 100%. I have started the script and left the server running. The pace was great, almost 50 million entries in one day, which gave me 10 days of parsing to complete the task. Then one day i have entered the server and noticed a big spike in memory: an additional 10 Gb was used. The server itself had 64Gb of total memory, graphhopper occupied 35, and scripts took an additional 3. The problem was that memory consumption kept growing. I inspected htop and noticed that it was redis memory consumption. Redis server used 10Gb of memory! So what was the cause of such consumption? I used redis to also store a list of routes that already checked, it was a simple key with string name and value equal to boolean. That way i could memorize what routes were processed and skip it between script restart. As it turns out, a simple key-value store is not optimized in redis and will consume a lot of memory. During my search for the solution i encountered this post: [storing hundreds of millions of simple key-value pairs in redis](https://instagram-engineering.com/storing-hundreds-of-millions-of-simple-key-value-pairs-in-redis-1091ae80f74c) which introduced a neat technique that can shred redis memory consumption by a lot. The technique used redis method [hset](https://redis.io/commands/hset) instead of the simple `set` key. The way it works is like this: we choose a bucket that will store the value then we store key-value parts in it. Its a simple hashing algorithm, python itself uses it for storing hashed values to avoid collisions. Such store is much more optimized by memory and without speed reduction in access. Even more, i noticed that the keys i used for completed routes were just simple strings so i decided to also hash this string to a hex string that can be easily matched during processing.

Here is the code i wrote to determine the bucket we will be storing route. I decided to use 500\_000 buckets by the number of routes used / 1000, so in each bucket, there will be max 1000 routes stored. python's `int` method can return int representation of the hex string(that's the second argument of `int`) which can be used with the remainder of dividing by `NUMBER_BUCKETS` to return a number from 0 to 500\_000 depending on hash passed.

```python
NUMBER_BUCKETS = 500_000

def bucket(hashed_route):
  return int(hashed_route, 16) % NUMBER_BUCKETS
```

Hash from string can be generated this way in python:

```python
def hash_route(route):
  return hashlib.md5(route.encode('utf-8')).hexdigest()
```

And the code for setting and retrieving keys from redis woth `hset` will look like this:

```python
def route_exists(route):
  hashed_route = hash_route(route)
  return router.redis_client.main.hexists(str(bucket(hashed_route)), hashed_route)

def memorize_route(route):
  hashed_route = hash_route(route)
  return router.redis_client.main.hset(str(bucket(hashed_route)), hashed_route, '1')
```

After these optimizations the memory consumption droped by a lot, but still redis consumed much less memory but after next iteration of parsing it still started to increase. I decided to look inside redis for the used keys. One thing i noticed was that there a lot of `celery*` keys inside redis:

```bash
$: redis-cli KEYS "celery*" | wc -l
500000
```

That's strange. After some research, i found the reason behind these keys creation. As it turns out, celery can store results into the broker but by default these keys last for one day! I did not need such long time as i was collecting the values right away, the simple tweak of the celery config:

```diff
from __future__ import absolute_import, unicode_literals
from celery import Celery

app = Celery('router',
             broker='redis://',
             backend='redis://',
             include=['router.tasks'])
+app.conf.result_expires = 60
```

Fixed the issue and redis memory consumption dropped by a lot! After all 500 million routes parsing the redis server occupied no more than 6 Gb of memory, nice!

## Retrieving the results

Parsing was progressing fast, i had the first results and they were huge. By default i stored the results into a csv file and after parsing just 50 million routes it size exceeded 12 Gb. It was obvious that i won't have enough space to even store such results and i also needed to parse them through AdWords key planner tool. I need a more optimized by size format to work with and, as it turned out, python has support for a number of marvelous data formats. The easiest one to work from python was [parquet](https://parquet.apache.org/documentation/latest/). Parquet is a binary columnar file format that can store a large array of data and can be easily converted in other formats with the help of pandas. Here is a script that can migrate csv file into the parquet one:

```python
import pandas
import cleaner.utils
import sys
import os

FILE_NAME = sys.argv[1]
CHUNK_SIZE = 8000000
FILE_RESULT_TEMPLATE = '{}_{}.parquet'
FILE_POSSIBLE_RESULT_TEMPLATE = '{}_{}_possible.parquet'

if __name__ == "__main__":
  i = 1
  base_name = os.path.basename(FILE_NAME).split('.')[0]
  for chunk in pandas.read_csv(FILE_NAME, chunksize=CHUNK_SIZE):
    print(FILE_RESULT_TEMPLATE.format(base_name, i))
    cleaned_chunk = cleaner.utils.clean_routes_dataframe(chunk)
    possible = cleaned_chunk.loc[((cleaned_chunk['distance'] != 0) & (cleaned_chunk['distance'] < 750000)) & (
        (cleaned_chunk['time'] != 0) & (cleaned_chunk['time'] < 28800000))]
    cleaned_chunk.to_parquet(
        FILE_RESULT_TEMPLATE.format(base_name, i), engine='pyarrow')
    possible.to_parquet(
        FILE_POSSIBLE_RESULT_TEMPLATE.format(base_name, i), engine='pyarrow')
    i += 1
```

I had one large csv file that was storing the parsing results and i need smaller files with no more than 8 million entries that i can easily download, read and convert to the csv and paste into AdWords keywords planner tool. This script will take the csv file name from the command line args(`sys.argv[1]`), open it, read in batches(remember that the original csv file is huge, we need to carefully read it in batches), and then write down a series of parquet files with indexes, no more than 8 million entries. The size optimization was a tremendous one, a 8 million rows parquet file weighted no more than 600 Mb!

## Conclusions

The described architecture model is not perfect, it has a lot of bottlenecks like local requests and waiting for the results to be retrieved from celery. If i will be asked to repeat the job and have more time for the preparations i will use more optimized cli tools like [osrm-backend](https://github.com/Project-OSRM/osrm-backend) or [valhalla](https://github.com/valhalla/valhalla) but in the end, the job was successfully completed and in a short period of time - just 18 days. Hope you liked these articles and stay tuned for the next ones!