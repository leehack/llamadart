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
        (OS.windows, _) => ('windows/x64', 'libllama.dll'),
        (OS.linux, Architecture.arm64) => ('linux/arm64', 'libllama.so'),
        (OS.linux, Architecture.x64) => ('linux/x64', 'libllama.so'),
        (OS.macOS, _) => ('macos/${arch.name}', 'libllama.dylib'),
        (OS.android, Architecture.arm64) => ('android/arm64', 'libllama.so'),
        (OS.android, Architecture.x64) => ('android/x64', 'libllama.so'),
        (OS.iOS, _) => ('ios', 'llama.xcframework'),
        _ => (null, null),
      };

      if (relPath == null || fileName == null) {
        log.warning('Unsupported platform: $os-$arch');
        return;
      }

      // 2. Hybrid Search Strategy
      // Path A: Local Build Output (Developer mode)
      final localBinDir = path.join(
        input.packageRoot.toFilePath(),
        'third_party',
        'bin',
        relPath,
      );
      final localAssetPath = path.join(localBinDir, fileName);

      // Path B: Download Cache (User mode)
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
        await _ensureAssets(targetDir: cacheDir, os: os, arch: arch, log: log);
        if (_exists(cacheAssetPath)) {
          finalAssetPath = cacheAssetPath;
        }
      }

      if (finalAssetPath == null) {
        log.severe('Missing Asset: $fileName for $os-$arch');
        return;
      }

      // 3. MacOS Thinning (only if it's a dylib and we downloaded a fat one)
      if (os == OS.macOS && finalAssetPath.endsWith('.dylib')) {
        await _thinBinary(finalAssetPath, arch, log);
      }

      // 4. Report Asset
      final absoluteAssetPath = path.absolute(finalAssetPath);
      log.info('Reporting: $absoluteAssetPath');

      output.assets.code.add(
        CodeAsset(
          package: 'llamadart',
          name: 'llama_cpp',
          linkMode: DynamicLoadingBundled(),
          // For iOS/macOS frameworks, providing the directory is preferred
          file: os == OS.iOS
              ? Uri.directory(absoluteAssetPath)
              : Uri.file(absoluteAssetPath),
        ),
      );
    } catch (e, st) {
      log.severe('FATAL ERROR in hook', e, st);
      rethrow;
    }
  });
}

bool _exists(String p) => File(p).existsSync() || Directory(p).existsSync();

Future<void> _ensureAssets({
  required String targetDir,
  required OS os,
  required Architecture arch,
  required Logger log,
}) async {
  final dir = Directory(targetDir);
  if (!dir.existsSync()) await dir.create(recursive: true);

  switch (os) {
    case OS.iOS:
      await _setupIOS(targetDir, log);
    case OS.macOS:
      await _download(
        'libllama-macos.dylib',
        path.join(targetDir, 'libllama.dylib'),
        log,
      );
    case OS.windows:
      await _download(
        'libllama-windows-x64.dll',
        path.join(targetDir, 'libllama.dll'),
        log,
      );
    case OS.linux:
    case OS.android:
      final osStr = os == OS.android ? 'android' : 'linux';
      final archStr = arch == Architecture.arm64 ? 'arm64' : 'x64';
      await _download(
        'libllama-$osStr-$archStr.so',
        path.join(targetDir, 'libllama.so'),
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
    throw Exception('Failed to download $url (${res.statusCode})');
  }
  await file.writeAsBytes(res.bodyBytes);
  log.info('Saved to $destPath');
}

Future<void> _setupIOS(String targetDir, Logger log) async {
  final frameworkPath = path.join(targetDir, 'llama.xcframework');
  if (Directory(frameworkPath).existsSync()) return;

  final zipName = 'llama-ios-xcframework.zip';
  final zipPath = path.join(targetDir, zipName);

  await _download(zipName, zipPath, log);

  log.info('Extracting $zipName...');
  final result = await Process.run('unzip', ['-o', zipPath, '-d', targetDir]);
  if (result.exitCode != 0) throw Exception('Unzip failed: ${result.stderr}');

  if (File(zipPath).existsSync()) await File(zipPath).delete();
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
