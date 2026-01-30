import 'dart:io';
import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;

// Constants for release
const _releaseTag = 'libs-v0.2.0';
const _baseUrl =
    'https://github.com/leehack/llamadart/releases/download/$_releaseTag';

void main(List<String> args) async {
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen(
    (r) => print('${r.level.name}: ${r.time}: ${r.message}'),
  );
  final log = Logger('llamadart_hook');

  await build(args, (input, output) async {
    final code = input.config.code;
    final (os, arch) = (code.targetOS, code.targetArchitecture);

    final binariesDir = path.join(
      input.packageRoot.toFilePath(),
      '.dart_tool',
      'llamadart',
      'binaries',
    );

    log.info('Hook Start: $os-$arch');

    try {
      // 1. Resolve Platform Configuration
      final (relPath, fileName) = switch ((os, arch)) {
        (OS.windows, _) => ('windows', 'libllama.dll'),
        (OS.linux, Architecture.arm64) => ('linux-arm64', 'libllama.so'),
        (OS.linux, Architecture.x64) => ('linux-x64', 'libllama.so'),
        (OS.macOS, _) => ('macos', 'libllama.dylib'),
        (OS.android, Architecture.arm64) => ('android-arm64', 'libllama.so'),
        (OS.android, Architecture.x64) => ('android-x64', 'libllama.so'),
        (OS.iOS, _) => (
          'ios',
          'llama.xcframework/ios-arm64/llama.framework/llama',
        ),
        _ => (null, null),
      };

      if (relPath == null || fileName == null) {
        log.warning('Unsupported platform: $os-$arch');
        return;
      }

      // Important: Use architecture-specific subfolder to avoid conflicts during universal builds
      final targetDir = path.join(binariesDir, relPath, arch.name);
      final assetPath = path.join(targetDir, fileName);

      // 2. Setup (Download/Extract)
      await _ensureAssets(targetDir: targetDir, os: os, arch: arch, log: log);

      // 3. MacOS Thinning
      // If we downloaded a fat binary, thin it to the requested architecture
      if (os == OS.macOS && File(assetPath).existsSync()) {
        await _thinBinary(assetPath, arch, log);
      }

      // 4. Report Asset
      if (File(assetPath).existsSync()) {
        final absoluteAssetPath = path.absolute(assetPath);
        log.info('Reporting: $absoluteAssetPath');

        output.assets.code.add(
          CodeAsset(
            package: 'llamadart',
            name: 'llama_cpp',
            linkMode: DynamicLoadingBundled(),
            file: Uri.file(absoluteAssetPath),
          ),
        );
      } else {
        log.severe('Missing Asset: $assetPath');
      }
    } catch (e, st) {
      log.severe('FATAL ERROR in hook', e, st);
      rethrow;
    }
  });
}

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
