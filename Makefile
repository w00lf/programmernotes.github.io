deploy:
	yarn run deploy && ls | grep -v public | xargs rm -r && mv public/* . && git commit -m $(message) && git push