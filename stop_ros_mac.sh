#!/usr/bin/env bash

set -euo pipefail

docker rm -f rdkdc_ros2_jazzy >/dev/null 2>&1 || true

echo "RDKDC ROS 2 Jazzy Docker container stopped."
