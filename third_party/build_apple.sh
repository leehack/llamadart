#!/bin/bash
set -e

# build_apple.sh <target> [clean]
# Targets: macos-arm64, macos-x86_64, ios-device-arm64, ios-sim-arm64, ios-sim-x86_64

TARGET=$1
CLEAN=$2

IOS_MIN_OS_VERSION=16.4
MACOS_MIN_OS_VERSION=11.0

# Helper function to build for a specific configuration
build_target() {
    local TYPE=$1 # STATIC or SHARED
    local BUILD_DIR=$2
    local OUT_NAME=$3
    local ARCH=$4
    local SDK=$5
    local EXTRA_ARGS=$6
    local DEP_TARGET=$7

    echo "--- Building $OUT_NAME ($ARCH, $TYPE) ---"
    
    local SHARED_FLAG="OFF"
    if [ "$TYPE" == "SHARED" ]; then SHARED_FLAG="ON"; fi

    cmake -G Ninja -S . -B "$BUILD_DIR" \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON \
      -DLLAMADART_SHARED=$SHARED_FLAG \
      -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
      -DLLAMA_BUILD_COMMON=OFF \
      -DLLAMA_BUILD_TESTS=OFF \
      -DLLAMA_BUILD_EXAMPLES=OFF \
      -DLLAMA_BUILD_SERVER=OFF \
      -DLLAMA_BUILD_TOOLS=OFF \
      -DGGML_METAL=ON \
      -DGGML_METAL_USE_BF16=OFF \
      -DGGML_METAL_EMBED_LIBRARY=ON \
      -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
      -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEP_TARGET" \
      -DGGML_NATIVE=OFF \
      $EXTRA_ARGS
    
    cmake --build "$BUILD_DIR" --config Release -j $(sysctl -n hw.logicalcpu)
    
    # Merge/Copy artifacts
    mkdir -p "$(dirname "$OUT_NAME")"
    if [ "$TYPE" == "STATIC" ]; then
        echo "Merging static libraries..."
        LIBS=$(find "$BUILD_DIR" -name "*.a" ! -name "libllamadart.a")
        libtool -static -o "$OUT_NAME" ${LIBS} 2> /dev/null
    else
        # Shared library (.dylib)
        cp "$BUILD_DIR/libllamadart.dylib" "$OUT_NAME"
    fi
}

if [[ "$TARGET" == macos-* ]]; then
    ARCH=${TARGET#macos-}
    if [ "$ARCH" == "x64" ]; then ARCH="x86_64"; fi
    echo "========================================"
    echo "Building for macOS ($ARCH)..."
    echo "========================================"
    
    # Build both Static and Shared for macOS
    build_target "STATIC" "build-macos-$ARCH-static" "bin/macos/$ARCH/libllamadart.a" "$ARCH" "" "" "$MACOS_MIN_OS_VERSION"
    build_target "SHARED" "build-macos-$ARCH-shared" "bin/macos/$ARCH/libllamadart.dylib" "$ARCH" "" "" "$MACOS_MIN_OS_VERSION"
    
    echo "macOS build complete for $ARCH"

elif [[ "$TARGET" == ios-* ]]; then
    if [ "$TARGET" == "ios-device-arm64" ]; then
        SDK="iphoneos"
        ARCH="arm64"
        OUT_BASE="bin/ios/libllamadart-ios-arm64"
    elif [ "$TARGET" == "ios-sim-arm64" ]; then
        SDK="iphonesimulator"
        ARCH="arm64"
        OUT_BASE="bin/ios/libllamadart-ios-arm64-sim"
    elif [ "$TARGET" == "ios-sim-x86_64" ] || [ "$TARGET" == "ios-sim-x64" ]; then
        SDK="iphonesimulator"
        ARCH="x86_64"
        OUT_BASE="bin/ios/libllamadart-ios-x86_64-sim"
    else
        echo "Error: Invalid iOS target '$TARGET'"
        exit 1
    fi

    echo "========================================"
    echo "Building for iOS ($TARGET)..."
    echo "========================================"
    
    EXTRA_IOS_ARGS="-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=$SDK -DIOS=ON -DLLAMA_OPENSSL=OFF"
    
    # Build both Static and Shared for iOS
    build_target "STATIC" "build-ios-$TARGET-static" "${OUT_BASE}.a" "$ARCH" "$SDK" "$EXTRA_IOS_ARGS" "$IOS_MIN_OS_VERSION"
    build_target "SHARED" "build-ios-$TARGET-shared" "${OUT_BASE}.dylib" "$ARCH" "$SDK" "$EXTRA_IOS_ARGS" "$IOS_MIN_OS_VERSION"
    
    echo "iOS build complete for $TARGET"

else
    echo "Error: Invalid target '$TARGET'. Use 'macos-arm64', 'macos-x86_64', or 'ios-*'."
    exit 1
fi
