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
  // 1. Try Native Assets (ID-based loading)
  // This is the modern way that works with hook/build.dart
  try {
    final lib = DynamicLibrary.open('package:llamadart/src/loader.dart');
    llamaLib = lib;
    return LlamaCpp(lib);
  } catch (_) {
    // Asset ID loading failed or Native Assets experiment not enabled
    // Fallback to manual platform-specific loading below
  }

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

  throw Exception('Failed to load libllama.dylib on macOS.\n'
      'If you are running in a CLI/Pure Dart project, please run:\n'
      '  dart run llamadart:setup');
}

DynamicLibrary _loadWindows() {
  // 1. Pure Dart
  final arch = (Platform.version.contains('arm64')) ? 'arm64' : 'x64';

  final packagePath = _resolvePackagePath('llamadart');
  if (packagePath != null) {
    final libPath = path.join(packagePath, 'windows/lib', arch, 'libllama.dll');
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

  throw Exception('Failed to load libllama.dll on Windows.\n'
      'If you are running in a CLI/Pure Dart project, please run:\n'
      '  dart run llamadart:setup');
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
  try {
    final execDir = path.dirname(Platform.resolvedExecutable);
    final libPath = path.join(execDir, 'lib', 'libllama.so');
    if (File(libPath).existsSync()) {
      return DynamicLibrary.open(libPath);
    }
  } catch (_) {}

  throw Exception('Failed to load libllama.so on Linux.\n'
      'If you are running in a CLI/Pure Dart project, please run:\n'
      '  dart run llamadart:setup');
}

DynamicLibrary _loadIOS() {
  // 1. Framework Bundle (Dynamic)
  // Replaced by top-level NativeAsset resolution if hook works.
  // But keep fallback if needed.
  try {
    return DynamicLibrary.open('llama.framework/llama');
  } catch (e) {
    print('LlamaDart: Failed to open dynamic library from framework path: $e');
  }

  // Try opening by name only (if native assets placed it flat)
  try {
    return DynamicLibrary.open('llama');
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
