#!/bin/bash

CONTAINER_NAME="ros2_jazzy_vnc"

docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true

echo "ROS 2 Jazzy desktop stopped."