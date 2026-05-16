@TestOn('vm')
library;

import 'dart:io';

import 'package:archive/archive.dart';
import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import '../../../hook/build.dart' as build_hook;

void main() {
  final nativeTag = _readHookNativeTag();
  final cacheRelativeDir =
      '.dart_tool/llamadart/native_bundles/$nativeTag/windows-x64';
  final bundleRelativePath = '$cacheRelativeDir/extracted';
  final bundleDir = Directory(bundleRelativePath);
  final backupDir = Directory('$bundleRelativePath.__hook_test_backup');
  final archivePath =
      '$cacheRelativeDir/llamadart-native-windows-x64-$nativeTag.tar.gz';
  final archiveFile = File(archivePath);

  setUpAll(() async {
    if (backupDir.existsSync()) {
      await backupDir.delete(recursive: true);
    }

    if (bundleDir.existsSync()) {
      await bundleDir.rename(backupDir.path);
    }
  });

  setUp(() async {
    if (bundleDir.existsSync()) {
      await bundleDir.delete(recursive: true);
    }
    await _writeBundleLibraries(bundleDir, const [
      'llamadart-windows-x64.dll',
      'llama-windows-x64.dll',
      'ggml-windows-x64.dll',
      'ggml-base-windows-x64.dll',
      'ggml-cpu-windows-x64.dll',
      'ggml-vulkan-windows-x64.dll',
      'ggml-cuda-windows-x64.dll',
      'cudart64_12.dll',
      'cublas64_12.dll',
      'cublaslt64_12.dll',
    ]);

    if (archiveFile.existsSync()) {
      await archiveFile.delete();
    }
  });

  tearDownAll(() async {
    if (archiveFile.existsSync()) {
      await archiveFile.delete();
    }
    if (bundleDir.existsSync()) {
      await bundleDir.delete(recursive: true);
    }
    if (backupDir.existsSync()) {
      await backupDir.rename(bundleDir.path);
    }
  });

  test(
    'build hook selects configured backend modules and emits primary asset',
    () async {
      final userDefines = PackageUserDefines(
        workspacePubspec: PackageUserDefinesSource(
          defines: {
            'llamadart_native_backends': {
              'platforms': {
                'windows-x64': ['vulkan'],
              },
            },
          },
          basePath: Directory.current.uri,
        ),
      );

      await testCodeBuildHook(
        mainMethod: build_hook.main,
        targetOS: OS.windows,
        targetArchitecture: Architecture.x64,
        userDefines: userDefines,
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

          expect(emittedNames, contains('ggml-vulkan-windows-x64.dll'));
          expect(emittedNames, contains('ggml-cpu-windows-x64.dll'));
          expect(emittedNames, contains('llamadart-windows-x64.dll'));
          expect(emittedNames, contains('llama-windows-x64.dll'));
          expect(emittedNames, contains('ggml-windows-x64.dll'));
          expect(emittedNames, contains('ggml-base-windows-x64.dll'));
          expect(emittedNames, isNot(contains('ggml-cuda-windows-x64.dll')));
          expect(emittedNames, isNot(contains('cudart64_12.dll')));
          expect(emittedNames, isNot(contains('cublas64_12.dll')));
          expect(emittedNames, isNot(contains('cublaslt64_12.dll')));
        },
      );
    },
  );

  test('build hook refreshes stale windows cache from local archive', () async {
    await _writeBundleLibraries(bundleDir, const [
      'llamadart-windows-x64.dll',
      'llama-windows-x64.dll',
      'ggml-windows-x64.dll',
      'ggml-base-windows-x64.dll',
      'ggml-cpu-windows-x64.dll',
      'ggml-cuda-windows-x64.dll',
    ]);

    await _writeBundleArchive(
      archiveFile: archiveFile,
      files: const [
        'llamadart-windows-x64.dll',
        'llama-windows-x64.dll',
        'ggml-windows-x64.dll',
        'ggml-base-windows-x64.dll',
        'ggml-cpu-windows-x64.dll',
        'ggml-cuda-windows-x64.dll',
        'cudart64_12.dll',
        'cublas64_12.dll',
        'cublaslt64_12.dll',
      ],
    );

    final userDefines = PackageUserDefines(
      workspacePubspec: PackageUserDefinesSource(
        defines: {
          'llamadart_native_backends': {
            'platforms': {
              'windows-x64': ['cuda'],
            },
          },
        },
        basePath: Directory.current.uri,
      ),
    );

    await testCodeBuildHook(
      mainMethod: build_hook.main,
      targetOS: OS.windows,
      targetArchitecture: Architecture.x64,
      userDefines: userDefines,
      check: (input, output) {
        final codeAssets = output.assets.encodedAssets
            .where((asset) => asset.isCodeAsset)
            .map((asset) => asset.asCodeAsset)
            .toList(growable: false);

        final emittedNames = codeAssets
            .map((asset) => path.basename(asset.file!.toFilePath()))
            .toSet();

        expect(emittedNames, contains('ggml-cuda-windows-x64.dll'));
        expect(emittedNames, contains('cudart64_12.dll'));
        expect(emittedNames, contains('cublas64_12.dll'));
        expect(emittedNames, contains('cublaslt64_12.dll'));
      },
    );
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

Future<void> _writeBundleArchive({
  required File archiveFile,
  required List<String> files,
}) async {
  final archive = Archive();
  for (final fileName in files) {
    final content = 'archive-$fileName';
    archive.addFile(ArchiveFile(fileName, content.length, content.codeUnits));
  }

  final tarBytes = TarEncoder().encode(archive);
  final gzBytes = GZipEncoder().encode(tarBytes);

  await archiveFile.parent.create(recursive: true);
  await archiveFile.writeAsBytes(gzBytes);
}
