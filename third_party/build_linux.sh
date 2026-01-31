#!/bin/bash
set -e

# build_linux.sh <backend> [clean]
# Example: ./build_linux.sh vulkan

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

CMAKE_ARGS="-DCMAKE_BUILD_TYPE=Release -DCMAKE_SHARED_LINKER_FLAGS='-s' -DBUILD_SHARED_LIBS=OFF -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_TOOLS=OFF"

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
elif [ "$BACKEND" == "cpu" ]; then
    echo "========================================"
    echo "Building for Linux ($TARGET_ARCH - CPU)..."
    echo "========================================"
    CMAKE_ARGS="$CMAKE_ARGS -DGGML_VULKAN=OFF"
else
    echo "Error: Invalid backend '$BACKEND'. Use 'vulkan' or 'cpu'."
    exit 1
fi

mkdir -p "$BUILD_DIR"
# Point to src/native (parent of llama_cpp)
cmake -S . -B "$BUILD_DIR" $CMAKE_ARGS
cmake --build "$BUILD_DIR" --config Release -j $(nproc 2>/dev/null || sysctl -n hw.logicalcpu)

    # Artifacts
    LIB_DIR="bin/linux/$TARGET_ARCH"

# Clean and recreate to ensure no leftovers
rm -rf "$LIB_DIR"
mkdir -p "$LIB_DIR"

echo "Copying libraries to $LIB_DIR (cleaning leftovers)..."
# Copy our consolidated library
cp -L "$BUILD_DIR/libllamadart.so" "$LIB_DIR/libllamadart.so" 2>/dev/null || \
find "$BUILD_DIR" -name "libllamadart.so" -exec cp -L {} "$LIB_DIR/libllamadart.so" \;

echo "Linux build complete for $TARGET_ARCH: $LIB_DIR"
