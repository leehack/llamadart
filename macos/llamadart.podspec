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
  s.platform         = :osx, '10.15'
  s.swift_version    = '5.0'

  # Vendor the native libraries.
  # These are pre-built using scripts/build_apple.sh macos
  s.vendored_libraries = 'Frameworks/*.dylib'

  s.pod_target_xcconfig = {
    'OTHER_LDFLAGS' => '-all_load -Wl,-export_dynamic',
    'STRIP_STYLE' => 'non-global'
  }

end

