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

  group('ensureModelTargetFiles', () {
    test('resolves in order, giving local files only the cancel token, and '
        'reports combined progress', () async {
      manager.remoteSize = 100;
      final cancelToken = ModelDownloadCancelToken();
      final options = ModelLoadOptions(
        cancelToken: cancelToken,
        bearerToken: 'secret',
        maxRetries: 1,
      );
      final progress = <(int, int?)>[];

      final paths = await ensureModelTargetFiles(
        [
          ModelSource.path('/models/a.gguf'),
          ModelSource.parse('https://example.com/b.safetensors'),
        ],
        resolver: const DefaultModelResolver(),
        manager: manager,
        options: options,
        onProgress: (p) => progress.add((p.receivedBytes, p.totalBytes)),
        knownSizes: const {0: 10},
      );

      expect(paths, ['/cache/a.gguf', '/cache/b.safetensors']);
      final [(_, localOptions, _), (_, remoteOptions, _)] = manager.calls;
      expect(localOptions.cancelToken, same(cancelToken));
      expect(localOptions.bearerToken, isNull);
      expect(localOptions.maxRetries, ModelLoadOptions.defaults.maxRetries);
      expect(remoteOptions, same(options));
      expect(progress, [(10, null), (60, 110), (110, 110), (110, 110)]);
    });
  });
}

final class _RecordingManager extends ThrowingModelDownloadManager {
  final List<(ModelSource, ModelLoadOptions, ModelDownloadProgressCallback?)>
  calls = [];

  /// Size of every remote file, reported as two progress events; `null`
  /// reports none.
  int? remoteSize;

  @override
  Future<ModelCacheEntry> ensureModel(
    ModelSource source, {
    ModelLoadOptions options = ModelLoadOptions.defaults,
    ModelDownloadProgressCallback? onProgress,
  }) async {
    calls.add((source, options, onProgress));
    final size = source.isRemote ? remoteSize : null;
    if (size != null) {
      onProgress?.call(
        ModelDownloadProgress(receivedBytes: size ~/ 2, totalBytes: size),
      );
      onProgress?.call(
        ModelDownloadProgress(receivedBytes: size, totalBytes: size),
      );
    }
    final now = DateTime.utc(2026);
    return ModelCacheEntry(
      sourceCanonicalKey: source.canonicalKey,
      cacheKey: source.cacheKey,
      fileName: source.fileName,
      filePath: '/cache/${source.fileName}',
      bytes: size,
      createdAt: now,
      updatedAt: now,
    );
  }
}
