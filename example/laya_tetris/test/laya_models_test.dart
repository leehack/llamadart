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
    test('is null without a URL or a file', () {
      expect(ModelStore(dir.path, tunedHeadUrl: '').tunedHead(), isNull);
    });

    test('reads the file in the folder', () {
      final store = ModelStore(dir.path, tunedHeadUrl: '');
      File(store.tunedHeadPath).writeAsBytesSync([0]);

      final source = store.tunedHead()!;
      expect(source.kind, ModelSourceKind.path);
      expect(source.path, store.tunedHeadPath);
    });

    test('prefers the URL over a file', () {
      final store = ModelStore(
        dir.path,
        tunedHeadUrl: 'https://example.com/heads/tuned.safetensors',
      );
      File(store.tunedHeadPath).writeAsBytesSync([0]);

      final source = store.tunedHead()!;
      expect(source.kind, ModelSourceKind.http);
      expect(
        source.url,
        Uri.parse('https://example.com/heads/tuned.safetensors'),
      );
      expect(source.fileName, tunedHeadFile);
    });
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
    expect(setup.tunedHead, isNull);
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
