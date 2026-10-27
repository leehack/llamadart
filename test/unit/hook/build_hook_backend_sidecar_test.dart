@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import 'package:llamadart/src/hook/native_archive_digest.dart';
import 'package:llamadart/src/hook/native_release_manifest.dart';

import '../../../hook/build.dart' as build_hook;
import '../../support/runtime_bundle_http_fixture.dart';

const _tag = 'v9.9.8';
const _coreArchive = 'llamadart-native-windows-x64-$_tag.tar.gz';
const _sidecarArchive = 'llamadart-native-windows-x64-cuda12-$_tag.tar.gz';

const _coreLibraries = [
  'llamadart.dll',
  'llama.dll',
  'llama-common.dll',
  'mtmd.dll',
  'ggml.dll',
  'ggml-base.dll',
  'ggml-cpu.dll',
  'ggml-vulkan.dll',
];

const _cudaLibraries = [
  'ggml-cuda.dll',
  'cudart64_12.dll',
  'cublas64_12.dll',
  'cublasLt64_12.dll',
];

String _url(String asset) =>
    'https://github.com/leehack/llamadart-native/releases/download/$_tag/'
    '$asset';

final _sumsUrl = _url('SHA256SUMS');
final _manifestUrl = _url('assets.json');
final _coreUrl = _url(_coreArchive);
final _sidecarUrl = _url(_sidecarArchive);

