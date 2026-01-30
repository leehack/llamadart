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

    try {
      // 1. Ensure binaries are present for the TARGET platform
      if (input.config.buildCodeAssets) {
        final codeConfig = input.config.code;
        final os = codeConfig.targetOS;
        final arch = codeConfig.targetArchitecture;

        String osName = 'unknown';
        if (os == OS.windows) {
          osName = 'windows';
        } else if (os == OS.linux) {
          osName = 'linux';
        } else if (os == OS.macOS) {
          osName = 'macos';
        } else if (os == OS.android) {
          osName = 'android';
        } else if (os == OS.iOS) {
          osName = 'ios';
        }

        String archName = 'x64';
        if (arch == Architecture.arm64) {
          archName = 'arm64';
        } else if (arch == Architecture.x64) {
          archName = 'x64';
        }
        // Add other archs if needed

        // Determine absolute path for SetupUtils to ensure we write to the source tree
        // regardless of where the hook runner's CWD is.
        final packageRoot = input.packageRoot.toFilePath();
        String? targetFolder;

        if (os == OS.windows) {
          targetFolder = path.join(packageRoot, 'windows/lib/x64');
        } else if (os == OS.linux) {
          // ... handled inside setup for arch usually, but let's be explicit if we can
          // SetupUtils handles specific linux/lib/{arch} logic if targetFolder is provided?
          // Actually SetupUtils.targetFolder overrides the WHOLE path.
          // Let's just pass the root for now or construct the specific one.
          // Simplest: Pass specific folder for Android/iOS which we know are problematic.
        } else if (os == OS.android) {
          // Force download BOTH architectures for Android to ensure Gradle has what it needs
          // even if the hook is only called for one architecture initially.
          final arm64Target =
              path.join(packageRoot, 'android/src/main/jniLibs', 'arm64-v8a');
          await SetupUtils.setup(
              targetOs: 'android',
              targetArch: 'arm64',
              targetFolder: arm64Target);

          final x64Target =
              path.join(packageRoot, 'android/src/main/jniLibs', 'x86_64');
          await SetupUtils.setup(
              targetOs: 'android', targetArch: 'x64', targetFolder: x64Target);
        } else if (os == OS.iOS) {
          targetFolder = path.join(packageRoot, 'ios/Frameworks');

          // Download binaries for the specific target (iOS/macOS/Windows/Linux)
          await SetupUtils.setup(
              targetOs: osName,
              targetArch: archName,
              targetFolder: targetFolder);
        } else {
          // Download binaries for the specific target (Windows/Linux/MacOS)
          await SetupUtils.setup(
              targetOs: osName,
              targetArch: archName,
              targetFolder: targetFolder);
        }
        String? libPath;
        if (os == OS.windows) {
          libPath = 'windows/lib/x64/libllama.dll';
        } else if (os == OS.linux) {
          final archStr = arch == Architecture.arm64 ? 'arm64' : 'x64';
          libPath = 'linux/lib/$archStr/libllama.so';
        } else if (os == OS.macOS) {
          libPath = 'macos/Frameworks/libllama.dylib';

          // Fix for macOS specific issue:
          // dartdev crashes if the native asset is a fat binary (universal) but we are
          // in a specific architecture build. We must thin it.
          final fullLibPath =
              path.join(input.packageRoot.toFilePath(), libPath);
          if (File(fullLibPath).existsSync()) {
            // Check if it's a fat file
            final result = await Process.run('lipo', ['-info', fullLibPath]);
            if (result.stdout
                .toString()
                .contains('Architectures in the fat file')) {
              print('Thinning universal binary for $archName...');
              // Thin it to the current target architecture
              final lipoArgs = [
                '-thin',
                archName,
                fullLibPath,
                '-output',
                fullLibPath
              ];
              final lipoResult = await Process.run('lipo', lipoArgs);
              if (lipoResult.exitCode != 0) {
                print('Failed to thin binary: ${lipoResult.stderr}');
                // Don't fail the build, maybe it works anyway
              } else {
                print('Successfully thinned binary to $archName');
              }
            }
          }
        } else if (os == OS.iOS) {
          // Resolve the correct path within the XCFramework based on architecture and simulator usage
          // The hook currently downloads checking targetOS. SetupUtils logic for iOS downloads a zip.
          // Note: SetupUtils extracts to ios/Frameworks/llama.xcframework

          final frameworkRoot = 'ios/Frameworks/llama.xcframework';

          // Determine the correct slice.
          // CodeAssets doesn't give us "simulator" vs "device" directly in architecture, but strict matching matters.
          // However, for iOS, XCFrameworks usually have 'ios-arm64' and 'ios-arm64_x86_64-simulator'.
          // We need to know if we are targeting simulator.
          // input.config.code.targetOS is iOS.
          // There isn't an easy "isSimulator" flag exposed in the top-level config object in this version?
          // Actually, we can check architectures.
          // If we are building for x64 on iOS, it is definitely simulator.
          // If we are building for arm64 on iOS, it could be device or simulator.

          // Hack/Heuristic: Check if we have the simulator slice.
          // Since we are "downloading" via SetupUtils, we know what we have.

          // Ideally: native_assets handling for XCFrameworks is the 'right' way,
          // but reporting the dylib inside it as a CodeAsset is the 'raw' way.

          // Detect if we are building for Simulator or Device
          // Architecture x64 on iOS is always Simulator.
          // Architecture arm64 on iOS can be Device OR Simulator (Apple Silicon).
          // We check the PATH or other environment variables to distinguish.

          bool isSimulator = false;
          if (arch == Architecture.x64) {
            isSimulator = true;
          } else if (arch == Architecture.arm64) {
            // Heuristic: Check if the PATH contains iPhoneSimulator platform tools.
            // This is set by the build system when targeting simulator.
            final pathVar = Platform.environment['PATH'] ?? '';
            if (pathVar.contains('iPhoneSimulator.platform')) {
              isSimulator = true;
            }
          }

          if (isSimulator) {
            libPath =
                '$frameworkRoot/ios-arm64_x86_64-simulator/llama.framework/llama';
          } else {
            libPath = '$frameworkRoot/ios-arm64/llama.framework/llama';
          }
        }

        // Note: iOS/Android native assets are handled via standard bundling
        // (jniLibs/Frameworks) populated by SetupUtils, not necessarily reported
        // as Dart Native Assets here yet, but we enable the download above.
        // UPDATE: We are now attempting to report it for iOS to bypass CocoaPods timing issues.
        // We will enable reporting below.

        if (libPath != null) {
          final fullPath = path.join(input.packageRoot.toFilePath(), libPath);
          if (File(fullPath).existsSync()) {
            final isLocalRun =
                Platform.environment['LLAMADART_SKIP_HOOK'] == 'true';

            output.assets.code.add(CodeAsset(
              package: packageName,
              name: 'src/loader.dart',
              linkMode: isLocalRun
                  ? DynamicLoadingSystem(Uri.file(fullPath))
                  : DynamicLoadingBundled(),
              file: isLocalRun ? null : input.packageRoot.resolve(libPath),
            ));
          }
        }
      }
    } catch (e, st) {
      File('/tmp/hook_error.txt')
          .writeAsStringSync('Error: $e\nStack: $st\n', mode: FileMode.append);
      rethrow;
    }
  });
}
