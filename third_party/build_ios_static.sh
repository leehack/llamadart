#!/usr/bin/env bash
set -e

# build_ios_static.sh <SDK> <ARCH> <OUT_NAME> [clean]
SDK=$1
ARCH=$2
OUT_NAME=$3
CLEAN=$4

IOS_MIN_OS_VERSION=16.4

COMMON_CMAKE_ARGS=(
    -DCMAKE_BUILD_TYPE=Release
    -DBUILD_SHARED_LIBS=OFF
    -DLLAMA_BUILD_EXAMPLES=OFF
    -DLLAMA_BUILD_TOOLS=OFF
    -DLLAMA_BUILD_TESTS=OFF
    -DLLAMA_BUILD_SERVER=OFF
    -DGGML_METAL=ON
    -DGGML_METAL_EMBED_LIBRARY=ON
    -DGGML_BLAS_DEFAULT=ON
    -DGGML_METAL_USE_BF16=ON
    -DGGML_OPENMP=OFF
    -DCMAKE_OSX_DEPLOYMENT_TARGET=${IOS_MIN_OS_VERSION}
    -DIOS=ON
    -DCMAKE_SYSTEM_NAME=iOS
    -DCMAKE_OSX_SYSROOT=${SDK}
    -DCMAKE_OSX_ARCHITECTURES=${ARCH}
    -DLLAMA_OPENSSL=OFF
)

BUILD_DIR="build-ios-${SDK}-${ARCH}"
if [ "$CLEAN" == "clean" ]; then rm -rf "$BUILD_DIR"; fi

echo "Configuring and building for $SDK ($ARCH)..."
cmake -B "$BUILD_DIR" -G Ninja "${COMMON_CMAKE_ARGS[@]}" -S .
cmake --build "$BUILD_DIR" --config Release -j $(sysctl -n hw.logicalcpu)

echo "Merging static libraries..."
LIBS=$(find "$BUILD_DIR" -name "*.a" ! -name "libllamadart.a")
mkdir -p bin/ios
libtool -static -o "bin/ios/${OUT_NAME}" ${LIBS} 2> /dev/null

echo "Done: bin/ios/${OUT_NAME}"
