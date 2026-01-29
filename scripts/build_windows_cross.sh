#!/bin/bash
set -e

# Usage: ./scripts/build_windows_cross.sh [vulkan] [clean]

BACKEND=$1
CLEAN=$2

# Handle arguments
if [ "$BACKEND" == "clean" ]; then
    CLEAN="clean"
    BACKEND="cpu"
fi

if [ -z "$BACKEND" ]; then
    BACKEND="cpu"
fi

BUILD_DIR="build-windows-cross-$BACKEND"

# Check for MinGW
if ! command -v x86_64-w64-mingw32-gcc &> /dev/null; then
    echo "Error: MinGW-w64 toolchain not found."
    echo "Please install it (e.g., 'sudo apt install mingw-w64' or 'brew install mingw-w64')."
    exit 1
fi

if [ "$CLEAN" == "clean" ]; then
    rm -rf "$BUILD_DIR"
fi

mkdir -p "$BUILD_DIR"

# Generate Toolchain File
TOOLCHAIN_FILE="$(pwd)/$BUILD_DIR/toolchain.cmake"
cat > "$TOOLCHAIN_FILE" <<EOF
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR x86_64)

set(CMAKE_C_COMPILER x86_64-w64-mingw32-gcc)
set(CMAKE_CXX_COMPILER x86_64-w64-mingw32-g++)
set(CMAKE_RC_COMPILER x86_64-w64-mingw32-windres)

set(CMAKE_FIND_ROOT_PATH /usr/x86_64-w64-mingw32)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
EOF

CMAKE_ARGS="-DCMAKE_TOOLCHAIN_FILE=$TOOLCHAIN_FILE -DCMAKE_BUILD_TYPE=Release -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF -DCMAKE_SHARED_LINKER_FLAGS='-s' -DBUILD_SHARED_LIBS=OFF -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=OFF -DGGML_OPENMP=OFF -DCMAKE_C_FLAGS='-D_WIN32_WINNT=0x0601' -DCMAKE_CXX_FLAGS='-D_WIN32_WINNT=0x0601'"

if [ "$BACKEND" == "vulkan" ]; then
    echo "Configuring for Vulkan..."
    # Check for Vulkan headers/libs. 
    # Users must provide paths if not in standard cross-compile paths.
    if [ -z "$VULKAN_SDK_PATH" ]; then
        echo "Warning: VULKAN_SDK_PATH is not set. The build might fail if Vulkan headers/libs are not found."
        echo "You can set it to the root of your Windows Vulkan SDK (containing Include and Lib)."
    else
         CMAKE_ARGS="$CMAKE_ARGS -DVulkan_INCLUDE_DIR=$VULKAN_SDK_PATH/Include -DVulkan_LIBRARY=$VULKAN_SDK_PATH/Lib/vulkan-1.lib"
    fi
    CMAKE_ARGS="$CMAKE_ARGS -DGGML_VULKAN=ON"
fi

echo "Building in $BUILD_DIR..."
cmake -S src/native -B "$BUILD_DIR" $CMAKE_ARGS
cmake --build "$BUILD_DIR" --config Release -j $(nproc 2>/dev/null || sysctl -n hw.logicalcpu)

# Output
DIST_DIR="windows/lib/x64"
mkdir -p "$DIST_DIR"
cp "$BUILD_DIR/libllama.dll" "$DIST_DIR/"
echo "Done. Artifact: $DIST_DIR/libllama.dll"
