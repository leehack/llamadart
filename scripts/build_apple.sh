#!/bin/bash
set -e

# build_apple.sh <platform> [clean]
# Example: ./scripts/build_apple.sh macos
# Example: ./scripts/build_apple.sh ios

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
    cmake -S src/native -B "$BUILD_DIR" \
      -DCMAKE_BUILD_TYPE=Release \
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
    MAC_FRAMEWORKS_DIR="macos/Frameworks"
    # Clean and recreate to ensure no leftovers (like libllama_cpp)
    rm -rf "$MAC_FRAMEWORKS_DIR"
    mkdir -p "$MAC_FRAMEWORKS_DIR"
    
    echo "Copying libraries to $MAC_FRAMEWORKS_DIR..."
    # We expect only libllama.dylib now from our top-level CMakeLists.txt
    cp "$BUILD_DIR/libllama.dylib" "$MAC_FRAMEWORKS_DIR/"
    
    echo "Patching dylib ID..."
    # Set ID to @rpath/libllama.dylib so it can be found when embedded
    install_name_tool -id "@rpath/libllama.dylib" "$MAC_FRAMEWORKS_DIR/libllama.dylib"
    
    # Verify
    otool -L "$MAC_FRAMEWORKS_DIR/libllama.dylib"
    
    echo "macOS build complete: $MAC_FRAMEWORKS_DIR/libllama.dylib"

elif [ "$PLATFORM" == "ios" ]; then
    echo "========================================"
    echo "Building for iOS (using llama.cpp/build-xcframework.sh)..."
    echo "========================================"
    
    LLAMA_CPP_DIR="src/native/llama_cpp"
    OUTPUT_DIR="ios/Frameworks"
    
    # Run the official script from its directory
    pushd "$LLAMA_CPP_DIR" > /dev/null
    ./build-xcframework.sh
    popd > /dev/null
    
    # Copy/Move the result to our expected location
    mkdir -p "$OUTPUT_DIR"
    rm -rf "$OUTPUT_DIR/llama.xcframework"
    # Copy without renaming
    cp -r "$LLAMA_CPP_DIR/build-apple/llama.xcframework" "$OUTPUT_DIR/llama.xcframework"
    
    echo "iOS XCFramework update complete: $OUTPUT_DIR/llama.xcframework"

else
    echo "Error: Invalid platform '$PLATFORM'. Use 'macos' or 'ios'."
    exit 1
fi
