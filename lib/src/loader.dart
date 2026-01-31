import 'dart:ffi';
import 'dart:io';
export 'generated/llama_bindings.dart';

/// The underlying DynamicLibrary, exposed for NativeFinalizer access.
///
/// This uses the Native Assets mapping for 'package:llamadart/llamadart'.
/// If it fails (e.g. in some isolate contexts), it returns null.
final DynamicLibrary? llamaLib = _openLibrary();

DynamicLibrary? _openLibrary() {
  try {
    final lib = DynamicLibrary.open('package:llamadart/llamadart');
    print('llamadart: Loaded via Native Assets');
    return lib;
  } catch (e) {
    try {
      if (Platform.isIOS || Platform.isMacOS) {
        // For Apple platforms, if Native Assets failed, it might be
        // because the library was statically linked into the executable.
        final lib = DynamicLibrary.executable();
        print(
          'llamadart: Loaded via DynamicLibrary.executable() (Static Linking fallback)',
        );
        return lib;
      }

      final libName = Platform.isWindows
          ? 'libllamadart.dll'
          : 'libllamadart.so'; // Linux/Android
      final lib = DynamicLibrary.open(libName);
      print('llamadart: Loaded via direct open($libName)');
      return lib;
    } catch (_) {
      print('llamadart: Failed to load native library');
      return null;
    }
  }
}
