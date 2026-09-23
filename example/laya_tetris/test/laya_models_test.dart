import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:laya_tetris_example/laya/models.dart';
import 'package:laya_tetris_example/laya/store.dart';
import 'package:llamadart/llamadart.dart';

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
      File(store.tunedHeadPath).writeAsBytesSync([0]);

      final source = store.tunedHead();
      expect(source.kind, ModelSourceKind.path);
      expect(source.path, store.tunedHeadPath);
    });

    test('prefers the URL over a file', () {
      final store = ModelStore(
        dir.path,
        tunedHeadUrl: 'https://example.com/heads/tuned.safetensors',
      );
      File(store.tunedHeadPath).writeAsBytesSync([0]);

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
        contains(store.tunedHeadPath),
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
      store.tunedHeadHelp(ModelSource.path(store.tunedHeadPath)),
      allOf(contains('delete it'), isNot(contains('try again'))),
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

  group('LayaSetup.modelParams', () {
    LayaSetup setup(GpuBackend backend) => LayaSetup(
      backbone: ModelSource.path('b.gguf'),
      head: ModelSource.path('h.safetensors'),
      backend: backend,
      threads: 6,
    );

    test('uses a 512-token context and the threads for batches', () {
      final params = setup(GpuBackend.auto).modelParams;
      expect(params.contextSize, 512);
      expect(params.numberOfThreadsBatch, 6);
      expect(params.numberOfThreads, 6);
      expect(params.preferredBackend, GpuBackend.auto);
      expect(params.gpuLayers, ModelParams.maxGpuLayers);
    });

    test('offloads no layers on the CPU', () {
      final params = setup(GpuBackend.cpu).modelParams;
      expect(params.preferredBackend, GpuBackend.cpu);
      expect(params.gpuLayers, 0);
    });
  });
}
