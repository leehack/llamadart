import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:llamadart/llamadart.dart';

class MockLlamaBackend
    implements LlamaBackend, BackendAvailability, BackendRuntimeDiagnostics {
  MockLlamaBackend({
    this.backendName = 'Mock',
    this.urlLoadingSupported = false,
    this.failModelLoad = false,
    this.failModelLoadFromUrl = false,
    this.failContextCreate = false,
    this.modelMetadataResponse,
  });

  bool _isReady = false;
  String? lastModelPath;
  String? lastLoraPath;
  String? lastModelUrl;
  double? lastLoraScale;
  int resolvedGpuLayers = 0;
  int modelLoadCalls = 0;
  int modelLoadFromUrlCalls = 0;
  int modelFreeCalls = 0;
  int contextFreeCalls = 0;
  int tokenizeCalls = 0;
  int modelMetadataCalls = 0;
  String generationText = 'response';
  List<String>? generationChunks;
  final String backendName;
  final bool urlLoadingSupported;
  final bool failModelLoad;
  final bool failModelLoadFromUrl;
  final bool failContextCreate;
  final Map<String, String>? modelMetadataResponse;

  @override
  bool get isReady => _isReady;

  @override
  Future<int> modelLoad(String path, ModelParams params) async {
    modelLoadCalls += 1;
    lastModelPath = path;
    if (failModelLoad) {
      throw Exception('model load failed');
    }
    _isReady = true;
    return 1;
  }

  @override
  Future<int> modelLoadFromUrl(
    String url,
    ModelParams params, {
    Function(double progress)? onProgress,
  }) async {
    modelLoadFromUrlCalls += 1;
    lastModelUrl = url;
    onProgress?.call(0.25);
    if (failModelLoadFromUrl) {
      throw Exception('url model load failed: $url');
    }
    _isReady = true;
    return 1;
  }

  @override
  Future<void> modelFree(int modelHandle) async {
    modelFreeCalls += 1;
  }

  @override
  Future<int> contextCreate(int modelHandle, ModelParams params) async {
    if (failContextCreate) {
      throw Exception('context create failed');
    }
    return 1;
  }

  @override
  Future<void> contextFree(int contextHandle) async {
    contextFreeCalls += 1;
  }

  @override
  Future<int> getContextSize(int contextHandle) async => 2048;

  @override
  Stream<List<int>> generate(
    int contextHandle,
    String prompt,
    GenerationParams params, {
    List<LlamaContentPart>? parts,
  }) async* {
    if (generationChunks != null) {
      for (final chunk in generationChunks!) {
        yield utf8.encode(chunk);
      }
      return;
    }
    yield utf8.encode(generationText);
  }

  @override
  void cancelGeneration() {}

  @override
  Future<List<int>> tokenize(
    int modelHandle,
    String text, {
    bool addSpecial = true,
  }) async {
    tokenizeCalls += 1;
    return [1, 2, 3];
  }

  @override
  Future<String> detokenize(
    int modelHandle,
    List<int> tokens, {
    bool special = false,
  }) async => 'decoded';

  @override
  Future<Map<String, String>> modelMetadata(int modelHandle) async {
    modelMetadataCalls += 1;
    return modelMetadataResponse ??
        {
          'llm.context_length': '4096',
          'tokenizer.chat_template':
              '{{ bos_token }}{% for message in messages %}{% if message["role"] == "user" %}{{ "user: " + message["content"] }}{% elif message["role"] == "assistant" %}{{ "assistant: " + message["content"] }}{% endif %}{% endfor %}{% if add_generation_prompt %}{{ "assistant: " }}{% endif %}',
        };
  }

  @override
  Future<void> setLoraAdapter(
    int contextHandle,
    String path,
    double scale,
  ) async {
    lastLoraPath = path;
    lastLoraScale = scale;
  }

  @override
  Future<void> removeLoraAdapter(int contextHandle, String path) async {
    lastLoraPath = null;
  }

  @override
  Future<void> clearLoraAdapters(int contextHandle) async {
    lastLoraPath = null;
  }

  @override
  Future<String> getBackendName() async => backendName;

  @override
  Future<String> getAvailableBackends() async => backendName;

  @override
  Future<int?> getResolvedGpuLayers() async => resolvedGpuLayers;

  @override
  bool get supportsUrlLoading => urlLoadingSupported;

  @override
  Future<bool> isGpuSupported() async => false;

  @override
  Future<void> setLogLevel(LlamaLogLevel level) async {}

  @override
  Future<void> dispose() async {
    _isReady = false;
  }

  @override
  Future<int?> multimodalContextCreate(
    int modelHandle,
    String mmProjPath,
  ) async => 2;

  @override
  Future<void> multimodalContextFree(int mmContextHandle) async {}

  @override
  Future<bool> supportsVision(int mmContextHandle) async => true;

  @override
  Future<bool> supportsAudio(int mmContextHandle) async => false;

  @override
  Future<({int total, int free})> getVramInfo() async =>
      (total: 8192, free: 4096);

  @override
  Future<String> applyChatTemplate(
    int modelHandle,
    List<Map<String, dynamic>> messages, {
    String? customTemplate,
    bool addAssistant = true,
  }) async {
    return messages.map((m) => "${m['role']}: ${m['content']}").join('\n');
  }
}

