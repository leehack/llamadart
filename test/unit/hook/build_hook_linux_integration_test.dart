@TestOn('vm')
library;

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import '../../../hook/build.dart' as build_hook;

void main() {
  final nativeTag = _readHookNativeTag();
  final litertVersion = _readHookLiteRtLmVersion();
  final cacheRelativeDir =
      '.dart_tool/llamadart/native_bundles/$nativeTag/linux-x64';
  final bundleRelativePath = '$cacheRelativeDir/extracted';
  final bundleDir = Directory(bundleRelativePath);
  final backupDir = Directory('$bundleRelativePath.__hook_test_backup');
  const historicalNativeTag = 'b10545';
  final historicalBundleRelativePath =
      '.dart_tool/llamadart/native_bundles/$historicalNativeTag/'
      'linux-x64/extracted';
  final historicalBundleDir = Directory(historicalBundleRelativePath);
  final historicalBackupDir = Directory(
    '$historicalBundleRelativePath.__hook_test_backup',
  );
  final litertBundleDir = Directory(
    '.dart_tool/llamadart/litert_lm/$litertVersion/linux/x64',
  );
  final litertBackupDir = Directory(
    '${litertBundleDir.path}.__hook_test_backup',
  );

  setUpAll(() async {
    if (backupDir.existsSync()) {
      await backupDir.delete(recursive: true);
    }
    if (historicalBackupDir.existsSync()) {
      await historicalBackupDir.delete(recursive: true);
    }
    if (litertBackupDir.existsSync()) {
      await litertBackupDir.delete(recursive: true);
    }

    if (bundleDir.existsSync()) {
      await bundleDir.rename(backupDir.path);
    }
    if (historicalBundleDir.existsSync()) {
      await historicalBundleDir.rename(historicalBackupDir.path);
    }
    if (litertBundleDir.existsSync()) {
      await litertBundleDir.rename(litertBackupDir.path);
    }
  });

  setUp(() async {
    if (bundleDir.existsSync()) {
      await bundleDir.delete(recursive: true);
    }
    await _writeBundleLibraries(bundleDir, const [
      'libllamadart.so',
      'libmtmd.so',
      'libllama.so',
      'libllama-common.so',
      'libggml.so',
      'libggml-base.so',
      'libggml-cpu.so',
      'libggml-vulkan.so',
    ]);
    await _writeBundleLibraries(historicalBundleDir, const [
      'libllamadart.so',
      'libmtmd.so',
      'libllama.so',
      'libllama-common.so',
      'libggml.so',
      'libggml-base.so',
      'libggml-cpu.so',
      'libggml-vulkan.so',
    ]);
    await _writeBundleLibraries(litertBundleDir, _linuxLiteRtLibraries);
  });

  tearDownAll(() async {
    if (bundleDir.existsSync()) {
      await bundleDir.delete(recursive: true);
    }
    if (backupDir.existsSync()) {
      await backupDir.rename(bundleDir.path);
    }
    if (historicalBundleDir.existsSync()) {
      await historicalBundleDir.delete(recursive: true);
    }
    if (historicalBackupDir.existsSync()) {
      await historicalBackupDir.rename(historicalBundleDir.path);
    }
    if (litertBundleDir.existsSync()) {
      await litertBundleDir.delete(recursive: true);
    }
    if (litertBackupDir.existsSync()) {
      await litertBackupDir.rename(litertBundleDir.path);
    }
  });

  test(
    'build hook emits linux SONAME aliases and all runtimes by default',
    () async {
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
          expect(codeAssetIds, contains('package:llamadart/llamadart'));

          final emittedNames = codeAssets
              .map((asset) => path.basename(asset.file!.toFilePath()))
              .toSet();

          expect(emittedNames, contains('libllamadart.so'));
          expect(emittedNames, contains('libmtmd.so'));
          expect(emittedNames, contains('libmtmd.so.0'));
          expect(emittedNames, isNot(contains('libmtmd.so.SOVERSION')));
          expect(emittedNames, contains('libllama.so'));
          expect(emittedNames, contains('libllama.so.0'));
          expect(emittedNames, contains('libllama-common.so'));
          expect(emittedNames, contains('libllama-common.so.0'));
          expect(emittedNames, contains('libggml.so'));
          expect(emittedNames, contains('libggml.so.0'));
          expect(emittedNames, contains('libggml-base.so'));
          expect(emittedNames, contains('libggml-base.so.0'));
          for (final library in _linuxLiteRtLibraries) {
            expect(emittedNames, contains(library));
          }
          for (final assetName in _linuxLiteRtAssetNames) {
            expect(codeAssetIds, contains('package:llamadart/$assetName'));
          }
        },
      );
    },
  );

  test('build hook preserves historical linux mtmd SONAME alias', () async {
    await testCodeBuildHook(
      mainMethod: build_hook.main,
      targetOS: OS.linux,
      targetArchitecture: Architecture.x64,
      userDefines: PackageUserDefines(
        workspacePubspec: PackageUserDefinesSource(
          defines: const {'llamadart_native_tag': historicalNativeTag},
          basePath: Directory.current.uri,
        ),
      ),
      check: (input, output) {
        final emittedNames = output.assets.encodedAssets
            .where((asset) => asset.isCodeAsset)
            .map((asset) => asset.asCodeAsset)
            .map((asset) => path.basename(asset.file!.toFilePath()))
            .toSet();

        expect(emittedNames, contains('libmtmd.so'));
        expect(emittedNames, contains('libmtmd.so.0'));
        expect(emittedNames, contains('libmtmd.so.SOVERSION'));
      },
    );
  });

  test('build hook fails when runtimes config selects none', () async {
    for (final rawUserConfig in const <Object>['none', false]) {
      await expectLater(
        testCodeBuildHook(
          mainMethod: build_hook.main,
          targetOS: OS.linux,
          targetArchitecture: Architecture.x64,
          userDefines: PackageUserDefines(
            workspacePubspec: PackageUserDefinesSource(
              defines: {'llamadart_native_runtimes': rawUserConfig},
              basePath: Directory.current.uri,
            ),
          ),
          check: (_, _) {},
        ),
        throwsA(
          isA<Exception>().having(
            (error) => error.toString(),
            'message',
            contains('No native runtimes selected for linux-x64'),
          ),
        ),
      );
    }
  });
}

