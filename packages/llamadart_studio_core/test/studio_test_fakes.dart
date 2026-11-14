import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

class FakeInferencePort implements StudioInferencePort {
  final StateStore<StudioRuntimeSnapshot> _runtime =
      StateStore<StudioRuntimeSnapshot>(
        const StudioRuntimeSnapshot(
          phase: StudioEnginePhase.ready,
          activeModelLabel: 'Fake Qwen',
          backendName: 'Metal',
        ),
      );

  List<StudioTurnEvent> nextEvents = const <StudioTurnEvent>[];
  StudioTurnRequest? lastRequest;

  @override
  ReadOnlyStore<StudioRuntimeSnapshot> get runtimeStore => _runtime;

  @override
  Future<void> refreshHardwareDiagnostics() async {}

  @override
  Future<void> loadModel({
    required ResolvedModelAssets assets,
    required StudioSettings settings,
    required bool isWeb,
  }) async {}

  @override
  Future<void> loadCustomSource({
    required StudioModelDescriptor descriptor,
    required StudioSettings settings,
    required bool isWeb,
  }) async {}

  @override
  Future<void> unloadModel() async {}

  @override
  Stream<StudioTurnEvent> streamTurn(StudioTurnRequest request) async* {
    lastRequest = request;
    for (final event in nextEvents) {
      yield event;
    }
  }

  @override
  void cancelGeneration() {}

  @override
  Future<void> dispose() => _runtime.dispose();
}

class UnloadedThenReadyInferencePort implements StudioInferencePort {
  UnloadedThenReadyInferencePort({this.refuseLoad = false});

  final bool refuseLoad;
  final StateStore<StudioRuntimeSnapshot> _runtime =
      StateStore<StudioRuntimeSnapshot>(const StudioRuntimeSnapshot());

  @override
  ReadOnlyStore<StudioRuntimeSnapshot> get runtimeStore => _runtime;

  @override
  Future<void> refreshHardwareDiagnostics() async {}

  @override
  Future<void> loadModel({
    required ResolvedModelAssets assets,
    required StudioSettings settings,
    required bool isWeb,
  }) async {
    if (refuseLoad) {
      throw LlamaStateException('Refused load');
    }
    _runtime.set(
      StudioRuntimeSnapshot(
        phase: StudioEnginePhase.ready,
        activeDescriptor: assets.descriptor,
        activeModelLabel: assets.descriptor.name,
        backendName: 'Metal',
      ),
    );
  }

  @override
  Future<void> loadCustomSource({
    required StudioModelDescriptor descriptor,
    required StudioSettings settings,
    required bool isWeb,
  }) async {}

  @override
  Future<void> unloadModel() async {
    _runtime.set(const StudioRuntimeSnapshot());
  }

  @override
  Stream<StudioTurnEvent> streamTurn(StudioTurnRequest request) async* {
    if (!_runtime.state.isReady) {
      throw LlamaStateException(
        'Load a model in Model Hub before sending a message.',
      );
    }
    yield const StudioTextDeltaEvent('Auto-loaded answer!');
    yield const StudioTurnCompletedEvent(
      StudioTurnResult(
        text: 'Auto-loaded answer!',
        metrics: StudioTurnMetrics(
          generatedTokens: 4,
          elapsedMs: 25,
          decodeElapsedMs: 20,
        ),
      ),
    );
  }

  @override
  void cancelGeneration() {}

  @override
  Future<void> dispose() => _runtime.dispose();
}

class DummySpeechPort implements StudioSpeechPort {
  @override
  Future<TextToSpeechCapabilities> loadTtsModel({
    required ResolvedModelAssets assets,
    required bool isWeb,
  }) async => const TextToSpeechCapabilities(isSupported: true);

  @override
  Future<SpeechToTextCapabilities> loadSttModel({
    required ResolvedModelAssets assets,
    required bool isWeb,
  }) async => const SpeechToTextCapabilities(isSupported: true);

  @override
  Future<StudioSynthesizedClip> synthesize({
    required String text,
    required bool isWeb,
    String? language,
    String? voice,
    Uint8List? speakerReferenceBytes,
    String? speakerReferencePath,
    double temperature = 0.8,
    void Function(int framesGenerated, TextToSpeechProgressPhase phase)?
    onProgress,
  }) async => StudioSynthesizedClip(
    wavBytes: Uint8List.fromList(<int>[82, 73, 70, 70]),
    duration: const Duration(milliseconds: 250),
    sampleRateHz: 24000,
    framesGenerated: 12,
  );

  @override
  void cancelSynthesis() {}

