#!/usr/bin/env bash
#
# Optimized build-xcframework.sh for llama_dart
# Only builds iOS (Device + Simulator) to save time.

set -e

IOS_MIN_OS_VERSION=16.4

# Copy upstream options
BUILD_SHARED_LIBS=OFF
LLAMA_BUILD_EXAMPLES=OFF
LLAMA_BUILD_TOOLS=OFF
LLAMA_BUILD_TESTS=OFF
LLAMA_BUILD_SERVER=OFF
GGML_METAL=ON
GGML_METAL_EMBED_LIBRARY=ON
GGML_BLAS_DEFAULT=ON
GGML_METAL_USE_BF16=ON
GGML_OPENMP=OFF

COMMON_C_FLAGS="-Wno-macro-redefined -Wno-shorten-64-to-32 -Wno-unused-command-line-argument -g"
COMMON_CXX_FLAGS="-Wno-macro-redefined -Wno-shorten-64-to-32 -Wno-unused-command-line-argument -g"

COMMON_CMAKE_ARGS=(
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED=NO
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY=""
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO
    -DCMAKE_XCODE_ATTRIBUTE_DEBUG_INFORMATION_FORMAT="dwarf-with-dsym"
    -DCMAKE_XCODE_ATTRIBUTE_GCC_GENERATE_DEBUGGING_SYMBOLS=YES
    -DCMAKE_XCODE_ATTRIBUTE_COPY_PHASE_STRIP=NO
    -DCMAKE_XCODE_ATTRIBUTE_STRIP_INSTALLED_PRODUCT=NO
    -DCMAKE_XCODE_ATTRIBUTE_DEVELOPMENT_TEAM=ggml
    -DBUILD_SHARED_LIBS=${BUILD_SHARED_LIBS}
    -DLLAMA_BUILD_EXAMPLES=${LLAMA_BUILD_EXAMPLES}
    -DLLAMA_BUILD_TOOLS=${LLAMA_BUILD_TOOLS}
    -DLLAMA_BUILD_TESTS=${LLAMA_BUILD_TESTS}
    -DLLAMA_BUILD_SERVER=${LLAMA_BUILD_SERVER}
    -DGGML_METAL_EMBED_LIBRARY=${GGML_METAL_EMBED_LIBRARY}
    -DGGML_BLAS_DEFAULT=${GGML_BLAS_DEFAULT}
    -DGGML_METAL=${GGML_METAL}
    -DGGML_METAL_USE_BF16=${GGML_METAL_USE_BF16}
    -DGGML_NATIVE=OFF
    -DGGML_OPENMP=${GGML_OPENMP}
)

# Setup function (simplified)
setup_framework_structure() {
    local build_dir=$1
    local min_os_version=$2
    local framework_name="llama"

    echo "Creating ios-style framework structure for ${build_dir}"

    mkdir -p ${build_dir}/framework/${framework_name}.framework/Headers
    mkdir -p ${build_dir}/framework/${framework_name}.framework/Modules
    rm -rf ${build_dir}/framework/${framework_name}.framework/Versions

    local header_path=${build_dir}/framework/${framework_name}.framework/Headers/
    local module_path=${build_dir}/framework/${framework_name}.framework/Modules/

    # Copy headers (Found in current directory/include/ and ggml/include/)
    # Note: We assume this script runs from the submodule root or we point to it correctly.
    # The caller (build_apple.sh) pushes to llama.cpp dir. So paths are relative to llama.cpp.

    cp include/llama.h             ${header_path}
    cp ggml/include/ggml.h         ${header_path}
    cp ggml/include/ggml-opt.h     ${header_path}
    cp ggml/include/ggml-alloc.h   ${header_path}
    cp ggml/include/ggml-backend.h ${header_path}
    cp ggml/include/ggml-metal.h   ${header_path}
    cp ggml/include/ggml-cpu.h     ${header_path}
    cp ggml/include/ggml-blas.h    ${header_path}
    cp ggml/include/gguf.h         ${header_path}

    # Module map
    cat > ${module_path}module.modulemap << EOF
framework module llama {
    header "llama.h"
    header "ggml.h"
    header "ggml-alloc.h"
    header "ggml-backend.h"
    header "ggml-metal.h"
    header "ggml-cpu.h"
    header "ggml-blas.h"
    header "gguf.h"

    link "c++"
    link framework "Accelerate"
    link framework "Metal"
    link framework "Foundation"

    export *
}
EOF

    # Info.plist
    local plist_path="${build_dir}/framework/${framework_name}.framework/Info.plist"
    cat > ${plist_path} << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>llama</string>
    <key>CFBundleIdentifier</key>
    <string>org.ggml.llama</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>llama</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>MinimumOSVersion</key>
    <string>${min_os_version}</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>iPhoneOS</string>
    </array>
    <key>UIDeviceFamily</key>
    <array>
        <integer>1</integer>
        <integer>2</integer>
    </array>
    <key>DTPlatformName</key>
    <string>iphoneos</string>
    <key>DTSDKName</key>
    <string>iphoneos${min_os_version}</string>
</dict>
</plist>
EOF
}

