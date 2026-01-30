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

void main(List<String> args) async {
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen(
    (r) => print('${r.level.name}: ${r.time}: ${r.message}'),
  );
  final log = Logger('llamadart_hook');

  await build(args, (input, output) async {
    final code = input.config.code;
    final (os, arch) = (code.targetOS, code.targetArchitecture);

    log.info('Hook Start: $os-$arch');

    try {
      // 1. Resolve Platform Configuration
      final (relPath, fileName) = switch ((os, arch)) {
        (OS.windows, _) => ('windows/x64', 'libllamadart.dll'),
        (OS.linux, Architecture.arm64) => ('linux/arm64', 'libllamadart.so'),
        (OS.linux, Architecture.x64) => ('linux/x64', 'libllamadart.so'),
        (OS.macOS, _) => ('macos/${arch.name}', 'libllamadart.a'),
        (OS.android, Architecture.arm64) => (
          'android/arm64',
          'libllamadart.so',
        ),
        (OS.android, Architecture.x64) => ('android/x64', 'libllamadart.so'),
        (OS.iOS, _) => ('ios', _getIOSFileName(input.config, arch)),
        _ => (null, null),
      };

      if (relPath == null || fileName == null) {
        log.warning('Unsupported platform: $os-$arch');
        return;
      }

      // 2. Hybrid Search Strategy
      final localBinDir = path.join(
        input.packageRoot.toFilePath(),
        'third_party',
        'bin',
        relPath,
      );
      final localAssetPath = path.join(localBinDir, fileName);

      final cacheDir = path.join(
        input.packageRoot.toFilePath(),
        '.dart_tool',
        'llamadart',
        'binaries',
        relPath,
      );
      final cacheAssetPath = path.join(cacheDir, fileName);

      String? finalAssetPath;

      if (_exists(localAssetPath)) {
        log.info('Using local binary: $localAssetPath');
        finalAssetPath = localAssetPath;
      } else {
        log.info('Local binary not found, ensuring cached assets...');
        await _ensureAssets(
          targetDir: cacheDir,
          os: os,
          arch: arch,
          log: log,
          config: input.config,
        );
        if (_exists(cacheAssetPath)) {
          finalAssetPath = cacheAssetPath;
        }
      }

      if (finalAssetPath == null) {
        log.severe('Missing Asset: $fileName for $os-$arch');
        return;
      }

      // 3. MacOS Thinning
      if (os == OS.macOS && finalAssetPath.endsWith('.dylib')) {
        await _thinBinary(finalAssetPath, arch, log);
      }

      // 4. Report Asset
      final absoluteAssetPath = path.absolute(finalAssetPath);
      log.info('Reporting: $absoluteAssetPath');

      output.assets.code.add(
        CodeAsset(
          package: 'llamadart',
          name: 'llamadart',
          linkMode: (os == OS.iOS || os == OS.macOS)
              ? StaticLinking()
              : DynamicLoadingBundled(),
          file: Uri.file(absoluteAssetPath),
        ),
      );
    } catch (e, st) {
      log.severe('FATAL ERROR in hook', e, st);
      rethrow;
    }
  });
}

String _getIOSFileName(BuildConfig config, Architecture arch) {
  // Use a string check on the target to detect simulator vs device
  // Standard targets are 'ios_arm64', 'ios_arm64_simulator', 'ios_x64_simulator'
  final target = config.code.targetOS.toString().toLowerCase();

  if (arch == Architecture.x64) return 'libllamadart-ios-x64-sim.a';

  // For arm64, it could be both. We check if the config string contains 'simulator'
  if (config.toString().toLowerCase().contains('simulator')) {
    return 'libllamadart-ios-arm64-sim.a';
  }
  return 'libllamadart-ios-arm64.a';
}

bool _exists(String p) => File(p).existsSync() || Directory(p).existsSync();

Future<void> _ensureAssets({
  required String targetDir,
  required OS os,
  required Architecture arch,
  required Logger log,
  required BuildConfig config,
}) async {
  final dir = Directory(targetDir);
  if (!dir.existsSync()) await dir.create(recursive: true);

  switch (os) {
    case OS.iOS:
      final fileName = _getIOSFileName(config, arch);
      await _download(fileName, path.join(targetDir, fileName), log);
    case OS.macOS:
      final archStr = arch == Architecture.arm64 ? 'arm64' : 'x64';
      await _download(
        'libllamadart-macos-$archStr.a',
        path.join(targetDir, 'libllamadart.a'),
        log,
      );
    case OS.windows:
      await _download(
        'libllamadart-windows-x64.dll',
        path.join(targetDir, 'libllamadart.dll'),
        log,
      );
    case OS.linux:
    case OS.android:
      final osStr = os == OS.android ? 'android' : 'linux';
      final archStr = arch == Architecture.arm64 ? 'arm64' : 'x64';
      await _download(
        'libllamadart-$osStr-$archStr.so',
        path.join(targetDir, 'libllamadart.so'),
        log,
      );
    default:
      throw UnsupportedError('Unsupported OS: $os');
  }
}

Future<void> _download(String assetName, String destPath, Logger log) async {
  final file = File(destPath);
  if (file.existsSync()) return;

  final url = '$_baseUrl/$assetName';
  log.info('Downloading $url...');
  final res = await http.get(Uri.parse(url));

  if (res.statusCode != 200) {
    // Fallback logic for name transition
    final oldAssetName = assetName.replaceAll('llamadart', 'llama');
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
