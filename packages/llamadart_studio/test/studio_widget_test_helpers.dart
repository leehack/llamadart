import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio/llamadart_studio.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

class FakeStoragePort implements StudioModelStoragePort {
  final StreamController<StudioModelDownloadProgress> _progress =
      StreamController<StudioModelDownloadProgress>.broadcast();

  static const List<StudioModelDescriptor> _sampleLocal =
      <StudioModelDescriptor>[
        StudioModelDescriptor(
          id: 'local:qwen3-5-2b-q4-k-m-gguf',
          name: 'Qwen3.5 2B (Q4_K_M)',
          publisher: 'Local · ~/Library/Caches/llamadart/models',
          description: 'Local GGUF model discovered on disk.',
          category: StudioModelCategory.chat,
          filename: 'Qwen3.5-2B-Q4_K_M.gguf',
          sourceUri: '/tmp/Qwen3.5-2B-Q4_K_M.gguf',
          sizeBytes: 1280 * 1024 * 1024,
          supportsToolCalling: true,
          supportsThinking: true,
          quantizationLabel: 'Q4_K_M',
        ),
      ];

  @override
  Stream<StudioModelDownloadProgress> get progressStream => _progress.stream;

  @override
  List<StudioModelDescriptor> get discoveredLocalModels => _sampleLocal;

  @override
  int get discoveredLocalBytes => 1280 * 1024 * 1024;

  @override
  Future<List<StudioModelDescriptor>> refreshLocalModels({
    List<String> extraDirectories = const <String>[],
  }) async => _sampleLocal;

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
  }) async {
    return ResolvedModelAssets(
      descriptor: descriptor,
      primarySource: ModelSource.parse('/tmp/${descriptor.filename}'),
    );
  }

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

class FakeInferencePort implements StudioInferencePort {
  final StateStore<StudioRuntimeSnapshot> _runtime =
      StateStore<StudioRuntimeSnapshot>(
        const StudioRuntimeSnapshot(
          phase: StudioEnginePhase.ready,
          activeModelLabel: 'Qwen3 4B Instruct (Q4_K_M)',
          backendName: 'Metal',
          vramTotalBytes: 16 * 1024 * 1024 * 1024,
          vramFreeBytes: 12 * 1024 * 1024 * 1024,
        ),
      );

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
    _runtime.set(
      _runtime.state.copyWith(
        phase: StudioEnginePhase.ready,
        activeDescriptor: assets.descriptor,
        activeModelLabel: assets.descriptor.name,
        loadedEngineSignature: settings.engineLoadSignature(isWeb: isWeb),
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
    _runtime.set(
      _runtime.state.copyWith(
        phase: StudioEnginePhase.unloaded,
        clearActiveDescriptor: true,
        clearActiveModelLabel: true,
        clearLoadedEngineSignature: true,
      ),
    );
  }

  @override
  Stream<StudioTurnEvent> streamTurn(StudioTurnRequest request) {
    final prompt = request.history.last.text;
    final answer = 'Reply to: $prompt';
    return Stream<StudioTurnEvent>.fromIterable(<StudioTurnEvent>[
      const StudioThinkingDeltaEvent('Checking context and tools...'),
      const StudioToolInvocationEvent(
        StudioToolInvocation(
          id: 'call_1',
          name: 'getWeather',
          argumentsJson: '{"city":"Seoul"}',
          resultJson: '{"temperature":19,"unit":"celsius"}',
          durationMs: 4,
        ),
      ),
      StudioTextDeltaEvent(answer),
      StudioTurnCompletedEvent(
        StudioTurnResult(
          text: answer,
          thinkingText: 'Checking context and tools...',
          thinkingDurationMs: 12,
          toolInvocations: const <StudioToolInvocation>[
            StudioToolInvocation(
              id: 'call_1',
              name: 'getWeather',
              argumentsJson: '{"city":"Seoul"}',
              resultJson: '{"temperature":19,"unit":"celsius"}',
              durationMs: 4,
            ),
          ],
          metrics: const StudioTurnMetrics(
            generatedTokens: 18,
            elapsedMs: 120,
            decodeElapsedMs: 100,
            firstTokenLatencyMs: 20,
            modelName: 'Qwen3 4B',
            backendLabel: 'Metal',
          ),
        ),
      ),
    ]);
  }

  @override
  void cancelGeneration() {}

  @override
  Future<void> dispose() => _runtime.dispose();
}

class FakeSpeechPort implements StudioSpeechPort {
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
  }) async {
    return StudioSynthesizedClip(
      wavBytes: Uint8List(44),
      duration: const Duration(seconds: 2),
      sampleRateHz: 24000,
      framesGenerated: 25,
    );
  }

  @override
  void cancelSynthesis() {}

  @override
  Future<StudioTranscriptResult> transcribe({
    Uint8List? audioBytes,
    String? audioFilePath,
    String? contextPrompt,
  }) async {
    return const StudioTranscriptResult(text: 'Hello Studio', elapsedMs: 32);
  }

  @override
  Future<void> dispose() async {}
}

