import 'dart:io';
import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;

// Constants for release
// This should match the pinned llama.cpp submodule tag in third_party/llama_cpp
const _llamaCppTag = 'b7883';
const _baseUrl =
    'https://github.com/leehack/llamadart/releases/download/$_llamaCppTag';

// Magic Strings as Constants
const _packageName = 'llamadart';
const _libPrefix = 'libllamadart';
const _thirdPartyDir = 'third_party';
const _binDir = 'bin';
const _dartToolDir = '.dart_tool';
const _cacheBaseDir = 'llamadart';
const _cacheBinDir = 'binaries';
const _reportDir = 'llamadart_bin';

// Extensions
const _extDylib = 'dylib';
const _extSo = 'so';
const _extDll = 'dll';

void main(List<String> args) async {
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen(
    (r) => print('${r.level.name}: ${r.time}: ${r.message}'),
  );
  final log = Logger('${_packageName}_hook');

  await build(args, (input, output) async {
    final code = input.config.code;
    final (os, arch) = (code.targetOS, code.targetArchitecture);

    log.info('Hook Start: $os-$arch');

    try {
      final isSimulator =
          os == OS.iOS && code.iOS.targetSdk == IOSSdk.iPhoneSimulator;

      // 1. Resolve Platform Metadata
      final (relPath, remoteFileName, extension) = switch ((os, arch)) {
        (OS.windows, _) => (
          'windows/x64',
          '$_libPrefix-windows-x64.$_extDll',
          _extDll,
        ),
        (OS.linux, Architecture.arm64) => (
          'linux/arm64',
          '$_libPrefix-linux-arm64.$_extSo',
          _extSo,
        ),
        (OS.linux, Architecture.x64) => (
          'linux/x64',
          '$_libPrefix-linux-x64.$_extSo',
          _extSo,
        ),
        (OS.android, Architecture.arm64) => (
          'android/arm64',
          '$_libPrefix-android-arm64.$_extSo',
          _extSo,
        ),
        (OS.android, Architecture.x64) => (
          'android/x64',
          '$_libPrefix-android-x64.$_extSo',
          _extSo,
        ),
        (OS.macOS, _) => (
          'macos/${arch.name}',
          '$_libPrefix-macos-${arch == Architecture.arm64 ? "arm64" : "x86_64"}.$_extDylib',
          _extDylib,
        ),
        (OS.iOS, _) => ('ios', _getIOSFileName(isSimulator, arch), _extDylib),
        _ => (null, null, null),
      };

      if (relPath == null || remoteFileName == null || extension == null) {
        log.warning('Unsupported platform: $os-$arch');
        return;
      }

      // 2. Resolve Paths
      final pkgRoot = input.packageRoot.toFilePath();
      final localAssetPath = path.join(
        pkgRoot,
        _thirdPartyDir,
        _binDir,
        relPath,
        remoteFileName,
      );
      final cacheDir = path.join(
        pkgRoot,
        _dartToolDir,
        _cacheBaseDir,
        _cacheBinDir,
        relPath,
      );
      final cacheAssetPath = path.join(cacheDir, remoteFileName);

      // 3. Asset Acquisition (Local -> Cache -> Download)
      String? finalAssetPath;
      if (File(localAssetPath).existsSync()) {
        log.info('Using local binary: $localAssetPath');
        finalAssetPath = localAssetPath;
      } else {
        if (!File(cacheAssetPath).existsSync()) {
          log.info('Cache miss, ensuring cached assets...');
          await _download(remoteFileName, cacheAssetPath, log);
        }
        if (File(cacheAssetPath).existsSync()) {
          finalAssetPath = cacheAssetPath;
        }
      }

      if (finalAssetPath == null) {
        log.severe('Failed to acquire asset: $remoteFileName');
        return;
      }

      // 4. Standardize Filename for Flutter/Dart
      // We copy the arch-specific file to a generic name so the Asset ID and
      // Framework name (on Apple) are consistent.
      final genericFileName = (os == OS.macOS || os == OS.iOS)
          ? '$_packageName.$extension'
          : (os == OS.windows
                ? '$_libPrefix.$_extDll'
                : '$_libPrefix.$extension');

      final reportDir = path.join(
        input.outputDirectory.toFilePath(),
        _reportDir,
      );
      await Directory(reportDir).create(recursive: true);

      final reportedAssetPath = path.join(reportDir, genericFileName);
      await File(finalAssetPath).copy(reportedAssetPath);

      // MacOS/iOS Thinning (if needed)
      if (os == OS.macOS && reportedAssetPath.endsWith('.$_extDylib')) {
        await _thinBinary(reportedAssetPath, arch, log);
      }

      // 5. Report Asset
      final absoluteAssetPath = path.absolute(reportedAssetPath);
      log.info('Reporting: $absoluteAssetPath (Link: Dynamic)');

      output.assets.code.add(
        CodeAsset(
          package: _packageName,
          name: _packageName,
          linkMode: DynamicLoadingBundled(),
          file: Uri.file(absoluteAssetPath),
        ),
      );
    } catch (e, st) {
      log.severe('FATAL ERROR in hook', e, st);
      rethrow;
    }
  });
}

String _getIOSFileName(bool isSimulator, Architecture arch) {
  if (arch == Architecture.x64) {
    return '$_libPrefix-ios-x86_64-sim.$_extDylib';
  }
  return isSimulator
      ? '$_libPrefix-ios-arm64-sim.$_extDylib'
      : '$_libPrefix-ios-arm64.$_extDylib';
}

Future<void> _download(String assetName, String destPath, Logger log) async {
  final file = File(destPath);
  await file.parent.create(recursive: true);

  final url = '$_baseUrl/$assetName';
  log.info('Downloading $url...');
  final res = await http.get(Uri.parse(url));

  if (res.statusCode != 200) {
    // Fallback logic for name transition
    final oldAssetName = assetName.replaceAll(_packageName, 'llama');
    if (oldAssetName != assetName) {
      log.warning('Trying fallback $oldAssetName');
      final oldUrl = '$_baseUrl/$oldAssetName';
      final oldRes = await http.get(Uri.parse(oldUrl));
      if (oldRes.statusCode == 200) {
        await file.writeAsBytes(oldRes.bodyBytes);
        return;
      }
    }
    throw Exception('Failed to download $url (${res.statusCode})');
  }
  await file.writeAsBytes(res.bodyBytes);
  log.info('Saved to $destPath');
}

Future<void> _thinBinary(
  String binaryPath,
  Architecture arch,
  Logger log,
) async {
  final info = await Process.run('lipo', ['-info', binaryPath]);
  final stdout = info.stdout.toString();
  if (!stdout.contains('Architectures in the fat file')) return;

  final archName = arch == Architecture.arm64 ? 'arm64' : 'x86_64';

  if (stdout.contains(archName)) {
    log.info('Thinning binary to $archName...');
    final tempPath = '$binaryPath.thin';
    await Process.run('lipo', [
      '-thin',
      archName,
      binaryPath,
      '-output',
      tempPath,
    ]);
    await File(tempPath).rename(binaryPath);
  }
}
