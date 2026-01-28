#!/bin/bash
set -e

# build_linux.sh <backend> [clean]
# Example: ./scripts/build_linux.sh vulkan

BACKEND=$1
CLEAN=$2

BUILD_DIR="build-linux-$BACKEND"
if [ "$CLEAN" == "clean" ]; then rm -rf "$BUILD_DIR"; fi

CMAKE_ARGS="-DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_TOOLS=OFF"

if [ "$BACKEND" == "vulkan" ]; then
    echo "========================================"
    echo "Building for Linux (Vulkan)..."
    echo "========================================"
    CMAKE_ARGS="$CMAKE_ARGS -DGGML_VULKAN=ON"
    # Note: Assumes libvulkan-dev and glslc are installed (done in CI)
elif [ "$BACKEND" == "cuda" ]; then
    echo "========================================"
    echo "Building for Linux (CUDA)..."
    echo "========================================"
    CMAKE_ARGS="$CMAKE_ARGS -DGGML_CUDA=ON"
    # Note: Assumes CUDA toolkit is installed (done via container in CI)
else
    echo "Error: Invalid backend '$BACKEND'. Use 'vulkan' or 'cuda'."
    exit 1
fi

mkdir -p "$BUILD_DIR"
cmake -S src/native/llama_cpp -B "$BUILD_DIR" $CMAKE_ARGS
cmake --build "$BUILD_DIR" --config Release -j $(nproc 2>/dev/null || sysctl -n hw.logicalcpu)

# Artifact
ARCH=$(uname -m)
if [ "$ARCH" == "aarch64" ]; then ARCH="arm64"; fi
if [ "$ARCH" == "x86_64" ]; then ARCH="x64"; fi
OUTPUT_NAME="libllama_linux_${ARCH}_$BACKEND.so"
cp "$BUILD_DIR/bin/libllama.so" "./$OUTPUT_NAME" 2>/dev/null || cp "$BUILD_DIR/libllama.so" "./$OUTPUT_NAME"
echo "Linux build complete: $OUTPUT_NAME"
