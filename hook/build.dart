import 'dart:io';
import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:llamadart/src/setup_utils.dart';
import 'package:path/path.dart' as path;

/// Native Assets build hook for llamadart.
/// Automatically downloads pre-built binaries if they are missing.
void main(List<String> args) async {
  await build(args, (input, output) async {
    final packageName = 'llamadart';
    final logFile = File('C:/Users/leeha/llamadart_hook.log');

    void log(String message) {
      logFile.writeAsStringSync(
        '${DateTime.now()}: $message\n',
        mode: FileMode.append,
      );
      print('llamadart hook: $message');
    }

    try {
      log('Hook started. buildCodeAssets: ${input.config.buildCodeAssets}');

      // 1. Ensure binaries are present for the TARGET platform
      if (input.config.buildCodeAssets) {
        // NOTE: Optimization flags (like GGML_USE_METAL or GGML_USE_VULKAN)
        // that were previously in android/build.gradle and ios/podspec
        // are now managed by the native-assets build system.
        // For pre-built binaries, these flags are already baked into the DLL/SO files.
        final codeConfig = input.config.code;
        final os = codeConfig.targetOS;
        final arch = codeConfig.targetArchitecture;

        String osName = 'unknown';
        if (os == OS.windows) osName = 'windows';
        if (os == OS.linux) osName = 'linux';
        if (os == OS.macOS) osName = 'macos';
        if (os == OS.android) osName = 'android';
        if (os == OS.iOS) osName = 'ios';

        String archName = 'x64';
        if (arch == Architecture.arm64) archName = 'arm64';

        final packageRoot = input.packageRoot.toFilePath();
        String? targetFolder;
        String? libPath;

        log('Target OS: $osName, Arch: $archName');
        log('Package root: $packageRoot');

        if (os == OS.windows) {
          targetFolder = path.join(packageRoot, 'windows/lib/x64');
          libPath = 'windows/lib/x64/libllama.dll';
        } else if (os == OS.linux) {
          final archStr = arch == Architecture.arm64 ? 'arm64' : 'x64';
          targetFolder = path.join(packageRoot, 'linux/lib', archStr);
          libPath = 'linux/lib/$archStr/libllama.so';
        } else if (os == OS.macOS) {
          targetFolder = path.join(packageRoot, 'macos/Frameworks');
          libPath = 'macos/Frameworks/libllama.dylib';
        } else if (os == OS.android) {
          log('Platform is Android, setting up and reporting assets...');
          final abi = arch == Architecture.arm64 ? 'arm64-v8a' : 'x86_64';
          targetFolder = path.join(
            packageRoot,
            'android/src/main/jniLibs',
            abi,
          );
          libPath = 'android/src/main/jniLibs/$abi/libllama.so';

          log(
            'Invoking SetupUtils.setup for Android $archName at $targetFolder',
          );
          await SetupUtils.setup(
            targetOs: 'android',
            targetArch: archName,
            targetFolder: targetFolder,
          );
        } else if (os == OS.iOS) {
          targetFolder = path.join(packageRoot, 'ios/Frameworks');
          libPath =
              'ios/Frameworks/llama.xcframework/ios-arm64/llama.framework/llama';
          log('Invoking SetupUtils.setup for iOS at $targetFolder');
          await SetupUtils.setup(
            targetOs: 'ios',
            targetArch: 'arm64',
            targetFolder: targetFolder,
          );
        }

        if (targetFolder != null && os != OS.android && os != OS.iOS) {
          log('Invoking SetupUtils.setup for $osName at $targetFolder');
          await SetupUtils.setup(
            targetOs: osName,
            targetArch: archName,
            targetFolder: targetFolder,
          );
          log('SetupUtils.setup finished');
        }

        if (os == OS.macOS && libPath != null) {
          final fullLibPath = path.join(packageRoot, libPath);
          if (File(fullLibPath).existsSync()) {
            final result = await Process.run('lipo', ['-info', fullLibPath]);
            if (result.stdout.toString().contains(
              'Architectures in the fat file',
            )) {
              log('Thinning universal binary for $archName...');
              await Process.run('lipo', [
                '-thin',
                archName,
                fullLibPath,
                '-output',
                fullLibPath,
              ]);
            }
          }
        }

        if (libPath != null) {
          final fullPath = path.join(packageRoot, libPath);
          log('Final check for asset at $fullPath');
          if (File(fullPath).existsSync()) {
            log(
              'Asset FOUND. Size: ${File(fullPath).lengthSync()}. Reporting to build system...',
            );
            output.assets.code.add(
              CodeAsset(
                package: packageName,
                name: 'src/loader.dart',
                linkMode: DynamicLoadingBundled(),
                file: input.packageRoot.resolve(libPath),
              ),
            );
          } else {
            log('ERROR: Asset file missing at $fullPath');
          }
        }
      }
      log('Hook finished successfully.');
    } catch (e, st) {
      log('FATAL ERROR in hook: $e\n$st');
      rethrow;
    }
  });
}
