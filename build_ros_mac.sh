#!/bin/bash

set -e

IMAGE_NAME="ros2-jazzy-vnc"

ARCH=$(uname -m)

if [ "$ARCH" = "arm64" ]; then
  PLATFORM="linux/arm64"
elif [ "$ARCH" = "x86_64" ]; then
  PLATFORM="linux/amd64"
else
  echo "Unsupported Mac architecture: $ARCH"
  exit 1
fi

echo "Detected Mac architecture: $ARCH"
echo "Using Docker platform: $PLATFORM"

docker build \
  --platform "$PLATFORM" \
  -t "$IMAGE_NAME" .

echo "Build complete."