class FakeImagePort implements StudioImagePort {
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
    return StudioGeneratedImageItem(
      id: 'img_1',
      prompt: prompt,
      negativePrompt: negativePrompt,
      pngBytes: base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      ),
      width: width,
      height: height,
      steps: steps,
      guidanceScale: guidanceScale,
      seed: seed ?? 42,
      elapsedMs: 220,
      modelName: 'SDXS-512',
      createdAt: DateTime.utc(2026),
    );
  }

  @override
  void cancelGeneration() {}

  @override
  Future<void> dispose() async {}
}

class FakePlaygroundPort implements StudioPlaygroundPort {
  @override
  Future<void> loadDedicatedModel({
    required ResolvedModelAssets assets,
    required bool isWeb,
  }) async {}

  @override
  Future<EmbeddingComparisonResult> computeEmbeddings(
    List<String> texts,
  ) async {
    return EmbeddingComparisonResult(
      texts: texts,
      dimensions: 384,
      similarityMatrix: List<List<double>>.generate(
        texts.length,
        (int r) =>
            List<double>.generate(texts.length, (int c) => r == c ? 1.0 : 0.72),
      ),
      elapsedMs: 14,
    );
  }

  List<double> _fakeVectorFor(String text) {
    final lower = text.toLowerCase();
    final hasKv =
        lower.contains('kv') ||
        lower.contains('memory') ||
        lower.contains('context');
    final hasAudio =
        lower.contains('audio') ||
        lower.contains('speech') ||
        lower.contains('tts');
    final hasCode =
        lower.contains('dart') ||
        lower.contains('code') ||
        lower.contains('coding');
    return <double>[
      hasKv ? 0.95 : 0.15,
      hasAudio ? 0.95 : 0.15,
      hasCode ? 0.95 : 0.15,
      0.2,
    ];
  }

  @override
  Future<EmbeddedPassageResult> embedDocuments(
    List<String> documents, {
    List<String?>? titles,
  }) async {
    return EmbeddedPassageResult(
      texts: documents,
      dimensions: 4,
      vectors: <List<double>>[
        for (var i = 0; i < documents.length; i++)
          _fakeVectorFor(
            '${titles != null && i < titles.length ? titles[i] ?? '' : ''} ${documents[i]}',
          ),
      ],
      elapsedMs: 12,
    );
  }

  @override
  Future<EmbeddedQueryResult> embedQuery(String query) async {
    return EmbeddedQueryResult(
      query: query,
      dimensions: 4,
      vector: _fakeVectorFor(query),
      elapsedMs: 6,
    );
  }

  @override
  Future<List<RankedDocumentItem>> rerank({
    required String query,
    required List<String> documents,
  }) async {
    return <RankedDocumentItem>[
      for (var i = 0; i < documents.length; i++)
        RankedDocumentItem(
          originalIndex: i,
          document: documents[i],
          score: 0.9 - (i * 0.2),
        ),
    ];
  }

  @override
  Future<SystemOneEvaluation> evaluateSystemOne({
    required String stateText,
    required String yesNoQuestion,
  }) async {
    return SystemOneEvaluation(
      question: yesNoQuestion,
      probabilityTrue: 0.91,
      confidence: 0.88,
      elapsedMs: 8,
      deviceName: 'Metal',
    );
  }

  @override
  Future<SystemOneBatchEvaluation> evaluateSystemOneBatch({
    required Object state,
    required List<SystemOneQuestionSpec> questions,
  }) async {
    final answers = <SystemOneQuestionAnswer>[
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
              confidence: 0.89,
              choice: labels.first,
              probabilities: <String, double>{
                for (var i = 0; i < labels.length; i++)
                  labels[i]: i == 0
                      ? 0.72
                      : 0.28 / (labels.length - 1).clamp(1, 99),
              },
            ),
          SystemOneScoreQuestionSpec(:final id, :final prompt, :final levels) =>
            SystemOneScoreAnswer(
              id: id,
              prompt: prompt,
              confidence: 0.85,
              score: levels.length >= 4 ? 4.2 : 2.0,
              levels: levels,
              levelProbabilities: <String, double>{
                for (var i = 0; i < levels.length; i++)
                  levels[i]: i == levels.length - 1
                      ? 0.65
                      : 0.35 / (levels.length - 1).clamp(1, 99),
              },
            ),
          SystemOneNoulQuestionSpec(:final id, :final prompt) =>
            SystemOneNoulAnswer(
              id: id,
              prompt: prompt,
              confidence: 0.87,
              probabilityTrue: 0.82,
            ),
        },
    ];
    return SystemOneBatchEvaluation(
      answers: answers,
      elapsedMs: 9,
      deviceName: 'CPU',
    );
  }

  @override
  Future<EmbeddingCapabilityInfo> probeEmbeddingCapabilities() async =>
      const EmbeddingCapabilityInfo(
        supportsText: true,
        supportsImage: true,
        supportsAudio: true,
        isReady: true,
      );

  @override
  Future<NoteEmbeddingVectorResult> embedNoteContent(
    NoteEmbeddingInput input,
  ) async {
    final hasMedia =
        (input.imageBytes != null && input.imageBytes!.isNotEmpty) ||
        (input.audioWavBytes != null && input.audioWavBytes!.isNotEmpty);
    return NoteEmbeddingVectorResult(
      vector: _fakeVectorFor('${input.title ?? ''} ${input.text}'),
      dimensions: 4,
      elapsedMs: 9,
      usedMultimodal: hasMedia,
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
      llmCompareElapsedMs: compareWithActiveChatLlm ? 460 : null,
      llmCompareModelName: compareWithActiveChatLlm ? 'Qwen3 4B' : null,
      llmCompareSummary: compareWithActiveChatLlm
          ? '{"domain":"coding_repo","needs_tools":true}'
          : null,
    );
  }

  @override
  Future<List<InspectedToken>> inspectTokens(String text) async {
    return const <InspectedToken>[
      InspectedToken(id: 101, piece: 'llama'),
      InspectedToken(id: 102, piece: 'dart'),
    ];
  }

  @override
  Future<BenchmarkRunSummary> runBenchmark({
    int targetDecodeTokens = 64,
  }) async {
    return const BenchmarkRunSummary(
      modelName: 'Qwen3 4B',
      backendName: 'Metal',
      promptTokens: 64,
      generatedTokens: 64,
      prefillLatencyMs: 28,
      decodeElapsedMs: 520,
    );
  }

  @override
  Future<void> dispose() async {}
}

