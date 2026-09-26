import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/backends/backend.dart'
    show
        BackendDeferredEngineCreation,
        BackendGenerationLimit,
        BackendGenerationLimitReporting,
        BackendGenerationUsageReporting,
        BackendVideoRuntimeSupport;
import 'package:llamadart/src/core/engine/engine.dart'
    show completionGenerationLimit;

class MockLlamaBackend
    implements
        LlamaBackend,
        BackendAvailability,
        BackendRuntimeDiagnostics,
        BackendVideoRuntimeSupport {
  MockLlamaBackend({
    this.backendName = 'Mock',
    this.urlLoadingSupported = false,
    this.failModelLoad = false,
    this.failModelLoadFromUrl = false,
    this.unsupportedModelLoad = false,
    this.unsupportedModelLoadFromUrl = false,
    this.failContextCreate = false,
    this.failContextFree = false,
    this.modelMetadataResponse,
    this.modelLoadDelay,
    this.modelLoadFromUrlDelay,
    this.contextFreeDelay,
    this.nativeVideoRuntimeSupported = false,
    this.videoProbeError,
  });

  bool _isReady = false;
  String? lastModelPath;
  String? lastLoraPath;
  String? lastModelUrl;
  String? lastMultimodalProjectorPath;
  double? lastLoraScale;
  int resolvedGpuLayers = 0;
  int modelLoadCalls = 0;
  int modelLoadFromUrlCalls = 0;
  int modelFreeCalls = 0;
  int contextFreeCalls = 0;
  int cancelGenerationCalls = 0;
  int disposeCalls = 0;
  int multimodalContextCreateCalls = 0;
  final List<String> multimodalProjectorPaths = <String>[];
  int tokenizeCalls = 0;
  int modelMetadataCalls = 0;
  String generationText = 'response';
  List<String>? generationChunks;
  String? lastGenerationPrompt;
  GenerationParams? lastGenerationParams;
  final String backendName;
  final bool urlLoadingSupported;
  final bool failModelLoad;
  final bool failModelLoadFromUrl;
  final bool unsupportedModelLoad;
  final bool unsupportedModelLoadFromUrl;
  final bool failContextCreate;
  final bool failContextFree;
  final Map<String, String>? modelMetadataResponse;
  Future<void>? modelLoadDelay;
  Future<void>? modelLoadFromUrlDelay;
  Future<void>? contextFreeDelay;
  final bool? nativeVideoRuntimeSupported;
  final Object? videoProbeError;
  int? lastVideoProbeHandle;

  @override
  bool get isReady => _isReady;

  @override
  Future<int> modelLoad(String path, ModelParams params) async {
    modelLoadCalls += 1;
    lastModelPath = path;
    if (unsupportedModelLoad) {
      throw UnsupportedError('model loading unsupported');
    }
    if (failModelLoad) {
      throw Exception('model load failed');
    }
    await modelLoadDelay;
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
    if (unsupportedModelLoadFromUrl) {
      throw UnsupportedError('URL runtime unsupported');
    }
    if (failModelLoadFromUrl) {
      throw Exception('url model load failed: $url');
    }
    await modelLoadFromUrlDelay;
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
    if (failContextFree) {
      throw Exception('context free failed');
    }
    await contextFreeDelay;
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
    lastGenerationPrompt = prompt;
    lastGenerationParams = params;
    if (generationChunks != null) {
      for (final chunk in generationChunks!) {
        yield utf8.encode(chunk);
      }
      return;
    }
    yield utf8.encode(generationText);
  }

  @override
  void cancelGeneration() {
    cancelGenerationCalls += 1;
  }

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
    disposeCalls += 1;
    _isReady = false;
  }

  @override
  Future<int?> multimodalContextCreate(
    int modelHandle,
    String mmProjPath,
  ) async {
    multimodalContextCreateCalls += 1;
    lastMultimodalProjectorPath = mmProjPath;
    multimodalProjectorPaths.add(mmProjPath);
    return 2;
  }

  @override
  Future<void> multimodalContextFree(int mmContextHandle) async {}

  @override
  Future<bool> supportsVision(int mmContextHandle) async => true;

  @override
  Future<bool> supportsAudio(int mmContextHandle) async => false;

  @override
  Future<bool?> supportsVideoRuntime(int mmContextHandle) async {
    lastVideoProbeHandle = mmContextHandle;
    if (videoProbeError case final error?) {
      throw error;
    }
    return nativeVideoRuntimeSupported;
  }

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

class DeferredEngineMockBackend extends MockLlamaBackend
    implements BackendDeferredEngineCreation {
  DeferredEngineMockBackend({this.defersEngineCreation = true});

  @override
  final bool defersEngineCreation;
}

class UnsupportedTokenizationBackend extends MockLlamaBackend {
  @override
  Future<List<int>> tokenize(
    int modelHandle,
    String text, {
    bool addSpecial = true,
  }) async {
    tokenizeCalls += 1;
    throw UnsupportedError('tokenization unavailable');
  }
}

class ScoringMockBackend extends MockLlamaBackend
    implements BackendNextTokenScoring, BackendNextTokenScoringSupport {
  ScoringMockBackend({this.supported = true, this.error});

  final bool supported;
  final Object? error;
  final List<(int, String, List<int>, int, bool)> scoreCalls = [];

  @override
  bool get supportsNextTokenScoring => supported;

  @override
  Future<LlamaNextTokenScores> scoreNextToken(
    int contextHandle,
    String prompt, {
    required List<int> candidates,
    required int topK,
    required bool reusePromptPrefix,
  }) async {
    scoreCalls.add((
      contextHandle,
      prompt,
      candidates,
      topK,
      reusePromptPrefix,
    ));
    if (error != null) throw error!;
    return LlamaNextTokenScores(
      candidates: [
        for (final token in candidates)
          LlamaTokenLogprob(token: token, bytes: const [65], logprob: -1),
      ],
      top: const [],
      promptTokens: 3,
    );
  }
}

class UnsupportedStateBackend extends MockLlamaBackend
    implements BackendStatePersistenceSupport {
  UnsupportedStateBackend({required super.backendName});

  @override
  bool get supportsStatePersistence => false;
}

class NoGrammarMockLlamaBackend extends MockLlamaBackend
    implements BackendGrammarConstraintsSupport {
  NoGrammarMockLlamaBackend({super.modelMetadataResponse});

  @override
  bool get supportsGrammarConstraints => false;
}

class NativeChatMockBackend extends MockLlamaBackend
    implements BackendNativeChatGeneration, BackendGrammarConstraintsSupport {
  NativeChatMockBackend()
    : super(
        modelMetadataResponse: const {
          'llm.context_length': '4096',
          'tokenizer.chat_template':
              '{{ bos_token }}{% for message in messages %}'
              '{% if message["role"] == "user" %}'
              '{{ "user: " }}'
              '{% if message["content"] is string %}'
              '{{ message["content"] }}'
              '{% elif message["content"] is sequence and message["content"] is not string %}'
              '{% for part in message["content"] %}'
              '{% if part["type"] == "text" %}{{ part["text"] }}'
              '{% elif part["type"] == "image" %}{{ "<image>" }}'
              '{% elif part["type"] == "audio" %}{{ "<audio>" }}'
              '{% endif %}{% endfor %}{% endif %}'
              '{% elif message["role"] == "assistant" %}'
              '{{ "assistant: " }}'
              '{% if message["content"] is string %}'
              '{{ message["content"] }}'
              '{% endif %}'
              '{% endif %}{% endfor %}'
              '{% if add_generation_prompt %}{{ "assistant: " }}{% endif %}',
        },
      );

  int nativeGenerateChatCalls = 0;
  List<LlamaChatMessage>? lastNativeMessages;
  GenerationParams? lastNativeParams;
  List<ToolDefinition>? lastNativeTools;
  ToolChoice? lastNativeToolChoice;
  bool? lastNativeParallelToolCalls;
  bool? lastNativeEnableThinking;
  Map<String, dynamic>? lastNativeChatTemplateKwargs;

  @override
  bool get supportsGrammarConstraints => false;

  @override
  bool get supportsNativeChatGeneration => true;

  @override
  Stream<List<int>> generateChat(
    int contextHandle,
    List<LlamaChatMessage> messages,
    GenerationParams params, {
    List<ToolDefinition>? tools,
    ToolChoice toolChoice = ToolChoice.auto,
    bool parallelToolCalls = false,
    bool enableThinking = true,
    Map<String, dynamic>? chatTemplateKwargs,
    String? sourceLangCode,
    String? targetLangCode,
    DateTime? templateNow,
  }) async* {
    nativeGenerateChatCalls += 1;
    lastNativeMessages = List<LlamaChatMessage>.from(messages);
    lastNativeParams = params;
    lastNativeTools = tools == null ? null : List<ToolDefinition>.from(tools);
    lastNativeToolChoice = toolChoice;
    lastNativeParallelToolCalls = parallelToolCalls;
    lastNativeEnableThinking = enableThinking;
    lastNativeChatTemplateKwargs = chatTemplateKwargs == null
        ? null
        : Map<String, dynamic>.from(chatTemplateKwargs);
    yield utf8.encode(generationText);
  }
}

class LimitReportingMockBackend extends NativeChatMockBackend
    implements
        BackendGenerationLimitReporting,
        BackendGenerationUsageReporting {
  BackendGenerationLimit? nextLimit;
  LlamaGenerationUsage? nextUsage;
  bool nativeChat = false;
  final Expando<BackendGenerationLimit> _limits =
      Expando<BackendGenerationLimit>();
  final Expando<LlamaGenerationUsage> _usages = Expando<LlamaGenerationUsage>();

  @override
  bool get supportsNativeChatGeneration => nativeChat;

  @override
  Stream<List<int>> generate(
    int contextHandle,
    String prompt,
    GenerationParams params, {
    List<LlamaContentPart>? parts,
  }) => _track(super.generate(contextHandle, prompt, params, parts: parts));

  @override
  Stream<List<int>> generateChat(
    int contextHandle,
    List<LlamaChatMessage> messages,
    GenerationParams params, {
    List<ToolDefinition>? tools,
    ToolChoice toolChoice = ToolChoice.auto,
    bool parallelToolCalls = false,
    bool enableThinking = true,
    Map<String, dynamic>? chatTemplateKwargs,
    String? sourceLangCode,
    String? targetLangCode,
    DateTime? templateNow,
  }) => _track(
    super.generateChat(
      contextHandle,
      messages,
      params,
      tools: tools,
      toolChoice: toolChoice,
      parallelToolCalls: parallelToolCalls,
      enableThinking: enableThinking,
      chatTemplateKwargs: chatTemplateKwargs,
      sourceLangCode: sourceLangCode,
      targetLangCode: targetLangCode,
      templateNow: templateNow,
    ),
  );

  Stream<List<int>> _track(Stream<List<int>> source) {
    late final Stream<List<int>> tracked;
    final limit = nextLimit;
    final usage = nextUsage;
    tracked = source.transform(
      StreamTransformer<List<int>, List<int>>.fromHandlers(
        handleDone: (sink) {
          if (limit != null) {
            _limits[tracked] = limit;
          }
          if (usage != null) {
            _usages[tracked] = usage;
          }
          sink.close();
        },
      ),
    );
    return tracked;
  }

  @override
  BackendGenerationLimit? generationLimitOf(Stream<List<int>> generation) =>
      _limits[generation];

  @override
  LlamaGenerationUsage? generationUsageOf(Stream<List<int>> generation) =>
      _usages[generation];
}

