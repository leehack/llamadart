import 'dart:async';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/backends/backend.dart'
    show BackendRuntimeIdentity;
import 'package:test/test.dart';

import 'engine_test.dart' show MockLlamaBackend, NativeChatMockBackend;

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

    test('loadModelSource gives an adapter without its own options only the '
        "load's non-secret options, and one with its own options those plus "
        "the load's cancel token", () async {
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
        bearerToken: 'MODEL-HOST-TOKEN',
        headers: const {'X-Model-Host': 'secret'},
        sha256: 'a' * 64,
        cachePolicy: ModelCachePolicy.cacheOnly,
        cacheDirectory: '/models/cache',
        cancelToken: token,
        resume: false,
        maxRetries: 5,
      );
      final adapterOptions = ModelLoadOptions(bearerToken: 'ADAPTER-TOKEN');

      await engine.loadModelSource(
        modelSource,
        options: options,
        modelParams: ModelParams(
          loras: [
            LoraAdapterConfig.source(hfAdapter, scale: 0.5),
            LoraAdapterConfig.source(localAdapter),
            LoraAdapterConfig.source(
              urlAdapter,
              scale: 0.75,
              download: adapterOptions,
            ),
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
      final inherited = manager.calls[1].options;
      expect(inherited.bearerToken, isNull);
      expect(inherited.headers, isEmpty);
      expect(inherited.sha256, isNull);
      expect(inherited.cachePolicy, ModelCachePolicy.cacheOnly);
      expect(inherited.cacheDirectory, '/models/cache');
      expect(inherited.resume, isFalse);
      expect(inherited.maxRetries, 5);
      expect(inherited.cancelToken, same(token));
      final local = manager.calls[2].options;
      expect(local.bearerToken, isNull);
      expect(local.cachePolicy, ModelCachePolicy.preferCached);
      expect(local.cacheDirectory, isNull);
      expect(local.cancelToken, same(token));
      final own = manager.calls[3].options;
      expect(own.bearerToken, 'ADAPTER-TOKEN');
      expect(own.headers, isEmpty);
      expect(own.cacheDirectory, isNull);
      expect(own.cancelToken!.isCancelled, isFalse);
      token.cancel();
      expect(own.cancelToken!.isCancelled, isTrue);

      await engine.removeLoraSource(urlAdapter);
      expect(backend.removedLoraPaths, ['/cache/tone.gguf']);
    });

    test("an adapter's own cancel token and the load's both cancel its "
        'download', () async {
      final loadToken = ModelDownloadCancelToken();
      final ownToken = ModelDownloadCancelToken();
      final manager = _CacheManager({hfAdapter: '/cache/style.gguf'});
      final engine = LlamaEngine(
        _RecordingBackend(),
        modelDownloadManager: manager,
      );

      await engine.loadModelSource(
        localAdapter,
        options: ModelLoadOptions(cancelToken: loadToken),
        modelParams: ModelParams(
          loras: [
            LoraAdapterConfig.source(
              hfAdapter,
              download: ModelLoadOptions(cancelToken: ownToken),
            ),
          ],
        ),
      );

      final linked = manager.calls.last.options.cancelToken!;
      expect(linked.isCancelled, isFalse);
      ownToken.cancel();
      expect(linked.isCancelled, isTrue);
      expect(loadToken.isCancelled, isFalse);
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
      final options = manager.calls.single.options;
      expect(options.bearerToken, isNull);
      expect(options.cachePolicy, ModelCachePolicy.preferCached);
      expect(options.cacheDirectory, isNull);
      expect(options.cancelToken, isNull);
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

  group('LoRA source lifecycle', () {
    test('unloading forgets where remote adapters resolved', () async {
      final backend = _RecordingBackend();
      final engine = LlamaEngine(
        backend,
        modelDownloadManager: _CacheManager({urlAdapter: '/cache/tone.gguf'}),
      );
      await engine.loadModel('/models/model.gguf');
      await engine.setLoraSource(urlAdapter);
      await engine.unloadModel();
      await engine.loadModel('/models/model.gguf');

      await engine.removeLoraSource(urlAdapter);

      expect(backend.removedLoraPaths, isEmpty);
    });

    test('removeLoraSource removes a local adapter by its path even when it '
        'was not set from that source', () async {
      final backend = _RecordingBackend();
      final engine = LlamaEngine(
        backend,
        modelDownloadManager: _CacheManager({}),
      );
      await engine.loadModel('/models/model.gguf');

      await engine.removeLoraSource(localAdapter);

      expect(backend.removedLoraPaths, ['/models/local-adapter.gguf']);
    });

    test('setLoraSource with options that resolve the same source to another '
        'file replaces the adapter applied from it', () async {
      final backend = _RecordingBackend();
      final manager = _DirectoryManager();
      final engine = LlamaEngine(backend, modelDownloadManager: manager);
      await engine.loadModel('/models/model.gguf');

      await engine.setLoraSource(
        urlAdapter,
        download: ModelLoadOptions(cacheDirectory: '/a'),
      );
      await engine.setLoraSource(
        urlAdapter,
        download: ModelLoadOptions(cacheDirectory: '/b'),
      );
      await engine.removeLoraSource(urlAdapter);

      expect(backend.setLoraPaths, ['/a/tone.gguf', '/b/tone.gguf']);
      expect(backend.removedLoraPaths, ['/a/tone.gguf', '/b/tone.gguf']);
    });

    test('setLoraSource stops when its token is cancelled while the adapter '
        'resolves', () async {
      final backend = _RecordingBackend();
      final token = ModelDownloadCancelToken();
      final engine = LlamaEngine(
        backend,
        modelDownloadManager: _CacheManager({
          hfAdapter: '/cache/style.gguf',
        }, onEnsure: token.cancel),
      );
      await engine.loadModel('/models/model.gguf');

      await expectLater(
        engine.setLoraSource(
          hfAdapter,
          download: ModelLoadOptions(cancelToken: token),
        ),
        throwsA(isA<LlamaStateException>()),
      );
      expect(backend.setLoraPaths, isEmpty);
    });

    test(
      'loadModelFromUrl resolves adapter sources through the resolver',
      () async {
        final backend = _RecordingBackend(urlLoadingSupported: true);
        final engine = LlamaEngine(backend, modelResolver: _MirrorResolver());

        await engine.loadModelFromUrl(
          'https://example.com/model.gguf',
          modelParams: ModelParams(
            loras: [LoraAdapterConfig.source(hfAdapter)],
          ),
        );

        expect(
          backend.contextParams.single.loras.single.path,
          'https://mirror.example.com/style.gguf',
        );
      },
    );
  });

  group('speculative draft model reuse', () {
    GenerationParams draftParams({
      ModelLoadOptions download = ModelLoadOptions.defaults,
    }) => GenerationParams(
      speculativeDecodingConfig: SpeculativeDecodingConfig.draftSimple(
        draftModel: hfDraft,
        draftModelDownload: download,
      ),
    );

    test('a draft model resolves once across generations, and again after '
        'the model reloads', () async {
      final backend = _RecordingBackend();
      final manager = _CacheManager({hfDraft: '/cache/draft.gguf'});
      final engine = LlamaEngine(backend, modelDownloadManager: manager);
      await engine.loadModel('/models/model.gguf');
      final download = ModelLoadOptions(sha256: 'b' * 64);

      for (var i = 0; i < 3; i++) {
        await engine
            .generate('hi', params: draftParams(download: download))
            .drain<void>();
        expect(
          backend
              .lastGenerationParams!
              .speculativeDecodingConfig!
              .draftModelPath,
          '/cache/draft.gguf',
        );
      }
      expect(manager.calls, hasLength(1));

      await engine.unloadModel();
      await engine.loadModel('/models/model.gguf');
      await engine
          .generate('hi', params: draftParams(download: download))
          .drain<void>();
      expect(manager.calls, hasLength(2));
    });

    test(
      'another cache directory or checksum resolves the draft model again',
      () async {
        final manager = _CacheManager({hfDraft: '/cache/draft.gguf'});
        final engine = LlamaEngine(
          _RecordingBackend(),
          modelDownloadManager: manager,
        );
        await engine.loadModel('/models/model.gguf');

        await engine.generate('hi', params: draftParams()).drain<void>();
        await engine
            .generate(
              'hi',
              params: draftParams(
                download: ModelLoadOptions(cacheDirectory: '/other'),
              ),
            )
            .drain<void>();
        await engine
            .generate(
              'hi',
              params: draftParams(download: ModelLoadOptions(sha256: 'c' * 64)),
            )
            .drain<void>();
        await engine.generate('hi', params: draftParams()).drain<void>();

        expect(manager.calls, hasLength(3));
      },
    );

    for (final policy in [ModelCachePolicy.noCache, ModelCachePolicy.refresh]) {
      test('draftModelDownload rejects ModelCachePolicy.${policy.name} before '
          'downloading', () async {
        final backend = _RecordingBackend();
        final manager = _CacheManager({hfDraft: '/cache/draft.gguf'});
        final engine = LlamaEngine(backend, modelDownloadManager: manager);
        await engine.loadModel('/models/model.gguf');

        await expectLater(
          engine
              .generate(
                'hi',
                params: draftParams(
                  download: ModelLoadOptions(cachePolicy: policy),
                ),
              )
              .drain<void>(),
          throwsA(
            isA<LlamaUnsupportedException>().having(
              (error) => error.message,
              'message',
              contains('ModelCachePolicy.${policy.name}'),
            ),
          ),
        );
        expect(manager.calls, isEmpty);
        expect(backend.lastGenerationParams, isNull);
      });
    }

    test('unloading the model stops a draft model download and the '
        'generation never reaches the backend', () async {
      final backend = _RecordingBackend();
      final manager = _BlockingManager();
      final engine = LlamaEngine(backend, modelDownloadManager: manager);
      await engine.loadModel('/models/model.gguf');

      final done = engine.generate('hi', params: draftParams()).drain<void>();
      await manager.started.future;
      await engine.unloadModel();
      await engine.loadModel('/models/model.gguf');
      await done;

      expect(manager.sawCancel, isTrue);
      expect(backend.lastGenerationParams, isNull);
    });

    test('LiteRT-LM rejects a draft model before it downloads', () async {
      final manager = _CacheManager({hfDraft: '/cache/draft.gguf'});
      final engine = LlamaEngine(
        _RuntimeBackend(LlamaRuntime.liteRtLm),
        modelDownloadManager: manager,
      );
      await engine.loadModel('/models/model.litertlm');

      await expectLater(
        engine.generate('hi', params: draftParams()).drain<void>(),
        throwsA(
          isA<LlamaUnsupportedException>().having(
            (error) => error.message,
            'message',
            contains('LiteRT-LM cannot load an external speculative draft'),
          ),
        ),
      );
      expect(manager.calls, isEmpty);
    });

    test('a backend that does not report the strategy rejects the draft '
        'model before it downloads, and one that does resolves it', () async {
      final manager = _CacheManager({hfDraft: '/cache/draft.gguf'});
      final unsupported = LlamaEngine(
        _RuntimeBackend(
          LlamaRuntime.llamaCpp,
          strategies: {SpeculativeDecodingStrategy.ngramMod},
        ),
        modelDownloadManager: manager,
      );
      await unsupported.loadModel('/models/model.gguf');

      await expectLater(
        unsupported.generate('hi', params: draftParams()).drain<void>(),
        throwsA(
          isA<LlamaUnsupportedException>().having(
            (error) => error.message,
            'message',
            contains('draftSimple'),
          ),
        ),
      );
      expect(manager.calls, isEmpty);

      final supportedBackend = _RuntimeBackend(
        LlamaRuntime.llamaCpp,
        strategies: {SpeculativeDecodingStrategy.draftSimple},
      );
      final supported = LlamaEngine(
        supportedBackend,
        modelDownloadManager: manager,
      );
      await supported.loadModel('/models/model.gguf');
      await supported.generate('hi', params: draftParams()).drain<void>();
      expect(manager.calls, hasLength(1));
    });

    test('native chat generation resolves the draft model', () async {
      final backend = NativeChatMockBackend();
      final engine = LlamaEngine(
        backend,
        modelDownloadManager: _CacheManager({hfDraft: '/cache/draft.gguf'}),
      );
      await engine.loadModel('/models/model.gguf');

      await engine.complete(const [
        LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'hi'),
      ], params: draftParams());

      expect(backend.nativeGenerateChatCalls, 1);
      expect(
        backend.lastNativeParams!.speculativeDecodingConfig!.draftModelPath,
        '/cache/draft.gguf',
      );
    });

    test('the resolved config keeps every other field', () async {
      final backend = _RecordingBackend();
      final engine = LlamaEngine(
        backend,
        modelDownloadManager: _CacheManager({hfDraft: '/cache/draft.gguf'}),
      );
      await engine.loadModel('/models/model.gguf');
      final config = SpeculativeDecodingConfig.mixed(
        strategies: const [
          SpeculativeDecodingStrategy.ngramSimple,
          SpeculativeDecodingStrategy.ngramMod,
          SpeculativeDecodingStrategy.ngramCache,
          SpeculativeDecodingStrategy.draftSimple,
        ],
        draftTokenMax: 9,
        draftTokenMin: 2,
        minProbability: 0.3,
        draftSplitProbability: 0.2,
        draftModel: hfDraft,
        ngramSize: 3,
        ngramSizeN: 4,
        ngramSizeM: 5,
        ngramMinHits: 6,
        ngramMatch: 7,
        ngramTokenMin: 8,
        ngramTokenMax: 10,
        ngramCacheStaticPath: '/static.bin',
        ngramCacheDynamicPath: '/dynamic.bin',
      );

      await engine
          .generate(
            'hi',
            params: GenerationParams(speculativeDecodingConfig: config),
          )
          .drain<void>();

      final sent = backend.lastGenerationParams!.speculativeDecodingConfig!;
      expect(
        (
          sent.strategy,
          sent.strategies,
          sent.draftTokenMax,
          sent.draftTokenMin,
          sent.minProbability,
          sent.draftSplitProbability,
          sent.draftModelPath,
          sent.draftModel,
        ),
        (
          config.strategy,
          config.strategies,
          9,
          2,
          0.3,
          0.2,
          '/cache/draft.gguf',
          null,
        ),
      );
      expect(
        (
          sent.ngramSize,
          sent.ngramSizeN,
          sent.ngramSizeM,
          sent.ngramMinHits,
          sent.ngramMatch,
          sent.ngramTokenMin,
          sent.ngramTokenMax,
          sent.ngramCacheStaticPath,
          sent.ngramCacheDynamicPath,
        ),
        (3, 4, 5, 6, 7, 8, 10, '/static.bin', '/dynamic.bin'),
      );
    });
  });
}

class _RecordingBackend extends MockLlamaBackend {
  _RecordingBackend({super.urlLoadingSupported});

  final List<ModelParams> contextParams = <ModelParams>[];
  final List<String> setLoraPaths = <String>[];
  final List<String> removedLoraPaths = <String>[];

  @override
  Future<void> setLoraAdapter(int contextHandle, String path, double scale) {
    setLoraPaths.add(path);
    return super.setLoraAdapter(contextHandle, path, scale);
  }

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
/// source, and fails for [failing] sources. [onEnsure] runs once a download
/// has passed its cancellation check, as a cancel arriving after it.
class _CacheManager implements ModelDownloadManager {
  _CacheManager(
    Map<ModelSource, String> files, {
    Set<ModelSource>? failing,
    this.onEnsure,
  }) : _files = {
         for (final MapEntry(:key, :value) in files.entries)
           key.cacheKey: value,
       },
       _failing = {for (final source in failing ?? {}) source.cacheKey};

  final Map<String, String> _files;
  final Set<String> _failing;
  final List<_Call> calls = <_Call>[];
  final void Function()? onEnsure;

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
    onEnsure?.call();
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

/// Puts each remote file in the options' cache directory.
class _DirectoryManager extends _CacheManager {
  _DirectoryManager() : super({});

  @override
  Future<ModelCacheEntry> ensureModel(
    ModelSource source, {
    ModelLoadOptions options = ModelLoadOptions.defaults,
    ModelDownloadProgressCallback? onProgress,
  }) async {
    calls.add((source: source, options: options));
    return ModelCacheEntry(
      sourceCanonicalKey: source.metadataSourceKey,
      cacheKey: source.cacheKey,
      fileName: source.fileName,
      filePath: '${options.cacheDirectory}/${source.fileName}',
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );
  }
}

/// Resolves every remote source to a mirror URL.
class _MirrorResolver implements ModelResolver {
  @override
  Future<ModelLoadTarget> resolve(
    ModelSource source,
    ModelResolveRequest request,
  ) async => source.isLocal
      ? LocalModelFile(source.path!)
      : RemoteModelUrl(
          Uri.parse('https://mirror.example.com/${source.fileName}'),
        );
}

class _RuntimeBackend extends _RecordingBackend
    implements BackendRuntimeIdentity, BackendGenerationCapabilitiesSupport {
  _RuntimeBackend(this.runtime, {this.strategies = const {}});

  @override
  final LlamaRuntime runtime;
  final Set<SpeculativeDecodingStrategy> strategies;

  @override
  Future<BackendGenerationCapabilities> generationCapabilities() async =>
      BackendGenerationCapabilities(
        presencePenalty: false,
        minP: false,
        thinkingBudget: false,
        speculativeDecodingStrategies: strategies,
      );
}
