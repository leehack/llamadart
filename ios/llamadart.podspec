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
  s.dependency 'Flutter'
  s.platform         = :ios, '12.0'
  s.swift_version    = '5.0'

  # Automate the build if the framework is missing
  s.prepare_command = <<-CMD
    if [ ! -d "Frameworks/llama_cpp.xcframework" ]; then
      echo "llamadart: Framework not found. Building llama.cpp for iOS..."
      # Run the build script
      if [ -f "../scripts/build_apple.sh" ]; then
        ../scripts/build_apple.sh ios
      else
        echo "Error: ../scripts/build_apple.sh not found."
        exit 1
      fi
    fi
  CMD

  # Vendor the native libraries
  s.vendored_frameworks = 'Frameworks/llama_cpp.xcframework'
  s.static_framework = true
  s.libraries = 'c++'
  s.frameworks = 'Accelerate', 'Metal', 'MetalKit', 'Foundation'
  
  # Use -all_load to force inclusion of all symbols.
  # Use -Wl,-export_dynamic to ensure symbols are visible to dlsym(RTLD_DEFAULT).
  s.user_target_xcconfig = { 
    'OTHER_LDFLAGS' => '-all_load -Wl,-export_dynamic',
    'STRIP_STYLE' => 'non-global'
  }

  s.pod_target_xcconfig = {
    'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) GGML_USE_METAL=1',
    'HEADER_SEARCH_PATHS' => '$(inherited) "${PODS_TARGET_SRCROOT}/Frameworks/llama_cpp.xcframework/ios-arm64/Headers" "${PODS_TARGET_SRCROOT}/Frameworks/llama_cpp.xcframework/ios-arm64_x86_64-simulator/Headers"',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'CLANG_CXX_LIBRARY' => 'libc++'
  }
  


  # Copy the native libraries to the app bundle
  # s.resource_bundles = {'llamadart_privacy' => ['Frameworks/*.dylib']}

  # Include Metal shader binary
  # s.resources = ['Resources/default.metallib']
end