  @override
  Future<StudioTranscriptResult> transcribe({
    Uint8List? audioBytes,
    String? audioFilePath,
    String? contextPrompt,
  }) async => const StudioTranscriptResult(text: '', elapsedMs: 1);

  @override
  Future<void> dispose() async {}
}

class MockAsrSpeechPort implements StudioSttPort {
  @override
  Future<SpeechToTextCapabilities> loadSttModel({
    required ResolvedModelAssets assets,
    required bool isWeb,
  }) async => const SpeechToTextCapabilities(isSupported: true);

  @override
  Future<StudioTranscriptResult> transcribe({
    Uint8List? audioBytes,
    String? audioFilePath,
    String? contextPrompt,
  }) async {
    return const StudioTranscriptResult(
      text: 'Voice note recommends Q8_0 KV cache on Metal.',
      elapsedMs: 14,
      detectedLanguage: 'en',
    );
  }

  @override
  Future<void> dispose() async {}
}

class DummyPlaygroundPort implements StudioPlaygroundPort {
  @override
  Future<void> loadDedicatedModel({
    required ResolvedModelAssets assets,
    required bool isWeb,
  }) async {}

  @override
  Future<EmbeddingCapabilityInfo> probeEmbeddingCapabilities() async =>
      const EmbeddingCapabilityInfo();

  @override
  Future<EmbeddingComparisonResult> computeEmbeddings(
    List<String> texts,
  ) async => EmbeddingComparisonResult(
    texts: texts,
    dimensions: 3,
    similarityMatrix: List<List<double>>.generate(
      texts.length,
      (int r) =>
          List<double>.generate(texts.length, (int c) => r == c ? 1.0 : 0.0),
    ),
    elapsedMs: 1,
  );

  @override
  Future<EmbeddedPassageResult> embedDocuments(
    List<String> documents, {
    List<String?>? titles,
  }) async => EmbeddedPassageResult(
    texts: documents,
    dimensions: 3,
    vectors: List<List<double>>.filled(documents.length, const <double>[
      1.0,
      0.0,
      0.0,
    ]),
    elapsedMs: 1,
  );

  @override
  Future<NoteEmbeddingVectorResult> embedNoteContent(
    NoteEmbeddingInput input,
  ) async => const NoteEmbeddingVectorResult(
    vector: <double>[1.0, 0.0, 0.0],
    dimensions: 3,
    elapsedMs: 1,
    usedMultimodal: false,
  );

  @override
  Future<EmbeddedQueryResult> embedQuery(String query) async =>
      EmbeddedQueryResult(
        query: query,
        dimensions: 3,
        vector: const <double>[1.0, 0.0, 0.0],
        elapsedMs: 1,
      );

  @override
  Future<List<RankedDocumentItem>> rerank({
    required String query,
    required List<String> documents,
  }) async => <RankedDocumentItem>[
    for (var i = 0; i < documents.length; i++)
      RankedDocumentItem(
        originalIndex: i,
        document: documents[i],
        score: 1.0 - (i * 0.1),
      ),
  ];

  @override
  Future<SystemOneEvaluation> evaluateSystemOne({
    required String stateText,
    required String yesNoQuestion,
  }) async => SystemOneEvaluation(
    question: yesNoQuestion,
    probabilityTrue: 0.5,
    confidence: 0.5,
    elapsedMs: 1,
    deviceName: 'CPU',
  );

  @override
  Future<SystemOneBatchEvaluation> evaluateSystemOneBatch({
    required Object state,
    required List<SystemOneQuestionSpec> questions,
  }) async => const SystemOneBatchEvaluation(
    answers: <SystemOneQuestionAnswer>[],
    elapsedMs: 1,
    deviceName: 'CPU',
  );

  @override
  Future<DecisionBenchmarkSummary> runDecisionSpeedBenchmark({
    required Object state,
    required List<SystemOneQuestionSpec> questions,
    int iterations = 15,
    bool compareWithActiveChatLlm = false,
  }) async => DecisionBenchmarkSummary(
    iterations: iterations,
    questionsPerPass: questions.length,
    totalElapsedMs: iterations,
    minMs: 1,
    medianMs: 1,
    p95Ms: 1,
    deviceName: 'CPU',
  );

  @override
  Future<List<InspectedToken>> inspectTokens(String text) async =>
      const <InspectedToken>[];

  @override
  Future<BenchmarkRunSummary> runBenchmark({
    int targetDecodeTokens = 64,
  }) async => BenchmarkRunSummary(
    modelName: 'Dummy',
    backendName: 'CPU',
    promptTokens: 32,
    generatedTokens: targetDecodeTokens,
    prefillLatencyMs: 10,
    decodeElapsedMs: 100,
  );

