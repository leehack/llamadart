import 'dart:async';

import 'package:llamadart/llamadart.dart';
import 'package:test/test.dart';

import 'engine_test.dart' show MockLlamaBackend;

void main() {
  final hfAdapter = ModelSource.parse('hf://owner/repo/adapters/style.gguf');
  final urlAdapter = ModelSource.url(
    Uri.parse('https://example.com/adapters/tone.gguf'),
  );
  final localAdapter = ModelSource.path('/models/local-adapter.gguf');
  final hfDraft = ModelSource.parse('hf://owner/repo/draft.gguf');

  group('LoRA sources', () {
    test('setLoraSource downloads a Hugging Face adapter with the options '
        'and progress, and removeLoraSource removes the cached file', () async {
      final backend = _RecordingBackend();
      final manager = _CacheManager({hfAdapter: '/cache/style.gguf'});
      final engine = LlamaEngine(backend, modelDownloadManager: manager);
      await engine.loadModel('/models/model.gguf');
      final options = ModelLoadOptions(bearerToken: 'secret-token');
      final progress = <ModelDownloadProgress>[];

      await engine.setLoraSource(
        hfAdapter,
        scale: 0.5,
        download: options,
        onProgress: progress.add,
      );

      expect(manager.calls.single.source.cacheKey, hfAdapter.cacheKey);
      expect(
        manager.calls.single.source.resolvedUri.toString(),
        'https://huggingface.co/owner/repo/resolve/main/adapters/style.gguf?download=true',
      );
      expect(manager.calls.single.options, same(options));
      expect(progress.single.fraction, 0.5);
      expect(backend.lastLoraPath, '/cache/style.gguf');
      expect(backend.lastLoraScale, 0.5);

      await engine.removeLoraSource(hfAdapter);
      expect(backend.removedLoraPaths, ['/cache/style.gguf']);
    });

    test('setLoraSource checks a local adapter and loads its path', () async {
      final backend = _RecordingBackend();
      final manager = _CacheManager({});
      final engine = LlamaEngine(backend, modelDownloadManager: manager);
      await engine.loadModel('/models/model.gguf');

      await engine.setLoraSource(localAdapter);
      await engine.removeLoraSource(localAdapter);

      expect(manager.calls.single.source.path, '/models/local-adapter.gguf');
      expect(backend.lastLoraScale, 1.0);
      expect(backend.removedLoraPaths, ['/models/local-adapter.gguf']);
    });

    test('removeLoraSource ignores a remote adapter that was never set, and '
        'clearLoras forgets the cached files', () async {
      final backend = _RecordingBackend();
      final manager = _CacheManager({urlAdapter: '/cache/tone.gguf'});
      final engine = LlamaEngine(backend, modelDownloadManager: manager);
      await engine.loadModel('/models/model.gguf');

      await engine.removeLoraSource(urlAdapter);
      await engine.setLoraSource(urlAdapter);
      await engine.clearLoras();
      await engine.removeLoraSource(urlAdapter);

      expect(backend.removedLoraPaths, isEmpty);
    });

    test('setLoraSource needs a loaded model before it downloads', () async {
      final manager = _CacheManager({hfAdapter: '/cache/style.gguf'});
      final engine = LlamaEngine(
        _RecordingBackend(),
        modelDownloadManager: manager,
      );

      await expectLater(
        engine.setLoraSource(hfAdapter),
        throwsA(isA<LlamaContextException>()),
      );
      expect(manager.calls, isEmpty);
    });

    test('setLoraSource stops at a cancelled download token', () async {
      final backend = _RecordingBackend();
      final engine = LlamaEngine(
        backend,
        modelDownloadManager: _CacheManager({hfAdapter: '/cache/a.gguf'}),
      );
      await engine.loadModel('/models/model.gguf');
      final token = ModelDownloadCancelToken()..cancel();

      await expectLater(
        engine.setLoraSource(
          hfAdapter,
          download: ModelLoadOptions(cancelToken: token),
        ),
        throwsA(isA<LlamaStateException>()),
      );
      expect(backend.lastLoraPath, isNull);
    });

    test('URL-loading backends get a remote adapter URL and reject a local '
        'adapter', () async {
      final backend = _RecordingBackend(urlLoadingSupported: true);
      final manager = _CacheManager({});
      final engine = LlamaEngine(backend, modelDownloadManager: manager);
      await engine.loadModelSource(
        ModelSource.url(Uri.parse('https://example.com/model.gguf')),
      );

      await engine.setLoraSource(urlAdapter, scale: 0.25);
      await engine.removeLoraSource(urlAdapter);

      expect(backend.lastLoraScale, 0.25);
      expect(backend.removedLoraPaths, [
        'https://example.com/adapters/tone.gguf',
      ]);
      expect(manager.calls, isEmpty);
      await expectLater(
        engine.setLoraSource(localAdapter),
        throwsA(
          isA<LlamaUnsupportedException>().having(
            (error) => error.message,
            'message',
            contains('local LoRA adapter paths'),
          ),
        ),
      );
      await expectLater(
        engine.setLoraSource(
          urlAdapter,
          download: ModelLoadOptions(bearerToken: 'secret-token'),
        ),
        throwsA(isA<LlamaUnsupportedException>()),
      );
    });

    test('loadModelSource resolves ModelParams.loras sources with its options '
        'except sha256, local ones with its cancel token only', () async {
      final modelSource = ModelSource.parse('hf://owner/repo/model.gguf');
      final backend = _RecordingBackend();
      final manager = _CacheManager({
        modelSource: '/cache/model.gguf',
        hfAdapter: '/cache/style.gguf',
        urlAdapter: '/cache/tone.gguf',
      });
      final engine = LlamaEngine(backend, modelDownloadManager: manager);
      final token = ModelDownloadCancelToken();
      final options = ModelLoadOptions(
        bearerToken: 'secret-token',
        sha256: 'a' * 64,
        cancelToken: token,
        maxRetries: 5,
      );

      await engine.loadModelSource(
        modelSource,
        options: options,
        modelParams: ModelParams(
          loras: [
            LoraAdapterConfig.source(hfAdapter, scale: 0.5),
            LoraAdapterConfig.source(localAdapter),
            LoraAdapterConfig.source(urlAdapter, scale: 0.75),
          ],
        ),
      );

      expect(backend.lastModelPath, '/cache/model.gguf');
      expect(
        [
          for (final lora in backend.contextParams.single.loras)
            (lora.path, lora.scale),
        ],
        [
          ('/cache/style.gguf', 0.5),
          ('/models/local-adapter.gguf', 1.0),
          ('/cache/tone.gguf', 0.75),
        ],
      );
      expect(manager.calls[0].options, same(options));
      final hfOptions = manager.calls[1].options;
      expect(hfOptions.sha256, isNull);
      expect(hfOptions.bearerToken, 'secret-token');
      expect(hfOptions.maxRetries, 5);
      expect(hfOptions.cancelToken, same(token));
      final localOptions = manager.calls[2].options;
      expect(localOptions.bearerToken, isNull);
      expect(localOptions.sha256, isNull);
      expect(localOptions.cancelToken, same(token));

      await engine.removeLoraSource(urlAdapter);
      expect(backend.removedLoraPaths, ['/cache/tone.gguf']);
    });

    test('loadModel resolves ModelParams.loras sources with default options '
        'and keeps deprecated path adapters as written', () async {
      final backend = _RecordingBackend();
      final manager = _CacheManager({hfAdapter: '/cache/style.gguf'});
      final engine = LlamaEngine(backend, modelDownloadManager: manager);

      await engine.loadModel(
        '/models/model.gguf',
        modelParams: ModelParams(
          loras: [
            const LoraAdapterConfig(path: 'relative/legacy.gguf'),
            LoraAdapterConfig.source(hfAdapter),
          ],
        ),
      );

      expect(backend.contextParams.single.loras.map((lora) => lora.path), [
        'relative/legacy.gguf',
        '/cache/style.gguf',
      ]);
      expect(manager.calls.single.options, same(ModelLoadOptions.defaults));
    });

    test('a failed adapter download fails the load before the model loads, '
        'and an already loaded engine downloads nothing', () async {
      final backend = _RecordingBackend();
      final manager = _CacheManager({}, failing: {hfAdapter});
      final engine = LlamaEngine(backend, modelDownloadManager: manager);
      final params = ModelParams(loras: [LoraAdapterConfig.source(hfAdapter)]);

      await expectLater(
        engine.loadModel('/models/model.gguf', modelParams: params),
        throwsA(isA<LlamaModelException>()),
      );
      expect(backend.modelLoadCalls, 0);
      expect(engine.isReady, isFalse);

      await engine.loadModel('/models/model.gguf');
      manager.calls.clear();
      await expectLater(
        engine.loadModel('/models/model.gguf', modelParams: params),
        throwsA(isA<LlamaStateException>()),
      );
      expect(manager.calls, isEmpty);
    });

    test('URL-loading backends load ModelParams.loras sources as URLs', () async {
      final backend = _RecordingBackend(urlLoadingSupported: true);
      final engine = LlamaEngine(backend);

      await engine.loadModelSource(
        ModelSource.url(Uri.parse('https://example.com/model.gguf')),
        modelParams: ModelParams(loras: [LoraAdapterConfig.source(hfAdapter)]),
      );

      expect(
        backend.contextParams.single.loras.single.path,
        'https://huggingface.co/owner/repo/resolve/main/adapters/style.gguf?download=true',
      );
    });
  });

  group('speculative draft model sources', () {
    const prompt = 'hello';

    test('a generation downloads a Hugging Face draft model with '
        'draftModelDownload and sends its cached path', () async {
      final backend = _RecordingBackend();
      final manager = _CacheManager({hfDraft: '/cache/draft.gguf'});
      final engine = LlamaEngine(backend, modelDownloadManager: manager);
      await engine.loadModel('/models/model.gguf');
      final userToken = ModelDownloadCancelToken();

      await engine
          .generate(
            prompt,
            params: GenerationParams(
              speculativeDecodingConfig: SpeculativeDecodingConfig.draftSimple(
                draftModel: hfDraft,
                draftModelDownload: ModelLoadOptions(
                  bearerToken: 'secret-token',
                  cancelToken: userToken,
                ),
                draftTokenMax: 8,
                minProbability: 0.6,
              ),
            ),
          )
          .drain<void>();

      final sent = backend.lastGenerationParams!.speculativeDecodingConfig!;
      expect(sent.draftModelPath, '/cache/draft.gguf');
      expect(sent.draftModel, isNull);
      expect(sent.strategy, SpeculativeDecodingStrategy.draftSimple);
      expect(sent.strategies, [SpeculativeDecodingStrategy.draftSimple]);
      expect(sent.draftTokenMax, 8);
      expect(sent.minProbability, 0.6);
      final options = manager.calls.single.options;
      expect(options.bearerToken, 'secret-token');
      expect(options.cancelToken, isNot(same(userToken)));
      expect(options.cancelToken!.isCancelled, isFalse);
      userToken.cancel();
      expect(options.cancelToken!.isCancelled, isTrue);
    });

    test('a local draft model is checked and sent as its path; a config '
        'without one is sent unchanged', () async {
      final backend = _RecordingBackend();
      final manager = _CacheManager({});
      final engine = LlamaEngine(backend, modelDownloadManager: manager);
      await engine.loadModel('/models/model.gguf');

      await engine
          .generate(
            prompt,
            params: GenerationParams(
              speculativeDecodingConfig: SpeculativeDecodingConfig.mixed(
                strategies: const [
                  SpeculativeDecodingStrategy.ngramMod,
                  SpeculativeDecodingStrategy.draftEagle3,
                ],
                draftModel: ModelSource.path('/models/eagle.gguf'),
                ngramMatch: 4,
              ),
            ),
          )
          .drain<void>();
      final sent = backend.lastGenerationParams!.speculativeDecodingConfig!;
      expect(sent.draftModelPath, '/models/eagle.gguf');
      expect(sent.ngramMatch, 4);
      expect(sent.effectiveStrategies, [
        SpeculativeDecodingStrategy.ngramMod,
        SpeculativeDecodingStrategy.draftEagle3,
      ]);
      expect(manager.calls.single.source.path, '/models/eagle.gguf');

      const ngram = GenerationParams(
        speculativeDecodingConfig: SpeculativeDecodingConfig.ngramMod(),
      );
      await engine.generate(prompt, params: ngram).drain<void>();
      expect(backend.lastGenerationParams, same(ngram));
      expect(manager.calls, hasLength(1));
    });

    test('chat completions resolve the draft model too', () async {
      final backend = _RecordingBackend();
      final engine = LlamaEngine(
        backend,
        modelDownloadManager: _CacheManager({hfDraft: '/cache/draft.gguf'}),
      );
      await engine.loadModel('/models/model.gguf');

      await engine.complete(
        const [LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'hi')],
        params: GenerationParams(
          speculativeDecodingConfig: SpeculativeDecodingConfig.draftSimple(
            draftModel: hfDraft,
          ),
        ),
      );

      expect(
        backend.lastGenerationParams!.speculativeDecodingConfig!.draftModelPath,
        '/cache/draft.gguf',
      );
    });

    test('URL-loading backends get the draft model URL', () async {
      final backend = _RecordingBackend(urlLoadingSupported: true);
      final engine = LlamaEngine(backend);
      await engine.loadModelSource(
        ModelSource.url(Uri.parse('https://example.com/model.gguf')),
      );

      await engine
          .generate(
            prompt,
            params: GenerationParams(
              speculativeDecodingConfig: SpeculativeDecodingConfig.draftSimple(
                draftModel: hfDraft,
              ),
            ),
          )
          .drain<void>();

      expect(
        backend.lastGenerationParams!.speculativeDecodingConfig!.draftModelPath,
        'https://huggingface.co/owner/repo/resolve/main/draft.gguf?download=true',
      );
    });

    test('cancelGeneration stops a draft model download without cancelling '
        "the caller's token", () async {
      final backend = _RecordingBackend();
      final manager = _BlockingManager();
      final engine = LlamaEngine(backend, modelDownloadManager: manager);
      await engine.loadModel('/models/model.gguf');
      final userToken = ModelDownloadCancelToken();

      final tokens = <String>[];
      final done = engine
          .generate(
            prompt,
            params: GenerationParams(
              speculativeDecodingConfig: SpeculativeDecodingConfig.draftSimple(
                draftModel: hfDraft,
                draftModelDownload: ModelLoadOptions(cancelToken: userToken),
              ),
            ),
          )
          .listen(tokens.add)
          .asFuture<void>();
      await manager.started.future;
      engine.cancelGeneration();
      await done;

      expect(tokens, isEmpty);
      expect(backend.lastGenerationParams, isNull);
      expect(manager.sawCancel, isTrue);
      expect(userToken.isCancelled, isFalse);
    });

    test('a failed draft model download fails the generation', () async {
      final backend = _RecordingBackend();
      final engine = LlamaEngine(
        backend,
        modelDownloadManager: _CacheManager({}, failing: {hfDraft}),
      );
      await engine.loadModel('/models/model.gguf');

      await expectLater(
        engine
            .generate(
              prompt,
              params: GenerationParams(
                speculativeDecodingConfig:
                    SpeculativeDecodingConfig.draftSimple(draftModel: hfDraft),
              ),
            )
            .drain<void>(),
        throwsA(isA<LlamaModelException>()),
      );
      expect(backend.lastGenerationParams, isNull);
    });
  });
}