void main() {
  final releaseCacheDir = Directory(
    path.join('.dart_tool', 'llamadart', 'native_bundles', _tag),
  );
  final backup = Directory('${releaseCacheDir.path}.__sidecar_test_backup');

  setUpAll(() async {
    if (releaseCacheDir.existsSync()) {
      await releaseCacheDir.rename(backup.path);
    }
  });

  setUp(() async {
    if (releaseCacheDir.existsSync()) {
      await releaseCacheDir.delete(recursive: true);
    }
  });

  tearDownAll(() async {
    if (releaseCacheDir.existsSync()) {
      await releaseCacheDir.delete(recursive: true);
    }
    if (backup.existsSync()) {
      await backup.rename(releaseCacheDir.path);
    }
  });

  final core = _archive('core', _coreLibraries);
  final sidecar = _archive('sidecar', _cudaLibraries);

  Map<String, List<int>> release({
    Object? manifest,
    List<int>? sidecarBody,
    bool listSidecar = true,
  }) => {
    _sumsUrl: sha256SumsFor({
      _coreArchive: core,
      if (listSidecar) _sidecarArchive: sidecar,
    }).codeUnits,
    if (manifest != null) _manifestUrl: utf8.encode(jsonEncode(manifest)),
    _coreUrl: core,
    _sidecarUrl: sidecarBody ?? sidecar,
  };

  group('a contract 2 release', () {
    test('adds the CUDA sidecar when cuda is selected', () async {
      final fixture = RuntimeBundleHttpFixture(release(manifest: _manifest()));

      final libraries = await _runHook(fixture, backends: ['cpu', 'cuda']);

      expect(fixture.requests, [
        _sumsUrl,
        _manifestUrl,
        _coreUrl,
        _sumsUrl,
        _sidecarUrl,
      ]);
      expect(libraries, containsPair('ggml-cuda.dll', 'sidecar-ggml-cuda.dll'));
      expect(
        libraries,
        containsPair('cublasLt64_12.dll', 'sidecar-cublasLt64_12.dll'),
      );
      expect(libraries, containsPair('ggml-cpu.dll', 'core-ggml-cpu.dll'));
      expect(libraries, isNot(contains('ggml-vulkan.dll')));
    });

    test('reuses the cached sidecar and manifest offline', () async {
      await _runHook(
        RuntimeBundleHttpFixture(release(manifest: _manifest())),
        backends: ['cpu', 'cuda'],
      );
      final offline = RuntimeBundleHttpFixture.offline();

      final libraries = await _runHook(offline, backends: ['cpu', 'cuda']);

      expect(offline.requests, isEmpty);
      expect(libraries, contains('ggml-cuda.dll'));
    });

    test('skips the sidecar unless cuda is selected', () async {
      final fixture = RuntimeBundleHttpFixture(release(manifest: _manifest()));

      final libraries = await _runHook(fixture);

      expect(fixture.requests, [_sumsUrl, _manifestUrl, _coreUrl]);
      expect(libraries.keys, containsAll(['ggml-cpu.dll', 'ggml-vulkan.dll']));
      expect(libraries.keys.where((name) => name.contains('cu')), isEmpty);
    });

    test(
      'fails instead of falling back when it lists no CUDA sidecar',
      () async {
        final fixture = RuntimeBundleHttpFixture(
          release(manifest: _manifest(sidecars: false), listSidecar: false),
        );

        await expectLater(
          _runHook(fixture, backends: ['cuda']),
          throwsA(
            isA<NativeHookContractException>().having(
              (error) => error.message,
              'message',
              allOf(
                contains('selects cuda for windows-x64'),
                contains('leehack/llamadart-native@$_tag (hook contract 2)'),
                contains('only as a sidecar archive'),
              ),
            ),
          ),
        );
        expect(fixture.requests, [_sumsUrl, _manifestUrl, _coreUrl]);
      },
    );

    test('rejects a sidecar that differs from SHA256SUMS', () async {
      final fixture = RuntimeBundleHttpFixture(
        release(
          manifest: _manifest(),
          sidecarBody: _archive('tampered', _cudaLibraries),
        ),
      );

      await expectLater(
        _runHook(fixture, backends: ['cuda']),
        throwsA(
          isA<NativeArchiveDigestException>().having(
            (error) => error.message,
            'message',
            allOf(contains(_sidecarArchive), contains('was deleted')),
          ),
        ),
      );
    });

    test('rejects a sidecar without the backend module', () async {
      final missingModule = _archive('sidecar', _cudaLibraries.sublist(1));
      final fixture = RuntimeBundleHttpFixture({
        ...release(manifest: _manifest()),
        _sumsUrl: sha256SumsFor({
          _coreArchive: core,
          _sidecarArchive: missingModule,
        }).codeUnits,
        _sidecarUrl: missingModule,
      });

      await expectLater(
        _runHook(fixture, backends: ['cuda']),
        throwsA(
          isA<NativeHookContractException>().having(
            (error) => error.message,
            'message',
            contains('holds no ggml-cuda module'),
          ),
        ),
      );
    });

    test('rejects a sidecar without the CUDA runtime', () async {
      final noRuntime = _archive('sidecar', _cudaLibraries.sublist(0, 1));
      final fixture = RuntimeBundleHttpFixture({
        ...release(manifest: _manifest()),
        _sumsUrl: sha256SumsFor({
          _coreArchive: core,
          _sidecarArchive: noRuntime,
        }).codeUnits,
        _sidecarUrl: noRuntime,
      });

      await expectLater(
        _runHook(fixture, backends: ['cuda']),
        throwsA(
          isA<NativeHookContractException>().having(
            (error) => error.message,
            'message',
            contains('missing runtime dependencies'),
          ),
        ),
      );
    });
  });

  group('an unsupported hook contract', () {
    test('fails before the core archive is downloaded', () async {
      final fixture = RuntimeBundleHttpFixture(
        release(manifest: _manifest(contract: 3)),
      );

      await expectLater(
        _runHook(fixture),
        throwsA(
          isA<NativeHookContractException>().having(
            (error) => error.message,
            'message',
            contains('requires native hook contract 3'),
          ),
        ),
      );
      expect(fixture.requests, [_sumsUrl, _manifestUrl]);
    });

    test('fails a CUDA build over a cached core bundle', () async {
      await _runHook(RuntimeBundleHttpFixture(release(manifest: _manifest())));
      await File(path.join(releaseCacheDir.path, 'assets.json')).delete();
      final fixture = RuntimeBundleHttpFixture(
        release(manifest: _manifest(contract: 3)),
      );

      await expectLater(
        _runHook(fixture, backends: ['cuda']),
        throwsA(isA<NativeHookContractException>()),
      );
      expect(fixture.requests, [_manifestUrl]);
    });
  });

  group('a release without assets.json', () {
    test('keeps CUDA from the core bundle', () async {
      final legacyCore = _archive('legacy', [
        ..._coreLibraries,
        ..._cudaLibraries,
      ]);
      final fixture = RuntimeBundleHttpFixture({
        _sumsUrl: sha256SumsFor({_coreArchive: legacyCore}).codeUnits,
        _coreUrl: legacyCore,
      });

      final libraries = await _runHook(fixture, backends: ['cuda']);

      expect(fixture.requests, [_sumsUrl, _manifestUrl, _coreUrl]);
      expect(libraries, containsPair('ggml-cuda.dll', 'legacy-ggml-cuda.dll'));
    });

    test('still warns and falls back when CUDA is missing', () async {
      final fixture = RuntimeBundleHttpFixture({
        _sumsUrl: sha256SumsFor({_coreArchive: core}).codeUnits,
        _coreUrl: core,
      });

      final libraries = await _runHook(fixture, backends: ['cuda']);

      expect(fixture.requests, [
        _sumsUrl,
        _manifestUrl,
        _coreUrl,
        _manifestUrl,
      ]);
      expect(libraries, isNot(contains('ggml-cuda.dll')));
      expect(libraries, contains('ggml-vulkan.dll'));
    });
  });

  test('a local native path bundle needs no manifest or sidecar', () async {
    final local = Directory.systemTemp.createTempSync('sidecar-local-');
    addTearDown(() => local.delete(recursive: true));
    for (final library in [..._coreLibraries, ..._cudaLibraries]) {
      File(path.join(local.path, library)).writeAsStringSync('local-$library');
    }
    final fixture = RuntimeBundleHttpFixture.offline();

    final libraries = await _runHook(
      fixture,
      backends: ['cuda'],
      nativePath: local.path,
    );

    expect(fixture.requests, isEmpty);
    expect(libraries, containsPair('ggml-cuda.dll', 'local-ggml-cuda.dll'));
  });
}