/// Models the llama.cpp backend: a cancel reaches only a generation whose
/// cancel token [generate] has already created.
class TokenCancelBackend extends MockLlamaBackend {
  int generateCalls = 0;
  void Function()? _cancelActive;

  @override
  Stream<List<int>> generate(
    int contextHandle,
    String prompt,
    GenerationParams params, {
    List<LlamaContentPart>? parts,
  }) {
    generateCalls += 1;
    var cancelled = false;
    _cancelActive = () => cancelled = true;
    Stream<List<int>> chunks() async* {
      try {
        for (final chunk in const <String>['one ', 'two ', 'three']) {
          await Future<void>.delayed(Duration.zero);
          if (cancelled) return;
          yield utf8.encode(chunk);
        }
      } finally {
        _cancelActive = null;
      }
    }

    return chunks();
  }

  @override
  void cancelGeneration() {
    super.cancelGeneration();
    _cancelActive?.call();
  }
}

/// Holds every generation open with no output, as during prompt evaluation,
/// and counts the backend subscriptions that are listened to and cancelled.
class PromptEvaluationBackend extends NativeChatMockBackend {
  PromptEvaluationBackend({required this.nativeChat});

  final bool nativeChat;
  int generateCalls = 0;
  int listens = 0;
  int cancels = 0;

  @override
  bool get supportsNativeChatGeneration => nativeChat;

  Stream<List<int>> _held() {
    generateCalls += 1;
    return StreamController<List<int>>(
      onListen: () => listens += 1,
      onCancel: () => cancels += 1,
    ).stream;
  }

  @override
  Stream<List<int>> generate(
    int contextHandle,
    String prompt,
    GenerationParams params, {
    List<LlamaContentPart>? parts,
  }) => _held();

  @override
  Stream<List<int>> generateChat(
    int contextHandle,
    List<LlamaChatMessage> messages,
    GenerationParams params, {
    List<ToolDefinition>? tools,
    ToolChoice toolChoice = ToolChoice.auto,
    bool parallelToolCalls = false,
    bool enableThinking = true,
    Map<String, dynamic>? chatTemplateKwargs,
    String? sourceLangCode,
    String? targetLangCode,
    DateTime? templateNow,
  }) => _held();
}

