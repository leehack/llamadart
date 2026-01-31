#!/bin/bash
set -e

# build_android.sh <ABI> [clean]
# Example: ./build_android.sh arm64-v8a

# Determine ABIs to build
if [ "$1" == "all" ]; then
    ABIS=("arm64-v8a" "x86_64")
    CLEAN=$2
else
    ABIS=("${1:-"arm64-v8a"}")
    CLEAN=$2
fi

# 1. NDK Selection (run once)
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

# Loop through ABIs
for ABI in "${ABIS[@]}"; do
    echo "========================================"
    echo "Building for Android ABI: $ABI"
    echo "========================================"

    # 2. Cleanup
    BUILD_DIR="build-android-$ABI"
    if [ "$CLEAN" == "clean" ]; then
        rm -rf "$BUILD_DIR" android-host-toolchain-$ABI.cmake
    fi

    # 3. Create Host Toolchain for Vulkan Shaders
    OS_NAME=$(uname)
    # Use absolute path for toolchain file to avoid issues with sub-projects
    TOOLCHAIN_FILE="$(pwd)/$BUILD_DIR/android-host-toolchain.cmake"
    mkdir -p "$BUILD_DIR"

    # Detect make program to use for host toolchain
    MAKE_PROG=$(which ninja 2>/dev/null || which make 2>/dev/null)
    echo "set(CMAKE_MAKE_PROGRAM \"$MAKE_PROG\" CACHE STRING \"make program\" FORCE)" > "$TOOLCHAIN_FILE"
    echo "set(CMAKE_SYSTEM_NAME \"$OS_NAME\")" >> "$TOOLCHAIN_FILE"
    echo "set(Threads_FOUND TRUE)" >> "$TOOLCHAIN_FILE"
    echo "set(CMAKE_THREAD_LIBS_INIT \"-pthread\")" >> "$TOOLCHAIN_FILE"
    echo "set(CMAKE_USE_PTHREADS_INIT TRUE)" >> "$TOOLCHAIN_FILE"

    # 4. Find Vulkan paths in NDK
    # Find glslc
    GLSLC=$(find $ANDROID_NDK_HOME -name glslc | head -n 1)
    if [ -z "$GLSLC" ]; then
        echo "Warning: glslc not found in NDK. Vulkan shaders might fail."
    fi

    # Find libvulkan.so for the target ABI
    # NDK paths use different names than the ABI (e.g. aarch64 for arm64-v8a)
    if [ "$ABI" == "arm64-v8a" ]; then
        ARCH_PATH="aarch64-linux-android"
    elif [ "$ABI" == "x86_64" ]; then
        ARCH_PATH="x86_64-linux-android"
    elif [ "$ABI" == "x86" ]; then
        ARCH_PATH="i686-linux-android"
    else
        ARCH_PATH="$ABI"
    fi

    # Look for libvulkan.so in the sysroot libs for the target architecture
    VULKAN_LIB=$(find "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt" -path "*/sysroot/usr/lib/$ARCH_PATH/*/libvulkan.so" | head -n 1)
    if [ -z "$VULKAN_LIB" ]; then
        # Fallback to broader search if specific structure not found
        VULKAN_LIB=$(find "$ANDROID_NDK_HOME" -name "libvulkan.so" | grep "/$ARCH_PATH/" | head -n 1)
    fi

    if [ -z "$VULKAN_LIB" ]; then
        echo "Error: libvulkan.so not found for ABI $ABI (path segment $ARCH_PATH)"
        exit 1
    fi
    echo "Found libvulkan: $VULKAN_LIB"

    # Use Vulkan headers from submodule
    VULKAN_INC_DIR="$(pwd)/Vulkan-Headers/include"
    if [ ! -d "$VULKAN_INC_DIR/vulkan" ]; then
        echo "Error: Vulkan-Headers submodule not found. Run: git submodule update --init Vulkan-Headers"
        exit 1
    fi

    # 5. Build
    # Note: explicit CPU flags might need adjustment for x86_64 if we were targeting AVX, but for Android usually defaults are okay or handled by ABI.
    # For ARM, we keep the specific flags.
    EXTRA_CMAKE_ARGS=""
    if [ "$ABI" == "arm64-v8a" ]; then
        EXTRA_CMAKE_ARGS="-DGGML_CPU_ARM_ARCH=armv8.5-a+fp16+i8mm"
    fi
    
    VULKAN_ENABLED="ON"
    
    cmake -G Ninja -S . -B "$BUILD_DIR" \
      -DCMAKE_TOOLCHAIN_FILE=$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake \
      -DANDROID_ABI=$ABI \
      -DANDROID_PLATFORM=android-23 \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON \
      -DCMAKE_SHARED_LINKER_FLAGS="-s" \
      -DBUILD_SHARED_LIBS=OFF \
      -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
      -DLLAMA_BUILD_COMMON=OFF \
      -DLLAMA_BUILD_TESTS=OFF \
      -DLLAMA_BUILD_EXAMPLES=OFF \
      -DLLAMA_BUILD_SERVER=OFF \
      -DLLAMA_BUILD_TOOLS=OFF \
      -DGGML_OPENMP=OFF \
      -DGGML_LLAMAFILE=OFF \
      -DGGML_VULKAN=$VULKAN_ENABLED \
      -DGGML_VULKAN_DEBUG=OFF \
      -DGGML_BACKEND_DL=OFF \
      $EXTRA_CMAKE_ARGS \
      -DVulkan_LIBRARY="$VULKAN_LIB" \
      -DVulkan_INCLUDE_DIR="$VULKAN_INC_DIR" \
      -DVulkan_GLSLC_EXECUTABLE="$GLSLC" \
      -DGGML_VULKAN_SHADERS_GEN_TOOLCHAIN="$TOOLCHAIN_FILE"

    cmake --build "$BUILD_DIR" -j $(nproc 2>/dev/null || sysctl -n hw.logicalcpu)

    # 6. Artifact management
    if [ "$ABI" == "arm64-v8a" ]; then
        TARGET_ARCH="arm64"
    elif [ "$ABI" == "x86_64" ]; then
        TARGET_ARCH="x64"
    else
        TARGET_ARCH="$ABI"
    fi
    JNI_LIBS_DIR="bin/android/$TARGET_ARCH"
    # Clean and recreate to ensure no leftovers
    rm -rf "$JNI_LIBS_DIR"
    mkdir -p "$JNI_LIBS_DIR"

    echo "Copying libraries to $JNI_LIBS_DIR (cleaning leftovers)..."
    # Copy our consolidated library
    cp -L "$BUILD_DIR/libllamadart.so" "$JNI_LIBS_DIR/libllamadart.so" 2>/dev/null || \
    find "$BUILD_DIR" -name "libllamadart.so" -exec cp -L {} "$JNI_LIBS_DIR/libllamadart.so" \;

    echo "Android build complete: $ABI binaries in $JNI_LIBS_DIR"
done
