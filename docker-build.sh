#!/bin/sh

if [ -z "$(command -v docker)" ] ; then
	echo "Docker is not installed."
	exit 2
fi
if [ -z "$(docker images | awk '{print $1}' | grep alpine-composer)" ] ; then
	docker build -t alpine-composer .
fi

docker run --rm -v $(pwd):/alpine-composer -t alpine-composer