  @override
  Future<void> dispose() async {}
}

class FakeSpeculativeFallbackBackend implements LlamaBackend {
  final List<bool> recordedSpeculativeFlags = <bool>[];
  bool _ready = false;

  @override
  bool get isReady => _ready;

  @override
  bool get supportsUrlLoading => false;

  @override
  Future<int> modelLoad(String path, ModelParams params) async {
    _ready = true;
    return 1;
  }

  @override
  Future<int> modelLoadFromUrl(
    String url,
    ModelParams params, {
    void Function(double progress)? onProgress,
  }) => modelLoad(url, params);

  @override
  Future<void> modelFree(int modelHandle) async => _ready = false;

  @override
  Future<int> contextCreate(int modelHandle, ModelParams params) async => 2;

  @override
  Future<void> contextFree(int contextHandle) async {}

  @override
  Future<int> getContextSize(int contextHandle) async => 4096;

  @override
  Stream<List<int>> generate(
    int contextHandle,
    String prompt,
    GenerationParams params, {
    List<LlamaContentPart>? parts,
  }) async* {
    recordedSpeculativeFlags.add(params.speculativeDecoding);
    if (params.speculativeDecoding) {
      throw LlamaUnsupportedException(
        'Bundled MTP speculative decoding requires the model to be loaded with loadMtp.',
      );
    }
    yield utf8.encode('hello');
  }

  @override
  void cancelGeneration() {}

  @override
  Future<List<int>> tokenize(
    int modelHandle,
    String text, {
    bool addSpecial = true,
  }) async => <int>[1, 2, 3];

  @override
  Future<String> detokenize(
    int modelHandle,
    List<int> tokens, {
    bool special = false,
  }) async => '';

  @override
  Future<Map<String, String>> modelMetadata(int modelHandle) async =>
      const <String, String>{'general.architecture': 'gemma4'};

  @override
  Future<String> getBackendName() async => 'Metal';

  @override
  Future<bool> isGpuSupported() async => true;

  @override
  Future<void> setLogLevel(LlamaLogLevel level) async {}

  @override
  Future<void> dispose() async => _ready = false;

  @override
  Future<({int total, int free})> getVramInfo() async =>
      (total: 16 * 1024 * 1024 * 1024, free: 12 * 1024 * 1024 * 1024);

  @override
  Future<String> applyChatTemplate(
    int modelHandle,
    List<Map<String, dynamic>> messages, {
    String? customTemplate,
    bool addAssistant = true,
  }) async => 'user: hi\nassistant:';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeStudioStoragePort implements StudioModelStoragePort {
  final StreamController<StudioModelDownloadProgress> _progress =
      StreamController<StudioModelDownloadProgress>.broadcast();

  @override
  Stream<StudioModelDownloadProgress> get progressStream => _progress.stream;

  @override
  List<StudioModelDescriptor> get discoveredLocalModels =>
      const <StudioModelDescriptor>[];

  @override
  int get discoveredLocalBytes => 0;

  @override
  Future<List<StudioModelDescriptor>> refreshLocalModels({
    List<String> extraDirectories = const <String>[],
  }) async => const <StudioModelDescriptor>[];

  @override
  Future<List<ModelCacheEntry>> listCachedEntries() async =>
      const <ModelCacheEntry>[];

  @override
  Future<bool> isCached(
    StudioModelDescriptor descriptor, {
    required bool isWeb,
  }) async => true;

  @override
  Future<ResolvedModelAssets> ensureDownloaded(
    StudioModelDescriptor descriptor, {
    required bool isWeb,
    String? bearerToken,
  }) async => ResolvedModelAssets(
    descriptor: descriptor,
    primarySource: ModelSource.parse(descriptor.sourceUri),
  );

  @override
  void cancelDownload(String modelId) {}

  @override
  Future<void> removeCachedModel(
    StudioModelDescriptor descriptor, {
    required bool isWeb,
  }) async {}

  @override
  Future<void> removeCacheEntry(String cacheKey) async {}

  @override
  Future<List<ModelCacheEntry>> pruneCache({
    Duration? maxAge,
    int? maxBytes,
  }) async => const <ModelCacheEntry>[];

  @override
  Future<void> dispose() => _progress.close();
}

class MockNoteAndDecisionPlaygroundPort implements StudioPlaygroundPort {
  int multimodalEmbedCalls = 0;

  @override
  Future<void> loadDedicatedModel({
    required ResolvedModelAssets assets,
    required bool isWeb,
  }) async {}

