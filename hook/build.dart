import 'dart:io';
import 'package:native_assets_cli/native_assets_cli.dart';
import 'package:llamadart/src/setup_utils.dart';
import 'package:path/path.dart' as path;

/// Native Assets build hook for llamadart.
/// Automatically downloads pre-built binaries if they are missing.
void main(List<String> args) async {
  await build(args, (config, output) async {
    final packageName = 'llamadart';
    final assetId =
        'package:$packageName/src/loader.dart'; // Or wherever loader is

    // 1. Ensure binaries are present
    // We run setup. If binaries exist, it will skip (unless we force, which we don't here)
    await SetupUtils.setup();

    // 2. Identify the library path for the current target
    final os = config.targetOS;
    final arch = config.targetArchitecture;

    String? libPath;
    if (os == OS.windows) {
      libPath = 'windows/lib/x64/libllama.dll';
    } else if (os == OS.linux) {
      final archStr = arch == Architecture.arm64 ? 'arm64' : 'x64';
      libPath = 'linux/lib/$archStr/libllama.so';
    } else if (os == OS.macOS) {
      libPath = 'macos/Frameworks/libllama.dylib';
    } else if (os == OS.iOS) {
      // For iOS, typically the XCFramework is handled by the podspec,
      // but we can register it here too if needed.
      // However, Native Assets for iOS often expects a .a or .dylib.
    }

    if (libPath != null) {
      final fullPath = path.join(config.packageRoot.toFilePath(), libPath);
      if (File(fullPath).existsSync()) {
        output.addAsset(
          NativeCodeAsset(
            package: packageName,
            name:
                'src/loader.dart', // This should match what loader.dart expects
            linkMode: DynamicLoadingBundled(),
            os: os,
            architecture: arch,
            file: config.packageRoot.resolve(libPath),
          ),
        );
      }
    }
  });
}