combine_static_libraries() {
    local build_dir="$1"
    local release_dir="$2"
    local is_simulator="$3"
    local base_dir="$(pwd)"
    local framework_name="llama"

    local output_lib="${build_dir}/framework/${framework_name}.framework/${framework_name}"

    local libs=(
        "${base_dir}/${build_dir}/src/libllama.a"
        "${base_dir}/${build_dir}/ggml/src/libggml.a"
        "${base_dir}/${build_dir}/ggml/src/libggml-base.a"
        "${base_dir}/${build_dir}/ggml/src/libggml-cpu.a"
        "${base_dir}/${build_dir}/ggml/src/ggml-metal/libggml-metal.a"
        "${base_dir}/${build_dir}/ggml/src/ggml-blas/libggml-blas.a"
    )

    local temp_dir="${base_dir}/${build_dir}/temp"
    mkdir -p "${temp_dir}"

    libtool -static -o "${temp_dir}/combined.a" "${libs[@]}" 2> /dev/null

    local sdk=""
    local archs=""
    local min_version_flag=""
    
    if [[ "$is_simulator" == "true" ]]; then
        sdk="iphonesimulator"
        archs="arm64 x86_64"
        min_version_flag="-mios-simulator-version-min=${IOS_MIN_OS_VERSION}"
    else
        sdk="iphoneos"
        archs="arm64"
        min_version_flag="-mios-version-min=${IOS_MIN_OS_VERSION}"
    fi

    local install_name="@rpath/llama.framework/llama"
    local arch_flags=""
    for arch in $archs; do
        arch_flags+=" -arch $arch"
    done

    echo "Creating dynamic library..."
    xcrun -sdk $sdk clang++ -dynamiclib \
        -isysroot $(xcrun --sdk $sdk --show-sdk-path) \
        $arch_flags \
        $min_version_flag \
        -Wl,-force_load,"${temp_dir}/combined.a" \
        -framework Foundation -framework Metal -framework Accelerate \
        -install_name "$install_name" \
        -o "${base_dir}/${output_lib}"

    if [[ "$is_simulator" == "false" ]]; then
        if command -v xcrun vtool &>/dev/null; then
             xcrun vtool -set-build-version ios ${IOS_MIN_OS_VERSION} ${IOS_MIN_OS_VERSION} -replace \
                -output "${base_dir}/${output_lib}" "${base_dir}/${output_lib}"
        fi
    fi

    # dSYMs
    mkdir -p "${base_dir}/${build_dir}/dSYMs"
    xcrun dsymutil "${base_dir}/${output_lib}" -o "${base_dir}/${build_dir}/dSYMs/llama.dSYM"
    cp "${base_dir}/${output_lib}" "${temp_dir}/binary_to_strip"
    xcrun strip -S "${temp_dir}/binary_to_strip" -o "${temp_dir}/stripped_lib"
    mv "${temp_dir}/stripped_lib" "${base_dir}/${output_lib}"

    rm -rf "${temp_dir}"
}

# 1. iOS Simulator
echo "Building for iOS simulator..."
rm -rf build-ios-sim
cmake -B build-ios-sim -G Ninja \
    "${COMMON_CMAKE_ARGS[@]}" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=${IOS_MIN_OS_VERSION} \
    -DIOS=ON \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT=iphonesimulator \
    -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
    -DCMAKE_C_FLAGS="${COMMON_C_FLAGS}" \
    -DCMAKE_CXX_FLAGS="${COMMON_CXX_FLAGS}" \
    -DLLAMA_OPENSSL=OFF \
    -S .
cmake --build build-ios-sim -j 8

# 2. iOS Device
echo "Building for iOS devices..."
rm -rf build-ios-device
cmake -B build-ios-device -G Ninja \
    "${COMMON_CMAKE_ARGS[@]}" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=${IOS_MIN_OS_VERSION} \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT=iphoneos \
    -DCMAKE_OSX_ARCHITECTURES="arm64" \
    -DCMAKE_C_FLAGS="${COMMON_C_FLAGS}" \
    -DCMAKE_CXX_FLAGS="${COMMON_CXX_FLAGS}" \
    -DLLAMA_OPENSSL=OFF \
    -S .
cmake --build build-ios-device -j 8

# 3. Package
echo "Setting up framework structures..."
setup_framework_structure "build-ios-sim" ${IOS_MIN_OS_VERSION}
setup_framework_structure "build-ios-device" ${IOS_MIN_OS_VERSION}

echo "Creating dynamic libraries..."
combine_static_libraries "build-ios-sim" "" "true"
combine_static_libraries "build-ios-device" "" "false"

rm -rf build-apple
mkdir -p build-apple

echo "Creating XCFramework..."
xcodebuild -create-xcframework \
    -framework $(pwd)/build-ios-sim/framework/llama.framework \
    -debug-symbols $(pwd)/build-ios-sim/dSYMs/llama.dSYM \
    -framework $(pwd)/build-ios-device/framework/llama.framework \
    -debug-symbols $(pwd)/build-ios-device/dSYMs/llama.dSYM \
    -output $(pwd)/build-apple/llama.xcframework

echo "Done: build-apple/llama.xcframework"
