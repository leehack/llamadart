#!/bin/bash
set -e

# build_linux_x64.sh
# Builds the Linux x86_64 library using Docker (via emulation on macOS if necessary).

echo "========================================"
echo "Building for Linux (x86_64/AMD64) via Docker"
echo "========================================"

IMAGE_NAME="llamadart_linux_x64_builder"
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DOCKERFILE="$SCRIPT_DIR/Dockerfile.linux"
echo "PROJECT_ROOT: $PROJECT_ROOT"

# 1. Build Docker image for linux/amd64
echo "Step 1: Building Docker image ($IMAGE_NAME) for platform linux/amd64..."
docker build --platform linux/amd64 -t "$IMAGE_NAME" -f "$DOCKERFILE" "$SCRIPT_DIR"

# 2. Run container to build and extract artifacts
echo "Step 2: compiling inside container..."
# We map the current directory to /app
# We run a build command inside.
# Note: We need to output the library to a mapped volume or copy it out.
# Using a temp container to copying is easier.

ID=$(docker create --platform linux/amd64 -v "$PROJECT_ROOT:/app" "$IMAGE_NAME" /bin/bash -c "
  set -e
  rm -rf build-linux-x64
  mkdir -p build-linux-x64
  cmake -S src/native -B build-linux-x64 \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF \
    -DCMAKE_SHARED_LINKER_FLAGS='-s' \
    -DBUILD_SHARED_LIBS=OFF \
    -DLLAMA_BUILD_COMMON=OFF \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_SERVER=OFF \
    -DLLAMA_BUILD_TOOLS=OFF \
    -DGGML_VULKAN=ON \
    -DGGML_OPENMP=OFF \
    -DGGML_BACKEND_DL=OFF
    
  cmake --build build-linux-x64 --config Release -j 4
  
  # Prepare output
  mkdir -p /export
  cp build-linux-x64/libllama.so /export/
")

echo "Step 3: Running build container..."
docker start -a "$ID"

echo "Step 4: Copying artifacts..."
mkdir -p linux/lib/x64
docker cp "$ID":/export/libllama.so linux/lib/x64/libllama.so

echo "Step 5: Cleanup..."
docker rm "$ID"
echo "Linux x64 build complete: linux/lib/x64/libllama.so"