class _RecordingBackend extends MockLlamaBackend {
  _RecordingBackend({super.urlLoadingSupported});

  final List<ModelParams> contextParams = <ModelParams>[];
  final List<String> removedLoraPaths = <String>[];

  @override
  Future<int> contextCreate(int modelHandle, ModelParams params) {
    contextParams.add(params);
    return super.contextCreate(modelHandle, params);
  }

  @override
  Future<void> removeLoraAdapter(int contextHandle, String path) {
    removedLoraPaths.add(path);
    return super.removeLoraAdapter(contextHandle, path);
  }
}

typedef _Call = ({ModelSource source, ModelLoadOptions options});

/// Returns the file mapped to each source's cache key, the path of a local
/// source, and fails for [failing] sources.
class _CacheManager implements ModelDownloadManager {
  _CacheManager(Map<ModelSource, String> files, {Set<ModelSource>? failing})
    : _files = {
        for (final MapEntry(:key, :value) in files.entries) key.cacheKey: value,
      },
      _failing = {for (final source in failing ?? {}) source.cacheKey};

  final Map<String, String> _files;
  final Set<String> _failing;
  final List<_Call> calls = <_Call>[];

  @override
  Future<ModelCacheEntry> ensureModel(
    ModelSource source, {
    ModelLoadOptions options = ModelLoadOptions.defaults,
    ModelDownloadProgressCallback? onProgress,
  }) async {
    calls.add((source: source, options: options));
    if (options.cancelToken?.isCancelled ?? false) {
      throw LlamaStateException('Model download was cancelled.');
    }
    if (_failing.contains(source.cacheKey)) {
      throw LlamaModelException('Download failed.');
    }
    onProgress?.call(
      const ModelDownloadProgress(receivedBytes: 1, totalBytes: 2),
    );
    return ModelCacheEntry(
      sourceCanonicalKey: source.metadataSourceKey,
      cacheKey: source.cacheKey,
      fileName: source.fileName,
      filePath: source.path ?? _files[source.cacheKey]!,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );
  }

  @override
  Future<void> clear({String? cacheDirectory}) async {}

  @override
  Future<ModelCacheEntry?> get(
    String cacheKey, {
    String? cacheDirectory,
  }) async => null;

  @override
  Future<List<ModelCacheEntry>> list({String? cacheDirectory}) async =>
      const <ModelCacheEntry>[];

  @override
  Future<List<ModelCacheEntry>> prune({
    Duration? maxAge,
    int? maxBytes,
    String? cacheDirectory,
  }) async => const <ModelCacheEntry>[];

  @override
  Future<void> remove(String cacheKey, {String? cacheDirectory}) async {}
}

/// Polls its cancel token like the package download manager, until it is
/// cancelled.
class _BlockingManager extends _CacheManager {
  _BlockingManager() : super({});

  final Completer<void> started = Completer<void>();
  bool sawCancel = false;

  @override
  Future<ModelCacheEntry> ensureModel(
    ModelSource source, {
    ModelLoadOptions options = ModelLoadOptions.defaults,
    ModelDownloadProgressCallback? onProgress,
  }) async {
    started.complete();
    while (!(options.cancelToken?.isCancelled ?? false)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    sawCancel = true;
    throw LlamaStateException('Model download was cancelled.');
  }
}
