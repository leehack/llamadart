#!/bin/bash
set -e

# build_apple.sh <target> [clean]
# Targets: macos-arm64, macos-x64, ios-device-arm64, ios-sim-arm64, ios-sim-x64

TARGET=$1
CLEAN=$2

if [[ "$TARGET" == macos-* ]]; then
    ARCH=${TARGET#macos-}
    echo "========================================"
    echo "Building for macOS ($ARCH)..."
    echo "========================================"
    BUILD_DIR="build-macos-$ARCH"
    if [ "$CLEAN" == "clean" ]; then rm -rf "$BUILD_DIR"; fi
    
    mkdir -p "$BUILD_DIR"
    cmake -G Ninja -S . -B "$BUILD_DIR" \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON \
      -DBUILD_SHARED_LIBS=OFF \
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
      -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0
    
    cmake --build "$BUILD_DIR" --config Release -j $(sysctl -n hw.logicalcpu)
    
    # Merge static libraries
    echo "Combining static libraries for macOS..."
    LIBS=$(find "$BUILD_DIR" -name "*.a" ! -name "libllamadart.a")
    
    DIR="bin/macos/$ARCH"
    mkdir -p "$DIR"
    libtool -static -o "$DIR/libllamadart.a" ${LIBS} 2> /dev/null

    echo "macOS build complete: $DIR/libllamadart.a"

elif [[ "$TARGET" == ios-* ]]; then
    if [ "$TARGET" == "ios-device-arm64" ]; then
        SDK="iphoneos"
        ARCH="arm64"
        OUT_NAME="libllamadart-ios-arm64.a"
    elif [ "$TARGET" == "ios-sim-arm64" ]; then
        SDK="iphonesimulator"
        ARCH="arm64"
        OUT_NAME="libllamadart-ios-arm64-sim.a"
    elif [ "$TARGET" == "ios-sim-x64" ]; then
        SDK="iphonesimulator"
        ARCH="x86_64"
        OUT_NAME="libllamadart-ios-x64-sim.a"
    else
        echo "Error: Invalid iOS target '$TARGET'"
        exit 1
    fi

    echo "========================================"
    echo "Building for iOS ($TARGET)..."
    echo "========================================"
    
    ./build_ios_static.sh "$SDK" "$ARCH" "$OUT_NAME" "$CLEAN"
    
    echo "iOS build complete: bin/ios/$OUT_NAME"

else
    echo "Error: Invalid target '$TARGET'. Use 'macos-arm64', 'macos-x64', or 'ios-*'."
    exit 1
fi