Future<StudioDependencies> buildTestDeps({
  Map<String, Object>? kvSeed,
  StudioModelStoragePort? storagePort,
  StudioInferencePort? inferencePort,
}) {
  final kv = InMemoryKeyValueStore(kvSeed);
  return StudioDependencies.fromPorts(
    keyValueStore: kv,
    conversationStore: KeyValueConversationStore(kv),
    mcpManager: McpManager(
      keyValueStore: kv,
      transportBuilder: (_) =>
          throw StateError('No live MCP transport in widget tests'),
    ),
    storagePort: storagePort ?? FakeStoragePort(),
    inferencePort: inferencePort ?? FakeInferencePort(),
    speechPort: FakeSpeechPort(),
    imagePort: FakeImagePort(),
    playgroundPort: FakePlaygroundPort(),
  );
}

class EmptyCacheStoragePort extends FakeStoragePort {
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
  Future<bool> isCached(
    StudioModelDescriptor descriptor, {
    required bool isWeb,
  }) async => false;
}

class ControllableDownloadStoragePort extends FakeStoragePort {
  final List<String> cancelledModelIds = <String>[];
  Completer<ResolvedModelAssets>? _downloadCompleter;

  void emitProgress(StudioModelDownloadProgress event) {
    _progress.add(event);
  }

  @override
  Future<bool> isCached(
    StudioModelDescriptor descriptor, {
    required bool isWeb,
  }) async => false;

  @override
  Future<ResolvedModelAssets> ensureDownloaded(
    StudioModelDescriptor descriptor, {
    required bool isWeb,
    String? bearerToken,
  }) {
    final completer = Completer<ResolvedModelAssets>();
    _downloadCompleter = completer;
    return completer.future;
  }

  @override
  void cancelDownload(String modelId) {
    cancelledModelIds.add(modelId);
    final completer = _downloadCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(
        LlamaStateException('Download cancelled by user.'),
      );
    }
  }
}

class ControllableStreamingInferencePort extends FakeInferencePort {
  bool manualMode = false;
  StreamController<StudioTurnEvent>? _activeController;

  void emit(StudioTurnEvent event) {
    _activeController?.add(event);
  }

  void complete({required String finalText, String? thinkingText}) {
    _activeController?.add(
      StudioTurnCompletedEvent(
        StudioTurnResult(
          text: finalText,
          thinkingText: thinkingText,
          thinkingDurationMs: 420,
          metrics: const StudioTurnMetrics(
            generatedTokens: 60,
            elapsedMs: 500,
            decodeElapsedMs: 450,
            firstTokenLatencyMs: 50,
            modelName: 'Qwen3.5 0.8B',
            backendLabel: 'Metal',
          ),
        ),
      ),
    );
    _activeController?.close();
    _activeController = null;
  }

  @override
  Stream<StudioTurnEvent> streamTurn(StudioTurnRequest request) {
    if (!manualMode) {
      final answer =
          'Seed reply for: ${request.history.last.text}\nExtra paragraph 1\nExtra paragraph 2\nExtra paragraph 3';
      return Stream<StudioTurnEvent>.fromIterable(<StudioTurnEvent>[
        StudioTextDeltaEvent(answer),
        StudioTurnCompletedEvent(
          StudioTurnResult(
            text: answer,
            metrics: const StudioTurnMetrics(
              generatedTokens: 24,
              elapsedMs: 60,
              decodeElapsedMs: 50,
            ),
          ),
        ),
      ]);
    }
    final ctrl = StreamController<StudioTurnEvent>();
    _activeController = ctrl;
    return ctrl.stream;
  }
}
