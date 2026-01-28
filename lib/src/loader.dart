import 'dart:ffi';
import 'dart:io';
import 'package:path/path.dart' as path;
import 'generated/llama_bindings.dart';

/// Loads the llama.cpp native library
LlamaCpp loadLlamaLib() {
  late DynamicLibrary lib;

  if (Platform.isMacOS) {
    // For local testing (Dart standalone), look in the build directory
    // This assumes we are running from the project root
    final localBuildPath = path.join(
      Directory.current.path,
      'build/bin/libllama.dylib',
    );
    final devBuildPath = path.join(
      Directory.current.path,
      '../../src/native/build/bin/libllama.dylib',
    );
    final frameworksPath = path.join(
      Directory.current.path,
      'macos/Frameworks/libllama.dylib',
    );

    if (File(localBuildPath).existsSync()) {
      lib = DynamicLibrary.open(localBuildPath);
    } else if (File(devBuildPath).existsSync()) {
      lib = DynamicLibrary.open(devBuildPath);
    } else if (File(frameworksPath).existsSync()) {
      lib = DynamicLibrary.open(frameworksPath);
    } else {
      // Fallback for Flutter apps
      try {
        print('llamadart: Attempting simple open libllama.dylib');
        lib = DynamicLibrary.open('libllama.dylib');
      } catch (e) {
        try {
          final executableDir = path.dirname(Platform.resolvedExecutable);
          final libPath = path.canonicalize(
            path.join(executableDir, '..', 'Frameworks', 'libllama.dylib'),
          );
          print('llamadart: Attempting absolute bundle path: $libPath');
          lib = DynamicLibrary.open(libPath);
        } catch (_) {
          try {
            final executableDir = path.dirname(Platform.resolvedExecutable);
            final libPath = path.join(
              executableDir,
              '..',
              'Frameworks',
              'llamadart.framework',
              'Resources',
              'libllama.dylib',
            );
            print('llamadart: Attempting framework resources path: $libPath');
            lib = DynamicLibrary.open(libPath);
          } catch (__) {
            print('llamadart: Falling back to process handle (Static Linking)');
            lib = DynamicLibrary.process();
          }
        }
      }
    }
  } else if (Platform.isLinux) {
    final arch =
        Platform.version.contains('aarch64') ||
            Platform.version.contains('arm64')
        ? 'arm64'
        : 'x64';
    final libDir = path.join(Directory.current.path, 'linux/lib', arch);
    final libPath = path.join(libDir, 'libllama.so');

    if (File(libPath).existsSync()) {
      lib = DynamicLibrary.open(libPath);
    } else {
      try {
        lib = DynamicLibrary.open('libllama.so');
      } catch (e) {
        // Fallback for local dev if not in the new lib dir
        final localBuildPath = path.join(
          Directory.current.path,
          'build/bin/libllama.so',
        );
        if (File(localBuildPath).existsSync()) {
          lib = DynamicLibrary.open(localBuildPath);
        } else {
          rethrow;
        }
      }
    }
  } else if (Platform.isWindows) {
    final libDir = path.join(Directory.current.path, 'windows/lib');
    final libPath1 = path.join(libDir, 'llama.dll');
    final libPath2 = path.join(libDir, 'libllama.dll');

    if (File(libPath1).existsSync()) {
      lib = DynamicLibrary.open(libPath1);
    } else if (File(libPath2).existsSync()) {
      lib = DynamicLibrary.open(libPath2);
    } else {
      try {
        lib = DynamicLibrary.open('llama.dll');
      } catch (_) {
        try {
          lib = DynamicLibrary.open('libllama.dll');
        } catch (e) {
          rethrow;
        }
      }
    }
  } else if (Platform.isIOS) {
    try {
      print('llamadart: Attempting to load from llama_cpp.framework/llama_cpp');
      lib = DynamicLibrary.open('llama_cpp.framework/llama_cpp');
      print('llamadart: Loaded successfully.');
    } catch (e1) {
      print('llamadart: Failed to load from framework bundle: $e1');
      try {
        // Construct absolute path
        final executableDir = path.dirname(Platform.resolvedExecutable);
        final libPath = path.join(
          executableDir,
          'Frameworks/llama_cpp.framework/llama_cpp',
        );
        print('llamadart: Attempting load from $libPath');
        lib = DynamicLibrary.open(libPath);
        print('llamadart: Loaded successfully from absolute path.');
      } catch (e2) {
        print('llamadart: Failed to load absolute path: $e2');
        try {
          print(
            'llamadart: Attempting process() fallback (for static linking)',
          );
          lib = DynamicLibrary.process();

          // Verify that we can actually find a symbol.
          // If strict stripping is enabled, process() returns a handle but lookup fails.
          if (!lib.providesSymbol('llama_backend_init')) {
            throw Exception(
              'llama_backend_init symbol not found in process(). '
              'This indicates symbols were stripped or not exported. '
              'Check STRIP_STYLE and -Wl,-export_dynamic in Podspec.',
            );
          }
          print('llamadart: Loaded process() and verified symbols.');
        } catch (e3) {
          print('llamadart: Failed process() fallback: $e3');
          rethrow;
        }
      }
    }
  } else if (Platform.isAndroid) {
    // For Android, we simply open the shared library by name.
    // Flutter will have packaged it into the APK.
    try {
      lib = DynamicLibrary.open('libllama.so');
    } catch (e) {
      print('llamadart: Failed to load libllama.so on Android: $e');
      rethrow;
    }
  } else {
    throw UnsupportedError('Unknown platform: ${Platform.operatingSystem}');
  }

  llamaLib = lib;
  return LlamaCpp(lib);
}

// Global instance for easy access
/// Global instance of the Llama bindings.
final LlamaCpp llama = loadLlamaLib();

/// The underlying DynamicLibrary, exposed for NativeFinalizer access.
late final DynamicLibrary llamaLib;
