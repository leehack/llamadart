@TestOn('vm')
library;

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import '../../../hook/build.dart' as build_hook;

void main() {
  final nativeTag = _readHookConst('_llamaCppTag');
  final litertVersion = _readHookConst('_litertLmVersion');
  final nativeBundleDir = Directory(
    '.dart_tool/llamadart/native_bundles/$nativeTag/linux-x64/extracted',
  );
  final litertBundleDir = Directory(
    '.dart_tool/llamadart/litert_lm/$litertVersion/linux/x64',
  );
  final nativeBackupDir = Directory('${nativeBundleDir.path}.__litert_test');
  final litertBackupDir = Directory('${litertBundleDir.path}.__litert_test');

  setUpAll(() async {
    await _backupDirectory(nativeBundleDir, nativeBackupDir);
    await _backupDirectory(litertBundleDir, litertBackupDir);
  });

  setUp(() async {
    await _writeBundleLibraries(nativeBundleDir, const [
      'libllamadart.so',
      'libllama.so',
      'libggml.so',
      'libggml-base.so',
      'libggml-cpu.so',
    ]);
    await _writeBundleLibraries(litertBundleDir, const [
      'libLiteRtLm.so',
      'libStreamProxy.so',
    ]);
  });

  tearDownAll(() async {
    await _restoreDirectory(nativeBundleDir, nativeBackupDir);
    await _restoreDirectory(litertBundleDir, litertBackupDir);
  });

  test('LiteRT-LM bundle specs require StreamProxy companions', () {
    final source = File('hook/build.dart').readAsStringSync();
    final specs = RegExp(
      r'requiredLibraries:\s*\{([^}]+)\}',
    ).allMatches(source).map((match) => match.group(1)!).toList();
    final liteRtSpecs = specs
        .where((spec) => spec.contains('LiteRtLm') || spec.contains('LiteRt'))
        .toList();

    expect(liteRtSpecs, hasLength(7));
    for (final spec in liteRtSpecs) {
      expect(spec, contains('StreamProxy'));
    }
  });

  test('build hook emits Linux LiteRT-LM runtime and StreamProxy', () async {
    await testCodeBuildHook(
      mainMethod: build_hook.main,
      targetOS: OS.linux,
      targetArchitecture: Architecture.x64,
      check: (input, output) {
        final codeAssets = output.assets.encodedAssets
            .where((asset) => asset.isCodeAsset)
            .map((asset) => asset.asCodeAsset)
            .toList(growable: false);

        final codeAssetIds = codeAssets.map((asset) => asset.id).toSet();
        final emittedNames = codeAssets
            .map((asset) => path.basename(asset.file!.toFilePath()))
            .toSet();

        expect(codeAssetIds, contains('package:llamadart/llamadart'));
        expect(codeAssetIds, contains('package:llamadart/litert_lm_LiteRtLm'));
        expect(
          codeAssetIds,
          contains('package:llamadart/litert_lm_StreamProxy'),
        );
        expect(emittedNames, contains('libLiteRtLm.so'));
        expect(emittedNames, contains('libStreamProxy.so'));
      },
    );
  });
}

String _readHookConst(String name) {
  final source = File('hook/build.dart').readAsStringSync();
  final match = RegExp("const $name = '([^']+)';").firstMatch(source);
  if (match == null) {
    throw StateError('Could not locate $name in hook/build.dart');
  }
  return match.group(1)!;
}

Future<void> _backupDirectory(Directory directory, Directory backup) async {
  if (backup.existsSync()) {
    await backup.delete(recursive: true);
  }
  if (directory.existsSync()) {
    await directory.rename(backup.path);
  }
}

Future<void> _restoreDirectory(Directory directory, Directory backup) async {
  if (directory.existsSync()) {
    await directory.delete(recursive: true);
  }
  if (backup.existsSync()) {
    await backup.rename(directory.path);
  }
}

Future<void> _writeBundleLibraries(
  Directory bundleDir,
  List<String> fileNames,
) async {
  if (bundleDir.existsSync()) {
    await bundleDir.delete(recursive: true);
  }
  await bundleDir.create(recursive: true);
  for (final name in fileNames) {
    await File(path.join(bundleDir.path, name)).writeAsString('fake-$name');
  }
}
