import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;

/// Utilities for downloading and setting up native binaries for llamadart.
class SetupUtils {
  /// The GitHub release tag to download binaries from.
  static const String releaseTag = 'libs-v0.2.0';

  /// The base URL for downloading release assets.
  static const String baseUrl =
      'https://github.com/leehack/llamadart/releases/download/$releaseTag';

  /// Downloads the appropriate binary for the current platform and architecture.
  static Future<void> setup({
    bool force = false,
    String? targetFolder,
    String? targetOs,
    String? targetArch,
  }) async {
    final os = targetOs ?? Platform.operatingSystem;
    final arch = targetArch ?? _getArch();

    print('Setup running for platform: $os ($arch)');

    if (os == 'windows') {
      await _setupWindows(arch, force, targetFolder);
    } else if (os == 'linux') {
      await _setupLinux(arch, force, targetFolder);
    } else if (os == 'macos') {
      await _setupMacOS(force, targetFolder);
    } else if (os == 'ios') {
      await _setupIOS(force, targetFolder);
    } else if (os == 'android') {
      await _setupAndroid(arch, force, targetFolder);
    } else {
      print('Unsupported platform for automated setup: $os');
    }
  }

  static String _getArch() {
    final version = Platform.version.toLowerCase();
    if (version.contains('arm64') || version.contains('aarch64')) {
      return 'arm64';
    }
    return 'x64';
  }

  static Future<void> _setupWindows(
    String arch,
    bool force,
    String? targetFolder,
  ) async {
    if (arch != 'x64') {
      print(
        'Warning: Only x64 is currently supported for Windows automated setup.',
      );
      return;
    }

    // Windows artifact in release is uniquely named
    final assetName = 'libllama-windows-x64.dll';
    final destDir = targetFolder ?? 'windows/lib/x64';
    final destFile = path.join(destDir, 'libllama.dll');

    await _downloadAsset(assetName, destFile, force);
  }

  static Future<void> _setupLinux(
    String arch,
    bool force,
    String? targetFolder,
  ) async {
    final assetName =
        arch == 'arm64' ? 'libllama-linux-arm64.so' : 'libllama-linux-x64.so';
    final destDir = targetFolder ?? 'linux/lib/$arch';
    final destFile = path.join(destDir, 'libllama.so');

    await _downloadAsset(assetName, destFile, force);
  }

  static Future<void> _setupMacOS(bool force, String? targetFolder) async {
    final assetName = 'libllama-macos.dylib';
    final destDir = targetFolder ?? 'macos/Frameworks';
    final destFile = path.join(destDir, 'libllama.dylib');

    await _downloadAsset(assetName, destFile, force);
  }

  static Future<void> _setupIOS(bool force, String? targetFolder) async {
    final assetName = 'llama-ios-xcframework.zip';
    final destDir = targetFolder ?? 'ios/Frameworks';
    final zipFile = path.join(destDir, assetName);
    final frameworkDir = path.join(destDir, 'llama.xcframework');

    // If framework exists and not force, skip
    if (Directory(frameworkDir).existsSync() && !force) {
      print(
          'iOS framework already exists at $frameworkDir. Use force=true to overwrite.');
      return;
    }

    await _downloadAsset(assetName, zipFile, force);

    print('Extracting $zipFile...');
    try {
      if (Platform.isMacOS || Platform.isLinux) {
        final result =
            await Process.run('unzip', ['-o', zipFile, '-d', destDir]);
        if (result.exitCode != 0) {
          print('Error extracting zip: ${result.stderr}');
        } else {
          print('Extraction complete.');
          // Clean up zip
          File(zipFile).deleteSync();
        }
      } else {
        print(
            'Warning: Automatic extraction not supported on this OS. Please unzip manually.');
      }
    } catch (e) {
      print('Exception during extraction: $e');
    }
  }

  static Future<void> _setupAndroid(
    String arch,
    bool force,
    String? targetFolder,
  ) async {
    // Check for valid Android archs
    if (arch != 'arm64' && arch != 'x64' && arch != 'x86_64') {
      print(
          'Warning: Unsupported Android architecture: $arch. Defaulting to x86_64 for emulator safety.');
      // Keep going, might be supported later or alias
    }

    // Normalize arch string for filename/path
    final safeArch = (arch == 'x86_64') ? 'x64' : arch;

    final assetName = safeArch == 'arm64'
        ? 'libllama-android-arm64.so'
        : 'libllama-android-x64.so';

    final jniArch = safeArch == 'arm64' ? 'arm64-v8a' : 'x86_64';

    final destDir = targetFolder ?? 'android/src/main/jniLibs/$jniArch';
    final destFile = path.join(destDir, 'libllama.so');

    await _downloadAsset(assetName, destFile, force);
  }

  static Future<void> _downloadAsset(
    String assetName,
    String destPath,
    bool force,
  ) async {
    final file = File(destPath);
    if (file.existsSync() && !force) {
      print('Asset already exists at $destPath. Use force=true to overwrite.');
      return;
    }

    final url = '$baseUrl/$assetName';
    print('Downloading $url to $destPath...');

    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        await file.parent.create(recursive: true);
        await file.writeAsBytes(response.bodyBytes);
        print('Download successful: $destPath');
      } else if (response.statusCode == 404) {
        print(
          'Error: Asset $assetName not found in release $releaseTag (404).',
        );
        print('Url: $url');
      } else {
        print(
          'Error: Failed to download $assetName. Status: ${response.statusCode}',
        );
      }
    } catch (e) {
      print('Exception during download: $e');
    }
  }
}