  @override
  Future<EmbeddingCapabilityInfo> probeEmbeddingCapabilities() async =>
      const EmbeddingCapabilityInfo(
        supportsText: true,
        supportsImage: true,
        supportsAudio: true,
        isReady: true,
      );

  List<double> _vectorFor(String text) {
    final lower = text.toLowerCase();
    final kvScore =
        (lower.contains('kv') ||
            lower.contains('halve') ||
            lower.contains('memory'))
        ? 0.98
        : 0.1;
    final metalScore =
        (lower.contains('metal') ||
            lower.contains('half') ||
            lower.contains('halve'))
        ? 0.95
        : 0.05;
    return <double>[kvScore, metalScore, 0.25];
  }

  @override
  Future<EmbeddingComparisonResult> computeEmbeddings(
    List<String> texts,
  ) async {
    return EmbeddingComparisonResult(
      texts: texts,
      dimensions: 3,
      similarityMatrix: List<List<double>>.generate(
        texts.length,
        (int r) =>
            List<double>.generate(texts.length, (int c) => r == c ? 1.0 : 0.5),
      ),
      elapsedMs: 5,
    );
  }

  @override
  Future<EmbeddedPassageResult> embedDocuments(
    List<String> documents, {
    List<String?>? titles,
  }) async {
    return EmbeddedPassageResult(
      texts: documents,
      dimensions: 3,
      vectors: <List<double>>[
        for (var i = 0; i < documents.length; i++)
          _vectorFor(
            '${titles != null && i < titles.length ? titles[i] ?? '' : ''} ${documents[i]}',
          ),
      ],
      elapsedMs: 7,
    );
  }

  @override
  Future<NoteEmbeddingVectorResult> embedNoteContent(
    NoteEmbeddingInput input,
  ) async {
    final hasMedia =
        (input.imageBytes != null && input.imageBytes!.isNotEmpty) ||
        (input.audioWavBytes != null && input.audioWavBytes!.isNotEmpty);
    if (hasMedia) {
      multimodalEmbedCalls++;
    }
    return NoteEmbeddingVectorResult(
      vector: _vectorFor('${input.title ?? ''} ${input.text}'),
      dimensions: 3,
      elapsedMs: 6,
      usedMultimodal: hasMedia,
    );
  }

  @override
  Future<EmbeddedQueryResult> embedQuery(String query) async {
    return EmbeddedQueryResult(
      query: query,
      dimensions: 3,
      vector: _vectorFor(query),
      elapsedMs: 3,
    );
  }

  @override
  Future<List<RankedDocumentItem>> rerank({
    required String query,
    required List<String> documents,
  }) async {
    final scored =
        <RankedDocumentItem>[
          for (var i = 0; i < documents.length; i++)
            RankedDocumentItem(
              originalIndex: i,
              document: documents[i],
              score:
                  (documents[i].toLowerCase().contains('half') ||
                      documents[i].toLowerCase().contains('halve') ||
                      documents[i].toLowerCase().contains('metal kv'))
                  ? 0.99
                  : (documents[i].toLowerCase().contains('kv') ? 0.65 : 0.25),
            ),
        ]..sort(
          (RankedDocumentItem a, RankedDocumentItem b) =>
              b.score.compareTo(a.score),
        );
    return scored;
  }

  @override
  Future<SystemOneEvaluation> evaluateSystemOne({
    required String stateText,
    required String yesNoQuestion,
  }) async => SystemOneEvaluation(
    question: yesNoQuestion,
    probabilityTrue: 0.9,
    confidence: 0.85,
    elapsedMs: 4,
    deviceName: 'CPU',
  );

  @override
  Future<SystemOneBatchEvaluation> evaluateSystemOneBatch({
    required Object state,
    required List<SystemOneQuestionSpec> questions,
  }) async {
    return SystemOneBatchEvaluation(
      answers: <SystemOneQuestionAnswer>[
        for (final q in questions)
          switch (q) {
            SystemOneChoiceQuestionSpec(
              :final id,
              :final prompt,
              :final labels,
            ) =>
              SystemOneChoiceAnswer(
                id: id,
                prompt: prompt,
                confidence: 0.9,
                choice: labels.first,
                probabilities: <String, double>{labels.first: 0.9},
              ),
            SystemOneScoreQuestionSpec(
              :final id,
              :final prompt,
              :final levels,
            ) =>
              SystemOneScoreAnswer(
                id: id,
                prompt: prompt,
                confidence: 0.88,
                score: levels.length >= 4 ? 4.0 : 2.0,
                levels: levels,
                levelProbabilities: <String, double>{levels.last: 0.8},
              ),
            SystemOneNoulQuestionSpec(:final id, :final prompt) =>
              SystemOneNoulAnswer(
                id: id,
                prompt: prompt,
                confidence: 0.86,
                probabilityTrue: 0.78,
              ),
          },
      ],
      elapsedMs: 6,
      deviceName: 'CPU',
    );
  }

