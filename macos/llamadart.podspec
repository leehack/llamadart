#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html
#
Pod::Spec.new do |s|
  s.name             = 'llamadart'
  s.version          = '0.0.1'
  s.summary          = 'Run Large Language Models using llama.cpp with zero-setup installation'
  s.description      = <<-DESC
A Dart/Flutter package that enables running Large Language Models (LLMs) using llama.cpp.
Provides FFI bindings to llama.cpp and embeds native libraries, requiring no additional setup.
                       DESC
  s.homepage         = 'https://github.com/jhinlee/llamadart'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Jhin Lee' => 'leehack@gmail.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'FlutterMacOS'
  s.platform         = :osx, '10.11'
  s.swift_version    = '5.0'

  # Prepare the native libraries for inclusion
  s.prepare_command = <<-CMD
    # Always clean Frameworks to be sure
    rm -rf Frameworks
    mkdir -p Frameworks

    # Define build path (use /tmp to ensure writability in sandboxed environments)
    BUILD_DIR="/tmp/llamadart_build_macos"
    
    echo "llamadart: Building native libraries in $BUILD_DIR..."
    mkdir -p "$BUILD_DIR"
    
    # Go to project root (relative to macos/ directory)
    PROJECT_ROOT=$(pwd)/..
    
    # Configure and Build universal binary (arm64 + x86_64)
    # We build from src/native/llama_cpp directly
    if cmake -S "$PROJECT_ROOT/src/native/llama_cpp" -B "$BUILD_DIR" \
        -DBUILD_SHARED_LIBS=ON \
        -DLLAMA_BUILD_COMMON=OFF \
        -DLLAMA_BUILD_TESTS=OFF \
        -DLLAMA_BUILD_EXAMPLES=OFF \
        -DLLAMA_BUILD_SERVER=OFF \
        -DLLAMA_BUILD_TOOLS=OFF \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" && \
       cmake --build "$BUILD_DIR" --config Release -j $(sysctl -n hw.ncpu); then
      echo "llamadart: Build successful."
    else
      echo "llamadart: Build failed."
      exit 1
    fi

    # Copy all dylibs from CMake build output
    echo "llamadart: Copying all libraries to Frameworks..."
    if ls "$BUILD_DIR"/bin/*.dylib >/dev/null 2>&1; then
      cp -L "$BUILD_DIR"/bin/*.dylib Frameworks/
    else
      echo "Error: No dylibs found in $BUILD_DIR/bin after build."
      exit 1
    fi
  CMD

  s.pod_target_xcconfig = {
    'OTHER_LDFLAGS' => '-all_load -Wl,-export_dynamic',
    'STRIP_STYLE' => 'non-global'
  }

  # Include the dylibs in the framework
  s.vendored_libraries = 'Frameworks/*.dylib'

end