class MockModelResolver implements ModelResolver {
  MockModelResolver(this.target);

  final ModelLoadTarget target;
  ModelSource? lastSource;

  @override
  Future<ModelLoadTarget> resolve(
    ModelSource source,
    ModelResolveRequest request,
  ) async {
    lastSource = source;
    return target;
  }
}

class MockModelDownloadManager implements ModelDownloadManager {
  MockModelDownloadManager(this.entry);

  final ModelCacheEntry entry;
  ModelSource? lastSource;
  ModelLoadOptions? lastOptions;
  int ensureModelCalls = 0;

  @override
  Future<ModelCacheEntry> ensureModel(
    ModelSource source, {
    ModelLoadOptions options = ModelLoadOptions.defaults,
    ModelDownloadProgressCallback? onProgress,
  }) async {
    ensureModelCalls += 1;
    lastSource = source;
    lastOptions = options;
    onProgress?.call(
      const ModelDownloadProgress(receivedBytes: 1, totalBytes: 2),
    );
    return entry;
  }

  @override
  Future<void> clear({String? cacheDirectory}) async {}

  @override
  Future<ModelCacheEntry?> get(
    String cacheKey, {
    String? cacheDirectory,
  }) async => cacheKey == entry.cacheKey ? entry : null;

  @override
  Future<List<ModelCacheEntry>> list({String? cacheDirectory}) async =>
      <ModelCacheEntry>[entry];

  @override
  Future<List<ModelCacheEntry>> prune({
    Duration? maxAge,
    int? maxBytes,
    String? cacheDirectory,
  }) async => <ModelCacheEntry>[];

  @override
  Future<void> remove(String cacheKey, {String? cacheDirectory}) async {}
}

class MockEmbeddingBackend extends MockLlamaBackend
    implements BackendEmbeddings {
  int embedCalls = 0;

  @override
  Future<List<double>> embed(
    int contextHandle,
    String text, {
    bool normalize = true,
  }) async {
    embedCalls += 1;
    const tailX = 3.0;
    const tailY = 4.0;
    final vector = <double>[text.length.toDouble(), tailX, tailY];
    if (!normalize) {
      return vector;
    }

    final norm = math.sqrt(
      vector[0] * vector[0] + tailX * tailX + tailY * tailY,
    );
    return <double>[vector[0] / norm, tailX / norm, tailY / norm];
  }
}

class MockBatchEmbeddingBackend extends MockLlamaBackend
    implements BackendBatchEmbeddings {
  int embedCalls = 0;
  int embedBatchCalls = 0;

  @override
  Future<List<double>> embed(
    int contextHandle,
    String text, {
    bool normalize = true,
  }) async {
    embedCalls += 1;
    return <double>[text.length.toDouble()];
  }

  @override
  Future<List<List<double>>> embedBatch(
    int contextHandle,
    List<String> texts, {
    bool normalize = true,
  }) async {
    embedBatchCalls += 1;
    return texts
        .map((text) => <double>[text.length.toDouble(), 99.0])
        .toList(growable: false);
  }
}

