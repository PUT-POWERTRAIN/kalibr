#!/bin/bash
xhost +local:docker

docker run --rm -it \
  --name oak_humble \
  --privileged \
  --net=host \
  --ipc=host \
  --shm-size=2g \
  -e DISPLAY=$DISPLAY \
  -v /tmp/.X11-unix:/tmp/.X11-unix \
  -v /dev/bus/usb:/dev/bus/usb \
  --device-cgroup-rule='c 189:* rmw' \
  --device /dev/dri:/dev/dri \
  -v "$(pwd)/data:/data" \
  oakd-stable-humble bash
