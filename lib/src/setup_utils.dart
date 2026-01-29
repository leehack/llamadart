import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;

/// Utilities for downloading and setting up native binaries for llamadart.
class SetupUtils {
  static const String releaseTag = 'libs-v0.2.0';
  static const String baseUrl =
      'https://github.com/leehack/llamadart/releases/download/$releaseTag';

  /// Downloads the appropriate binary for the current platform and architecture.
  static Future<void> setup({bool force = false, String? targetFolder}) async {
    final os = Platform.operatingSystem;
    final arch = _getArch();

    print('Detecting platform: $os ($arch)');

    if (Platform.isWindows) {
      await _setupWindows(arch, force, targetFolder);
    } else if (Platform.isLinux) {
      await _setupLinux(arch, force, targetFolder);
    } else if (Platform.isMacOS) {
      await _setupMacOS(force, targetFolder);
    } else if (Platform.isIOS) {
      await _setupIOS(force, targetFolder);
    } else if (Platform.isAndroid) {
      await _setupAndroid(force, targetFolder);
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

    // Windows artifact in release is named 'libllama.dll' (assuming from libllama_windows_vulkan)
    // Wait, if we have multiple assets, we should name them uniquely in the CI.
    // For now, I will use a mapping.
    final assetName = 'libllama.dll';
    final destDir = targetFolder ?? 'windows/lib/x64';
    final destFile = path.join(destDir, 'libllama.dll');

    await _downloadAsset(assetName, destFile, force);
  }

  static Future<void> _setupLinux(
    String arch,
    bool force,
    String? targetFolder,
  ) async {
    final assetName = arch == 'arm64'
        ? 'libllama_linux_arm64.so'
        : 'libllama.so';
    final destDir = targetFolder ?? 'linux/lib/$arch';
    final destFile = path.join(destDir, 'libllama.so');

    await _downloadAsset(assetName, destFile, force);
  }

  static Future<void> _setupMacOS(bool force, String? targetFolder) async {
    final assetName = 'libllama.dylib';
    final destDir = targetFolder ?? 'macos/Frameworks';
    final destFile = path.join(destDir, 'libllama.dylib');

    await _downloadAsset(assetName, destFile, force);
  }

  static Future<void> _setupIOS(bool force, String? targetFolder) async {
    print('iOS setup requires manual extraction of llama_ios_xcframework.zip');
    final assetName = 'llama_ios_xcframework.zip';
    final destDir = targetFolder ?? 'ios/Frameworks';
    final destFile = path.join(destDir, assetName);

    await _downloadAsset(assetName, destFile, force);
    print('Please extract $destFile to $destDir/llama.xcframework');
  }

  static Future<void> _setupAndroid(bool force, String? targetFolder) async {
    print('Android setup currently handles JNI libs separately.');
    // In a real scenario, we might want to download the whole jniLibs folder zip.
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
