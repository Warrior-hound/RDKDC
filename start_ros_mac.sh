#!/bin/bash

set -e

CONTAINER_NAME="ros2_jazzy_vnc"
IMAGE_NAME="ros2-jazzy-vnc"
URL="http://localhost:6080/vnc_lite.html?autoconnect=true&resize=remote&quality=9&compression=0"

ARCH=$(uname -m)

if [ "$ARCH" = "arm64" ]; then
  PLATFORM="linux/arm64"
elif [ "$ARCH" = "x86_64" ]; then
  PLATFORM="linux/amd64"
else
  echo "Unsupported Mac architecture: $ARCH"
  exit 1
fi

# Detect Mac logical screen size
SCREEN_INFO=$(osascript -e 'tell application "Finder" to get bounds of window of desktop')
WIDTH=$(echo "$SCREEN_INFO" | awk -F',' '{print $3}' | tr -d ' ')
HEIGHT=$(echo "$SCREEN_INFO" | awk -F',' '{print $4}' | tr -d ' ')

# Slightly reduce height so Safari/tab/menu bars do not make it feel oversized
HEIGHT=$((HEIGHT - 120))

VNC_GEOMETRY="${WIDTH}x${HEIGHT}"

echo "Detected screen: ${WIDTH}x${HEIGHT}"
echo "Using VNC geometry: $VNC_GEOMETRY"

mkdir -p "$HOME/ros2_ws/src"

docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

docker run -d \
  --platform "$PLATFORM" \
  --name "$CONTAINER_NAME" \
  -e VNC_GEOMETRY="$VNC_GEOMETRY" \
  -p 127.0.0.1:6080:6080 \
  -p 127.0.0.1:5901:5901 \
  -v "$HOME/ros2_ws:/root/ros2_ws" \
  "$IMAGE_NAME"

echo "Starting ROS 2 Jazzy desktop..."

until curl -s http://localhost:6080 >/dev/null; do
  sleep 1
done

open "$URL"

echo "ROS 2 Jazzy desktop is running."
echo "Workspace on Mac: $HOME/ros2_ws"
echo "Workspace in Docker: /root/ros2_ws"
echo "To stop it: ./stop_ros_mac.sh"