#!/bin/bash
set -e

# build_linux.sh <backend> [clean]
# Example: ./scripts/build_linux.sh vulkan

BACKEND=$1
ARCH=$2
CLEAN=$3

# Default arch to host if not specified
if [ -z "$ARCH" ] || [ "$ARCH" == "clean" ]; then
    CLEAN=$ARCH
    ARCH=$(uname -m)
fi

BUILD_DIR="build-linux-$ARCH-$BACKEND"
if [ "$CLEAN" == "clean" ]; then rm -rf "$BUILD_DIR"; fi

CMAKE_ARGS="-DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_TOOLS=OFF -DGGML_CPU_ALL_VARIANTS=ON -DGGML_BACKEND_DL=ON"

# Cross-compilation setup
if [ "$ARCH" == "aarch64" ] || [ "$ARCH" == "arm64" ]; then
    TARGET_ARCH="arm64"
    if [ "$(uname -m)" != "aarch64" ] && [ "$(uname -m)" != "arm64" ]; then
        echo "Detected cross-compile for arm64..."
        if command -v aarch64-linux-gnu-gcc >/dev/null; then
            CMAKE_ARGS="$CMAKE_ARGS -DCMAKE_C_COMPILER=aarch64-linux-gnu-gcc -DCMAKE_CXX_COMPILER=aarch64-linux-gnu-g++ -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=aarch64"
        else
            echo "Warning: aarch64-linux-gnu-gcc not found. Building for host instead."
            TARGET_ARCH=$(uname -m)
        fi
    fi
elif [ "$ARCH" == "x86_64" ] || [ "$ARCH" == "x64" ]; then
    TARGET_ARCH="x64"
    if [ "$(uname -m)" != "x86_64" ]; then
         echo "Detected cross-compile for x64..."
         # Assuming x86_64-linux-gnu-gcc
         if command -v x86_64-linux-gnu-gcc >/dev/null; then
             CMAKE_ARGS="$CMAKE_ARGS -DCMAKE_C_COMPILER=x86_64-linux-gnu-gcc -DCMAKE_CXX_COMPILER=x86_64-linux-gnu-g++ -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=x86_64"
         fi
    fi
fi

if [ "$BACKEND" == "vulkan" ]; then
    echo "========================================"
    echo "Building for Linux ($TARGET_ARCH - Vulkan)..."
    echo "========================================"
    CMAKE_ARGS="$CMAKE_ARGS -DGGML_VULKAN=ON"
elif [ "$BACKEND" == "cuda" ]; then
    echo "========================================"
    echo "Building for Linux ($TARGET_ARCH - CUDA)..."
    echo "========================================"
    CMAKE_ARGS="$CMAKE_ARGS -DGGML_CUDA=ON"
else
    echo "Error: Invalid backend '$BACKEND'. Use 'vulkan' or 'cuda'."
    exit 1
fi

mkdir -p "$BUILD_DIR"
cmake -S src/native/llama_cpp -B "$BUILD_DIR" $CMAKE_ARGS
cmake --build "$BUILD_DIR" --config Release -j $(nproc 2>/dev/null || sysctl -n hw.logicalcpu)

# Artifact
OUTPUT_NAME="libllama_linux_${TARGET_ARCH}_$BACKEND.so"
cp "$BUILD_DIR/bin/libllama.so" "./$OUTPUT_NAME" 2>/dev/null || cp "$BUILD_DIR/libllama.so" "./$OUTPUT_NAME"
echo "Linux build complete: $OUTPUT_NAME"
