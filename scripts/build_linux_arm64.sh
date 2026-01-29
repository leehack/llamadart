#!/bin/bash
set -e

# build_linux_arm64.sh
# Builds libllama.so for Linux ARM64 using Docker (ghcr.io/cirruslabs/flutter)

PROJECT_ROOT=$(pwd)
IMAGE_NAME="llamadart_linux_arm64_builder"

echo "========================================"
echo "Building for Linux (ARM64) via Docker"
echo "========================================"
echo "PROJECT_ROOT: $PROJECT_ROOT"

# 1. Build the Docker image (if not already built)
# We use the same Dockerfile.linux, just passing the platform
echo "Step 1: Building Docker image ($IMAGE_NAME) for platform linux/arm64..."
docker build --platform linux/arm64 -t "$IMAGE_NAME" -f scripts/Dockerfile.linux .

# 2. Run the build inside the container
echo "Step 2: compiling inside container..."
echo "Step 3: Running build container..."

ID=$(docker create --platform linux/arm64 -v "$PROJECT_ROOT:/app" "$IMAGE_NAME" /bin/bash -c "
  set -e
  rm -rf build-linux-arm64
  mkdir -p build-linux-arm64
  cmake -S src/native -B build-linux-arm64 \
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
    
  cmake --build build-linux-arm64 --config Release -j \$(nproc)
")

docker start -a "$ID"

# 3. Copy artifacts out
echo "Step 4: Copying artifacts..."
mkdir -p linux/lib/arm64
docker cp "$ID":/app/build-linux-arm64/libllama.so linux/lib/arm64/libllama.so

# 4. Cleanup
echo "Step 5: Cleanup..."
docker rm "$ID"

echo "Linux ARM64 build complete: linux/lib/arm64/libllama.so"
