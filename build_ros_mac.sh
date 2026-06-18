#!/usr/bin/env bash

set -euo pipefail

IMAGE_NAME="ros2-jazzy-vnc"

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker was not found. Install Docker Desktop for Mac, start it, then reopen Terminal." >&2
  exit 1
fi

case "$(uname -m)" in
  arm64|aarch64)
    PLATFORM="linux/arm64"
    ;;
  x86_64|amd64)
    PLATFORM="linux/amd64"
    ;;
  *)
    echo "Unsupported Mac architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

echo "Detected Docker platform: $PLATFORM"
echo "Building $IMAGE_NAME..."

docker build --platform "$PLATFORM" -t "$IMAGE_NAME" .

echo "Build complete."