  @override
  Future<DecisionBenchmarkSummary> runDecisionSpeedBenchmark({
    required Object state,
    required List<SystemOneQuestionSpec> questions,
    int iterations = 15,
    bool compareWithActiveChatLlm = false,
  }) async {
    return DecisionBenchmarkSummary(
      iterations: iterations,
      questionsPerPass: questions.length,
      totalElapsedMs: iterations * 4,
      minMs: 3,
      medianMs: 4,
      p95Ms: 6,
      deviceName: 'Metal',
      llmCompareElapsedMs: compareWithActiveChatLlm ? 420 : null,
      llmCompareModelName: compareWithActiveChatLlm ? 'Fake Qwen 0.8B' : null,
      llmCompareSummary: compareWithActiveChatLlm
          ? '{"domain":"coding_repo"}'
          : null,
    );
  }

  @override
  Future<List<InspectedToken>> inspectTokens(String text) async =>
      const <InspectedToken>[];

  @override
  Future<BenchmarkRunSummary> runBenchmark({
    int targetDecodeTokens = 64,
  }) async => BenchmarkRunSummary(
    modelName: 'Mock Playground',
    backendName: 'Metal',
    promptTokens: 64,
    generatedTokens: targetDecodeTokens,
    prefillLatencyMs: 12,
    decodeElapsedMs: 120,
  );

  @override
  Future<void> dispose() async {}
}

class FakeConnectedMcpManager extends McpManager {
  FakeConnectedMcpManager({required super.keyValueStore});

  @override
  List<ToolDefinition> buildActiveToolDefinitions() {
    return <ToolDefinition>[
      ToolDefinition(
        name: 'mcp_lookup',
        description: 'Mock external MCP lookup tool',
        parameters: const <ToolParam>[],
        handler: (_) async => 'ok',
      ),
    ];
  }
}

class CountingMockImagePort implements StudioImagePort {
  int _counter = 0;

  @override
  Future<ImageGenerationCapabilities> checkRuntime() async =>
      const ImageGenerationCapabilities(isSupported: true);

  @override
  Future<ImageGenerationCapabilities> loadModel({
    required ResolvedModelAssets assets,
    ComputeDevice device = ComputeDevice.auto,
  }) async => const ImageGenerationCapabilities(isSupported: true);

  @override
  Future<StudioGeneratedImageItem> generateImage({
    required String prompt,
    String negativePrompt = '',
    int width = 512,
    int height = 512,
    int steps = 1,
    double guidanceScale = 1.0,
    int? seed,
    void Function(ImageGenerationProgressEvent event)? onProgress,
  }) async {
    _counter++;
    return StudioGeneratedImageItem(
      id: 'img_$_counter',
      prompt: prompt,
      negativePrompt: negativePrompt,
      pngBytes: Uint8List.fromList(<int>[137, 80, 78, 71]),
      width: width,
      height: height,
      steps: steps,
      guidanceScale: guidanceScale,
      seed: seed ?? _counter,
      elapsedMs: 20,
      modelName: 'SDXS-512',
      createdAt: DateTime.utc(2026, 1, 1),
    );
  }

  @override
  void cancelGeneration() {}

  @override
  Future<void> dispose() async {}
}

class CountingMockTtsSpeechPort implements StudioTtsPort {
  @override
  Future<TextToSpeechCapabilities> loadTtsModel({
    required ResolvedModelAssets assets,
    required bool isWeb,
  }) async => const TextToSpeechCapabilities(isSupported: true);

  @override
  Future<StudioSynthesizedClip> synthesize({
    required String text,
    required bool isWeb,
    String? language,
    String? voice,
    Uint8List? speakerReferenceBytes,
    String? speakerReferencePath,
    double temperature = 0.8,
    void Function(int framesGenerated, TextToSpeechProgressPhase phase)?
    onProgress,
  }) async {
    return StudioSynthesizedClip(
      wavBytes: Uint8List.fromList(<int>[82, 73, 70, 70]),
      duration: const Duration(milliseconds: 500),
      sampleRateHz: 24000,
      framesGenerated: 24,
    );
  }

  @override
  void cancelSynthesis() {}

  @override
  Future<void> dispose() async {}
}