Map<String, Object?> _manifest({int contract = 2, bool sidecars = true}) => {
  'tag': _tag,
  'native_release_tag': _tag,
  'hook_contract_version': contract,
  'artifacts': [
    {
      'module': 'core',
      'platform': 'windows',
      'arch': 'x64',
      'backend': 'core',
      'file': _coreArchive,
    },
    if (sidecars)
      {
        'module': 'backend-cuda12',
        'platform': 'windows',
        'arch': 'x64',
        'backend': 'cuda',
        'file': _sidecarArchive,
      },
  ],
};

/// Runs the hook for Windows x64 against release [_tag] with every download
/// served by [fixture], and returns the emitted libraries' contents by file
/// name.
Future<Map<String, String>> _runHook(
  RuntimeBundleHttpFixture fixture, {
  List<String>? backends,
  String? nativePath,
}) async {
  final libraries = <String, String>{};
  await build_hook.withRuntimeBundleHttpClientForTesting(
    fixture.createClient,
    () => testCodeBuildHook(
      mainMethod: build_hook.main,
      targetOS: OS.windows,
      targetArchitecture: Architecture.x64,
      userDefines: PackageUserDefines(
        workspacePubspec: PackageUserDefinesSource(
          defines: {
            'llamadart_native_runtimes': ['llama_cpp'],
            'llamadart_native_tag': _tag,
            if (backends != null)
              'llamadart_native_backends': {
                'platforms': {'windows-x64': backends},
              },
            'llamadart_native_path': ?nativePath,
          },
          basePath: Directory.current.uri,
        ),
      ),
      check: (_, output) {
        for (final asset
            in output.assets.encodedAssets
                .where((asset) => asset.isCodeAsset)
                .map((asset) => asset.asCodeAsset)) {
          final file = File.fromUri(asset.file!);
          libraries[path.basename(file.path)] = file.readAsStringSync();
        }
      },
    ),
  );
  return libraries;
}

/// A `.tar.gz` bundle whose libraries hold `<label>-<library>`.
List<int> _archive(String label, List<String> libraries) {
  final archive = Archive();
  for (final library in libraries) {
    final content = '$label-$library'.codeUnits;
    archive.addFile(ArchiveFile(library, content.length, content));
  }
  return GZipEncoder().encode(TarEncoder().encode(archive));
}