String _readHookNativeTag() {
  final source = File('hook/build.dart').readAsStringSync();
  final match = RegExp(r"const _llamaCppTag = '([^']+)';").firstMatch(source);
  if (match == null) {
    throw StateError('Could not locate _llamaCppTag in hook/build.dart');
  }
  return match.group(1)!;
}

String _readHookLiteRtLmVersion() {
  final source = File('hook/build.dart').readAsStringSync();
  final match = RegExp(
    r"const _litertLmVersion = '([^']+)';",
  ).firstMatch(source);
  if (match == null) {
    throw StateError('Could not locate _litertLmVersion in hook/build.dart');
  }
  return match.group(1)!;
}

const List<String> _linuxLiteRtLibraries = [
  'libGemmaModelConstraintProvider.so',
  'libLiteRt.so',
  'libLiteRtLm.so',
  'libwebgpu_dawn.so',
  'libLiteRtTopKWebGpuSampler.so',
  'libLiteRtWebGpuAccelerator.so',
];

const List<String> _linuxLiteRtAssetNames = [
  'litert_lm_GemmaModelConstraintProvider',
  'litert_lm_LiteRt',
  'litert_lm_LiteRtLm',
  'litert_lm_webgpu_dawn',
  'litert_lm_LiteRtTopKWebGpuSampler',
  'litert_lm_LiteRtWebGpuAccelerator',
];

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
