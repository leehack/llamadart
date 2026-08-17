@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import 'package:llamadart/src/hook/windows_cuda_pack.dart';

void main() {
  const nativeTag = 'native-test';
  const llamaTag = 'b-test';
  const llamaCommit = '1111111111111111111111111111111111111111';

  test('parses exact release provenance and asset digests', () {
    final release = WindowsCudaReleaseManifest.parse(
      jsonEncode({
        'tag': nativeTag,
        'llama_cpp_tag': llamaTag,
        'llama_cpp_commit': llamaCommit,
        'artifacts': [
          {'file': 'cuda.tar.gz', 'sha256': '2' * 64},
        ],
      }),
    );
    expect(release.nativeTag, nativeTag);
    expect(release.llamaCppTag, llamaTag);
    expect(release.assetDigests['cuda.tar.gz'], '2' * 64);
  });

  test(
    'verifies pack provenance, core, dependency family, and payloads',
    () async {
      await _withPack((directory, core, release) async {
        final manifest = await verifyWindowsCudaPackDirectory(
          directory: directory,
          expectedCudaMajor: 13,
          release: release,
          coreLibrary: core,
        );
        expect(manifest.cudaMajor, 13);
        expect(manifest.backendLibrary, 'ggml-cuda-13.dll');
      });
    },
  );

  test('rejects wrong core and corrupt payloads', () async {
    await _withPack((directory, core, release) async {
      final wrongCore = File(path.join(directory.parent.path, 'wrong-core.dll'))
        ..writeAsBytesSync(const [9]);
      await expectLater(
        verifyWindowsCudaPackDirectory(
          directory: directory,
          expectedCudaMajor: 13,
          release: release,
          coreLibrary: wrongCore,
        ),
        throwsA(isA<FormatException>()),
      );

      File(
        path.join(directory.path, 'ggml-cuda-13.dll'),
      ).writeAsBytesSync(const [8]);
      await expectLater(
        verifyWindowsCudaPackDirectory(
          directory: directory,
          expectedCudaMajor: 13,
          release: release,
          coreLibrary: core,
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });

  test('rejects an unexpected payload directory', () async {
    await _withPack((directory, core, release) async {
      Directory(path.join(directory.path, 'nested')).createSync();

      await expectLater(
        verifyWindowsCudaPackDirectory(
          directory: directory,
          expectedCudaMajor: 13,
          release: release,
          coreLibrary: core,
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });
}

Future<void> _withPack(
  Future<void> Function(
    Directory directory,
    File core,
    WindowsCudaReleaseManifest release,
  )
  body,
) async {
  final root = await Directory.systemTemp.createTemp('cuda-pack-test-');
  try {
    final directory = Directory(path.join(root.path, 'pack'))..createSync();
    final core = File(path.join(root.path, 'ggml-base.dll'))
      ..writeAsBytesSync(const [1, 2, 3]);
    final payload = <String, List<int>>{
      'ggml-cuda-13.dll': const [4],
      'cudart64_13.dll': const [5],
      'cublas64_13.dll': const [6],
      'cublasLt64_13.dll': const [7],
    };
    final files = <Map<String, Object?>>[];
    for (final MapEntry(key: name, value: bytes) in payload.entries) {
      final file = File(path.join(directory.path, name))
        ..writeAsBytesSync(bytes);
      files.add({
        'name': name,
        'sha256': await sha256File(file),
        'size': bytes.length,
      });
    }
    File(path.join(directory.path, 'cuda-pack.json')).writeAsStringSync(
      jsonEncode({
        'contract_version': windowsCudaPackContractVersion,
        'native_release_tag': 'native-test',
        'llama_cpp_tag': 'b-test',
        'llama_cpp_commit': '1' * 40,
        'platform': 'windows',
        'arch': 'x64',
        'backend': 'cuda',
        'cuda_version': '13.3',
        'cuda_major': 13,
        'backend_library': 'ggml-cuda-13.dll',
        'compatibility': const {
          'minimum_compute_capability': 75,
          'minimum_driver_family': 580,
          'minimum_driver_api': 13000,
        },
        'core_compatibility': {
          'library': 'ggml-base.dll',
          'sha256': await sha256File(core),
        },
        'files': files,
      }),
    );
    final release = WindowsCudaReleaseManifest.parse(
      jsonEncode({
        'tag': 'native-test',
        'llama_cpp_tag': 'b-test',
        'llama_cpp_commit': '1' * 40,
        'artifacts': const <Object?>[],
      }),
    );
    await body(directory, core, release);
  } finally {
    await root.delete(recursive: true);
  }
}
