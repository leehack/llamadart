import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:llamadart/src/loader.dart';

void main() {
  print('Loading cpp...');

  try {
    // Initialize backend
    llama_backend_init();
    print('Backend initialized.');

    // Print system info
    final sysInfo = llama_print_system_info();
    print('System Info: ${sysInfo.cast<Utf8>().toDartString()}');

    // Basic check passed
    print('SUCCESS: Native library loaded and communicating.');

    // Cleanup
    llama_backend_free();
  } catch (e) {
    print('ERROR: $e');
    exit(1);
  }
}
