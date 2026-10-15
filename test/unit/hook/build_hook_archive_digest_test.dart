@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import 'package:llamadart/src/hook/native_archive_digest.dart';
import 'package:llamadart/src/hook/native_release_pins.dart';

import '../../../hook/build.dart' as build_hook;
import '../../support/runtime_bundle_http_fixture.dart';

const _bundle = 'linux-arm64';
const _overrideTag = 'v9.9.9';
const _forkRepository = 'digest-test/fork';
const _llamaLibraries = [
  'libllamadart.so',
  'libmtmd.so',
  'libllama.so',
  'libllama-common.so',
  'libggml.so',
  'libggml-base.so',
  'libggml-cpu.so',
];

const _windowsLibraries = [
  'llamadart-windows-x64.dll',
  'llama-windows-x64.dll',
  'ggml-windows-x64.dll',
  'ggml-base-windows-x64.dll',
  'ggml-cpu-windows-x64.dll',
];

/// A Windows bundle with a CUDA module but no CUDA runtime, which the hook
/// treats as incomplete.
const _windowsCudaLibraries = [
  ..._windowsLibraries,
  'ggml-cuda-windows-x64.dll',
];

void main() {
  final nativeBundlesDir = path.join(
    '.dart_tool',
    'llamadart',
    'native_bundles',
  );
  final defaultCacheDir = Directory(
    path.join(nativeBundlesDir, llamaCppTag, _bundle),
  );
  final overrideCacheDir = Directory(
    path.join(nativeBundlesDir, _overrideTag, _bundle),
  );
  final windowsOverrideCacheDir = Directory(
    path.join(nativeBundlesDir, _overrideTag, 'windows-x64'),
  );
  final forkCacheDir = Directory(
    path.joinAll([
      nativeBundlesDir,
      'github',
      ..._forkRepository.split('/'),
      llamaCppTag,
      _bundle,
    ]),
  );
  final stableDiffusionCacheDir = path.join(
    '.dart_tool',
    'llamadart',
    'stable_diffusion',
    stableDiffusionVersion,
  );
  final stableDiffusionArchiveName =
      'stable-diffusion-native-runtime-$_bundle-$stableDiffusionReleaseTag'
      '.tar.gz';
  final stableDiffusionArchive = File(
    path.join(stableDiffusionCacheDir, stableDiffusionArchiveName),
  );
  final stableDiffusionBundleDir = Directory(
    path.join(stableDiffusionCacheDir, _bundle),
  );
  final liteRtLmCacheDir = path.join(
    '.dart_tool',
    'llamadart',
    'litert_lm',
    liteRtLmVersion,
  );
  final liteRtLmArchiveName =
      'litert-lm-native-runtime-$_bundle-$liteRtLmReleaseTag.tar.gz';
  final liteRtLmArchive = File(
    path.join(liteRtLmCacheDir, liteRtLmArchiveName),
  );
  final liteRtLmBundleDir = Directory(
    path.join(liteRtLmCacheDir, 'linux', 'arm64'),
  );
  final touched = <FileSystemEntity>[
    defaultCacheDir,
    overrideCacheDir,
    windowsOverrideCacheDir,
    forkCacheDir,
    stableDiffusionArchive,
    stableDiffusionBundleDir,
    liteRtLmArchive,
    liteRtLmBundleDir,
  ];

  String archiveName(String tag) => 'llamadart-native-$_bundle-$tag.tar.gz';
  String releaseUrl(String repository, String tag, String asset) =>
      'https://github.com/$repository/releases/download/$tag/$asset';
  final defaultArchiveUrl = releaseUrl(
    'leehack/llamadart-native',
    llamaCppTag,
    archiveName(llamaCppTag),
  );
  final overrideArchiveUrl = releaseUrl(
    'leehack/llamadart-native',
    _overrideTag,
    archiveName(_overrideTag),
  );
  final overrideSumsUrl = releaseUrl(
    'leehack/llamadart-native',
    _overrideTag,
    'SHA256SUMS',
  );

  setUpAll(() async {
    for (final entity in touched) {
      await _move(entity, _backupOf(entity));
    }
  });

  setUp(() async {
    for (final entity in touched) {
      if (entity.existsSync()) {
        await entity.delete(recursive: true);
      }
    }
  });

  tearDownAll(() async {
    for (final entity in touched) {
      if (entity.existsSync()) {
        await entity.delete(recursive: true);
      }
      await _move(_backupOf(entity), entity);
    }
  });

  group('llama.cpp pinned release', () {
    test('rejects a downloaded archive that differs from its pin', () async {
      final fixture = RuntimeBundleHttpFixture({
        defaultArchiveUrl: _archive('tampered'),
      });
      var emitted = false;

      await expectLater(
        _runHook(fixture, check: () => emitted = true),
        throwsA(
          isA<NativeArchiveDigestException>().having(
            (error) => error.message,
            'message',
            allOf(
              contains(archiveName(llamaCppTag)),
              contains(llamaCppBundleSha256[_bundle]),
              contains('was deleted and not used'),
            ),
          ),
        ),
      );
      expect(fixture.requests, [defaultArchiveUrl]);
      expect(emitted, isFalse);
      expect(
        File(path.join(defaultCacheDir.path, archiveName(llamaCppTag))),
        isNot(_exists),
      );
      expect(
        Directory(path.join(defaultCacheDir.path, 'extracted')),
        isNot(_exists),
      );
    });

    test('redownloads a cached archive that differs from its pin', () async {
      final cached = File(
        path.join(defaultCacheDir.path, archiveName(llamaCppTag)),
      );
      await cached.parent.create(recursive: true);
      await cached.writeAsBytes(_archive('cached-tampered'));
      final fixture = RuntimeBundleHttpFixture({
        defaultArchiveUrl: _archive('downloaded-tampered'),
      });

      final log = await _captureLog(() async {
        await expectLater(
          _runHook(fixture),
          throwsA(isA<NativeArchiveDigestException>()),
        );
      });

      expect(
        log,
        contains(
          stringContainsInOrder([
            'Cached native bundle archive',
            cached.path,
            llamaCppBundleSha256[_bundle]!,
            'redownloading',
          ]),
        ),
      );
      expect(fixture.requests, [defaultArchiveUrl]);
      expect(cached, isNot(_exists));
      expect(
        Directory(path.join(defaultCacheDir.path, 'extracted')),
        isNot(_exists),
      );
    });
  });

  test('the pinned release ignores a cached SHA256SUMS', () async {
    final tampered = _archive('tampered');
    final cached = File(
      path.join(defaultCacheDir.path, archiveName(llamaCppTag)),
    );
    await cached.parent.create(recursive: true);
    await cached.writeAsBytes(tampered);
    await File(
      path.join(defaultCacheDir.path, 'SHA256SUMS'),
    ).writeAsString(sha256SumsFor({archiveName(llamaCppTag): tampered}));
    final fixture = RuntimeBundleHttpFixture({defaultArchiveUrl: tampered});

    await expectLater(
      _runHook(fixture),
      throwsA(
        isA<NativeArchiveDigestException>().having(
          (error) => error.message,
          'message',
          contains(llamaCppBundleSha256[_bundle]),
        ),
      ),
    );
    expect(fixture.requests, [defaultArchiveUrl]);
    expect(
      Directory(path.join(defaultCacheDir.path, 'extracted')),
      isNot(_exists),
    );
  });

  group('llama.cpp tag override', () {
    test('verifies the download against the release SHA256SUMS', () async {
      final archive = _archive('valid');
      final fixture = RuntimeBundleHttpFixture({
        overrideSumsUrl: sha256SumsFor({
          archiveName(_overrideTag): archive,
        }).codeUnits,
        overrideArchiveUrl: archive,
      });

      final libraries = await _runHook(
        fixture,
        tag: _overrideTag,
        check: () {},
      );

      expect(fixture.requests, [overrideSumsUrl, overrideArchiveUrl]);
      expect(libraries['libllamadart.so'], 'valid-libllamadart.so');
      expect(
        File(path.join(overrideCacheDir.path, archiveName(_overrideTag))),
        _exists,
      );
    });

    test('reuses a cached archive that matches SHA256SUMS', () async {
      final archive = _archive('cached-valid');
      final cached = File(
        path.join(overrideCacheDir.path, archiveName(_overrideTag)),
      );
      await cached.parent.create(recursive: true);
      await cached.writeAsBytes(archive);
      final fixture = RuntimeBundleHttpFixture({
        overrideSumsUrl: sha256SumsFor({
          archiveName(_overrideTag): archive,
        }).codeUnits,
      });

      final libraries = await _runHook(
        fixture,
        tag: _overrideTag,
        check: () {},
      );

      expect(fixture.requests, [overrideSumsUrl]);
      expect(libraries['libllamadart.so'], 'cached-valid-libllamadart.so');
    });

    test(
      'replaces a cached archive that differs from SHA256SUMS before use',
      () async {
        final archive = _archive('valid');
        final cached = File(
          path.join(overrideCacheDir.path, archiveName(_overrideTag)),
        );
        await cached.parent.create(recursive: true);
        await cached.writeAsBytes(_archive('cached-tampered'));
        final fixture = RuntimeBundleHttpFixture({
          overrideSumsUrl: sha256SumsFor({
            archiveName(_overrideTag): archive,
          }).codeUnits,
          overrideArchiveUrl: archive,
        });

        late Map<String, String> libraries;
        final log = await _captureLog(() async {
          libraries = await _runHook(fixture, tag: _overrideTag, check: () {});
        });

        expect(fixture.requests, [overrideSumsUrl, overrideArchiveUrl]);
        expect(libraries['libllamadart.so'], 'valid-libllamadart.so');
        expect(
          log,
          contains(
            stringContainsInOrder([
              cached.path,
              'SHA256SUMS expects',
              'redownloading',
            ]),
          ),
        );
      },
    );

    test('rejects a download that differs from SHA256SUMS', () async {
      final fixture = RuntimeBundleHttpFixture({
        overrideSumsUrl: sha256SumsFor({
          archiveName(_overrideTag): _archive('published'),
        }).codeUnits,
        overrideArchiveUrl: _archive('tampered'),
      });

      await expectLater(
        _runHook(fixture, tag: _overrideTag),
        throwsA(
          isA<NativeArchiveDigestException>().having(
            (error) => error.message,
            'message',
            contains('leehack/llamadart-native@$_overrideTag SHA256SUMS'),
          ),
        ),
      );
      expect(
        File(path.join(overrideCacheDir.path, archiveName(_overrideTag))),
        isNot(_exists),
      );
    });

    test(
      'fails before downloading when the release has no SHA256SUMS',
      () async {
        final fixture = RuntimeBundleHttpFixture({
          overrideArchiveUrl: _archive('unverifiable'),
        });

        await expectLater(
          _runHook(fixture, tag: _overrideTag),
          throwsA(
            isA<NativeArchiveDigestException>().having(
              (error) => error.message,
              'message',
              allOf(
                contains('publishes no SHA256SUMS'),
                contains('llamadart_native_path'),
              ),
            ),
          ),
        );
        expect(fixture.requests, [overrideSumsUrl]);
      },
    );

    test(
      'fails before downloading when SHA256SUMS omits the archive',
      () async {
        final fixture = RuntimeBundleHttpFixture({
          overrideSumsUrl: sha256SumsFor({
            'llamadart-native-linux-x64-$_overrideTag.tar.gz': _archive(
              'other',
            ),
          }).codeUnits,
          overrideArchiveUrl: _archive('unverifiable'),
        });

        await expectLater(
          _runHook(fixture, tag: _overrideTag),
          throwsA(
            isA<NativeArchiveDigestException>().having(
              (error) => error.message,
              'message',
              contains('lists no SHA-256 for ${archiveName(_overrideTag)}'),
            ),
          ),
        );
        expect(fixture.requests, [overrideSumsUrl]);
        expect(overrideCacheDir.listSync(), isEmpty);
      },
    );
  });

  group('llama.cpp tag override offline', () {
    final cachedArchive = File(
      path.join(overrideCacheDir.path, archiveName(_overrideTag)),
    );
    final cachedSums = File(path.join(overrideCacheDir.path, 'SHA256SUMS'));
    final extractedDir = Directory(
      path.join(overrideCacheDir.path, 'extracted'),
    );

    Future<void> seed({
      required List<int> archive,
      Map<String, List<int>>? sumsFor,
      String? sums,
    }) async {
      await overrideCacheDir.create(recursive: true);
      await cachedArchive.writeAsBytes(archive);
      final sumsText =
          sums ?? (sumsFor == null ? null : sha256SumsFor(sumsFor));
      if (sumsText != null) {
        await cachedSums.writeAsString(sumsText);
      }
    }

    test(
      'extracts a pre-seeded archive verified by a pre-seeded SHA256SUMS',
      () async {
        final archive = _archive('seeded');
        await seed(
          archive: archive,
          sumsFor: {archiveName(_overrideTag): archive},
        );
        final fixture = RuntimeBundleHttpFixture.offline();

        final libraries = await _runHook(
          fixture,
          tag: _overrideTag,
          check: () {},
        );

        expect(fixture.requests, isEmpty);
        expect(libraries['libllamadart.so'], 'seeded-libllamadart.so');
      },
    );

    test('keeps the fetched SHA256SUMS for a later offline build', () async {
      final archive = _archive('valid');
      final online = RuntimeBundleHttpFixture({
        overrideSumsUrl: sha256SumsFor({
          archiveName(_overrideTag): archive,
        }).codeUnits,
        overrideArchiveUrl: archive,
      });
      await _runHook(online, tag: _overrideTag, check: () {});
      expect(
        await cachedSums.readAsString(),
        sha256SumsFor({archiveName(_overrideTag): archive}),
      );

      await extractedDir.delete(recursive: true);
      final offline = RuntimeBundleHttpFixture.offline();
      final libraries = await _runHook(
        offline,
        tag: _overrideTag,
        check: () {},
      );

      expect(offline.requests, isEmpty);
      expect(libraries['libllamadart.so'], 'valid-libllamadart.so');
    });

    test(
      'fails with a typed error naming the pre-seed path without SHA256SUMS',
      () async {
        await seed(archive: _archive('seeded'));
        final fixture = RuntimeBundleHttpFixture.offline();

        await expectLater(
          _runHook(fixture, tag: _overrideTag),
          throwsA(
            isA<NativeArchiveDigestException>().having(
              (error) => error.message,
              'message',
              allOf(
                contains(overrideSumsUrl),
                contains('OfflineFixtureException'),
                contains(cachedSums.path),
                contains('llamadart_native_path'),
              ),
            ),
          ),
        );
        expect(fixture.requests, [overrideSumsUrl]);
        expect(cachedArchive, _exists);
        expect(extractedDir, isNot(_exists));
      },
    );

    test(
      'rejects a pre-seeded archive that differs from the cached SHA256SUMS',
      () async {
        await seed(
          archive: _archive('tampered'),
          sumsFor: {archiveName(_overrideTag): _archive('published')},
        );
        final fixture = RuntimeBundleHttpFixture.offline();

        await expectLater(
          _runHook(fixture, tag: _overrideTag),
          throwsA(isA<NativeArchiveDigestException>()),
        );
        expect(fixture.requests, [overrideSumsUrl]);
        expect(cachedArchive, _exists);
        expect(extractedDir, isNot(_exists));
      },
    );

    test(
      'reuses a cached archive the release lists when the cached list is stale',
      () async {
        final archive = _archive('cached-valid');
        await seed(
          archive: archive,
          sumsFor: {archiveName(_overrideTag): _archive('older')},
        );
        final sums = sha256SumsFor({archiveName(_overrideTag): archive});
        final fixture = RuntimeBundleHttpFixture({
          overrideSumsUrl: sums.codeUnits,
        });

        final libraries = await _runHook(
          fixture,
          tag: _overrideTag,
          check: () {},
        );

        expect(fixture.requests, [overrideSumsUrl]);
        expect(libraries['libllamadart.so'], 'cached-valid-libllamadart.so');
        expect(await cachedSums.readAsString(), sums);
      },
    );

    test(
      'verifies a download against the fetched SHA256SUMS, not the cache',
      () async {
        final evil = _archive('evil');
        await seed(
          archive: _archive('stale'),
          sumsFor: {archiveName(_overrideTag): evil},
        );
        final fixture = RuntimeBundleHttpFixture({
          overrideSumsUrl: sha256SumsFor({
            archiveName(_overrideTag): _archive('published'),
          }).codeUnits,
          overrideArchiveUrl: evil,
        });

        await expectLater(
          _runHook(fixture, tag: _overrideTag),
          throwsA(
            isA<NativeArchiveDigestException>().having(
              (error) => error.message,
              'message',
              contains('was deleted and not used'),
            ),
          ),
        );
        expect(fixture.requests, [overrideSumsUrl, overrideArchiveUrl]);
        expect(extractedDir, isNot(_exists));
      },
    );

    test(
      'refreshes a cached SHA256SUMS that is not UTF-8 from the release',
      () async {
        final archive = _archive('cached-valid');
        await seed(archive: archive);
        final sums = sha256SumsFor({archiveName(_overrideTag): archive});
        await cachedSums.writeAsBytes(_utf16le(sums));
        final fixture = RuntimeBundleHttpFixture({
          overrideSumsUrl: sums.codeUnits,
        });

        final libraries = await _runHook(
          fixture,
          tag: _overrideTag,
          check: () {},
        );

        expect(fixture.requests, [overrideSumsUrl]);
        expect(libraries['libllamadart.so'], 'cached-valid-libllamadart.so');
        expect(await cachedSums.readAsString(), sums);
      },
    );

    test(
      'names why a cached SHA256SUMS was rejected when it cannot refetch',
      () async {
        final archive = _archive('seeded');
        await seed(archive: archive);
        await cachedSums.writeAsBytes(
          _utf16le(sha256SumsFor({archiveName(_overrideTag): archive})),
        );
        final fixture = RuntimeBundleHttpFixture.offline();

        await expectLater(
          _runHook(fixture, tag: _overrideTag),
          throwsA(
            isA<NativeArchiveDigestException>().having(
              (error) => error.message,
              'message',
              allOf(
                contains('The cached SHA256SUMS was not used'),
                contains('is not UTF-8 text'),
                contains(cachedSums.path),
              ),
            ),
          ),
        );
        expect(extractedDir, isNot(_exists));
      },
    );

    test('accepts a cached SHA256SUMS with a BOM and uppercase hex', () async {
      final archive = _archive('seeded');
      await seed(
        archive: archive,
        sums:
            '\uFEFF${sha256.convert(archive).toString().toUpperCase()}  '
            '${archiveName(_overrideTag)}\n',
      );
      final fixture = RuntimeBundleHttpFixture.offline();

      final libraries = await _runHook(
        fixture,
        tag: _overrideTag,
        check: () {},
      );

      expect(fixture.requests, isEmpty);
      expect(libraries['libllamadart.so'], 'seeded-libllamadart.so');
    });

    test(
      'builds when a directory occupies the cached SHA256SUMS path',
      () async {
        final archive = _archive('cached-valid');
        await seed(archive: archive);
        await Directory(cachedSums.path).create();
        final fixture = RuntimeBundleHttpFixture({
          overrideSumsUrl: sha256SumsFor({
            archiveName(_overrideTag): archive,
          }).codeUnits,
        });

        final libraries = await _runHook(
          fixture,
          tag: _overrideTag,
          check: () {},
        );

        expect(fixture.requests, [overrideSumsUrl]);
        expect(libraries['libllamadart.so'], 'cached-valid-libllamadart.so');
      },
    );

    test('fetches a fresh SHA256SUMS before replacing an incomplete cached '
        'archive', () async {
      final windowsArchiveName =
          'llamadart-native-windows-x64-$_overrideTag.tar.gz';
      final stale = _archive('stale', libraries: _windowsCudaLibraries);
      final complete = _archive('valid', libraries: _windowsLibraries);
      await windowsOverrideCacheDir.create(recursive: true);
      await File(
        path.join(windowsOverrideCacheDir.path, windowsArchiveName),
      ).writeAsBytes(stale);
      await File(
        path.join(windowsOverrideCacheDir.path, 'SHA256SUMS'),
      ).writeAsString(sha256SumsFor({windowsArchiveName: stale}));
      final archiveUrl = releaseUrl(
        'leehack/llamadart-native',
        _overrideTag,
        windowsArchiveName,
      );
      final fixture = RuntimeBundleHttpFixture({
        overrideSumsUrl: sha256SumsFor({
          windowsArchiveName: complete,
        }).codeUnits,
        archiveUrl: complete,
      });

      final libraries = await _runHook(
        fixture,
        tag: _overrideTag,
        targetOS: OS.windows,
        targetArchitecture: Architecture.x64,
        check: () {},
      );

      expect(fixture.requests, [overrideSumsUrl, archiveUrl]);
      expect(
        libraries['llamadart-windows-x64.dll'],
        'valid-llamadart-windows-x64.dll',
      );
    });

    test('refreshes a malformed cached SHA256SUMS from the release', () async {
      final archive = _archive('cached-valid');
      await seed(archive: archive, sums: 'not a checksum line\n');
      final sums = sha256SumsFor({archiveName(_overrideTag): archive});
      final fixture = RuntimeBundleHttpFixture({
        overrideSumsUrl: sums.codeUnits,
      });

      final libraries = await _runHook(
        fixture,
        tag: _overrideTag,
        check: () {},
      );

      expect(fixture.requests, [overrideSumsUrl]);
      expect(libraries['libllamadart.so'], 'cached-valid-libllamadart.so');
      expect(await cachedSums.readAsString(), sums);
    });
  });

  test(
    'a repository override verifies against that release, not the pin',
    () async {
      final archive = _archive('fork');
      final sumsUrl = releaseUrl(_forkRepository, llamaCppTag, 'SHA256SUMS');
      final archiveUrl = releaseUrl(
        _forkRepository,
        llamaCppTag,
        archiveName(llamaCppTag),
      );
      final fixture = RuntimeBundleHttpFixture({
        sumsUrl: sha256SumsFor({archiveName(llamaCppTag): archive}).codeUnits,
        archiveUrl: archive,
      });

      final libraries = await _runHook(
        fixture,
        repository: _forkRepository,
        check: () {},
      );

      expect(fixture.requests, [sumsUrl, archiveUrl]);
      expect(libraries['libllamadart.so'], 'fork-libllamadart.so');
    },
  );

  group('stable_diffusion', () {
    final url =
        'https://github.com/leehack/stable-diffusion-native/releases/download/'
        '$stableDiffusionReleaseTag/$stableDiffusionArchiveName';

    test('rejects a downloaded archive with a typed error', () async {
      final fixture = RuntimeBundleHttpFixture({url: _archive('tampered')});

      await expectLater(
        _runHook(fixture, runtimes: const ['stable_diffusion']),
        throwsA(
          isA<NativeArchiveDigestException>().having(
            (error) => error.message,
            'message',
            contains(stableDiffusionArchiveName),
          ),
        ),
      );
      expect(fixture.requests, [url]);
      expect(stableDiffusionArchive, isNot(_exists));
    });

    test('redownloads a cached archive that differs from its pin', () async {
      await stableDiffusionArchive.parent.create(recursive: true);
      await stableDiffusionArchive.writeAsBytes(_archive('cached-tampered'));
      final fixture = RuntimeBundleHttpFixture({url: _archive('tampered')});

      await expectLater(
        _runHook(fixture, runtimes: const ['stable_diffusion']),
        throwsA(isA<NativeArchiveDigestException>()),
      );
      expect(fixture.requests, [url]);
    });
  });

  group('LiteRT-LM', () {
    final url =
        'https://github.com/leehack/litert-lm-native/releases/download/'
        '$liteRtLmReleaseTag/$liteRtLmArchiveName';

    test('rejects a downloaded archive with a typed error', () async {
      final fixture = RuntimeBundleHttpFixture({url: _archive('tampered')});

      await expectLater(
        _runHook(fixture, runtimes: const ['litert_lm']),
        throwsA(
          isA<NativeArchiveDigestException>().having(
            (error) => error.message,
            'message',
            contains(liteRtLmArchiveName),
          ),
        ),
      );
      expect(fixture.requests, [url]);
      expect(liteRtLmArchive, isNot(_exists));
    });

    test('redownloads a cached archive that differs from its pin', () async {
      await liteRtLmArchive.parent.create(recursive: true);
      await liteRtLmArchive.writeAsBytes(_archive('cached-tampered'));
      final fixture = RuntimeBundleHttpFixture({url: _archive('tampered')});

      await expectLater(
        _runHook(fixture, runtimes: const ['litert_lm']),
        throwsA(isA<NativeArchiveDigestException>()),
      );
      expect(fixture.requests, [url]);
    });
  });
}

