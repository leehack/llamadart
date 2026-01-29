#!/bin/bash
set -e

# build_windows_docker.sh
# Builds libllama.dll for Windows (x64) using Docker (MinGW + Vulkan SDK)

PROJECT_ROOT=$(pwd)
IMAGE_NAME="llamadart_windows_builder"

echo "========================================"
echo "Building for Windows (x64) via Docker"
echo "========================================"
echo "PROJECT_ROOT: $PROJECT_ROOT"

# 1. Build the Docker image
echo "Step 1: Building Docker image ($IMAGE_NAME)..."
docker build --platform linux/amd64 -t "$IMAGE_NAME" -f scripts/Dockerfile.linux .

# 2. Run the build inside the container
echo "Step 2: compiling inside container..."
echo "Step 3: Running build container..."

# We set VULKAN_SDK_PATH to the location where we extracted it in the Dockerfile
# We also pass 'vulkan' and 'clean' arguments to the internal script
ID=$(docker create --platform linux/amd64 -v "$PROJECT_ROOT:/app" -e VULKAN_SDK_PATH="/opt/windows-vulkan" "$IMAGE_NAME" /bin/bash -c "
  set -e
  ./scripts/build_windows_cross.sh vulkan clean
")

docker start -a "$ID"

# 3. Copy artifacts out
echo "Step 4: Copying artifacts..."
mkdir -p windows/lib/x64
# Attempt to find the built dll (it might be in build-windows-cross-vulkan)
docker cp "$ID":/app/windows/lib/x64/libllama.dll windows/lib/x64/libllama.dll

# 4. Cleanup
echo "Step 5: Cleanup..."
docker rm "$ID"

echo "Windows Docker build complete: windows/lib/x64/libllama.dll"
