#!/bin/bash
set -e

# build_apple.sh <platform> [clean]
# Example: ./scripts/build_apple.sh macos
# Example: ./scripts/build_apple.sh ios

PLATFORM=$1
CLEAN=$2

if [ "$PLATFORM" == "macos" ]; then
    echo "========================================"
    echo "Building for macOS (Universal)..."
    echo "========================================"
    BUILD_DIR="build-macos"
    if [ "$CLEAN" == "clean" ]; then rm -rf "$BUILD_DIR"; fi
    
    mkdir -p "$BUILD_DIR"
    cmake -S src/native/llama_cpp -B "$BUILD_DIR" \
      -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_SHARED_LIBS=ON \
      -DLLAMA_BUILD_COMMON=OFF \
      -DLLAMA_BUILD_TESTS=OFF \
      -DLLAMA_BUILD_EXAMPLES=OFF \
      -DLLAMA_BUILD_SERVER=OFF \
      -DLLAMA_BUILD_TOOLS=OFF \
      -DGGML_METAL=ON \
      -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64"
    
    cmake --build "$BUILD_DIR" --config Release -j $(sysctl -n hw.logicalcpu)
    
    # Artifact
    cp "$BUILD_DIR/bin/libllama.dylib" ./libllama_macos_universal.dylib 2>/dev/null || cp "$BUILD_DIR/libllama.dylib" ./libllama_macos_universal.dylib
    echo "macOS build complete: libllama_macos_universal.dylib"

elif [ "$PLATFORM" == "ios" ]; then
    echo "========================================"
    echo "Building for iOS (XCFramework)..."
    echo "========================================"
    
    BASE_BUILD_DIR="/tmp/llamadart_build_ios"
    OUTPUT_DIR="ios/Frameworks"
    LLAMA_CPP_DIR="src/native/llama_cpp"
    
    # Clean
    rm -rf "$BASE_BUILD_DIR"
    rm -rf "$OUTPUT_DIR/llama_cpp.xcframework"
    mkdir -p "$BASE_BUILD_DIR/device" "$BASE_BUILD_DIR/sim-arm64" "$BASE_BUILD_DIR/sim-x86"
    mkdir -p "$OUTPUT_DIR"
    
    # 1. Build for Device (arm64)
    echo "Building for iOS Device (arm64)..."
    cmake -S "$LLAMA_CPP_DIR" -B "$BASE_BUILD_DIR/device" -G Xcode \
      -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_ARCHITECTURES=arm64 \
      -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
      -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
      -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_TOOLS=OFF -DGGML_METAL=ON \
      -DGGML_METAL_EMBED_LIBRARY=ON -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO
    cmake --build "$BASE_BUILD_DIR/device" --config Release --target llama --target ggml -- -allowProvisioningUpdates CODE_SIGNING_ALLOWED=NO

    # 2. Build for Simulator (arm64)
    echo "Building for iOS Simulator (arm64)..."
    cmake -S "$LLAMA_CPP_DIR" -B "$BASE_BUILD_DIR/sim-arm64" -G Xcode \
      -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphonesimulator -DCMAKE_OSX_ARCHITECTURES=arm64 \
      -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
      -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
      -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_TOOLS=OFF -DGGML_METAL=ON \
      -DGGML_METAL_EMBED_LIBRARY=ON -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO
    cmake --build "$BASE_BUILD_DIR/sim-arm64" --config Release --target llama --target ggml -- -allowProvisioningUpdates CODE_SIGNING_ALLOWED=NO

    # 3. Build for Simulator (x86_64)
    echo "Building for iOS Simulator (x86_64)..."
    cmake -S "$LLAMA_CPP_DIR" -B "$BASE_BUILD_DIR/sim-x86" -G Xcode \
      -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphonesimulator -DCMAKE_OSX_ARCHITECTURES=x86_64 \
      -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
      -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
      -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_TOOLS=OFF -DGGML_METAL=ON \
      -DGGML_METAL_EMBED_LIBRARY=ON -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO
    cmake --build "$BASE_BUILD_DIR/sim-x86" --config Release --target llama --target ggml -- -allowProvisioningUpdates CODE_SIGNING_ALLOWED=NO

    # 4. Merge libraries and create XCFramework
    echo "Packaging XCFramework..."
    mkdir -p "$BASE_BUILD_DIR/headers"
    cp "$LLAMA_CPP_DIR"/include/*.h "$BASE_BUILD_DIR/headers/"
    cp "$LLAMA_CPP_DIR"/ggml/include/*.h "$BASE_BUILD_DIR/headers/"
    
    # Merge device libs
    libtool -static -o "$BASE_BUILD_DIR/libllama_device.a" \
      "$BASE_BUILD_DIR/device/src/Release-iphoneos/libllama.a" \
      "$BASE_BUILD_DIR/device/ggml/src/Release-iphoneos/libggml.a"

    # Merge simulator libs
    libtool -static -o "$BASE_BUILD_DIR/libllama_sim_arm64.a" \
      "$BASE_BUILD_DIR/sim-arm64/src/Release-iphonesimulator/libllama.a" \
      "$BASE_BUILD_DIR/sim-arm64/ggml/src/Release-iphonesimulator/libggml.a"
    
    libtool -static -o "$BASE_BUILD_DIR/libllama_sim_x86.a" \
      "$BASE_BUILD_DIR/sim-x86/src/Release-iphonesimulator/libllama.a" \
      "$BASE_BUILD_DIR/sim-x86/ggml/src/Release-iphonesimulator/libggml.a"

    lipo -create \
      "$BASE_BUILD_DIR/libllama_sim_arm64.a" \
      "$BASE_BUILD_DIR/libllama_sim_x86.a" \
      -output "$BASE_BUILD_DIR/libllama_sim.a"

    xcodebuild -create-xcframework \
      -library "$BASE_BUILD_DIR/libllama_device.a" \
      -headers "$BASE_BUILD_DIR/headers" \
      -library "$BASE_BUILD_DIR/libllama_sim.a" \
      -headers "$BASE_BUILD_DIR/headers" \
      -output "$OUTPUT_DIR/llama_cpp.xcframework"

    cp -r "$OUTPUT_DIR/llama_cpp.xcframework" ./libllama_ios.xcframework
    echo "iOS XCFramework build successful: libllama_ios.xcframework"

else
    echo "Error: Invalid platform '$PLATFORM'. Use 'macos' or 'ios'."
    exit 1
fi