void main() {
  late MockLlamaBackend backend;
  late LlamaEngine engine;

  setUp(() {
    backend = MockLlamaBackend();
    engine = LlamaEngine(backend);
  });

  group('LlamaEngine Mock Tests', () {
    test('loadModel successful', () async {
      await engine.loadModel('qwen-test.gguf');
      expect(engine.isReady, true);
    });

    test(
      'loadModel cleans up partial state when context creation fails',
      () async {
        final failingBackend = MockLlamaBackend(failContextCreate: true);
        final failingEngine = LlamaEngine(failingBackend);

        await expectLater(
          () => failingEngine.loadModel('C:\\models\\qwen-test.gguf'),
          throwsA(isA<LlamaModelException>()),
        );

        expect(failingBackend.modelFreeCalls, 1);
        expect(failingBackend.contextFreeCalls, 0);
        expect(failingEngine.isReady, isFalse);
        expect(failingEngine.modelHandle, isNull);
        expect(failingEngine.contextHandle, isNull);
      },
    );

    test('loadModel routes through URL loader when supported', () async {
      final webBackend = MockLlamaBackend(urlLoadingSupported: true);
      final webEngine = LlamaEngine(webBackend);

      await webEngine.loadModel('https://example.com/model.gguf');

      expect(webBackend.modelLoadCalls, 0);
      expect(webBackend.modelLoadFromUrlCalls, 1);
      expect(webEngine.isReady, isTrue);
    });

    test(
      'loadModelSource rejects explicit local paths on URL backends',
      () async {
        final webBackend = MockLlamaBackend(urlLoadingSupported: true);
        final webEngine = LlamaEngine(webBackend);

        await expectLater(
          () =>
              webEngine.loadModelSource(ModelSource.path('/models/model.gguf')),
          throwsA(isA<LlamaUnsupportedException>()),
        );
      },
    );

    test(
      'native loadModelSource applies load options for local path sources',
      () async {
        final source = ModelSource.path('/models/model.gguf');
        final entry = ModelCacheEntry(
          sourceCanonicalKey: source.metadataSourceKey,
          cacheKey: source.cacheKey,
          fileName: source.fileName,
          filePath: '/models/model.gguf',
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
        );
        final downloadManager = MockModelDownloadManager(entry);
        final nativeBackend = MockLlamaBackend();
        final nativeEngine = LlamaEngine(
          nativeBackend,
          modelDownloadManager: downloadManager,
        );
        final options = ModelLoadOptions(
          sha256:
              '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        );

        await nativeEngine.loadModelSource(source, options: options);

        expect(downloadManager.ensureModelCalls, 1);
        expect(downloadManager.lastSource?.path, source.path);
        expect(downloadManager.lastSource?.cacheKey, source.cacheKey);
        expect(downloadManager.lastOptions, same(options));
        expect(nativeBackend.lastModelPath, '/models/model.gguf');
      },
    );

    test('native loadModelSource rejects local remote-only options', () async {
      final nativeBackend = MockLlamaBackend();
      final nativeEngine = LlamaEngine(nativeBackend);

      await expectLater(
        () => nativeEngine.loadModelSource(
          ModelSource.path('/models/local-model.gguf'),
          options: ModelLoadOptions(cachePolicy: ModelCachePolicy.refresh),
        ),
        throwsA(isA<LlamaUnsupportedException>()),
      );
      expect(nativeBackend.modelLoadCalls, 0);
    });

    test(
      'native loadModelSource honors resolver-provided local path',
      () async {
        final source = ModelSource.path('/models/original.gguf');
        final resolvedSource = ModelSource.path('/models/resolved.gguf');
        final entry = ModelCacheEntry(
          sourceCanonicalKey: resolvedSource.metadataSourceKey,
          cacheKey: resolvedSource.cacheKey,
          fileName: resolvedSource.fileName,
          filePath: '/models/resolved.gguf',
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
        );
        final resolver = MockModelResolver(
          const LocalModelFile('/models/resolved.gguf'),
        );
        final downloadManager = MockModelDownloadManager(entry);
        final nativeBackend = MockLlamaBackend();
        final nativeEngine = LlamaEngine(
          nativeBackend,
          modelResolver: resolver,
          modelDownloadManager: downloadManager,
        );

        await nativeEngine.loadModelSource(source);

        expect(resolver.lastSource, source);
        expect(downloadManager.lastSource?.path, '/models/resolved.gguf');
        expect(nativeBackend.lastModelPath, '/models/resolved.gguf');
      },
    );

    test('loadModelFromUrl unsupported on non-URL backend', () async {
      expect(
        () => engine.loadModelFromUrl('http://test.gguf'),
        throwsA(isA<LlamaUnsupportedException>()),
      );
    });

    test(
      'loadModelFromUrl marks engine ready on URL-capable backend',
      () async {
        final webBackend = MockLlamaBackend(
          backendName: 'WASM (Web)',
          urlLoadingSupported: true,
        );
        final webEngine = LlamaEngine(webBackend);

        await webEngine.loadModelFromUrl('https://example.com/model.gguf');

        expect(webEngine.isReady, isTrue);
        expect(webEngine.modelHandle, isNotNull);
        expect(webEngine.contextHandle, isNotNull);
      },
    );

    test(
      'loadModelFromUrl redacts completion model metadata for signed URLs',
      () async {
        final webBackend = MockLlamaBackend(urlLoadingSupported: true)
          ..generationText = 'hello';
        final webEngine = LlamaEngine(webBackend);

        await webEngine.loadModelFromUrl(
          'https://user:secret@example.com/model.gguf?token=abc123#fragment',
        );
        final chunks = await webEngine.create(const [
          LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'hi'),
        ]).toList();

        expect(chunks, isNotEmpty);
        for (final chunk in chunks) {
          expect(chunk.model, 'https://example.com/model.gguf');
          expect(chunk.model, isNot(contains('secret')));
          expect(chunk.model, isNot(contains('token=abc123')));
        }
      },
    );

    test('loadModelSource forwards progress for remote URL targets', () async {
      final webBackend = MockLlamaBackend(urlLoadingSupported: true);
      final webEngine = LlamaEngine(webBackend);
      final progressEvents = <ModelDownloadProgress>[];

      await webEngine.loadModelSource(
        ModelSource.url(Uri.parse('https://example.com/model.gguf')),
        onProgress: progressEvents.add,
      );

      expect(webBackend.lastModelUrl, 'https://example.com/model.gguf');
      expect(progressEvents, hasLength(1));
      expect(progressEvents.single.receivedBytes, 0);
      expect(progressEvents.single.totalBytes, isNull);
      expect(progressEvents.single.fraction, 0.25);
    });

    test(
      'loadModelSource downloads remote sources before native model load',
      () async {
        final source = ModelSource.url(
          Uri.parse('https://example.com/model.gguf'),
        );
        final entry = ModelCacheEntry(
          sourceCanonicalKey: source.metadataSourceKey,
          cacheKey: source.cacheKey,
          fileName: source.fileName,
          filePath: '/cache/model.gguf',
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
          bytes: 12,
        );
        final downloadManager = MockModelDownloadManager(entry);
        final nativeBackend = MockLlamaBackend();
        final nativeEngine = LlamaEngine(
          nativeBackend,
          modelDownloadManager: downloadManager,
        );
        final options = ModelLoadOptions(
          cachePolicy: ModelCachePolicy.refresh,
          bearerToken: 'secret-token',
        );
        final progressEvents = <ModelDownloadProgress>[];

        await nativeEngine.loadModelSource(
          source,
          options: options,
          onProgress: progressEvents.add,
        );

        expect(downloadManager.ensureModelCalls, 1);
        expect(downloadManager.lastSource?.resolvedUri, source.resolvedUri);
        expect(downloadManager.lastSource?.fileName, source.fileName);
        expect(downloadManager.lastOptions, same(options));
        expect(nativeBackend.modelLoadCalls, 1);
        expect(nativeBackend.modelLoadFromUrlCalls, 0);
        expect(nativeBackend.lastModelPath, '/cache/model.gguf');
        expect(nativeEngine.isReady, isTrue);
        expect(progressEvents.single.fraction, 0.5);
      },
    );

    test(
      'native loadModelSource downloads resolved remote URL target',
      () async {
        final source = ModelSource.huggingFace(
          repoId: 'owner/repo',
          filePath: 'models/original.gguf',
          fileName: 'resolved.gguf',
        );
        final resolvedUrl = Uri.parse('https://cdn.example.com/resolved.gguf');
        final entry = ModelCacheEntry(
          sourceCanonicalKey: source.metadataSourceKey,
          cacheKey: source.cacheKey,
          fileName: source.fileName,
          filePath: '/cache/resolved.gguf',
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
        );
        final resolver = MockModelResolver(RemoteModelUrl(resolvedUrl));
        final downloadManager = MockModelDownloadManager(entry);
        final nativeBackend = MockLlamaBackend();
        final nativeEngine = LlamaEngine(
          nativeBackend,
          modelResolver: resolver,
          modelDownloadManager: downloadManager,
        );

        await nativeEngine.loadModelSource(source);

        expect(resolver.lastSource, source);
        expect(downloadManager.lastSource?.resolvedUri, resolvedUrl);
        expect(downloadManager.lastSource?.fileName, 'resolved.gguf');
        expect(downloadManager.lastSource?.cacheKey, source.cacheKey);
        expect(
          downloadManager.lastSource?.cacheDirectoryName,
          source.cacheDirectoryName,
        );
        expect(nativeBackend.lastModelPath, '/cache/resolved.gguf');
      },
    );

    test(
      'loadModelSource rejects unsupported cancellation on URL backends',
      () async {
        final webBackend = MockLlamaBackend(urlLoadingSupported: true);
        final webEngine = LlamaEngine(webBackend);

        await expectLater(
          () => webEngine.loadModelSource(
            ModelSource.url(Uri.parse('https://example.com/model.gguf')),
            options: ModelLoadOptions(cancelToken: ModelDownloadCancelToken()),
          ),
          throwsA(isA<LlamaUnsupportedException>()),
        );
        expect(webBackend.modelLoadFromUrlCalls, 0);
      },
    );

    test(
      'loadModelSource rejects unsupported noCache remote URL option',
      () async {
        final webBackend = MockLlamaBackend(urlLoadingSupported: true);
        final webEngine = LlamaEngine(webBackend);

        await expectLater(
          () => webEngine.loadModelSource(
            ModelSource.url(Uri.parse('https://example.com/model.gguf')),
            options: ModelLoadOptions(cachePolicy: ModelCachePolicy.noCache),
          ),
          throwsA(isA<LlamaUnsupportedException>()),
        );
      },
    );

    test(
      'loadModelFromUrl redacts credentials from thrown exception messages',
      () async {
        final failingBackend = MockLlamaBackend(
          urlLoadingSupported: true,
          failModelLoadFromUrl: true,
        );
        final failingEngine = LlamaEngine(failingBackend);

        Object? thrown;
        try {
          await failingEngine.loadModelFromUrl(
            'https://user:secret@example.com/model.gguf?token=abc123#fragment',
          );
        } catch (e) {
          thrown = e;
        }

        expect(thrown, isA<LlamaModelException>());
        expect(thrown.toString(), isNot(contains('secret')));
        expect(thrown.toString(), isNot(contains('token=abc123')));
        expect(thrown.toString(), contains('https://example.com/model.gguf'));
        final exception = thrown as LlamaModelException;
        expect(
          exception.details,
          isA<Map<String, Object?>>()
              .having(
                (details) => details['type'].toString(),
                'type',
                contains('Exception'),
              )
              .having(
                (details) => details['message'].toString(),
                'message',
                contains('url model load failed'),
              )
              .having(
                (details) => details['message'].toString(),
                'redacted message',
                isNot(anyOf(contains('secret'), contains('token=abc123'))),
              ),
        );
      },
    );

    test(
      'loadModelFromUrl cleans up partial state when context creation fails',
      () async {
        final failingBackend = MockLlamaBackend(
          urlLoadingSupported: true,
          failContextCreate: true,
        );
        final failingEngine = LlamaEngine(failingBackend);

        await expectLater(
          () =>
              failingEngine.loadModelFromUrl('https://example.com/model.gguf'),
          throwsA(isA<LlamaModelException>()),
        );

        expect(failingBackend.modelFreeCalls, 1);
        expect(failingBackend.contextFreeCalls, 0);
        expect(failingEngine.isReady, isFalse);
        expect(failingEngine.modelHandle, isNull);
        expect(failingEngine.contextHandle, isNull);
      },
    );

    test('create throws when not ready', () {
      expect(
        () => engine.create([
          const LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'hi'),
        ]).first,
        throwsA(isA<LlamaContextException>()),
      );
    });

    test('multimodal loading and support', () async {
      await engine.loadModel('qwen-test.gguf');
      await engine.loadMultimodalProjector('proj.gguf');
      expect(await engine.supportsVision, true);
      expect(await engine.supportsAudio, false);
    });

    test(
      'multimodal projector can be unloaded without unloading model',
      () async {
        await engine.loadModel('qwen-test.gguf');
        await engine.loadMultimodalProjector('proj.gguf');

        await engine.unloadMultimodalProjector();

        expect(await engine.supportsVision, isFalse);
        expect(await engine.supportsAudio, isFalse);
        expect(engine.isReady, isTrue);
      },
    );

    test('tokenize and detokenize', () async {
      await engine.loadModel('qwen-test.gguf');
      final tokens = await engine.tokenize('hello');
      expect(tokens, [1, 2, 3]);
      final text = await engine.detokenize(tokens);
      expect(text, 'decoded');
    });

    test('embed throws when not ready', () {
      expect(
        () => engine.embed('hello'),
        throwsA(isA<LlamaContextException>()),
      );
    });

    test('embed throws when backend does not support embeddings', () async {
      await engine.loadModel('qwen-test.gguf');

      expect(
        () => engine.embed('hello'),
        throwsA(isA<LlamaUnsupportedException>()),
      );
    });

    test('embed returns normalized vector by default', () async {
      final embeddingBackend = MockEmbeddingBackend();
      final embeddingEngine = LlamaEngine(embeddingBackend);

      await embeddingEngine.loadModel('qwen-test.gguf');
      final vector = await embeddingEngine.embed('hello');

      expect(vector.length, 3);
      expect(vector[0], closeTo(0.7071067, 0.000001));
      expect(vector[1], closeTo(0.4242640, 0.000001));
      expect(vector[2], closeTo(0.5656854, 0.000001));
      expect(embeddingBackend.embedCalls, 1);
    });

    test('embedBatch returns vectors for each input in order', () async {
      final embeddingBackend = MockEmbeddingBackend();
      final embeddingEngine = LlamaEngine(embeddingBackend);

      await embeddingEngine.loadModel('qwen-test.gguf');
      final vectors = await embeddingEngine.embedBatch(const [
        'a',
        'bb',
        'ccc',
      ], normalize: false);

      expect(vectors, <List<double>>[
        <double>[1.0, 3.0, 4.0],
        <double>[2.0, 3.0, 4.0],
        <double>[3.0, 3.0, 4.0],
      ]);
      expect(embeddingBackend.embedCalls, 3);
    });

    test('embedBatch uses backend batch capability when available', () async {
      final embeddingBackend = MockBatchEmbeddingBackend();
      final embeddingEngine = LlamaEngine(embeddingBackend);

      await embeddingEngine.loadModel('qwen-test.gguf');
      final vectors = await embeddingEngine.embedBatch(const [
        'a',
        'bb',
      ], normalize: false);

      expect(vectors, <List<double>>[
        <double>[1.0, 99.0],
        <double>[2.0, 99.0],
      ]);
      expect(embeddingBackend.embedBatchCalls, 1);
      expect(embeddingBackend.embedCalls, 0);
    });

    test('chatTemplate', () async {
      await engine.loadModel('qwen-test.gguf');
      final result = await engine.chatTemplate([
        const LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'hi'),
      ]);
      expect(result.prompt, '<s>user: hiassistant: ');
      expect(result.tokenCount, 3);
    });

    test('chatTemplate can skip token counting', () async {
      await engine.loadModel('qwen-test.gguf');

      final result = await engine.chatTemplate(const [
        LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'hi'),
      ], includeTokenCount: false);

      expect(result.prompt, '<s>user: hiassistant: ');
      expect(result.tokenCount, isNull);
      expect(backend.tokenizeCalls, 0);
    });

    test('create reuses cached metadata across requests', () async {
      await engine.loadModel('qwen-test.gguf');

      await engine.create(const [
        LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'first'),
      ]).drain();
      expect(backend.modelMetadataCalls, 1);

      await engine.create(const [
        LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'second'),
      ]).drain();
      expect(backend.modelMetadataCalls, 1);
    });

    test('create disables tool-call parsing when toolChoice is none', () async {
      backend.generationText =
          '{"tool_call":{"name":"get_weather","arguments":{"city":"Seoul"}}}';
      await engine.loadModel('qwen-test.gguf');

      final chunks = await engine
          .create(
            const [
              LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'hi'),
            ],
            tools: [
              ToolDefinition(
                name: 'get_weather',
                description: 'Get weather',
                parameters: [ToolParam.string('city')],
                handler: (_) async => 'ok',
              ),
            ],
            toolChoice: ToolChoice.none,
          )
          .toList();

      expect(chunks.last.choices.first.finishReason, equals('stop'));
      final hasToolCallChunk = chunks.any(
        (chunk) =>
            chunk.choices.first.delta.toolCalls != null &&
            chunk.choices.first.delta.toolCalls!.isNotEmpty,
      );
      expect(hasToolCallChunk, isFalse);
    });

    test('create assigns missing tool call ids like llama.cpp', () async {
      backend.generationText =
          '{"tool_call":{"name":"get_weather","arguments":{"city":"Seoul"}}}';
      await engine.loadModel('qwen-test.gguf');

      final chunks = await engine
          .create(
            const [
              LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'hi'),
            ],
            tools: [
              ToolDefinition(
                name: 'get_weather',
                description: 'Get weather',
                parameters: [ToolParam.string('city')],
                handler: (_) async => 'ok',
              ),
            ],
            toolChoice: ToolChoice.auto,
          )
          .toList();

      final toolChunk = chunks.last;
      expect(toolChunk.choices.first.finishReason, equals('tool_calls'));
      final toolCalls = toolChunk.choices.first.delta.toolCalls;
      expect(toolCalls, isNotNull);
      expect(toolCalls, hasLength(1));
      expect(toolCalls!.first.id, equals('call_0'));
      expect(toolCalls.first.function?.name, equals('get_weather'));
    });

    test('create does not stream raw tool-call JSON as content', () async {
      backend.generationText =
          '{"tool_call":{"name":"get_weather","arguments":{"city":"Seoul"}}}';
      await engine.loadModel('qwen-test.gguf');

      final chunks = await engine
          .create(
            const [
              LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'hi'),
            ],
            tools: [
              ToolDefinition(
                name: 'get_weather',
                description: 'Get weather',
                parameters: [ToolParam.string('city')],
                handler: (_) async => 'ok',
              ),
            ],
            toolChoice: ToolChoice.auto,
          )
          .toList();

      final streamedContent = chunks
          .map((chunk) => chunk.choices.first.delta.content)
          .whereType<String>()
          .join();

      expect(streamedContent, isNot(contains('"tool_call"')));
      expect(chunks.last.choices.first.finishReason, equals('tool_calls'));
    });

    test('create still streams plain content when tools are enabled', () async {
      backend.generationText = 'hello world';
      await engine.loadModel('qwen-test.gguf');

      final chunks = await engine
          .create(
            const [
              LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'hi'),
            ],
            tools: [
              ToolDefinition(
                name: 'get_weather',
                description: 'Get weather',
                parameters: [ToolParam.string('city')],
                handler: (_) async => 'ok',
              ),
            ],
            toolChoice: ToolChoice.auto,
          )
          .toList();

      final streamedContent = chunks
          .map((chunk) => chunk.choices.first.delta.content)
          .whereType<String>()
          .join();

      expect(streamedContent, contains('hello world'));
      expect(chunks.last.choices.first.finishReason, equals('stop'));
    });

    test(
      'create preserves raw whitespace for plain tool-enabled content',
      () async {
        backend.generationChunks = const ['  hello', '  ', '\n'];
        await engine.loadModel('qwen-test.gguf');

        final chunks = await engine
            .create(
              const [
                LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'hi'),
              ],
              tools: [
                ToolDefinition(
                  name: 'get_weather',
                  description: 'Get weather',
                  parameters: [ToolParam.string('city')],
                  handler: (_) async => 'ok',
                ),
              ],
              toolChoice: ToolChoice.auto,
            )
            .toList();

        final streamedContent = chunks
            .map((chunk) => chunk.choices.first.delta.content)
            .whereType<String>()
            .join();

        expect(streamedContent, equals('  hello  \n'));
        expect(chunks.last.choices.first.finishReason, equals('stop'));
      },
    );

    test(
      'create preserves whitespace-only output with tools enabled',
      () async {
        backend.generationChunks = const [' ', '  ', '\n'];
        await engine.loadModel('qwen-test.gguf');

        final chunks = await engine
            .create(
              const [
                LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'hi'),
              ],
              tools: [
                ToolDefinition(
                  name: 'get_weather',
                  description: 'Get weather',
                  parameters: [ToolParam.string('city')],
                  handler: (_) async => 'ok',
                ),
              ],
              toolChoice: ToolChoice.auto,
            )
            .toList();

        final streamedContent = chunks
            .map((chunk) => chunk.choices.first.delta.content)
            .whereType<String>()
            .join();

        expect(streamedContent, equals('   \n'));
        expect(chunks.last.choices.first.finishReason, equals('stop'));
      },
    );

    test('create streams decoded escaped generic response content', () async {
      backend.generationChunks = const [
        r'{"response":"line1\n',
        r'line2\"quoted',
        r'\""}',
      ];
      await engine.loadModel('qwen-test.gguf');

      final chunks = await engine
          .create(
            const [
              LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'hi'),
            ],
            tools: [
              ToolDefinition(
                name: 'get_weather',
                description: 'Get weather',
                parameters: [ToolParam.string('city')],
                handler: (_) async => 'ok',
              ),
            ],
            toolChoice: ToolChoice.auto,
          )
          .toList();

      final streamedContent = chunks
          .map((chunk) => chunk.choices.first.delta.content)
          .whereType<String>()
          .join();

      expect(streamedContent, equals('line1\nline2"quoted"'));
      expect(chunks.last.choices.first.finishReason, equals('stop'));
    });

    test(
      'create does not append corrupted final delta when partial and final prefixes differ',
      () async {
        backend.generationChunks = const [r'{"response":"foo"} bar'];
        await engine.loadModel('qwen-test.gguf');

        final chunks = await engine
            .create(
              const [
                LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'hi'),
              ],
              tools: [
                ToolDefinition(
                  name: 'get_weather',
                  description: 'Get weather',
                  parameters: [ToolParam.string('city')],
                  handler: (_) async => 'ok',
                ),
              ],
              toolChoice: ToolChoice.auto,
            )
            .toList();

        final streamedContent = chunks
            .map((chunk) => chunk.choices.first.delta.content)
            .whereType<String>()
            .join();

        expect(streamedContent, equals('foo'));
        expect(streamedContent, isNot(contains('fooesponse')));
        expect(chunks.last.choices.first.finishReason, equals('stop'));
      },
    );

    test('create streams raw json text when tools are enabled', () async {
      backend.generationChunks = const ['  {"note"', ': 1', '}\n'];
      await engine.loadModel('qwen-test.gguf');

      final chunks = await engine
          .create(
            const [
              LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'hi'),
            ],
            tools: [
              ToolDefinition(
                name: 'get_weather',
                description: 'Get weather',
                parameters: [ToolParam.string('city')],
                handler: (_) async => 'ok',
              ),
            ],
            toolChoice: ToolChoice.auto,
          )
          .toList();

      final contentChunks = chunks
          .where((chunk) => chunk.choices.first.delta.content != null)
          .toList();
      final streamedContent = contentChunks
          .map((chunk) => chunk.choices.first.delta.content!)
          .join();

      expect(streamedContent, equals('  {"note": 1}\n'));
      expect(contentChunks.length, greaterThan(1));
      expect(chunks.last.choices.first.finishReason, equals('stop'));
    });

    test('create streams raw xml text when tools are enabled', () async {
      backend.generationChunks = const ['  <div', '>hello', '</div>\n'];
      await engine.loadModel('qwen-test.gguf');

      final chunks = await engine
          .create(
            const [
              LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'hi'),
            ],
            tools: [
              ToolDefinition(
                name: 'get_weather',
                description: 'Get weather',
                parameters: [ToolParam.string('city')],
                handler: (_) async => 'ok',
              ),
            ],
            toolChoice: ToolChoice.auto,
          )
          .toList();

      final contentChunks = chunks
          .where((chunk) => chunk.choices.first.delta.content != null)
          .toList();
      final streamedContent = contentChunks
          .map((chunk) => chunk.choices.first.delta.content!)
          .join();

      expect(streamedContent, equals('  <div>hello</div>\n'));
      expect(contentChunks.length, greaterThan(1));
      expect(chunks.last.choices.first.finishReason, equals('stop'));
    });

    test(
      'create keeps thinking deltas separate in raw tool-enabled mode',
      () async {
        backend.generationChunks = const ['<think>reason', '</think> answer'];
        await engine.loadModel('qwen-test.gguf');

        final chunks = await engine
            .create(
              const [
                LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'hi'),
              ],
              tools: [
                ToolDefinition(
                  name: 'get_weather',
                  description: 'Get weather',
                  parameters: [ToolParam.string('city')],
                  handler: (_) async => 'ok',
                ),
              ],
              toolChoice: ToolChoice.auto,
            )
            .toList();

        final streamedContent = chunks
            .map((chunk) => chunk.choices.first.delta.content)
            .whereType<String>()
            .join();
        final streamedThinking = chunks
            .map((chunk) => chunk.choices.first.delta.thinking)
            .whereType<String>()
            .join();

        expect(streamedThinking, equals('reason'));
        expect(streamedContent, equals(' answer'));
        expect(streamedContent, isNot(contains('reason')));
        expect(chunks.last.choices.first.finishReason, equals('stop'));
      },
    );

    test('create streams Gemma 4 thought blocks as thinking deltas', () async {
      final gemmaBackend = MockLlamaBackend(
        modelMetadataResponse: const {
          'llm.context_length': '4096',
          'tokenizer.chat_template':
              '<|turn>user\n{{ messages[0]["content"] }}<turn|>{% if add_generation_prompt %}<|turn>model\n{% endif %}',
        },
      );
      final gemmaEngine = LlamaEngine(gemmaBackend);
      gemmaBackend.generationChunks = const [
        '<|chan',
        'nel>thought\npl',
        'an first<chan',
        'nel|>Final answer.',
      ];

      await gemmaEngine.loadModel('gemma4-test.gguf');

      final chunks = await gemmaEngine.create(const [
        LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'hi'),
      ]).toList();

      final streamedContent = chunks
          .map((chunk) => chunk.choices.first.delta.content)
          .whereType<String>()
          .join();
      final streamedThinking = chunks
          .map((chunk) => chunk.choices.first.delta.thinking)
          .whereType<String>()
          .join();

      expect(streamedThinking, equals('plan first'));
      expect(streamedContent, equals('Final answer.'));
      expect(streamedContent, isNot(contains('thought')));
      expect(chunks.last.choices.first.finishReason, equals('stop'));
    });

    test('create handles many plain chunks when tools are enabled', () async {
      backend.generationChunks = List<String>.filled(80, 'a');
      await engine.loadModel('qwen-test.gguf');

      final chunks = await engine
          .create(
            const [
              LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'hi'),
            ],
            tools: [
              ToolDefinition(
                name: 'get_weather',
                description: 'Get weather',
                parameters: [ToolParam.string('city')],
                handler: (_) async => 'ok',
              ),
            ],
            toolChoice: ToolChoice.auto,
          )
          .toList();

      final streamedContent = chunks
          .map((chunk) => chunk.choices.first.delta.content)
          .whereType<String>()
          .join();

      expect(streamedContent, equals('a' * 80));
      expect(chunks.last.choices.first.finishReason, equals('stop'));
    });

    test(
      'create streams short plain chunks incrementally with tools',
      () async {
        backend.generationChunks = const ['h', 'e', 'l', 'l', 'o'];
        await engine.loadModel('qwen-test.gguf');

        final chunks = await engine
            .create(
              const [
                LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'hi'),
              ],
              tools: [
                ToolDefinition(
                  name: 'get_weather',
                  description: 'Get weather',
                  parameters: [ToolParam.string('city')],
                  handler: (_) async => 'ok',
                ),
              ],
              toolChoice: ToolChoice.auto,
            )
            .toList();

        final contentChunks = chunks
            .where((chunk) => chunk.choices.first.delta.content != null)
            .toList();
        final streamedContent = contentChunks
            .map((chunk) => chunk.choices.first.delta.content!)
            .join();

        expect(streamedContent, equals('hello'));
        expect(contentChunks.length, greaterThan(1));
        expect(chunks.last.choices.first.finishReason, equals('stop'));
      },
    );

    test('metadata and context size', () async {
      await engine.loadModel('qwen-test.gguf');
      final meta = await engine.getMetadata();
      expect(meta['llm.context_length'], '4096');
      expect(
        await engine.getContextSize(),
        2048,
      ); // From backend.getContextSize
    });

    test('available backend names', () async {
      expect(await engine.getAvailableBackends(), 'Mock');
    });

    test('resolved gpu layers', () async {
      backend.resolvedGpuLayers = 24;
      expect(await engine.getResolvedGpuLayers(), 24);
    });

    test('LoRA management', () async {
      await engine.loadModel('qwen-test.gguf');
      await engine.setLora('adapter.bin', scale: 0.5);
      expect(backend.lastLoraPath, 'adapter.bin');
      expect(backend.lastLoraScale, 0.5);

      await engine.removeLora('adapter.bin');
      expect(backend.lastLoraPath, isNull);

      await engine.setLora('adapter.bin');
      await engine.clearLoras();
      expect(backend.lastLoraPath, isNull);
    });

    test('cancelGeneration', () {
      engine.cancelGeneration();
      // Should not throw
    });

    test('getTokenCount', () async {
      await engine.loadModel('qwen-test.gguf');
      expect(await engine.getTokenCount('test'), 3);
    });

    test('dispose', () async {
      await engine.loadModel('qwen-test.gguf');
      await engine.loadMultimodalProjector('proj.gguf');
      await engine.dispose();
      expect(engine.isReady, false);
    });
  });
}
