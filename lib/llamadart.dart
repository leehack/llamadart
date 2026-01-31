/// High-performance Dart and Flutter plugin for llama.cpp.
///
/// This package provides a streamlined interface for running Large Language Models (LLMs)
/// locally using GGUF models across all major platforms with minimal setup.
library llamadart;

export 'src/generated/llama_bindings.dart'
    if (dart.library.js_interop) 'src/generated/llama_bindings_stub.dart';
export 'src/llama_service_interface.dart';

export 'src/llama_service_stub.dart'
    if (dart.library.ffi) 'src/llama_service_native.dart'
    if (dart.library.js_interop) 'src/llama_service_web.dart';