/// Emits [output] when a generation is listened to, then holds it open, as a
/// model still running, until the subscription is cancelled.
class HeldOutputBackend extends MockLlamaBackend
    implements BackendNativeChatGeneration, BackendGrammarConstraintsSupport {
  HeldOutputBackend({
    this.output = const <String>[],
    this.nativeChat = false,
    this.cancelError,
    super.modelMetadataResponse,
  });

  final List<String> output;
  final bool nativeChat;
  final Object? cancelError;
  int generateCalls = 0;
  int listens = 0;

  @override
  bool get supportsNativeChatGeneration => nativeChat;

  @override
  bool get supportsGrammarConstraints => true;

  Stream<List<int>> _held() {
    generateCalls += 1;
    late final StreamController<List<int>> controller;
    controller = StreamController<List<int>>(
      onListen: () {
        listens += 1;
        for (final text in output) {
          controller.add(utf8.encode(text));
        }
      },
      onCancel: () {
        final error = cancelError;
        if (error != null) throw error;
      },
    );
    return controller.stream;
  }

  @override
  Stream<List<int>> generate(
    int contextHandle,
    String prompt,
    GenerationParams params, {
    List<LlamaContentPart>? parts,
  }) => _held();

  @override
  Stream<List<int>> generateChat(
    int contextHandle,
    List<LlamaChatMessage> messages,
    GenerationParams params, {
    List<ToolDefinition>? tools,
    ToolChoice toolChoice = ToolChoice.auto,
    bool parallelToolCalls = false,
    bool enableThinking = true,
    Map<String, dynamic>? chatTemplateKwargs,
    String? sourceLangCode,
    String? targetLangCode,
    DateTime? templateNow,
  }) => _held();
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
  MockModelDownloadManager(ModelCacheEntry entry)
    : entriesByCacheKey = <String, ModelCacheEntry>{entry.cacheKey: entry};

  MockModelDownloadManager.forEntries(Iterable<ModelCacheEntry> entries)
    : entriesByCacheKey = <String, ModelCacheEntry>{
        for (final entry in entries) entry.cacheKey: entry,
      };

  final Map<String, ModelCacheEntry> entriesByCacheKey;
  ModelSource? lastSource;
  ModelLoadOptions? lastOptions;
  final List<ModelSource> sources = <ModelSource>[];
  final List<ModelLoadOptions> options = <ModelLoadOptions>[];
  int ensureModelCalls = 0;

  ModelCacheEntry get entry => entriesByCacheKey.values.first;

  @override
  Future<ModelCacheEntry> ensureModel(
    ModelSource source, {
    ModelLoadOptions options = ModelLoadOptions.defaults,
    ModelDownloadProgressCallback? onProgress,
  }) async {
    ensureModelCalls += 1;
    lastSource = source;
    lastOptions = options;
    sources.add(source);
    this.options.add(options);
    onProgress?.call(
      const ModelDownloadProgress(receivedBytes: 1, totalBytes: 2),
    );
    return entriesByCacheKey[source.cacheKey] ?? entry;
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

class ControlledModelDownloadManager extends MockModelDownloadManager {
  ControlledModelDownloadManager({
    required Iterable<ModelCacheEntry> entries,
    this.gatesByCacheKey = const <String, Completer<void>>{},
    this.startedByCacheKey = const <String, Completer<void>>{},
  }) : super.forEntries(entries);

  final Map<String, Completer<void>> gatesByCacheKey;
  final Map<String, Completer<void>> startedByCacheKey;

  @override
  Future<ModelCacheEntry> ensureModel(
    ModelSource source, {
    ModelLoadOptions options = ModelLoadOptions.defaults,
    ModelDownloadProgressCallback? onProgress,
  }) async {
    ensureModelCalls += 1;
    lastSource = source;
    lastOptions = options;
    sources.add(source);
    this.options.add(options);
    final started = startedByCacheKey[source.cacheKey];
    if (started != null && !started.isCompleted) {
      started.complete();
    }
    final gate = gatesByCacheKey[source.cacheKey];
    if (gate != null) {
      await gate.future;
    }
    onProgress?.call(
      const ModelDownloadProgress(receivedBytes: 1, totalBytes: 2),
    );
    return entriesByCacheKey[source.cacheKey] ?? entry;
  }
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

class DartLogLevelMockBackend extends MockLlamaBackend
    implements BackendDartLogLevel {
  final List<LlamaLogLevel> dartLogLevels = <LlamaLogLevel>[];

  @override
  Future<void> setDartLogLevel(LlamaLogLevel level) async {
    dartLogLevels.add(level);
  }
}

void main() {
  late MockLlamaBackend backend;
  late LlamaEngine engine;

  setUp(() {
    backend = MockLlamaBackend();
    engine = LlamaEngine(backend);
  });

  group('LlamaEngine Dart log level', () {
    tearDown(() => LlamaLogger.instance.setLevel(LlamaLogLevel.none));

    test(
      'setDartLogLevel and setLogLevel reach a BackendDartLogLevel',
      () async {
        final logBackend = DartLogLevelMockBackend();
        final logEngine = LlamaEngine(logBackend);
        await logEngine.setDartLogLevel(LlamaLogLevel.info);
        await logEngine.setLogLevel(LlamaLogLevel.warn);
        expect(logBackend.dartLogLevels, [
          LlamaLogLevel.info,
          LlamaLogLevel.warn,
        ]);
        expect(LlamaLogger.instance.level, LlamaLogLevel.warn);
        expect(logEngine.dartLogLevel, LlamaLogLevel.warn);
      },
    );

    test('setDartLogLevel skips a backend without the capability', () async {
      await engine.setDartLogLevel(LlamaLogLevel.info);
      expect(LlamaLogger.instance.level, LlamaLogLevel.info);
      expect(engine.dartLogLevel, LlamaLogLevel.info);
    });
  });

  group('LlamaEngine Mock Tests', () {
    test('loadModel successful', () async {
      await engine.loadModel('qwen-test.gguf');
      expect(engine.isReady, true);
    });

    test('loadModel log states whether engine creation is deferred', () async {
      final records = <LlamaLogRecord>[];
      LlamaEngine.configureLogging(
        level: LlamaLogLevel.info,
        handler: records.add,
      );
      addTearDown(LlamaEngine.configureLogging);

      await engine.loadModel('qwen-test.gguf');
      expect(
        records.map((record) => record.message),
        contains(
          'Model qwen-test.gguf loaded successfully from qwen-test.gguf',
        ),
      );

      records.clear();
      await LlamaEngine(
        DeferredEngineMockBackend(),
      ).loadModel('model.litertlm');
      final messages = records.map((record) => record.message).toList();
      expect(
        messages,
        contains(
          'Model model.litertlm loaded from model.litertlm; native engine '
          'creation is deferred until the first generation or tokenizer call',
        ),
      );
      expect(messages, isNot(contains(contains('loaded successfully'))));

      records.clear();
      await LlamaEngine(
        DeferredEngineMockBackend(defersEngineCreation: false),
      ).loadModel('model.litertlm');
      expect(
        records.map((record) => record.message),
        contains(
          'Model model.litertlm loaded successfully from model.litertlm',
        ),
      );
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

    test('loadModel while ready preserves the active model', () async {
      await engine.loadModel('qwen-test.gguf');

      await expectLater(
        () => engine.loadModel('other.gguf'),
        throwsA(isA<LlamaStateException>()),
      );

      expect(engine.isReady, isTrue);
      expect(engine.modelHandle, isNotNull);
      expect(engine.contextHandle, isNotNull);
      expect(backend.modelLoadCalls, 1);
      expect(backend.modelFreeCalls, 0);
      expect(backend.contextFreeCalls, 0);
      expect(backend.lastModelPath, 'qwen-test.gguf');
    });

    test(
      'rejects concurrent model loads before handles are assigned',
      () async {
        final loadGate = Completer<void>();
        final slowBackend = MockLlamaBackend(modelLoadDelay: loadGate.future);
        final slowEngine = LlamaEngine(slowBackend);

        final firstLoad = slowEngine.loadModel('qwen-test.gguf');
        await Future<void>.delayed(Duration.zero);

        await expectLater(
          () => slowEngine.loadModel('other.gguf'),
          throwsA(isA<LlamaStateException>()),
        );

        loadGate.complete();
        await firstLoad;

        expect(slowBackend.modelLoadCalls, 1);
        expect(slowBackend.modelFreeCalls, 0);
        expect(slowBackend.contextFreeCalls, 0);
        expect(slowEngine.isReady, isTrue);
        expect(slowBackend.lastModelPath, 'qwen-test.gguf');
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
      'rejects concurrent URL model loads before handles are assigned',
      () async {
        final loadGate = Completer<void>();
        final webBackend = MockLlamaBackend(
          urlLoadingSupported: true,
          modelLoadFromUrlDelay: loadGate.future,
        );
        final webEngine = LlamaEngine(webBackend);

        final firstLoad = webEngine.loadModelFromUrl(
          'https://example.com/model.gguf',
        );
        await Future<void>.delayed(Duration.zero);

        await expectLater(
          () => webEngine.loadModelFromUrl('https://example.com/other.gguf'),
          throwsA(isA<LlamaStateException>()),
        );

        loadGate.complete();
        await firstLoad;

        expect(webBackend.modelLoadFromUrlCalls, 1);
        expect(webBackend.modelFreeCalls, 0);
        expect(webBackend.contextFreeCalls, 0);
        expect(webEngine.isReady, isTrue);
        expect(webBackend.lastModelUrl, 'https://example.com/model.gguf');
      },
    );

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
      'native loadModelSource skips model load when download is cancelled',
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
        );
        final downloadGate = Completer<void>();
        final downloadStarted = Completer<void>();
        final downloadManager = ControlledModelDownloadManager(
          entries: [entry],
          gatesByCacheKey: {source.cacheKey: downloadGate},
          startedByCacheKey: {source.cacheKey: downloadStarted},
        );
        final nativeBackend = MockLlamaBackend();
        final nativeEngine = LlamaEngine(
          nativeBackend,
          modelDownloadManager: downloadManager,
        );
        final cancelToken = ModelDownloadCancelToken();

        final load = nativeEngine.loadModelSource(
          source,
          options: ModelLoadOptions(cancelToken: cancelToken),
        );
        await downloadStarted.future;

        cancelToken.cancel();
        downloadGate.complete();

        await expectLater(load, throwsA(isA<LlamaStateException>()));
        expect(nativeBackend.modelLoadCalls, 0);
        expect(nativeEngine.isReady, isFalse);
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
      'native loadMultimodalProjectorSource supports local and remote model/projector combinations',
      () async {
        ModelCacheEntry entryFor(ModelSource source, String filePath) {
          return ModelCacheEntry(
            sourceCanonicalKey: source.metadataSourceKey,
            cacheKey: source.cacheKey,
            fileName: source.fileName,
            filePath: filePath,
            createdAt: DateTime.utc(2026),
            updatedAt: DateTime.utc(2026),
          );
        }

        final cases =
            <
              ({
                String label,
                ModelSource modelSource,
                String modelPath,
                ModelSource projectorSource,
                String projectorPath,
              })
            >[
              (
                label: 'local model + local projector',
                modelSource: ModelSource.path('/models/local-model.gguf'),
                modelPath: '/models/local-model.gguf',
                projectorSource: ModelSource.path('/models/local-mmproj.gguf'),
                projectorPath: '/models/local-mmproj.gguf',
              ),
              (
                label: 'local model + remote projector',
                modelSource: ModelSource.path('/models/local-model.gguf'),
                modelPath: '/models/local-model.gguf',
                projectorSource: ModelSource.url(
                  Uri.parse('https://example.com/remote-mmproj.gguf'),
                ),
                projectorPath: '/cache/remote-mmproj.gguf',
              ),
              (
                label: 'remote model + local projector',
                modelSource: ModelSource.url(
                  Uri.parse('https://example.com/remote-model.gguf'),
                ),
                modelPath: '/cache/remote-model.gguf',
                projectorSource: ModelSource.path('/models/local-mmproj.gguf'),
                projectorPath: '/models/local-mmproj.gguf',
              ),
              (
                label: 'remote model + remote projector',
                modelSource: ModelSource.url(
                  Uri.parse('https://example.com/remote-model.gguf'),
                ),
                modelPath: '/cache/remote-model.gguf',
                projectorSource: ModelSource.url(
                  Uri.parse('https://example.com/remote-mmproj.gguf'),
                ),
                projectorPath: '/cache/remote-mmproj.gguf',
              ),
            ];

        for (final testCase in cases) {
          final nativeBackend = MockLlamaBackend();
          final downloadManager = MockModelDownloadManager.forEntries([
            entryFor(testCase.modelSource, testCase.modelPath),
            entryFor(testCase.projectorSource, testCase.projectorPath),
          ]);
          final nativeEngine = LlamaEngine(
            nativeBackend,
            modelDownloadManager: downloadManager,
          );

          await nativeEngine.loadModelSource(testCase.modelSource);
          await nativeEngine.loadMultimodalProjectorSource(
            testCase.projectorSource,
          );

          expect(
            nativeBackend.lastModelPath,
            testCase.modelPath,
            reason: testCase.label,
          );
          expect(
            nativeBackend.lastMultimodalProjectorPath,
            testCase.projectorPath,
            reason: testCase.label,
          );
          expect(downloadManager.ensureModelCalls, 2, reason: testCase.label);
          expect(downloadManager.sources.map((source) => source.cacheKey), [
            testCase.modelSource.cacheKey,
            testCase.projectorSource.cacheKey,
          ], reason: testCase.label);
        }
      },
    );

    test(
      'native loadMultimodalProjectorSource forwards options and progress',
      () async {
        final source = ModelSource.url(
          Uri.parse('https://example.com/mmproj.gguf'),
        );
        final entry = ModelCacheEntry(
          sourceCanonicalKey: source.metadataSourceKey,
          cacheKey: source.cacheKey,
          fileName: source.fileName,
          filePath: '/cache/mmproj.gguf',
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
          cachePolicy: ModelCachePolicy.refresh,
          bearerToken: 'secret-token',
        );
        final progressEvents = <ModelDownloadProgress>[];

        await nativeEngine.loadModel('model.gguf');
        await nativeEngine.loadMultimodalProjectorSource(
          source,
          options: options,
          onProgress: progressEvents.add,
        );

        expect(downloadManager.ensureModelCalls, 1);
        expect(downloadManager.lastSource?.resolvedUri, source.resolvedUri);
        expect(downloadManager.lastOptions, same(options));
        expect(nativeBackend.lastMultimodalProjectorPath, '/cache/mmproj.gguf');
        expect(progressEvents.single.fraction, 0.5);
      },
    );

    test(
      'loadMultimodalProjectorSource serializes source work before backend load',
      () async {
        ModelCacheEntry entryFor(ModelSource source, String filePath) {
          return ModelCacheEntry(
            sourceCanonicalKey: source.metadataSourceKey,
            cacheKey: source.cacheKey,
            fileName: source.fileName,
            filePath: filePath,
            createdAt: DateTime.utc(2026),
            updatedAt: DateTime.utc(2026),
          );
        }

        final firstSource = ModelSource.url(
          Uri.parse('https://example.com/first-mmproj.gguf'),
        );
        final secondSource = ModelSource.url(
          Uri.parse('https://example.com/second-mmproj.gguf'),
        );
        final firstGate = Completer<void>();
        final firstStarted = Completer<void>();
        final secondStarted = Completer<void>();
        final downloadManager = ControlledModelDownloadManager(
          entries: [
            entryFor(firstSource, '/cache/first-mmproj.gguf'),
            entryFor(secondSource, '/cache/second-mmproj.gguf'),
          ],
          gatesByCacheKey: {firstSource.cacheKey: firstGate},
          startedByCacheKey: {
            firstSource.cacheKey: firstStarted,
            secondSource.cacheKey: secondStarted,
          },
        );
        final nativeBackend = MockLlamaBackend();
        final nativeEngine = LlamaEngine(
          nativeBackend,
          modelDownloadManager: downloadManager,
        );

        await nativeEngine.loadModel('model.gguf');

        final firstLoad = nativeEngine.loadMultimodalProjectorSource(
          firstSource,
        );
        await firstStarted.future;

        final secondLoad = nativeEngine.loadMultimodalProjectorSource(
          secondSource,
        );
        await pumpEventQueue();

        expect(secondStarted.isCompleted, isFalse);
        expect(downloadManager.sources.map((source) => source.cacheKey), [
          firstSource.cacheKey,
        ]);
        expect(nativeBackend.multimodalProjectorPaths, isEmpty);

        firstGate.complete();
        await Future.wait<void>([firstLoad, secondLoad]);

        expect(secondStarted.isCompleted, isTrue);
        expect(downloadManager.sources.map((source) => source.cacheKey), [
          firstSource.cacheKey,
          secondSource.cacheKey,
        ]);
        expect(nativeBackend.multimodalProjectorPaths, [
          '/cache/first-mmproj.gguf',
          '/cache/second-mmproj.gguf',
        ]);
      },
    );

    test(
      'loadMultimodalProjectorSource loads remote URL directly on URL backends',
      () async {
        final webBackend = MockLlamaBackend(urlLoadingSupported: true);
        final webEngine = LlamaEngine(webBackend);

        await webEngine.loadModelSource(
          ModelSource.url(Uri.parse('https://example.com/model.gguf')),
        );
        await webEngine.loadMultimodalProjectorSource(
          ModelSource.url(Uri.parse('https://example.com/mmproj.gguf')),
        );

        expect(webBackend.lastModelUrl, 'https://example.com/model.gguf');
        expect(
          webBackend.lastMultimodalProjectorPath,
          'https://example.com/mmproj.gguf',
        );
        expect(webBackend.multimodalContextCreateCalls, 1);
      },
    );

    test(
      'loadMultimodalProjectorSource rejects local paths on URL backends',
      () async {
        final webBackend = MockLlamaBackend(urlLoadingSupported: true);
        final webEngine = LlamaEngine(webBackend);

        await webEngine.loadModelSource(
          ModelSource.url(Uri.parse('https://example.com/model.gguf')),
        );

        await expectLater(
          () => webEngine.loadMultimodalProjectorSource(
            ModelSource.path('/models/mmproj.gguf'),
          ),
          throwsA(isA<LlamaUnsupportedException>()),
        );
        expect(webBackend.multimodalContextCreateCalls, 0);
      },
    );

    test(
      'loadMultimodalProjectorSource rejects URL-backend cache IO options',
      () async {
        final webBackend = MockLlamaBackend(urlLoadingSupported: true);
        final webEngine = LlamaEngine(webBackend);

        await webEngine.loadModelSource(
          ModelSource.url(Uri.parse('https://example.com/model.gguf')),
        );

        Object? thrown;
        try {
          await webEngine.loadMultimodalProjectorSource(
            ModelSource.url(Uri.parse('https://example.com/mmproj.gguf')),
            options: ModelLoadOptions(bearerToken: 'secret-token'),
          );
        } catch (error) {
          thrown = error;
        }

        expect(thrown, isA<LlamaUnsupportedException>());
        expect(
          thrown.toString(),
          contains('Authenticated multimodal projector URL loading'),
        );
        expect(webBackend.multimodalContextCreateCalls, 0);

        Object? cancellationError;
        try {
          await webEngine.loadMultimodalProjectorSource(
            ModelSource.url(Uri.parse('https://example.com/mmproj.gguf')),
            options: ModelLoadOptions(cancelToken: ModelDownloadCancelToken()),
          );
        } catch (error) {
          cancellationError = error;
        }

        expect(cancellationError, isA<LlamaUnsupportedException>());
        expect(
          cancellationError.toString(),
          contains('Cancellation tokens for multimodal projector loading'),
        );
        expect(webBackend.multimodalContextCreateCalls, 0);
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

    test('loadModelFromUrl preserves unsupported load diagnostics', () async {
      final webBackend = MockLlamaBackend(
        urlLoadingSupported: true,
        unsupportedModelLoadFromUrl: true,
      );
      final webEngine = LlamaEngine(webBackend);

      await expectLater(
        () => webEngine.loadModelFromUrl('https://example.com/model.gguf'),
        throwsA(
          isA<LlamaUnsupportedException>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('Model URL loading'),
              contains('URL runtime unsupported'),
            ),
          ),
        ),
      );
      expect(webEngine.isReady, isFalse);
      expect(webEngine.modelHandle, isNull);
      expect(webEngine.contextHandle, isNull);
    });

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

    test(
      'unloadModel cancels any active generation before freeing handles',
      () async {
        await engine.loadModel('qwen-test.gguf');

        await engine.unloadModel();

        expect(backend.cancelGenerationCalls, 1);
        expect(backend.contextFreeCalls, 1);
        expect(backend.modelFreeCalls, 1);
        expect(engine.isReady, isFalse);
      },
    );

    test('unloadModel marks engine not ready before freeing handles', () async {
      final unloadGate = Completer<void>();
      final unloadingBackend = MockLlamaBackend(
        contextFreeDelay: unloadGate.future,
      );
      final unloadingEngine = LlamaEngine(unloadingBackend);

      await unloadingEngine.loadModel('qwen-test.gguf');

      final unload = unloadingEngine.unloadModel();
      await Future<void>.delayed(Duration.zero);

      expect(unloadingBackend.cancelGenerationCalls, 1);
      expect(unloadingBackend.contextFreeCalls, 1);
      expect(unloadingEngine.isReady, isFalse);
      await expectLater(
        unloadingEngine.generate('hello').drain<void>(),
        throwsA(isA<LlamaContextException>()),
      );

      unloadGate.complete();
      await unload;

      expect(unloadingBackend.modelFreeCalls, 1);
      expect(unloadingEngine.modelHandle, isNull);
      expect(unloadingEngine.contextHandle, isNull);
    });

    test(
      'dispose waits for active lifecycle before unloading backend resources',
      () async {
        final loadGate = Completer<void>();
        final slowBackend = MockLlamaBackend(modelLoadDelay: loadGate.future);
        final slowEngine = LlamaEngine(slowBackend);

        final load = slowEngine.loadModel('qwen-test.gguf');
        await Future<void>.delayed(Duration.zero);

        final dispose = slowEngine.dispose();
        await Future<void>.delayed(Duration.zero);

        expect(slowBackend.disposeCalls, 0);
        expect(slowBackend.contextFreeCalls, 0);
        expect(slowBackend.modelFreeCalls, 0);

        loadGate.complete();
        await load;
        await dispose;

        expect(slowBackend.contextFreeCalls, 1);
        expect(slowBackend.modelFreeCalls, 1);
        expect(slowBackend.disposeCalls, 1);
        expect(slowEngine.isReady, isFalse);
      },
    );

    test('dispose releases backend even when unload fails', () async {
      final failingBackend = MockLlamaBackend(failContextFree: true);
      final failingEngine = LlamaEngine(failingBackend);
      await failingEngine.loadModel('qwen-test.gguf');

      await expectLater(
        () => failingEngine.dispose(),
        throwsA(
          isA<Exception>().having(
            (error) => error.toString(),
            'message',
            contains('context free failed'),
          ),
        ),
      );

      expect(failingBackend.disposeCalls, 1);
    });

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
      expect(await engine.supportsVideo, false);
    });

    test('video input fails with compiled-runtime guidance', () async {
      await engine.loadModel('qwen-test.gguf');
      await engine.loadMultimodalProjector('proj.gguf');

      await expectLater(
        engine.create([
          LlamaChatMessage.withContent(
            role: LlamaChatRole.user,
            content: [LlamaVideoContent(path: '/tmp/clip.mp4')],
          ),
        ]).drain<void>(),
        throwsA(
          isA<LlamaUnsupportedException>()
              .having((error) => error.message, 'message', contains('FFmpeg'))
              .having(
                (error) => error.message,
                'message',
                contains('image frames'),
              ),
        ),
      );
      expect(backend.lastVideoProbeHandle, 2);
      expect(backend.lastGenerationPrompt, isNull);
    });

    test(
      'video input without projector explains inspection boundary',
      () async {
        await engine.loadModel('qwen-test.gguf');

        await expectLater(
          engine
              .generate(
                'describe',
                parts: [LlamaVideoContent(path: '/tmp/clip.mp4')],
              )
              .drain<void>(),
          throwsA(
            isA<LlamaUnsupportedException>()
                .having(
                  (error) => error.message,
                  'message',
                  contains('Without an active multimodal context'),
                )
                .having(
                  (error) => error.message,
                  'message',
                  contains('backend that does not expose one'),
                )
                .having(
                  (error) => error.message,
                  'message',
                  contains('does not enable public video ingestion'),
                ),
          ),
        );
        expect(backend.lastVideoProbeHandle, isNull);
        expect(backend.lastGenerationPrompt, isNull);
      },
    );

    test('video input remains unavailable when native probe is true', () async {
      final videoBackend = MockLlamaBackend(nativeVideoRuntimeSupported: true);
      final videoEngine = LlamaEngine(videoBackend);
      try {
        await videoEngine.loadModel('qwen-test.gguf');
        await videoEngine.loadMultimodalProjector('proj.gguf');

        expect(await videoEngine.supportsVideo, isFalse);
        await expectLater(
          videoEngine
              .generate(
                'describe',
                parts: [LlamaVideoContent(path: '/tmp/clip.mp4')],
              )
              .drain<void>(),
          throwsA(
            isA<LlamaUnsupportedException>().having(
              (error) => error.message,
              'message',
              contains('frame iteration'),
            ),
          ),
        );
        expect(videoBackend.lastVideoProbeHandle, 2);
        expect(videoBackend.lastGenerationPrompt, isNull);
      } finally {
        await videoEngine.dispose();
      }
    });

    test('backend without native probe receives generic guidance', () async {
      final videoBackend = MockLlamaBackend(nativeVideoRuntimeSupported: null);
      final videoEngine = LlamaEngine(videoBackend);
      try {
        await videoEngine.loadModel('qwen-test.gguf');
        await videoEngine.loadMultimodalProjector('proj.gguf');

        await expectLater(
          videoEngine
              .generate(
                'describe',
                parts: [LlamaVideoContent(path: '/tmp/clip.mp4')],
              )
              .drain<void>(),
          throwsA(
            isA<LlamaUnsupportedException>()
                .having(
                  (error) => error.message,
                  'message',
                  contains('active backend'),
                )
                .having(
                  (error) => error.message,
                  'message',
                  isNot(contains('FFmpeg')),
                ),
          ),
        );
      } finally {
        await videoEngine.dispose();
      }
    });

    test('video probe failure still produces generic typed error', () async {
      final videoBackend = MockLlamaBackend(
        videoProbeError: StateError('missing optional probe'),
      );
      final videoEngine = LlamaEngine(videoBackend);
      try {
        await videoEngine.loadModel('qwen-test.gguf');
        await videoEngine.loadMultimodalProjector('proj.gguf');

        await expectLater(
          videoEngine
              .generate(
                'describe',
                parts: [LlamaVideoContent(path: '/tmp/clip.mp4')],
              )
              .drain<void>(),
          throwsA(
            isA<LlamaUnsupportedException>().having(
              (error) => error.message,
              'message',
              contains('active backend'),
            ),
          ),
        );
        expect(videoBackend.lastGenerationPrompt, isNull);
      } finally {
        await videoEngine.dispose();
      }
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

    test('hasMultimodalProjector tracks projector load and unload', () async {
      await engine.loadModel('qwen-test.gguf');
      expect(engine.hasMultimodalProjector, isFalse);

      await engine.loadMultimodalProjector('proj.gguf');
      expect(engine.hasMultimodalProjector, isTrue);

      await engine.unloadMultimodalProjector();
      expect(engine.hasMultimodalProjector, isFalse);
    });

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

    test('next-token scoring is unsupported without the capability', () async {
      await engine.loadModel('qwen-test.gguf');

      expect(engine.supportsNextTokenScoring, isFalse);
      await expectLater(
        engine.scoreNextToken('hello', topK: 1),
        throwsA(
          isA<LlamaUnsupportedException>().having(
            (error) => error.message,
            'message',
            'Next-token scoring is not supported by the active backend.',
          ),
        ),
      );
    });

    test('next-token scoring forwards to a supporting backend', () async {
      final scoringBackend = ScoringMockBackend();
      final scoringEngine = LlamaEngine(scoringBackend);
      await scoringEngine.loadModel('qwen-test.gguf');
      final candidates = [4, 7];

      final scores = await scoringEngine.scoreNextToken(
        'Answer:',
        candidates: candidates,
        topK: 2,
      );
      candidates.add(9);

      expect(scoringEngine.supportsNextTokenScoring, isTrue);
      expect(scores.candidates.map((t) => t.token), [4, 7]);
      final (_, prompt, sentCandidates, topK, reuse) =
          scoringBackend.scoreCalls.single;
      expect(prompt, 'Answer:');
      expect(sentCandidates, [4, 7]);
      expect(topK, 2);
      expect(reuse, GenerationParams.defaultReusePromptPrefix);

      await scoringEngine.scoreNextToken(
        'Answer:',
        topK: 1,
        reusePromptPrefix: false,
      );
      expect(scoringBackend.scoreCalls.last.$5, isFalse);
      await scoringEngine.dispose();
    });

    test('next-token scoring honours a false support probe', () async {
      final scoringBackend = ScoringMockBackend(supported: false);
      final scoringEngine = LlamaEngine(scoringBackend);
      await scoringEngine.loadModel('qwen-test.gguf');

      expect(scoringEngine.supportsNextTokenScoring, isFalse);
      await expectLater(
        scoringEngine.scoreNextToken('hello', topK: 1),
        throwsA(isA<LlamaUnsupportedException>()),
      );
      expect(scoringBackend.scoreCalls, isEmpty);
      await scoringEngine.dispose();
    });

    test('next-token scoring maps backend UnsupportedError', () async {
      final scoringBackend = ScoringMockBackend(
        error: UnsupportedError('not on this delegate'),
      );
      final scoringEngine = LlamaEngine(scoringBackend);
      await scoringEngine.loadModel('qwen-test.gguf');

      await expectLater(
        scoringEngine.scoreNextToken('hello', topK: 1),
        throwsA(
          isA<LlamaUnsupportedException>().having(
            (error) => error.message,
            'message',
            'Next-token scoring is not supported by the active backend: '
                'not on this delegate',
          ),
        ),
      );
      await scoringEngine.dispose();
    });

    test('next-token scoring validates arguments before the backend', () async {
      final scoringBackend = ScoringMockBackend();
      final scoringEngine = LlamaEngine(scoringBackend);
      await expectLater(
        scoringEngine.scoreNextToken('hello', topK: 1),
        throwsA(isA<LlamaContextException>()),
      );
      await scoringEngine.loadModel('qwen-test.gguf');

      for (final call in <Future<LlamaNextTokenScores> Function()>[
        () => scoringEngine.scoreNextToken('', topK: 1),
        () => scoringEngine.scoreNextToken('hi', candidates: const [-1]),
        () => scoringEngine.scoreNextToken('hi', topK: -1),
        () => scoringEngine.scoreNextToken('hi'),
      ]) {
        await expectLater(call(), throwsArgumentError);
      }
      expect(scoringBackend.scoreCalls, isEmpty);
      await scoringEngine.dispose();
    });

    test('state persistence unsupported message is backend-aware', () async {
      final stateBackend = UnsupportedStateBackend(backendName: 'Mock');
      final stateEngine = LlamaEngine(stateBackend);
      await stateEngine.loadModel('qwen-test.gguf');

      await expectLater(
        stateEngine.stateSaveFile('/tmp/state.bin', tokens: const []),
        throwsA(
          isA<LlamaUnsupportedException>().having(
            (error) => error.message,
            'message',
            'State persistence is not supported by the active backend.',
          ),
        ),
      );
    });

    test(
      'state persistence unsupported keeps WebGPU bridge guidance',
      () async {
        final stateBackend = UnsupportedStateBackend(backendName: 'WebGPU');
        final stateEngine = LlamaEngine(stateBackend);
        await stateEngine.loadModel('qwen-test.gguf');

        await expectLater(
          stateEngine.stateLoadFile('/tmp/state.bin', tokenCapacity: 16),
          throwsA(
            isA<LlamaUnsupportedException>().having(
              (error) => error.message,
              'message',
              allOf(contains('WebGPU'), contains('stateSaveFile')),
            ),
          ),
        );
      },
    );

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

    test('chatTemplate tolerates backends without tokenization', () async {
      final tokenlessBackend = UnsupportedTokenizationBackend();
      final tokenlessEngine = LlamaEngine(tokenlessBackend);

      try {
        await tokenlessEngine.loadModel('gemma-4-E2B-it.litertlm');

        final result = await tokenlessEngine.chatTemplate(const [
          LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'hi'),
        ]);

        expect(result.prompt, '<s>user: hiassistant: ');
        expect(result.tokenCount, isNull);
        expect(tokenlessBackend.tokenizeCalls, 1);
      } finally {
        await tokenlessEngine.dispose();
      }
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

    test(
      'create uses native structured chat generation when supported',
      () async {
        final nativeBackend = NativeChatMockBackend()
          ..generationText = 'native response';
        final nativeEngine = LlamaEngine(nativeBackend);

        try {
          await nativeEngine.loadModel('gemma-4-E2B-it.litertlm');

          final chunks = await nativeEngine
              .create(
                const [
                  LlamaChatMessage.fromText(
                    role: LlamaChatRole.system,
                    text: 'Be concise.',
                  ),
                  LlamaChatMessage.fromText(
                    role: LlamaChatRole.user,
                    text: 'hello',
                  ),
                ],
                params: const GenerationParams(maxTokens: 12),
                tools: [
                  ToolDefinition(
                    name: 'get_weather',
                    description: 'Get weather',
                    parameters: const [],
                    handler: (_) async => 'sunny',
                  ),
                ],
                chatTemplateKwargs: const {'locale': 'en_CA'},
              )
              .toList();

          expect(nativeBackend.nativeGenerateChatCalls, 1);
          expect(nativeBackend.lastGenerationPrompt, isNull);
          expect(
            nativeBackend.lastNativeMessages?.map((message) => message.role),
            [LlamaChatRole.system, LlamaChatRole.user],
          );
          expect(nativeBackend.lastNativeParams?.maxTokens, 12);
          expect(nativeBackend.lastNativeTools?.single.name, 'get_weather');
          expect(nativeBackend.lastNativeToolChoice, ToolChoice.auto);
          expect(nativeBackend.lastNativeParallelToolCalls, isFalse);
          expect(nativeBackend.lastNativeEnableThinking, isTrue);
          expect(nativeBackend.lastNativeChatTemplateKwargs, {
            'locale': 'en_CA',
          });
          expect(
            chunks
                .map((chunk) => chunk.choices.first.delta.content)
                .whereType<String>()
                .join(),
            'native response',
          );
          expect(chunks.last.choices.first.finishReason, 'stop');
        } finally {
          await nativeEngine.dispose();
        }
      },
    );

    test('create parses native structured chat tool_calls envelope', () async {
      final nativeBackend = NativeChatMockBackend()
        ..generationText =
            '{"tool_calls":[{"type":"function","function":'
            '{"name":"get_weather","arguments":{"location":"Seoul"}}}]}';
      final nativeEngine = LlamaEngine(nativeBackend);

      try {
        await nativeEngine.loadModel('gemma-4-E2B-it.litertlm');

        final chunks = await nativeEngine
            .create(
              const [
                LlamaChatMessage.fromText(
                  role: LlamaChatRole.user,
                  text: 'weather?',
                ),
              ],
              tools: [
                ToolDefinition(
                  name: 'get_weather',
                  description: 'Get weather',
                  parameters: [ToolParam.string('location')],
                  handler: (_) async => 'sunny',
                ),
              ],
              toolChoice: ToolChoice.auto,
            )
            .toList();

        final streamedContent = chunks
            .map((chunk) => chunk.choices.first.delta.content)
            .whereType<String>()
            .join();
        final toolChunk = chunks.last;
        final toolCalls = toolChunk.choices.first.delta.toolCalls;

        expect(nativeBackend.nativeGenerateChatCalls, 1);
        expect(streamedContent, isEmpty);
        expect(toolChunk.choices.first.finishReason, equals('tool_calls'));
        expect(toolCalls, hasLength(1));
        expect(toolCalls!.first.function?.name, equals('get_weather'));
        expect(
          jsonDecode(toolCalls.first.function!.arguments!),
          equals({'location': 'Seoul'}),
        );
      } finally {
        await nativeEngine.dispose();
      }
    });

    test(
      'create keeps non-media history parts on native structured chat path',
      () async {
        final nativeBackend = NativeChatMockBackend()
          ..generationText = 'native response';
        final nativeEngine = LlamaEngine(nativeBackend);

        try {
          await nativeEngine.loadModel('gemma-4-E2B-it.litertlm');

          await nativeEngine.create(const [
            LlamaChatMessage.withContent(
              role: LlamaChatRole.assistant,
              content: [
                LlamaThinkingContent('check tool state'),
                LlamaToolCallContent(
                  id: 'call_1',
                  name: 'get_weather',
                  arguments: {'city': 'Seoul'},
                  rawJson: '{"city":"Seoul"}',
                ),
              ],
            ),
            LlamaChatMessage.withContent(
              role: LlamaChatRole.tool,
              content: [
                LlamaToolResultContent(
                  id: 'call_1',
                  name: 'get_weather',
                  result: 'sunny',
                ),
              ],
            ),
            LlamaChatMessage.fromText(
              role: LlamaChatRole.user,
              text: 'summarize',
            ),
          ]).drain();

          expect(nativeBackend.nativeGenerateChatCalls, 1);
          expect(nativeBackend.lastGenerationPrompt, isNull);
          expect(
            nativeBackend.lastNativeMessages?.map((message) => message.role),
            [LlamaChatRole.assistant, LlamaChatRole.tool, LlamaChatRole.user],
          );
        } finally {
          await nativeEngine.dispose();
        }
      },
    );

    test(
      'create keeps media messages on native structured chat path',
      () async {
        final nativeBackend = NativeChatMockBackend()
          ..generationText = 'native response';
        final nativeEngine = LlamaEngine(nativeBackend);

        try {
          await nativeEngine.loadModel('gemma-4-E2B-it.litertlm');

          await nativeEngine.create(const [
            LlamaChatMessage.withContent(
              role: LlamaChatRole.user,
              content: [
                LlamaTextContent('Describe this image.'),
                LlamaImageContent(path: '/tmp/image.png'),
              ],
            ),
          ]).drain();

          expect(nativeBackend.nativeGenerateChatCalls, 1);
          expect(nativeBackend.lastGenerationPrompt, isNull);
          expect(
            nativeBackend.lastNativeMessages?.single.parts
                .whereType<LlamaImageContent>(),
            hasLength(1),
          );
        } finally {
          await nativeEngine.dispose();
        }
      },
    );

    test(
      'create falls back to rendered prompt for required native tools',
      () async {
        final nativeBackend = NativeChatMockBackend();
        final nativeEngine = LlamaEngine(nativeBackend);

        try {
          await nativeEngine.loadModel('gemma-4-E2B-it.litertlm');

          await nativeEngine
              .create(
                const [
                  LlamaChatMessage.fromText(
                    role: LlamaChatRole.user,
                    text: 'hello',
                  ),
                ],
                tools: [
                  ToolDefinition(
                    name: 'get_weather',
                    description: 'Get weather',
                    parameters: const [],
                    handler: (_) async => 'sunny',
                  ),
                ],
                toolChoice: ToolChoice.required,
              )
              .drain();

          expect(nativeBackend.nativeGenerateChatCalls, 0);
          expect(nativeBackend.lastGenerationPrompt, isNotNull);
        } finally {
          await nativeEngine.dispose();
        }
      },
    );

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

    test(
      'create does not stream raw Hermes bare tool-call JSON as content',
      () async {
        final hermesBackend = MockLlamaBackend(
          modelMetadataResponse: const {
            'llm.context_length': '4096',
            'tokenizer.chat_template':
                '{%- if tools %}<tools>{{ tools[0] | tojson }}</tools>'
                '<tool_call>{"name": <function-name>, "arguments": <args-json-object>}</tool_call>{% endif %}'
                '{% for message in messages %}<|im_start|>{{ message["role"] }}\n{{ message["content"] }}<|im_end|>\n{% endfor %}'
                '{% if add_generation_prompt %}<|im_start|>assistant\n{% endif %}',
          },
        );
        final hermesEngine = LlamaEngine(hermesBackend);
        hermesBackend.generationChunks = const [
          '</think>\n\n{"na',
          'me": "get_weather", "arguments": {"l',
          'ocation": "Seoul"}}',
        ];
        await hermesEngine.loadModel('qwen-test.gguf');

        final chunks = await hermesEngine
            .create(
              const [
                LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'hi'),
              ],
              tools: [
                ToolDefinition(
                  name: 'get_weather',
                  description: 'Get weather',
                  parameters: [ToolParam.string('location')],
                  handler: (_) async => 'ok',
                ),
              ],
              toolChoice: ToolChoice.required,
            )
            .toList();

        final streamedContent = chunks
            .map((chunk) => chunk.choices.first.delta.content)
            .whereType<String>()
            .join();
        final toolChunk = chunks.last;
        final toolCalls = toolChunk.choices.first.delta.toolCalls;

        expect(streamedContent, isEmpty);
        expect(toolChunk.choices.first.finishReason, equals('tool_calls'));
        expect(toolCalls, hasLength(1));
        expect(toolCalls!.first.function?.name, equals('get_weather'));
        expect(
          jsonDecode(toolCalls.first.function!.arguments!),
          equals({'location': 'Seoul'}),
        );
      },
    );

    test(
      'create does not stream raw Hermes XML tool-call prefix as content',
      () async {
        final hermesBackend = MockLlamaBackend(
          modelMetadataResponse: const {
            'llm.context_length': '4096',
            'tokenizer.chat_template':
                '{%- if tools %}<tools>{{ tools[0] | tojson }}</tools>'
                '<tool_call>{"name": <function-name>, "arguments": <args-json-object>}</tool_call>{% endif %}'
                '{% for message in messages %}<|im_start|>{{ message["role"] }}\n{{ message["content"] }}<|im_end|>\n{% endfor %}'
                '{% if add_generation_prompt %}<|im_start|>assistant\n{% endif %}',
          },
        );
        final hermesEngine = LlamaEngine(hermesBackend);
        hermesBackend.generationChunks = const [
          '<tool_call>',
          '{"name":"get_weather","arguments":{"location":"Seoul"}}',
          '</tool_call>',
        ];
        await hermesEngine.loadModel('qwen-test.gguf');

        final chunks = await hermesEngine
            .create(
              const [
                LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'hi'),
              ],
              tools: [
                ToolDefinition(
                  name: 'get_weather',
                  description: 'Get weather',
                  parameters: [ToolParam.string('location')],
                  handler: (_) async => 'ok',
                ),
              ],
              toolChoice: ToolChoice.required,
            )
            .toList();

        final streamedContent = chunks
            .map((chunk) => chunk.choices.first.delta.content)
            .whereType<String>()
            .join();
        final toolChunk = chunks.last;
        final toolCalls = toolChunk.choices.first.delta.toolCalls;

        expect(streamedContent, isEmpty);
        expect(toolChunk.choices.first.finishReason, equals('tool_calls'));
        expect(toolCalls, hasLength(1));
        expect(toolCalls!.first.function?.name, equals('get_weather'));
        expect(
          jsonDecode(toolCalls.first.function!.arguments!),
          equals({'location': 'Seoul'}),
        );
      },
    );

    test(
      'create skips template grammar for backends without grammar constraints',
      () async {
        final noGrammarBackend = NoGrammarMockLlamaBackend(
          modelMetadataResponse: const {
            'llm.context_length': '4096',
            'tokenizer.chat_template':
                '<|turn>user\n{{ messages[0]["content"] }}<turn|>{% if add_generation_prompt %}<|turn>model\n{% endif %}',
          },
        );
        final noGrammarEngine = LlamaEngine(noGrammarBackend);
        noGrammarBackend.generationText =
            '<|tool_call>call:get_weather{location:<|"|>Seoul<|"|>}<tool_call|>';

        await noGrammarEngine.loadModel('gemma4-test.litertlm');

        final chunks = await noGrammarEngine
            .create(
              const [
                LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'hi'),
              ],
              tools: [
                ToolDefinition(
                  name: 'get_weather',
                  description: 'Get weather',
                  parameters: [ToolParam.string('location')],
                  handler: (_) async => 'ok',
                ),
              ],
            )
            .toList();

        final streamedContent = chunks
            .map((chunk) => chunk.choices.first.delta.content)
            .whereType<String>()
            .join();
        expect(streamedContent, isEmpty);

        expect(noGrammarBackend.lastGenerationParams?.grammar, isNull);
        expect(noGrammarBackend.lastGenerationParams?.grammarLazy, isFalse);
        expect(noGrammarBackend.lastGenerationParams?.grammarTriggers, isEmpty);
        expect(noGrammarBackend.lastGenerationParams?.preservedTokens, isEmpty);

        final toolChunk = chunks.last;
        expect(toolChunk.choices.first.finishReason, equals('tool_calls'));
        final toolCalls = toolChunk.choices.first.delta.toolCalls;
        expect(toolCalls, hasLength(1));
        expect(toolCalls!.first.function?.name, equals('get_weather'));
        expect(
          jsonDecode(toolCalls.first.function!.arguments!),
          equals({'location': 'Seoul'}),
        );
      },
    );

    test(
      'create forwards responseFormat grammar to capable backends',
      () async {
        await engine.loadModel('test-model.bin');

        await engine
            .create(
              const [
                LlamaChatMessage.fromText(
                  role: LlamaChatRole.user,
                  text: 'return status',
                ),
              ],
              responseFormat: const {
                'type': 'json_schema',
                'json_schema': {
                  'schema': {
                    'type': 'object',
                    'properties': {
                      'ok': {'type': 'boolean'},
                    },
                    'required': ['ok'],
                  },
                },
              },
            )
            .drain();

        expect(backend.lastGenerationParams?.grammar, isNotNull);
        expect(backend.lastGenerationParams?.grammar, contains('ok'));
        expect(backend.lastGenerationParams?.grammarLazy, isFalse);
        expect(backend.lastGenerationParams?.grammarTriggers, isEmpty);
      },
    );

    test(
      'createStructuredJson forwards grammar and decodes typed output',
      () async {
        backend.generationText = '{"ok":true}';
        await engine.loadModel('test-model.bin');

        final result = await engine.createStructuredJson<bool>(
          const [
            LlamaChatMessage.fromText(
              role: LlamaChatRole.user,
              text: 'return status',
            ),
          ],
          output: LlamaStructuredOutput<bool>.jsonSchema(
            schema: const {
              'type': 'object',
              'properties': {
                'ok': {'type': 'boolean'},
              },
              'required': ['ok'],
              'additionalProperties': false,
            },
            decoder: (json) => json['ok'] as bool,
          ),
        );

        expect(result, isTrue);
        expect(backend.lastGenerationParams?.grammar, isNotNull);
        expect(backend.lastGenerationParams?.grammar, contains('ok'));
      },
    );

    test(
      'create rejects strict response format when backend lacks grammar',
      () async {
        final noGrammarBackend = NoGrammarMockLlamaBackend();
        final noGrammarEngine = LlamaEngine(noGrammarBackend);

        await noGrammarEngine.loadModel('gemma4-test.litertlm');

        await expectLater(
          noGrammarEngine
              .create(
                const [
                  LlamaChatMessage.fromText(
                    role: LlamaChatRole.user,
                    text: 'return status',
                  ),
                ],
                responseFormat: const {
                  'type': 'json_schema',
                  'json_schema': {
                    'schema': {
                      'type': 'object',
                      'properties': {
                        'ok': {'type': 'boolean'},
                      },
                      'required': ['ok'],
                    },
                  },
                },
              )
              .drain(),
          throwsA(
            isA<LlamaUnsupportedException>()
                .having(
                  (error) => error.message,
                  'message',
                  contains('Strict responseFormat output requires'),
                )
                .having(
                  (error) => error.message,
                  'message',
                  contains('LiteRT-LM native and web currently do not expose'),
                )
                .having(
                  (error) => error.message,
                  'message',
                  contains('omit responseFormat'),
                ),
          ),
        );

        expect(noGrammarBackend.lastGenerationPrompt, isNull);
      },
    );

    test(
      'create rejects malformed strict response format on no-grammar backend',
      () async {
        final noGrammarBackend = NoGrammarMockLlamaBackend();
        final noGrammarEngine = LlamaEngine(noGrammarBackend);

        await noGrammarEngine.loadModel('gemma4-test.litertlm');

        await expectLater(
          noGrammarEngine
              .create(
                const [
                  LlamaChatMessage.fromText(
                    role: LlamaChatRole.user,
                    text: 'return status',
                  ),
                ],
                responseFormat: const {'type': 'json_schema'},
              )
              .drain(),
          throwsA(isA<LlamaUnsupportedException>()),
        );

        expect(noGrammarBackend.lastGenerationPrompt, isNull);
      },
    );

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

    test('create streams raw bracket text when tools are enabled', () async {
      backend.generationChunks = const ['  ["', 'note', '"]\n'];
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

      expect(streamedContent, equals('  ["note"]\n'));
      expect(contentChunks, hasLength(3));
      expect(chunks.last.choices.first.finishReason, equals('stop'));
    });

    test('create parses Cohere bare action arrays as tool calls', () async {
      final cohereBackend = MockLlamaBackend(
        modelMetadataResponse: const {
          'llm.context_length': '4096',
          'tokenizer.chat_template':
              '{% for message in messages %}{{ message["content"] }}{% endfor %}'
              '{% if add_generation_prompt %}<|START_TEXT|>{% endif %}'
              '{# <|START_ACTION|> #}',
        },
      );
      final cohereEngine = LlamaEngine(cohereBackend);
      cohereBackend.generationChunks = const [
        '[{"tool_name"',
        ':"get_weather","parameters":{"city":"Seoul"}}]',
      ];
      await cohereEngine.loadModel('north-code-test.gguf');

      final chunks = await cohereEngine
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
      final toolChunk = chunks.last;
      final toolCalls = toolChunk.choices.first.delta.toolCalls;

      expect(streamedContent, isEmpty);
      expect(toolChunk.choices.first.finishReason, equals('tool_calls'));
      expect(toolCalls, hasLength(1));
      expect(toolCalls!.first.function?.name, equals('get_weather'));
      expect(jsonDecode(toolCalls.first.function!.arguments!), {
        'city': 'Seoul',
      });
    });

    test('create suppresses partial Cohere bare action array content', () async {
      final cohereBackend = MockLlamaBackend(
        modelMetadataResponse: const {
          'llm.context_length': '4096',
          'tokenizer.chat_template':
              '{% for message in messages %}{{ message["content"] }}{% endfor %}'
              '{% if add_generation_prompt %}<|START_TEXT|>{% endif %}'
              '{# <|START_ACTION|> #}',
        },
      );
      final cohereEngine = LlamaEngine(cohereBackend);
      cohereBackend.generationChunks = const [
        '[{"tool_name":"get_weather",',
        '"parameters":{"location":"Seoul"}}]',
      ];
      await cohereEngine.loadModel('north-code-test.gguf');

      final chunks = await cohereEngine
          .create(
            const [
              LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'hi'),
            ],
            tools: [
              ToolDefinition(
                name: 'get_weather',
                description: 'Get weather',
                parameters: [ToolParam.string('location')],
                handler: (_) async => 'ok',
              ),
            ],
            toolChoice: ToolChoice.required,
          )
          .toList();

      final streamedContent = chunks
          .map((chunk) => chunk.choices.first.delta.content)
          .whereType<String>()
          .join();
      final toolChunk = chunks.last;
      final toolCalls = toolChunk.choices.first.delta.toolCalls;

      expect(streamedContent, isEmpty);
      expect(toolChunk.choices.first.finishReason, equals('tool_calls'));
      expect(toolCalls, hasLength(1));
      expect(toolCalls!.first.function?.name, equals('get_weather'));
      expect(jsonDecode(toolCalls.first.function!.arguments!), {
        'location': 'Seoul',
      });
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

    test(
      'create suppresses thinking deltas when thinking is disabled',
      () async {
        backend.generationChunks = const ['<think>reason', '</think> answer'];
        await engine.loadModel('qwen-test.gguf');

        final chunks = await engine.create(const [
          LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'hi'),
        ], enableThinking: false).toList();

        final streamedContent = chunks
            .map((chunk) => chunk.choices.first.delta.content)
            .whereType<String>()
            .join();
        final streamedThinking = chunks
            .map((chunk) => chunk.choices.first.delta.thinking)
            .whereType<String>()
            .join();

        expect(streamedThinking, isEmpty);
        expect(streamedContent, equals(' answer'));
        expect(streamedContent, isNot(contains('reason')));
        expect(chunks.last.choices.first.finishReason, equals('stop'));
      },
    );

    test(
      'create suppresses thinking deltas in raw tool-enabled mode when disabled',
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
              enableThinking: false,
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

        expect(streamedThinking, isEmpty);
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

    group('cancelGeneration before the backend starts', () {
      late TokenCancelBackend tokenBackend;
      late LlamaEngine tokenEngine;
      const user = LlamaChatMessage.fromText(
        role: LlamaChatRole.user,
        text: 'hello',
      );

      setUp(() async {
        tokenBackend = TokenCancelBackend();
        tokenEngine = LlamaEngine(tokenBackend);
        await tokenEngine.loadModel('qwen-test.gguf');
      });

      tearDown(() => tokenEngine.dispose());

      Future<String> collect(Stream<String> stream, {bool cancel = false}) {
        final output = StringBuffer();
        final done = Completer<String>();
        stream.listen(
          output.write,
          onError: done.completeError,
          onDone: () => done.complete(output.toString()),
        );
        if (cancel) tokenEngine.cancelGeneration();
        return done.future;
      }

      Stream<String> content(Stream<LlamaCompletionChunk> chunks) => chunks
          .where((chunk) => chunk.choices.isNotEmpty)
          .map((chunk) => chunk.choices.first.delta.content ?? '');

      test('generate honours a cancel issued right after listen', () async {
        final output = await collect(
          tokenEngine.generate('hello'),
          cancel: true,
        );

        expect(output, isEmpty);
        expect(tokenBackend.generateCalls, 0);
      });

      test('create honours a cancel issued right after listen', () async {
        final output = await collect(
          content(tokenEngine.create(const [user])),
          cancel: true,
        );

        expect(output, isEmpty);
        expect(tokenBackend.generateCalls, 0);
      });

      test('native chat create honours a cancel right after listen', () async {
        final nativeBackend = NativeChatMockBackend();
        final nativeEngine = LlamaEngine(nativeBackend);
        addTearDown(nativeEngine.dispose);
        await nativeEngine.loadModel('gemma.litertlm');

        final chunks = nativeEngine.create(const [user]).toList();
        nativeEngine.cancelGeneration();
        final output = await content(Stream.fromIterable(await chunks)).join();

        expect(output, isEmpty);
        expect(nativeBackend.nativeGenerateChatCalls, 0);
      });

      test('a cancel after completion leaves the next stream intact', () async {
        expect(await collect(tokenEngine.generate('hello')), 'one two three');
        tokenEngine.cancelGeneration();

        expect(await collect(tokenEngine.generate('hello')), 'one two three');
        expect(
          await collect(content(tokenEngine.create(const [user]))),
          'one two three',
        );
        expect(tokenBackend.generateCalls, 3);
      });

      test('a cancel before listen leaves the stream intact', () async {
        final stream = tokenEngine.generate('hello');
        tokenEngine.cancelGeneration();

        expect(await collect(stream), 'one two three');
        expect(tokenBackend.generateCalls, 1);
      });

      test('a cancel after the backend starts still reaches it', () async {
        final output = StringBuffer();
        final done = Completer<void>();
        tokenEngine.generate('hello').listen((token) {
          output.write(token);
          tokenEngine.cancelGeneration();
        }, onDone: done.complete);
        await done.future;

        expect(output.toString(), 'one ');
        expect(tokenBackend.generateCalls, 1);
      });
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

  group('LlamaEngine subscription cancel during prompt evaluation', () {
    const user = LlamaChatMessage.fromText(
      role: LlamaChatRole.user,
      text: 'hello',
    );
    final paths = <String, (bool, Stream<Object?> Function(LlamaEngine))>{
      'generate': (false, (engine) => engine.generate('hello')),
      'create': (false, (engine) => engine.create(const [user])),
      'native chat create': (true, (engine) => engine.create(const [user])),
      'ChatSession.create': (
        false,
        (engine) => ChatSession(engine).create([LlamaTextContent('hello')]),
      ),
    };

    for (final MapEntry(key: path, value: (nativeChat, start))
        in paths.entries) {
      Future<(PromptEvaluationBackend, LlamaEngine)> load() async {
        final backend = PromptEvaluationBackend(nativeChat: nativeChat);
        final engine = LlamaEngine(backend);
        addTearDown(engine.dispose);
        await engine.loadModel('qwen-test.gguf');
        return (backend, engine);
      }

      test(
        '$path cancels the backend stream before the cancel returns',
        () async {
          final (backend, engine) = await load();
          final subscription = start(engine).listen(null);
          while (backend.listens == 0) {
            await Future<void>.delayed(Duration.zero);
          }

          final cancelled = subscription.cancel();

          expect(backend.cancels, 1);
          await cancelled;
          expect(backend.generateCalls, 1);
        },
      );
    }

    for (final path in const ['generate', 'ChatSession.create']) {
      test('$path cancelled before the backend starts skips it', () async {
        final backend = PromptEvaluationBackend(nativeChat: false);
        final engine = LlamaEngine(backend);
        addTearDown(engine.dispose);
        await engine.loadModel('qwen-test.gguf');

        await paths[path]!.$2(engine).listen(null).cancel();
        await pumpEventQueue();

        expect(backend.generateCalls, 0);
      });
    }

    test('ChatSession.create cancelled during prompt evaluation adds no '
        'assistant message', () async {
      final backend = PromptEvaluationBackend(nativeChat: false);
      final engine = LlamaEngine(backend);
      addTearDown(engine.dispose);
      await engine.loadModel('qwen-test.gguf');
      final session = ChatSession(engine);
      final subscription = session
          .create([LlamaTextContent('hello')])
          .listen(null);
      while (backend.listens == 0) {
        await Future<void>.delayed(Duration.zero);
      }

      await subscription.cancel();
      await pumpEventQueue();

      expect(session.history.map((message) => message.role), [
        LlamaChatRole.user,
      ]);
    });
  });

  group('LlamaEngine subscription cancel delivers no events', () {
    const user = LlamaChatMessage.fromText(
      role: LlamaChatRole.user,
      text: 'hello',
    );
    const toolTemplate = {
      'llm.context_length': '4096',
      'tokenizer.chat_template':
          '[SYSTEM_PROMPT]x[/SYSTEM_PROMPT][TOOL_CALLS]get_weather[ARGS]{}'
          '{% for m in messages %}{{ m["content"] }}{% endfor %}',
    };
    final tools = [
      ToolDefinition(
        name: 'search',
        description: 'Search docs',
        parameters: [ToolParam.string('query', required: true)],
        handler: (_) async => 'ok',
      ),
    ];
    const toolCall = '[TOOL_CALLS]search[ARGS]{"query":"Seoul"}';
    final paths = <String, (bool, Stream<Object?> Function(LlamaEngine))>{
      'generate': (false, (engine) => engine.generate('hello')),
      'create': (false, (engine) => engine.create(const [user])),
      'native chat create': (true, (engine) => engine.create(const [user])),
      'ChatSession.create': (
        false,
        (engine) => ChatSession(engine).create([LlamaTextContent('hello')]),
      ),
    };

    Future<LlamaEngine> load(HeldOutputBackend backend) async {
      final engine = LlamaEngine(backend);
      addTearDown(engine.dispose);
      await engine.loadModel('qwen-test.gguf');
      return engine;
    }

    /// Listens to [stream], cancels it once [backend] has run, and returns
    /// the callbacks that ran after the cancel was called, including inside
    /// it. A cancel before the backend runs happens right after the listen.
    Future<List<String>> eventsAfterCancel(
      Stream<Object?> stream,
      HeldOutputBackend backend, {
      bool beforeBackend = false,
      bool cancelTwice = false,
      void Function(Future<void> cancelled)? onCancelled,
    }) async {
      final events = <String>[];
      var cancelCalled = false;
      final subscription = stream.listen(
        (event) {
          if (cancelCalled) events.add('data $event');
        },
        onError: (Object error) {
          if (cancelCalled) events.add('error $error');
        },
        onDone: () {
          if (cancelCalled) events.add('done');
        },
      );
      if (!beforeBackend) {
        while (backend.listens == 0) {
          await Future<void>.delayed(Duration.zero);
        }
        await pumpEventQueue();
      }
      cancelCalled = true;
      final cancelled = subscription.cancel();
      if (onCancelled != null) {
        onCancelled(cancelled);
      } else {
        await cancelled;
      }
      if (cancelTwice) await subscription.cancel();
      await pumpEventQueue();
      return events;
    }

    for (final MapEntry(key: path, value: (nativeChat, start))
        in paths.entries) {
      for (final output in const [
        <String>[],
        <String>['Hello'],
      ]) {
        final state = output.isEmpty
            ? 'during prompt evaluation'
            : 'mid-output';
        test('$path cancelled $state delivers nothing after the cancel is '
            'called', () async {
          final backend = HeldOutputBackend(
            output: output,
            nativeChat: nativeChat,
          );
          final engine = await load(backend);

          expect(await eventsAfterCancel(start(engine), backend), isEmpty);
        });
      }

      test('$path cancelled before the backend starts delivers nothing and '
          'skips it', () async {
        final backend = HeldOutputBackend(
          output: const ['Hello'],
          nativeChat: nativeChat,
        );
        final engine = await load(backend);

        final events = await eventsAfterCancel(
          start(engine),
          backend,
          beforeBackend: true,
        );

        expect(events, isEmpty);
        expect(backend.generateCalls, 0);
      });
    }

    test('create cancelled with a whole tool call buffered delivers nothing '
        'after the cancel is called', () async {
      final backend = HeldOutputBackend(
        output: const [toolCall],
        modelMetadataResponse: toolTemplate,
      );
      final engine = await load(backend);

      final events = await eventsAfterCancel(
        engine.create(const [user], tools: tools),
        backend,
      );

      expect(events, isEmpty);
    });

    test('ChatSession.create cancelled with a whole tool call buffered '
        'delivers nothing and adds no assistant message', () async {
      final backend = HeldOutputBackend(
        output: const [toolCall],
        modelMetadataResponse: toolTemplate,
      );
      final engine = await load(backend);
      final session = ChatSession(engine);

      final events = await eventsAfterCancel(
        session.create([LlamaTextContent('hello')], tools: tools),
        backend,
      );

      expect(events, isEmpty);
      expect(session.history.map((message) => message.role), [
        LlamaChatRole.user,
      ]);
    });

    test('a second cancel delivers nothing', () async {
      final backend = HeldOutputBackend(output: const ['Hello']);
      final engine = await load(backend);

      final events = await eventsAfterCancel(
        engine.create(const [user]),
        backend,
        cancelTwice: true,
      );

      expect(events, isEmpty);
    });

    final failure = StateError('backend cancel failed');
    final llamaFailure = LlamaStateException('backend cancel state');
    final cancelFailures =
        <String, (Object, String, Matcher Function(String operation))>{
          'a raw error': (
            failure,
            'wraps it',
            (operation) => isA<LlamaInferenceException>()
                .having((e) => e.message, 'message', '$operation failed')
                .having((e) => e.details, 'details', same(failure)),
          ),
          'an UnsupportedError': (
            UnsupportedError('no cancel'),
            'reports it as unsupported',
            (operation) => isA<LlamaUnsupportedException>().having(
              (e) => e.message,
              'message',
              '$operation is not supported by the active backend: no cancel',
            ),
          ),
          'a LlamaException': (
            llamaFailure,
            'keeps it',
            (_) => same(llamaFailure),
          ),
        };
    final operations = <String, (bool, String)>{
      'generate': (false, 'Generation'),
      'create': (false, 'Generation'),
      'native chat create': (true, 'Native chat generation'),
    };

    for (final MapEntry(key: path, value: (nativeChat, operation))
        in operations.entries) {
      for (final MapEntry(key: kind, value: (error, action, matcher))
          in cancelFailures.entries) {
        test('$path: a backend cancel failure with $kind $action as the '
            'generation does, and delivers nothing', () async {
          final backend = HeldOutputBackend(
            output: const ['Hello'],
            nativeChat: nativeChat,
            cancelError: error,
          );
          final engine = await load(backend);
          late Future<void> cancelled;

          final events = await eventsAfterCancel(
            paths[path]!.$2(engine),
            backend,
            onCancelled: (future) {
              cancelled = future;
              future.ignore();
            },
          );

          expect(events, isEmpty);
          await expectLater(cancelled, throwsA(matcher(operation)));
        });
      }
    }

    test('an unawaited cancel reports a backend cancel failure once, as a '
        'LlamaException', () async {
      final backend = HeldOutputBackend(
        output: const ['Hello'],
        cancelError: failure,
      );
      final engine = await load(backend);
      final unhandled = <Object>[];

      await runZonedGuarded(() async {
        final subscription = engine.create(const [user]).listen(null);
        while (backend.listens == 0) {
          await Future<void>.delayed(Duration.zero);
        }
        unawaited(subscription.cancel());
        await pumpEventQueue();
      }, (error, _) => unhandled.add(error));

      expect(unhandled, [
        isA<LlamaInferenceException>().having(
          (e) => e.details,
          'details',
          same(failure),
        ),
      ]);
    });
  });

  group('LlamaEngine generation limits', () {
    late LimitReportingMockBackend limitBackend;
    late LlamaEngine limitEngine;
    const messages = [
      LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'hi'),
    ];

    setUp(() async {
      limitBackend = LimitReportingMockBackend()..generationText = 'partial';
      limitEngine = LlamaEngine(limitBackend);
      await limitEngine.loadModel('qwen-test.gguf');
    });

    tearDown(() async {
      await limitEngine.dispose();
    });

    for (final nativeChat in <bool>[false, true]) {
      final path = nativeChat ? 'native chat' : 'rendered prompt';

      for (final limit in BackendGenerationLimit.values) {
        test(
          'create finishes with length at $limit on the $path path',
          () async {
            limitBackend
              ..nativeChat = nativeChat
              ..nextLimit = limit;

            final chunks = await limitEngine.create(messages).toList();

            expect(limitBackend.nativeGenerateChatCalls, nativeChat ? 1 : 0);
            expect(
              chunks
                  .map((chunk) => chunk.choices.first.delta.content ?? '')
                  .join(),
              'partial',
            );
            expect(chunks.last.choices.first.finishReason, 'length');
          },
        );
      }

      test(
        'create finishes with stop without a limit on the $path path',
        () async {
          limitBackend.nativeChat = nativeChat;

          final chunks = await limitEngine.create(messages).toList();

          expect(chunks.last.choices.first.finishReason, 'stop');
        },
      );
    }

    for (final limit in BackendGenerationLimit.values) {
      test(
        'completionGenerationLimit names $limit on the final chunk',
        () async {
          limitBackend.nextLimit = limit;

          final chunks = await limitEngine.create(messages).toList();

          expect(completionGenerationLimit(chunks.last), limit);
          expect(
            chunks.take(chunks.length - 1).map(completionGenerationLimit),
            everyElement(isNull),
          );
        },
      );
    }

    test('completionGenerationLimit is null without a limit', () async {
      final chunks = await limitEngine.create(messages).toList();

      expect(chunks.map(completionGenerationLimit), everyElement(isNull));
    });

    const usage = LlamaGenerationUsage(
      promptTokens: 6,
      completionTokens: 2,
      duration: Duration(milliseconds: 9),
    );

    for (final nativeChat in <bool>[false, true]) {
      final path = nativeChat ? 'native chat' : 'rendered prompt';

      test('create puts usage on the final chunk on the $path path', () async {
        limitBackend
          ..nativeChat = nativeChat
          ..nextUsage = usage;

        final chunks = await limitEngine.create(messages).toList();

        expect(limitBackend.nativeGenerateChatCalls, nativeChat ? 1 : 0);
        expect(chunks.last.usage, same(usage));
        expect(
          chunks.take(chunks.length - 1).map((chunk) => chunk.usage),
          everyElement(isNull),
        );
      });
    }

    test('create puts usage on a final tool-call chunk', () async {
      limitBackend
        ..generationText =
            '{"tool_call":{"name":"get_weather","arguments":{"city":"Seoul"}}}'
        ..nextUsage = usage;

      final chunks = await limitEngine
          .create(
            messages,
            tools: [
              ToolDefinition(
                name: 'get_weather',
                description: 'Get weather',
                parameters: [ToolParam.string('city')],
                handler: (_) async => 'ok',
              ),
            ],
          )
          .toList();

      expect(chunks.last.choices.first.finishReason, 'tool_calls');
      expect(chunks.last.usage, same(usage));
    });

    test(
      'create leaves usage null when cancelled before the backend',
      () async {
        limitBackend.nextUsage = usage;
        final chunks = <LlamaCompletionChunk>[];
        final done = Completer<void>();
        limitEngine
            .create(messages)
            .listen(
              chunks.add,
              onDone: done.complete,
              onError: done.completeError,
            );
        limitEngine.cancelGeneration();
        await done.future;

        expect(chunks.last.choices.first.finishReason, 'stop');
        expect(chunks.map((chunk) => chunk.usage), everyElement(isNull));
      },
    );

    test('create leaves usage null when the backend reports none', () async {
      final chunks = await limitEngine.create(messages).toList();

      expect(chunks.map((chunk) => chunk.usage), everyElement(isNull));
    });
  });

  group('LlamaEngine source URL redaction', () {
    late List<String> logs;

    setUp(() {
      logs = <String>[];
      LlamaLogger.instance
        ..setLevel(LlamaLogLevel.debug)
        ..setHandler(
          (record) => logs.add('${record.message} ${record.error ?? ''}'),
        );
    });

    tearDown(() {
      LlamaLogger.instance
        ..setHandler(null)
        ..setLevel(LlamaLogLevel.none);
    });

    for (final (url, display, secrets) in const [
      (
        'https://alice:Pw1secret@example.com/m.gguf',
        'https://example.com/m.gguf',
        <String>['Pw1secret', 'alice'],
      ),
      (
        '//alice:Pw2secret@example.com/m.gguf?token=Tk2secret',
        '//example.com/m.gguf',
        <String>['Pw2secret', 'Tk2secret', 'alice'],
      ),
      ('models/m.gguf?token=Tk3secret', 'models/m.gguf', <String>['Tk3secret']),
      (
        'https://example.com/m.gguf#Fr4secretfrag',
        'https://example.com/m.gguf',
        <String>['Fr4secretfrag'],
      ),
      (
        'https://bucket.example.com/m.gguf?X-Amz-Signature=Sig5secret',
        'https://bucket.example.com/m.gguf',
        <String>['Sig5secret'],
      ),
    ]) {
      Matcher withoutSecrets() => allOf(<Matcher>[
        for (final secret in secrets) isNot(contains(secret)),
      ]);

      test('keeps $url secrets out of load failures', () async {
        for (final urlLoading in const [false, true]) {
          final failing = LlamaEngine(
            _SourceEchoBackend(urlLoadingSupported: urlLoading, fail: true),
          );
          logs.clear();
          Object? thrown;
          try {
            await failing.loadModel(url);
          } catch (error) {
            thrown = error;
          }

          expect(
            thrown,
            isA<LlamaModelException>()
                .having((e) => e.message, 'message', contains(display))
                .having((e) => '$e', 'error', withoutSecrets())
                .having(
                  (e) => '${e.details}',
                  'details',
                  allOf(contains('not found'), withoutSecrets()),
                ),
            reason: 'URL loading: $urlLoading',
          );
          expect(logs, isNotEmpty);
          expect(
            logs.join('\n'),
            withoutSecrets(),
            reason: 'URL loading: $urlLoading',
          );
        }
      });

      test('keeps $url secrets out of projector failures', () async {
        for (final urlLoading in const [false, true]) {
          final engine = LlamaEngine(
            _SourceEchoBackend(urlLoadingSupported: urlLoading),
          );
          await engine.loadModel('model.gguf');
          logs.clear();
          Object? thrown;
          try {
            await engine.loadMultimodalProjector(url);
          } catch (error) {
            thrown = error;
          }

          expect(
            thrown,
            isA<LlamaModelException>()
                .having((e) => e.message, 'message', endsWith(' m.gguf'))
                .having((e) => '$e', 'error', withoutSecrets())
                .having(
                  (e) => '${e.details}',
                  'details',
                  allOf(contains('not found'), withoutSecrets()),
                ),
            reason: 'URL loading: $urlLoading',
          );
          expect(logs.join('\n'), withoutSecrets());
        }
      });

      test('keeps $url secrets out of a loaded model', () async {
        for (final urlLoading in const [false, true]) {
          final loaded = LlamaEngine(
            _SourceEchoBackend(urlLoadingSupported: urlLoading),
          );
          logs.clear();
          await loaded.loadModel(url);
          final chunks = await loaded.create(const [
            LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'hi'),
          ]).toList();
          await expectLater(
            loaded.loadMultimodalProjector(url),
            throwsA(isA<Exception>()),
          );

          expect(
            chunks.first.model,
            display,
            reason: 'URL loading: $urlLoading',
          );
          expect(
            logs.join('\n'),
            allOf(contains('m.gguf'), withoutSecrets()),
            reason: 'URL loading: $urlLoading',
          );
        }
      });
    }

    test('keeps a backend LlamaException from projector loading', () async {
      final error = LlamaModelException('Multimodal projector file not found.');
      final engine = LlamaEngine(_SourceEchoBackend(projectorError: error));
      await engine.loadModel('model.gguf');

      await expectLater(
        engine.loadMultimodalProjector('proj.gguf'),
        throwsA(same(error)),
      );
    });
  });
}

/// A backend whose failures echo the source path or URL, as native file
/// checks and browser fetch errors do, and its secret parts on their own.
class _SourceEchoBackend extends MockLlamaBackend {
  _SourceEchoBackend({
    super.urlLoadingSupported,
    this.fail = false,
    this.projectorError,
  });

  final bool fail;
  final Object? projectorError;

  @override
  Future<int> modelLoad(String path, ModelParams params) async {
    if (fail) throw _notFound(path);
    return super.modelLoad(path, params);
  }

  @override
  Future<int> modelLoadFromUrl(
    String url,
    ModelParams params, {
    Function(double progress)? onProgress,
  }) async {
    if (fail) throw _notFound(url);
    return super.modelLoadFromUrl(url, params, onProgress: onProgress);
  }

  @override
  Future<int?> multimodalContextCreate(
    int modelHandle,
    String mmProjPath,
  ) async => throw projectorError ?? _notFound(mmProjPath);

  static Exception _notFound(String source) {
    final uri = Uri.parse(source);
    return Exception(
      'File not found: $source (${uri.userInfo} ${uri.query} ${uri.fragment})',
    );
  }
}