final _exists = predicate<FileSystemEntity>(
  (entity) => entity.existsSync(),
  'exists',
);

List<int> _utf16le(String text) => [
  0xFF,
  0xFE,
  for (final unit in text.codeUnits) ...[unit & 0xFF, unit >> 8],
];

/// Runs the hook (for Linux arm64 by default) with every download served by
/// [fixture], and returns the emitted llama.cpp libraries' contents by file
/// name.
Future<Map<String, String>> _runHook(
  RuntimeBundleHttpFixture fixture, {
  String? tag,
  String? repository,
  List<String> runtimes = const ['llama_cpp'],
  OS targetOS = OS.linux,
  Architecture targetArchitecture = Architecture.arm64,
  void Function()? check,
}) async {
  final libraries = <String, String>{};
  await build_hook.withRuntimeBundleHttpClientForTesting(
    fixture.createClient,
    () => testCodeBuildHook(
      mainMethod: build_hook.main,
      targetOS: targetOS,
      targetArchitecture: targetArchitecture,
      userDefines: PackageUserDefines(
        workspacePubspec: PackageUserDefinesSource(
          defines: {
            'llamadart_native_runtimes': runtimes,
            'llamadart_stable_diffusion_backends': ['cpu'],
            'llamadart_native_tag': ?tag,
            'llamadart_native_repository': ?repository,
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
        if (check == null) {
          fail('The hook emitted assets from an unverified archive.');
        }
        check();
      },
    ),
  );
  return libraries;
}

/// A `.tar.gz` bundle whose libraries hold `<label>-<library>`.
List<int> _archive(String label, {List<String> libraries = _llamaLibraries}) {
  final archive = Archive();
  for (final library in libraries) {
    final content = '$label-$library'.codeUnits;
    archive.addFile(ArchiveFile(library, content.length, content));
  }
  return GZipEncoder().encode(TarEncoder().encode(archive));
}

Future<List<String>> _captureLog(Future<void> Function() body) async {
  final lines = <String>[];
  await runZoned(
    body,
    zoneSpecification: ZoneSpecification(
      print: (_, _, _, line) => lines.add(line),
    ),
  );
  return lines;
}

FileSystemEntity _backupOf(FileSystemEntity entity) => entity is File
    ? File('${entity.path}.__digest_test_backup')
    : Directory('${entity.path}.__digest_test_backup');

Future<void> _move(FileSystemEntity from, FileSystemEntity to) async {
  if (to.existsSync()) {
    await to.delete(recursive: true);
  }
  if (from.existsSync()) {
    await to.parent.create(recursive: true);
    await from.rename(to.path);
  }
}
