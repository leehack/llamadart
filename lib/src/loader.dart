import 'dart:ffi';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as path;
import 'generated/llama_bindings.dart';

/// Global instance of the Llama bindings.
final LlamaCpp llama = loadLlamaLib();

/// The underlying DynamicLibrary, exposed for NativeFinalizer access.
late final DynamicLibrary llamaLib;

/// Loads the llama.cpp native library
LlamaCpp loadLlamaLib() {
  DynamicLibrary lib;

  if (Platform.isMacOS) {
    lib = _loadMacOS();
  } else if (Platform.isWindows) {
    lib = _loadWindows();
  } else if (Platform.isLinux) {
    lib = _loadLinux();
  } else if (Platform.isAndroid) {
    lib = DynamicLibrary.open('libllama.so');
  } else if (Platform.isIOS) {
    lib = _loadIOS();
  } else {
    throw UnsupportedError('Unknown platform: ${Platform.operatingSystem}');
  }

  llamaLib = lib;
  return LlamaCpp(lib);
}

DynamicLibrary _loadMacOS() {
  // 1. Pure Dart (CLI/Server)
  final packagePath = _resolvePackagePath('llamadart');
  if (packagePath != null) {
    final libPath = path.join(packagePath, 'macos/Frameworks/libllama.dylib');
    if (File(libPath).existsSync()) {
      return DynamicLibrary.open(libPath);
    }
  }

  // 2. Flutter App (macOS Bundle)
  try {
    final executableDir = path.dirname(Platform.resolvedExecutable);
    final libPath =
        path.join(executableDir, '..', 'Frameworks', 'libllama.dylib');
    if (File(libPath).existsSync()) {
      return DynamicLibrary.open(libPath);
    }
  } catch (_) {}

  throw Exception('Failed to load libllama.dylib on macOS.');
}

DynamicLibrary _loadWindows() {
  // 1. Pure Dart
  final packagePath = _resolvePackagePath('llamadart');
  if (packagePath != null) {
    final libPath = path.join(packagePath, 'windows/bin/libllama.dll');
    if (File(libPath).existsSync()) {
      return DynamicLibrary.open(libPath);
    }
  }

  // 2. Flutter App / Installed App
  try {
    final execDir = path.dirname(Platform.resolvedExecutable);
    final libPath = path.join(execDir, 'libllama.dll');
    if (File(libPath).existsSync()) {
      return DynamicLibrary.open(libPath);
    }
  } catch (_) {}

  throw Exception('Failed to load libllama.dll on Windows.');
}

DynamicLibrary _loadLinux() {
  // 1. Pure Dart
  final arch = (Platform.version.contains('aarch64') ||
          Platform.version.contains('arm64'))
      ? 'arm64'
      : 'x64';

  final packagePath = _resolvePackagePath('llamadart');
  if (packagePath != null) {
    final libPath = path.join(packagePath, 'linux/lib', arch, 'libllama.so');
    if (File(libPath).existsSync()) {
      return DynamicLibrary.open(libPath);
    }
  }

  // 2. Flutter App / System
  // Rely on LD_LIBRARY_PATH or standard system/flutter locations
  try {
    return DynamicLibrary.open('libllama.so');
  } catch (e) {
    throw Exception('Failed to load libllama.so on Linux: $e');
  }
}

DynamicLibrary _loadIOS() {
  // 1. Framework Bundle (Dynamic)
  try {
    return DynamicLibrary.open('llama.framework/llama');
  } catch (_) {}

  // 2. Static Linking (Fallback/Alternative mode)
  final lib = DynamicLibrary.process();
  if (!lib.providesSymbol('llama_backend_init')) {
    throw Exception(
        'Failed to load llama library on iOS (checked framework and static linking).');
  }
  return lib;
}

/// Helper to find the package path using package_config.json
String? _resolvePackagePath(String packageName) {
  try {
    // Check for .dart_tool/package_config.json in the current directory
    final packageConfigFile = File(
      path.join(Directory.current.path, '.dart_tool', 'package_config.json'),
    );

    if (!packageConfigFile.existsSync()) {
      return null;
    }

    final content = packageConfigFile.readAsStringSync();
    final json = jsonDecode(content) as Map<String, dynamic>;
    final packages = json['packages'] as List<dynamic>;

    final package = packages.firstWhere(
      (p) => p['name'] == packageName,
      orElse: () => null,
    );

    if (package == null) return null;

    final rootUri = Uri.parse(package['rootUri'] as String);

    // If it's already an absolute file URI
    if (rootUri.hasScheme && rootUri.scheme == 'file') {
      return rootUri.toFilePath();
    }

    // Resolve relative to the package_config.json file location
    // Note: package_config.json is in .dart_tool/
    final configDirUri = packageConfigFile.parent.uri;
    return configDirUri.resolveUri(rootUri).toFilePath();
  } catch (_) {
    return null;
  }
}
