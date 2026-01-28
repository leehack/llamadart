#!/bin/bash
set -e

# build_android.sh <ABI> [clean]
# Example: ./scripts/build_android.sh arm64-v8a

ABI=${1:-"arm64-v8a"}
CLEAN=$2

# 1. NDK Selection
if [ -z "$ANDROID_NDK_HOME" ]; then
    POSSIBLE_NDKS=(
        "$HOME/Library/Android/sdk/ndk/26.3.11579264"
        "$HOME/Library/Android/sdk/ndk/27.0.12077973"
        "$HOME/Library/Android/sdk/ndk/25.1.8937393"
        "/usr/local/lib/android/sdk/ndk-bundle" # Common in CI
    )
    for ndk in "${POSSIBLE_NDKS[@]}"; do
        if [ -d "$ndk" ]; then
            export ANDROID_NDK_HOME="$ndk"
            break
        fi
    done
fi

if [ -z "$ANDROID_NDK_HOME" ]; then
    echo "Error: ANDROID_NDK_HOME not set and could not be auto-detected."
    exit 1
fi
echo "Using NDK: $ANDROID_NDK_HOME"

# 2. Cleanup
BUILD_DIR="build-android-$ABI"
if [ "$CLEAN" == "clean" ]; then
    rm -rf "$BUILD_DIR" android-host-toolchain.cmake
fi

# 3. Create Host Toolchain for Vulkan Shaders
OS_NAME=$(uname)
echo "set(CMAKE_MAKE_PROGRAM \"$(which make)\" CACHE STRING \"make program\" FORCE)" > android-host-toolchain.cmake
echo "set(CMAKE_SYSTEM_NAME \"$OS_NAME\")" >> android-host-toolchain.cmake
echo "set(Threads_FOUND TRUE)" >> android-host-toolchain.cmake
echo "set(CMAKE_THREAD_LIBS_INIT \"-pthread\")" >> android-host-toolchain.cmake
echo "set(CMAKE_USE_PTHREADS_INIT TRUE)" >> android-host-toolchain.cmake

# 4. Find Vulkan paths in NDK
# Find glslc
GLSLC=$(find $ANDROID_NDK_HOME -name glslc | head -n 1)
if [ -z "$GLSLC" ]; then
    echo "Warning: glslc not found in NDK. Vulkan shaders might fail."
fi

# Find libvulkan.so for the target ABI
# NDK paths use different names than the ABI (e.g. aarch64 for arm64-v8a)
ARCH_PATTERN=$ABI
if [ "$ABI" == "arm64-v8a" ]; then ARCH_PATTERN="aarch64"; fi
if [ "$ABI" == "armeabi-v7a" ]; then ARCH_PATTERN="arm-linux-androideabi"; fi
if [ "$ABI" == "x86_64" ]; then ARCH_PATTERN="x86_64"; fi
if [ "$ABI" == "x86" ]; then ARCH_PATTERN="i686"; fi

VULKAN_LIB=$(find "$ANDROID_NDK_HOME" -name "libvulkan.so" | grep "$ARCH_PATTERN" | head -n 1)
if [ -z "$VULKAN_LIB" ]; then
    echo "Error: libvulkan.so not found for ABI $ABI (pattern $ARCH_PATTERN)"
    exit 1
fi
echo "Found libvulkan: $VULKAN_LIB"

# Use Vulkan headers from submodule
VULKAN_INC_DIR="$(pwd)/src/native/Vulkan-Headers/include"
if [ ! -d "$VULKAN_INC_DIR/vulkan" ]; then
    echo "Error: Vulkan-Headers submodule not found. Run: git submodule update --init src/native/Vulkan-Headers"
    exit 1
fi

# 5. Build
mkdir -p "$BUILD_DIR"
cmake -S src/native/llama_cpp -B "$BUILD_DIR" \
  -DCMAKE_TOOLCHAIN_FILE=$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake \
  -DANDROID_ABI=$ABI \
  -DANDROID_PLATFORM=android-23 \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=ON \
  -DLLAMA_BUILD_COMMON=OFF \
  -DLLAMA_BUILD_TESTS=OFF \
  -DLLAMA_BUILD_EXAMPLES=OFF \
  -DLLAMA_BUILD_SERVER=OFF \
  -DLLAMA_BUILD_TOOLS=OFF \
  -DGGML_VULKAN=ON \
  -DGGML_BACKEND_DL=ON \
  -DGGML_CPU_ARM_ARCH=armv8.5-a+fp16+i8mm \
  -DVulkan_LIBRARY="$VULKAN_LIB" \
  -DVulkan_INCLUDE_DIR="$VULKAN_INC_DIR" \
  -DVulkan_GLSLC_EXECUTABLE="$GLSLC" \
  -DGGML_VULKAN_SHADERS_GEN_TOOLCHAIN=$(pwd)/android-host-toolchain.cmake

cmake --build "$BUILD_DIR" --config Release -j $(nproc 2>/dev/null || sysctl -n hw.logicalcpu)

# 6. Artifact management
OUTPUT_NAME="libllama_android_$ABI.so"
cp "$BUILD_DIR/bin/libllama.so" "./$OUTPUT_NAME" 2>/dev/null || cp "$BUILD_DIR/libllama.so" "./$OUTPUT_NAME"
echo "Android build complete: $OUTPUT_NAME"
