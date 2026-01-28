#!/bin/bash
set -e

# verify_linux_docker.sh
# Validates the modular Linux build script using a Docker container.

# Get the project root
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "========================================"
echo "Validating Linux Build with Docker"
echo "========================================"

# 1. Build the Docker image
echo "Step 1: Building Docker image (llama_dart_linux_builder)..."
docker build -t llama_dart_linux_builder -f "$SCRIPT_DIR/Dockerfile.linux" "$SCRIPT_DIR"

# 2. Run the modular build script inside the container
echo "Step 2: Running scripts/build_linux.sh vulkan in Docker..."
docker run --rm \
  -v "$PROJECT_ROOT:/app" \
  llama_dart_linux_builder \
  bash -c "cd /app && ./scripts/build_linux.sh vulkan clean"

# 3. Verify artifact existence in the host
ARCH=$(uname -m)
if [ "$ARCH" == "aarch64" ]; then ARCH="arm64"; fi
if [ "$ARCH" == "x86_64" ]; then ARCH="x64"; fi
ARTIFACT="libllama_linux_${ARCH}_vulkan.so"
if [ -f "$PROJECT_ROOT/$ARTIFACT" ]; then
    echo "========================================"
    echo "SUCCESS: $ARTIFACT found!"
    echo "Linux build validated with Docker."
    echo "========================================"
else
    echo "========================================"
    echo "ERROR: $ARTIFACT NOT found!"
    echo "Docker validation failed."
    echo "========================================"
    exit 1
fi
