import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:laya_tetris_example/laya/models.dart';
import 'package:laya_tetris_example/laya/store.dart';
import 'package:llamadart/llamadart.dart';

class _FakeDownloads implements ModelDownloadManager {
  _FakeDownloads(this.entries, {this.inUse = const <String>{}});

  final List<ModelCacheEntry> entries;
  final Set<String> inUse;

  @override
  Future<List<ModelCacheEntry>> list({String? cacheDirectory}) async =>
      List.of(entries);

  @override
  Future<void> remove(String cacheKey, {String? cacheDirectory}) async {
    if (inUse.contains(cacheKey)) {
      throw ModelCacheEntryInUseException(
        'in use',
        entryDirectories: <String>['/cache/$cacheKey'],
      );
    }
    entries.removeWhere((e) => e.cacheKey == cacheKey);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

ModelCacheEntry _entry(String cacheKey) => ModelCacheEntry(
  sourceCanonicalKey: 'hf://test/$cacheKey',
  cacheKey: cacheKey,
  fileName: 'model.bin',
  filePath: '/cache/$cacheKey/model.bin',
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('laya_store_'));
  tearDown(() => dir.deleteSync(recursive: true));

  group('ModelStore.tunedHead', () {
    test('is the published head without a URL or a file', () {
      final source = ModelStore(dir.path, tunedHeadUrl: '').tunedHead();
      expect(source.kind, ModelSourceKind.huggingFace);
      expect(source.repoId, tunedHeadRepoId);
      expect(source.revision, tunedHeadRevision);
      expect(source.filePath, tunedHeadFile);
      expect(
        source.resolvedUri,
        Uri.parse(
          'https://huggingface.co/leehack/laya-tetris-head/resolve/'
          '465546a595ee2e8e3b212b8cb16829205d5dfab6/'
          'laya-head-tetris.safetensors?download=true',
        ),
      );
    });

    test('prefers the file in the folder over the published head', () {
      final store = ModelStore(dir.path, tunedHeadUrl: '');
      File(store.tunedHeadPath!).writeAsBytesSync([0]);

      final source = store.tunedHead();
      expect(source.kind, ModelSourceKind.path);
      expect(source.path, store.tunedHeadPath);
    });

    test('prefers the URL over a file', () {
      final store = ModelStore(
        dir.path,
        tunedHeadUrl: 'https://example.com/heads/tuned.safetensors',
      );
      File(store.tunedHeadPath!).writeAsBytesSync([0]);

      final source = store.tunedHead();
      expect(source.kind, ModelSourceKind.http);
      expect(
        source.url,
        Uri.parse('https://example.com/heads/tuned.safetensors'),
      );
      expect(source.fileName, tunedHeadFile);
    });
  });

  test('ModelStore.tunedHeadHelp names the recovery for each source', () {
    final store = ModelStore(dir.path, tunedHeadUrl: '');
    expect(
      store.tunedHeadHelp(publishedTunedHead),
      allOf(
        contains('Tap Reload models to try again'),
        contains(store.tunedHeadPath!),
        isNot(contains('LAYA_TUNED_HEAD_URL')),
      ),
    );
    expect(
      store.tunedHeadHelp(ModelSource.url(Uri.parse('https://example.com/h'))),
      allOf(
        contains('Tap Reload models to try again'),
        contains('LAYA_TUNED_HEAD_URL'),
      ),
    );
    expect(
      store.tunedHeadHelp(ModelSource.path(store.tunedHeadPath!)),
      allOf(contains('delete it'), isNot(contains('try again'))),
    );
  });

  test('ModelStore without a folder uses the published head', () {
    final store = ModelStore(null, tunedHeadUrl: '');
    expect(store.downloads, isNull);
    expect(store.tunedHeadPath, isNull);
    expect(store.tunedHead().kind, ModelSourceKind.huggingFace);
    expect(
      store.tunedHeadHelp(publishedTunedHead),
      'Tap Reload models to try again.',
    );
  });

  test('ModelStore.setup pins the published files', () {
    final setup = ModelStore(
      dir.path,
      tunedHeadUrl: '',
    ).setup(LayaBackbone.f16, backend: GpuBackend.cpu, threads: 3);

    for (final (source, file) in [
      (setup.backbone, 'laya-F16.gguf'),
      (setup.head, baseHeadFile),
    ]) {
      expect(source.kind, ModelSourceKind.huggingFace);
      expect(source.repoId, layaRepoId);
      expect(source.revision, layaRevision);
      expect(source.filePath, file);
    }
    expect(setup.tunedHead, same(publishedTunedHead));
    expect(setup.backend, GpuBackend.cpu);
    expect(setup.threads, 3);
  });

  test(
    'ModelStore.removeSupersededDownloads drops every stale entry not in use',
    () async {
      final busy = ModelSource.huggingFace(
        repoId: tunedHeadRepoId,
        revision: '0a1b2c3d',
        filePath: tunedHeadFile,
      );
      final stale = ModelSource.huggingFace(
        repoId: tunedHeadRepoId,
        revision: '83794e0b',
        filePath: tunedHeadFile,
      );
      final pinned = [
        layaSource(LayaBackbone.q8.fileName),
        layaSource(LayaBackbone.f16.fileName),
        layaSource(baseHeadFile),
        publishedTunedHead,
      ];
      final downloads = _FakeDownloads(
        [
          _entry(busy.cacheKey),
          _entry(stale.cacheKey),
          for (final source in pinned) _entry(source.cacheKey),
        ],
        inUse: {busy.cacheKey},
      );
      final store = ModelStore(
        dir.path,
        tunedHeadUrl: '',
        downloadManager: downloads,
      );
      final userFile = File(store.tunedHeadPath!)..writeAsBytesSync([0]);

      await store.removeSupersededDownloads();

      expect(downloads.entries.map((e) => e.cacheKey), [
        busy.cacheKey,
        for (final source in pinned) source.cacheKey,
      ]);
      expect(userFile.existsSync(), isTrue);
    },
  );

  group('LayaSetup.params', () {
    LayaSetup setup(GpuBackend backend) => LayaSetup(
      backbone: ModelSource.path('b.gguf'),
      head: ModelSource.path('h.safetensors'),
      backend: backend,
      threads: 6,
    );

    test('runs on the best device with the threads', () {
      final params = setup(GpuBackend.auto).params;
      expect(params.device, ComputeDevice.auto);
      expect(params.threads, 6);
    });

    test('runs on the CPU for the CPU backend', () {
      expect(setup(GpuBackend.cpu).params.device, ComputeDevice.cpu);
    });
  });
}
