import 'package:test/test.dart';

import 'package:llamadart/src/core/exceptions.dart';
import 'package:llamadart/src/core/models/download/model_download_manager_base.dart';
import 'package:llamadart/src/core/models/model_format.dart';
import 'package:llamadart/src/core/models/model_load_options.dart';
import 'package:llamadart/src/core/models/model_resolver.dart';
import 'package:llamadart/src/core/models/model_source.dart';
import 'package:llamadart/src/core/models/model_target_file.dart';

void main() {
  late _RecordingManager manager;

  setUp(() => manager = _RecordingManager());

  test('a local target is checked by the manager as a path source', () async {
    final options = ModelLoadOptions(maxRetries: 1);
    void onProgress(ModelDownloadProgress _) {}

    final entry = await ensureModelTargetFile(
      manager,
      ModelSource.parse('hf://owner/repo@main/model.gguf'),
      const LocalModelFile('/models/model.gguf'),
      options: options,
      onProgress: onProgress,
    );

    final (source, passedOptions, passedProgress) = manager.calls.single;
    expect(source.kind, ModelSourceKind.path);
    expect(source.path, '/models/model.gguf');
    expect(passedOptions, same(options));
    expect(passedProgress, same(onProgress));
    expect(entry.filePath, '/cache/model.gguf');
  });

  test('a remote target downloads under the source cache identity', () async {
    final source = ModelSource.parse('hf://owner/repo@main/model.gguf');
    final mirror = Uri.parse('https://mirror.example.com/model.gguf');

    await ensureModelTargetFile(
      manager,
      source,
      RemoteModelUrl(mirror),
      options: ModelLoadOptions.defaults,
    );

    final (downloaded, _, _) = manager.calls.single;
    expect(downloaded.resolvedUri, mirror);
    expect(downloaded.canonicalKey, source.canonicalKey);
  });

  test('a remote target for a local source downloads as a URL keeping the '
      'file name', () async {
    final url = Uri.parse('https://example.com/download?id=1');

    await ensureModelTargetFile(
      manager,
      ModelSource.path('/models/vae.safetensors'),
      RemoteModelUrl(url),
      options: ModelLoadOptions.defaults,
    );

    final (downloaded, _, _) = manager.calls.single;
    expect(downloaded.kind, ModelSourceKind.http);
    expect(downloaded.resolvedUri, url);
    expect(downloaded.fileName, 'vae.safetensors');
  });

  test(
    'keeps the source format on local, remote and re-sourced targets',
    () async {
      final hf = ModelSource.parse(
        'hf://owner/repo@main/download',
        format: ModelFormat.liteRtLm,
      );
      final local = ModelSource.path(
        '/models/download',
        format: ModelFormat.liteRtLm,
      );

      await ensureModelTargetFile(
        manager,
        local,
        const LocalModelFile('/models/download'),
        options: ModelLoadOptions.defaults,
      );
      await ensureModelTargetFile(
        manager,
        hf,
        RemoteModelUrl(Uri.parse('https://mirror.example.com/download')),
        options: ModelLoadOptions.defaults,
      );
      await ensureModelTargetFile(
        manager,
        local,
        RemoteModelUrl(Uri.parse('https://example.com/download?id=1')),
        options: ModelLoadOptions.defaults,
      );

      expect([
        for (final (source, _, _) in manager.calls) source.format,
      ], everyElement(ModelFormat.liteRtLm));
      expect(manager.calls, hasLength(3));
    },
  );

  test('a remote target without the backend cache is unsupported and names '
      'the asset type', () async {
    await expectLater(
      ensureModelTargetFile(
        manager,
        ModelSource.parse('hf://owner/repo@main/model.gguf'),
        RemoteModelUrl(
          Uri.parse('https://example.com/model.gguf?token=secret'),
          useBrowserCache: false,
        ),
        options: ModelLoadOptions.defaults,
        assetType: 'image model',
      ),
      throwsA(
        isA<LlamaUnsupportedException>().having(
          (error) => error.message,
          'message',
          allOf(
            'Remote image model loading without browser/backend cache is not '
            'supported yet.',
            isNot(contains('secret')),
          ),
        ),
      ),
    );
    expect(manager.calls, isEmpty);
  });
}

final class _RecordingManager extends ThrowingModelDownloadManager {
  final List<(ModelSource, ModelLoadOptions, ModelDownloadProgressCallback?)>
  calls = [];

  @override
  Future<ModelCacheEntry> ensureModel(
    ModelSource source, {
    ModelLoadOptions options = ModelLoadOptions.defaults,
    ModelDownloadProgressCallback? onProgress,
  }) async {
    calls.add((source, options, onProgress));
    final now = DateTime.utc(2026);
    return ModelCacheEntry(
      sourceCanonicalKey: source.canonicalKey,
      cacheKey: source.cacheKey,
      fileName: source.fileName,
      filePath: '/cache/${source.fileName}',
      createdAt: now,
      updatedAt: now,
    );
  }
}
