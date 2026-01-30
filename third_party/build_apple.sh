#!/bin/bash
set -e

# build_apple.sh <platform> [clean]
# Example: ./build_apple.sh macos
# Example: ./build_apple.sh ios

PLATFORM=$1
CLEAN=$2

if [ "$PLATFORM" == "macos" ]; then
    echo "========================================"
    echo "Building for macOS (Universal) via src/native..."
    echo "========================================"
    BUILD_DIR="build-macos"
    if [ "$CLEAN" == "clean" ]; then rm -rf "$BUILD_DIR"; fi
    
    mkdir -p "$BUILD_DIR"
    # match Android: point to src/native, BUILD_SHARED_LIBS=OFF to link statically internally
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
      -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
      -DCMAKE_OSX_DEPLOYMENT_TARGET=10.15
    
    # We turned OFF BF16 because sometimes it causes issues on older targets, 
    # but you can enable it if targeting newer macOS only.
    
    cmake --build "$BUILD_DIR" --config Release -j $(sysctl -n hw.logicalcpu)
    
    # Artifacts
    # On macOS, we also need to combine all static libraries into one
    echo "Combining static libraries for macOS..."
    # Find all .a files, excluding our target output name if it exists
    LIBS=$(find "$BUILD_DIR" -name "*.a" ! -name "libllamadart.a")
    libtool -static -o "$BUILD_DIR/libllamadart.a" $LIBS

    ARCH=$(uname -m)
    if [ "$ARCH" == "aarch64" ]; then ARCH="arm64"; fi
    if [ "$ARCH" == "x86_64" ]; then ARCH="x64"; fi

    # Copy to both arm64 and x64 directories since it's a universal binary
    for A in arm64 x64; do
        DIR="bin/macos/$A"
        mkdir -p "$DIR"
        cp "$BUILD_DIR/libllamadart.a" "$DIR/libllamadart.a"
    done
    
    echo "macOS build complete: Universal libllamadart.a in bin/macos/"

elif [ "$PLATFORM" == "ios" ]; then
    echo "========================================"
    echo "Building for iOS..."
    echo "========================================"
    
    # Run the iOS build script from the current directory (third_party)
    ./build_ios_xcframework.sh
    
    echo "iOS build complete: static slices in bin/ios/"

else
    echo "Error: Invalid platform '$PLATFORM'. Use 'macos' or 'ios'."
    exit 1
fi
