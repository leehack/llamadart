import 'dart:math' as math;

import 'package:llamadart/llamadart.dart';

import '../../domain/studio_model_descriptor.dart';
import '../../ports/engine_lease_port.dart';
import '../../ports/model_storage_port.dart';
import '../../ports/playground_port.dart';

part 'direct_llama_playground_helpers.dart';

/// Production [StudioPlaygroundPort] integrating [LlamaTextEmbedder],
/// [LlamaReranker], [DecisionEngine], tokenization, and throughput benchmarks.
class DirectLlamaPlaygroundPort implements StudioPlaygroundPort {
  /// Creates a [DirectLlamaPlaygroundPort].
  ///
  /// When [sharedChatPort] is provided, token inspection, benchmarking, and
  /// fallback embeddings can reuse the already-loaded chat [LlamaEngine]
  /// without allocating a second model in memory.
  DirectLlamaPlaygroundPort({SharedLlamaEngineProvider? sharedChatPort})
    : _sharedChatPort = sharedChatPort;

  final SharedLlamaEngineProvider? _sharedChatPort;

  LlamaEngine? _embeddingEngine;
  LlamaEmbeddingProfile _embeddingProfile = LlamaEmbeddingProfile.raw;
  LlamaReranker? _reranker;
  DecisionEngine? _decisionEngine;

  @override
  Future<void> loadDedicatedModel({
    required ResolvedModelAssets assets,
    required bool isWeb,
  }) async {
    switch (assets.descriptor.specialty) {
      case StudioModelSpecialty.embedding:
        await _loadEmbeddingEngine(assets: assets, isWeb: isWeb);
      case StudioModelSpecialty.reranker:
        await _loadReranker(assets: assets);
      case StudioModelSpecialty.decision:
        await _loadDecisionEngine(assets: assets);
      case StudioModelSpecialty.generalChat:
      case StudioModelSpecialty.qwen3Asr:
      case StudioModelSpecialty.liteRtAsr:
      case StudioModelSpecialty.qwen3Tts:
      case StudioModelSpecialty.stableDiffusion:
        throw LlamaUnsupportedException(
          'Model "${assets.descriptor.name}" is not an Embedding, Reranker, or '
          'Decision model.',
        );
    }
  }

  Future<void> _loadEmbeddingEngine({
    required ResolvedModelAssets assets,
    required bool isWeb,
  }) async {
    await _embeddingEngine?.dispose();
    _embeddingEngine = null;
    final engine = LlamaEngine(LlamaBackend.withTextHistory());
    final ModelParams embedParams =
        assets.descriptor.format == ModelFormat.liteRtLm
        ? const LiteRtLmModelParams(
            contextSize: 2048,
            device: ComputeDevice.cpu,
            embeddingEngine: true,
          )
        : LlamaCppModelParams(
            contextSize: 2048,
            batchSize: 2048,
            microBatchSize: 2048,
            modelBytesHint: isWeb
                ? assets.descriptor.effectiveSizeBytes(isWeb: true)
                : null,
          );
    await engine.setModel(
      LlamaModel(
        assets.primarySource,
        projector: assets.companionSources['projector'],
      ),
      params: embedParams,
    );
    _embeddingEngine = engine;
    _embeddingProfile = assets.descriptor.embeddingProfile;
  }

  Future<void> _loadReranker({required ResolvedModelAssets assets}) async {
    await _reranker?.dispose();
    _reranker = await LlamaReranker.load(
      LlamaModel(assets.primarySource),
      params: const LlamaCppModelParams(
        contextSize: 2048,
        batchSize: 2048,
        microBatchSize: 2048,
      ),
    );
  }

  Future<void> _loadDecisionEngine({
    required ResolvedModelAssets assets,
  }) async {
    await _decisionEngine?.dispose();
    _decisionEngine = null;
    final head = assets.companionSources['decisionHead'];
    if (head == null) {
      throw LlamaArgumentException(
        'Decision model requires a decisionHead (.safetensors) companion.',
      );
    }
    _decisionEngine = await DecisionEngine.load(
      DecisionModel(encoder: assets.primarySource, head: head),
    );
  }

  @override
  Future<EmbeddingComparisonResult> computeEmbeddings(
    List<String> texts,
  ) async {
    final cleaned = texts
        .map((String s) => s.trim())
        .where((String s) => s.isNotEmpty)
        .toList(growable: false);
    if (cleaned.isEmpty) {
      throw LlamaArgumentException(
        'Enter at least one non-empty text passage to embed.',
      );
    }

    return _withEmbedEngine('Playground embeddings', (
      LlamaEngine engine,
      bool isDedicated,
    ) async {
      final embedder = LlamaTextEmbedder(
        engine,
        profile: isDedicated ? _embeddingProfile : LlamaEmbeddingProfile.raw,
        normalize: true,
      );
      final inputs = <LlamaEmbeddingText>[
        for (final item in cleaned)
          isDedicated &&
                  _embeddingProfile == LlamaEmbeddingProfile.embeddingGemma2
              ? LlamaEmbeddingText.query(
                  item,
                  task: LlamaEmbeddingTask.sentenceSimilarity,
                )
              : LlamaEmbeddingText.prepared(item),
      ];

      final watch = Stopwatch()..start();
      final vectors = await embedder.embedBatch(inputs);
      watch.stop();

      final count = vectors.length;
      final dims = vectors.first.length;
      final matrix = List<List<double>>.generate(
        count,
        (int i) => List<double>.generate(
          count,
          (int j) =>
              i == j ? 1.0 : _cosineSimilarityHelper(vectors[i], vectors[j]),
          growable: false,
        ),
        growable: false,
      );

      return EmbeddingComparisonResult(
        texts: cleaned,
        dimensions: dims,
        similarityMatrix: matrix,
        elapsedMs: watch.elapsedMilliseconds,
      );
    });
  }

  @override
  Future<EmbeddedPassageResult> embedDocuments(
    List<String> documents, {
    List<String?>? titles,
  }) async {
    final cleaned = <String>[];
    final cleanedTitles = <String?>[];
    for (var i = 0; i < documents.length; i++) {
      final text = documents[i].trim();
      if (text.isEmpty) {
        continue;
      }
      cleaned.add(text);
      final title = titles != null && i < titles.length
          ? titles[i]?.trim()
          : null;
      cleanedTitles.add((title == null || title.isEmpty) ? null : title);
    }
    if (cleaned.isEmpty) {
      throw LlamaArgumentException(
        'Provide at least one non-empty document to index.',
      );
    }

    return _withEmbedEngine('Notebook document indexing', (
      LlamaEngine engine,
      bool isDedicated,
    ) async {
      final profile = isDedicated
          ? _embeddingProfile
          : LlamaEmbeddingProfile.raw;
      final embedder = LlamaTextEmbedder(
        engine,
        profile: profile,
        normalize: true,
      );
      final inputs = <LlamaEmbeddingText>[
        for (var i = 0; i < cleaned.length; i++)
          profile == LlamaEmbeddingProfile.embeddingGemma2
              ? LlamaEmbeddingText.document(cleaned[i], title: cleanedTitles[i])
              : LlamaEmbeddingText.prepared(
                  cleanedTitles[i] == null
                      ? cleaned[i]
                      : '${cleanedTitles[i]}\n${cleaned[i]}',
                ),
      ];

      final watch = Stopwatch()..start();
      final vectors = await embedder.embedBatch(inputs);
      watch.stop();

      return EmbeddedPassageResult(
        texts: cleaned,
        dimensions: vectors.first.length,
        vectors: vectors
            .map((List<double> v) => List<double>.unmodifiable(v))
            .toList(growable: false),
        elapsedMs: watch.elapsedMilliseconds,
      );
    });
  }

  @override
  Future<EmbeddingCapabilityInfo> probeEmbeddingCapabilities() async {
    final dedicated = _embeddingEngine;
    if (dedicated != null && dedicated.isReady) {
      return _probeEngineCaps(dedicated);
    }
    final sharedPort = _sharedChatPort;
    if (sharedPort == null || !sharedPort.isEngineReady) {
      return const EmbeddingCapabilityInfo();
    }
    try {
      return await sharedPort.runExclusiveOnEngine(
        'Embedding capability probe',
        _probeEngineCaps,
      );
    } catch (_) {
      return const EmbeddingCapabilityInfo(isReady: true);
    }
  }

  Future<EmbeddingCapabilityInfo> _probeEngineCaps(LlamaEngine engine) async {
    try {
      final caps = await engine.embeddingCapabilities;
      return EmbeddingCapabilityInfo(
        supportsText: caps.text,
        supportsImage: caps.image,
        supportsAudio: caps.audio,
        isReady: true,
      );
    } catch (_) {
      return const EmbeddingCapabilityInfo(isReady: true);
    }
  }

  @override
  Future<NoteEmbeddingVectorResult> embedNoteContent(
    NoteEmbeddingInput input,
  ) async {
    final dedicatedReady = _embeddingEngine?.isReady ?? false;
    final sharedReady = _sharedChatPort?.isEngineReady ?? false;
    if (!dedicatedReady && !sharedReady) {
      throw LlamaStateException(
        'Load an Embedding model (such as EmbeddingGemma 2) first.',
      );
    }

    final hasImage = input.imageBytes != null && input.imageBytes!.isNotEmpty;
    final hasAudio =
        input.audioWavBytes != null && input.audioWavBytes!.isNotEmpty;
    final cleanText = input.text.trim();
    final cleanTitle = input.title?.trim();

    if (!hasImage &&
        !hasAudio &&
        cleanText.isEmpty &&
        (cleanTitle ?? '').isEmpty) {
      throw LlamaArgumentException('Note must contain text, image, or audio.');
    }

    final watch = Stopwatch()..start();

    if (hasImage || hasAudio) {
      try {
        final multimodalResult = await _withEmbedEngine(
          'Multimodal note indexing',
          (LlamaEngine engine, bool isDedicated) async {
            final caps = await engine.embeddingCapabilities;
            final canImage = !hasImage || caps.image;
            final canAudio = !hasAudio || caps.audio;
            if (!canImage || !canAudio) {
              return null;
            }
            final docBody = cleanText.isEmpty ? (cleanTitle ?? '') : cleanText;
            final formattedText = docBody.isEmpty
                ? ''
                : (isDedicated &&
                      _embeddingProfile ==
                          LlamaEmbeddingProfile.embeddingGemma2)
                ? 'title: ${(cleanTitle == null || cleanTitle.isEmpty) ? 'none' : cleanTitle} | text: $docBody'
                : <String>[
                    if (cleanTitle != null && cleanTitle.isNotEmpty) cleanTitle,
                    if (cleanText.isNotEmpty) cleanText,
                  ].join('\n');

            final parts = <LlamaContentPart>[
              if (formattedText.trim().isNotEmpty)
                LlamaTextContent(formattedText),
              if (hasImage) LlamaImageContent(bytes: input.imageBytes),
              if (hasAudio) LlamaAudioContent(bytes: input.audioWavBytes),
            ];
            final vec = await engine.embedContent(
              LlamaEmbeddingInput(parts),
              normalize: true,
            );
            watch.stop();
            return NoteEmbeddingVectorResult(
              vector: List<double>.unmodifiable(vec),
              dimensions: vec.length,
              elapsedMs: watch.elapsedMilliseconds,
              usedMultimodal: true,
            );
          },
        );
        if (multimodalResult != null) {
          return multimodalResult;
        }
      } on LlamaStateException {
        rethrow;
      } catch (_) {
        // Fall through to text embedding fallback when media fails or is unsupported.
      }
    }

    final fallbackDoc = cleanText.isEmpty
        ? (cleanTitle?.isNotEmpty == true ? cleanTitle! : 'Untitled note')
        : cleanText;
    final embedded = await embedDocuments(
      <String>[fallbackDoc],
      titles: <String?>[cleanTitle],
    );
    watch.stop();
    return NoteEmbeddingVectorResult(
      vector: embedded.vectors.first,
      dimensions: embedded.dimensions,
      elapsedMs: watch.elapsedMilliseconds,
      usedMultimodal: false,
    );
  }

  @override
  Future<EmbeddedQueryResult> embedQuery(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      throw LlamaArgumentException('Enter a non-empty search query.');
    }

    return _withEmbedEngine('Semantic note search', (
      LlamaEngine engine,
      bool isDedicated,
    ) async {
      final profile = isDedicated
          ? _embeddingProfile
          : LlamaEmbeddingProfile.raw;
      final embedder = LlamaTextEmbedder(
        engine,
        profile: profile,
        normalize: true,
      );
      final input = profile == LlamaEmbeddingProfile.embeddingGemma2
          ? LlamaEmbeddingText.query(trimmed, task: LlamaEmbeddingTask.search)
          : LlamaEmbeddingText.prepared(trimmed);

      final watch = Stopwatch()..start();
      final vector = await embedder.embed(input);
      watch.stop();

      return EmbeddedQueryResult(
        query: trimmed,
        dimensions: vector.length,
        vector: List<double>.unmodifiable(vector),
        elapsedMs: watch.elapsedMilliseconds,
      );
    });
  }

  @override
  Future<List<RankedDocumentItem>> rerank({
    required String query,
    required List<String> documents,
  }) async {
    final cleanDocs = documents
        .map((String d) => d.trim())
        .where((String d) => d.isNotEmpty)
        .toList(growable: false);
    if (query.trim().isEmpty || cleanDocs.isEmpty) {
      throw LlamaArgumentException(
        'Provide a non-empty query and at least one candidate document.',
      );
    }

    final reranker = _reranker;
    if (reranker == null) {
      throw LlamaStateException(
        'Select a cross-encoder Reranker model above (e.g. BGE Reranker v2 M3) '
        'to download and load it first.',
      );
    }

    final results = await reranker.rerank(query.trim(), cleanDocs);
    return results
        .map(
          (LlamaRerankResult r) => RankedDocumentItem(
            originalIndex: r.index,
            document: cleanDocs[r.index],
            score: r.score,
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<SystemOneEvaluation> evaluateSystemOne({
    required String stateText,
    required String yesNoQuestion,
  }) async {
    final engine = _decisionEngine;
    if (engine == null) {
      throw LlamaStateException(
        'Load Laya System-1 Decision Model in Playground first.',
      );
    }
    final key = NoulKey.of('q', yesNoQuestion.trim());
    final watch = Stopwatch()..start();
    final result = await engine.systemOne(
      state: stateText.trim(),
      questions: DecisionKey.questionsOf(<DecisionKey<Object>>[key]),
    );
    watch.stop();
    final answer = result.answerOf(key);
    return SystemOneEvaluation(
      question: yesNoQuestion.trim(),
      probabilityTrue: answer.noul,
      confidence: answer.confidence,
      elapsedMs: watch.elapsedMilliseconds,
      deviceName: engine.info.deviceName,
    );
  }

  @override
  Future<SystemOneBatchEvaluation> evaluateSystemOneBatch({
    required Object state,
    required List<SystemOneQuestionSpec> questions,
  }) async {
    final engine = _decisionEngine;
    if (engine == null) {
      throw LlamaStateException(
        'Load Laya System-1 Decision Model in Playground first.',
      );
    }
    if (questions.isEmpty) {
      throw LlamaArgumentException(
        'Provide at least one System-1 question to evaluate.',
      );
    }

    final builtKeys = <DecisionKey<Object?>>[];
    for (final spec in questions) {
      switch (spec) {
        case SystemOneChoiceQuestionSpec():
          builtKeys.add(
            ChoiceKey.labels(
              spec.id,
              spec.prompt,
              criteria: <String, Object?>{
                for (final label in spec.labels) label: null,
              },
            ),
          );
        case SystemOneScoreQuestionSpec():
          builtKeys.add(ScoreKey.of(spec.id, spec.prompt, levels: spec.levels));
        case SystemOneNoulQuestionSpec():
          builtKeys.add(NoulKey.of(spec.id, spec.prompt));
      }
    }

    final watch = Stopwatch()..start();
    final result = await engine.systemOne(
      state: state is String ? state.trim() : state,
      questions: DecisionKey.questionsOf(builtKeys),
    );
    watch.stop();

    final answers = <SystemOneQuestionAnswer>[];
    for (var i = 0; i < questions.length; i++) {
      final spec = questions[i];
      final key = builtKeys[i];
      switch (spec) {
        case SystemOneChoiceQuestionSpec():
          final choiceKey = key as ChoiceKey<String>;
          final choiceOf = result.answerOf(choiceKey);
          answers.add(
            SystemOneChoiceAnswer(
              id: spec.id,
              prompt: spec.prompt,
              confidence: choiceOf.confidence,
              choice: choiceOf.label,
              probabilities: choiceOf.probabilities,
            ),
          );
        case SystemOneScoreQuestionSpec():
          final scoreKey = key as ScoreKey;
          final scoreAns = result.answerOf(scoreKey);
          final probs = scoreAns.levelProbabilities;
          answers.add(
            SystemOneScoreAnswer(
              id: spec.id,
              prompt: spec.prompt,
              confidence: scoreAns.confidence,
              score: scoreAns.score,
              levels: spec.levels,
              levelProbabilities: <String, double>{
                for (var idx = 0; idx < spec.levels.length; idx++)
                  spec.levels[idx]: idx < probs.length ? probs[idx] : 0.0,
              },
            ),
          );
        case SystemOneNoulQuestionSpec():
          final noulKey = key as NoulKey;
          final noulAns = result.answerOf(noulKey);
          answers.add(
            SystemOneNoulAnswer(
              id: spec.id,
              prompt: spec.prompt,
              confidence: noulAns.confidence,
              probabilityTrue: noulAns.noul,
            ),
          );
      }
    }

    return SystemOneBatchEvaluation(
      answers: List<SystemOneQuestionAnswer>.unmodifiable(answers),
      elapsedMs: watch.elapsedMilliseconds,
      deviceName: engine.info.deviceName,
    );
  }

  @override
  Future<DecisionBenchmarkSummary> runDecisionSpeedBenchmark({
    required Object state,
    required List<SystemOneQuestionSpec> questions,
    int iterations = 15,
    bool compareWithActiveChatLlm = false,
  }) async {
    final engine = _decisionEngine;
    if (engine == null) {
      throw LlamaStateException(
        'Load Laya System-1 Decision Model in Playground first.',
      );
    }
    if (questions.isEmpty) {
      throw LlamaArgumentException(
        'Provide at least one System-1 question to benchmark.',
      );
    }

    final count = iterations.clamp(1, 100);
    final builtKeys = _buildDecisionKeysHelper(questions);
    final compiled = DecisionKey.questionsOf(builtKeys);
    final normalizedState = state is String ? state.trim() : state;

    // Warm up once before timing steady-state single-pass latency.
    await engine.systemOne(state: normalizedState, questions: compiled);

    final samplesUs = <int>[];
    final totalWatch = Stopwatch()..start();
    for (var i = 0; i < count; i++) {
      final passWatch = Stopwatch()..start();
      await engine.systemOne(state: normalizedState, questions: compiled);
      passWatch.stop();
      samplesUs.add(passWatch.elapsedMicroseconds);
    }
    totalWatch.stop();

    samplesUs.sort();
    int usToMs(int us) => math.max(1, (us / 1000.0).round());
    final minMs = usToMs(samplesUs.first);
    final medianMs = usToMs(samplesUs[samplesUs.length ~/ 2]);
    final p95Index = ((samplesUs.length - 1) * 0.95).round();
    final p95Ms = usToMs(samplesUs[p95Index]);
    final totalMs = math.max(1, totalWatch.elapsedMilliseconds);

    int? llmMs;
    String? llmModel;
    String? llmPreview;

    if (compareWithActiveChatLlm) {
      final chatPort = _sharedChatPort;
      if (chatPort != null && chatPort.isEngineReady) {
        final comparison = await _compareDecisionWithChatLlmHelper(
          chatPort: chatPort,
          normalizedState: normalizedState,
          questions: questions,
        );
        llmMs = comparison.elapsedMs;
        llmModel = comparison.modelName;
        llmPreview = comparison.summary;
      }
    }

    return DecisionBenchmarkSummary(
      iterations: count,
      questionsPerPass: questions.length,
      totalElapsedMs: totalMs,
      minMs: minMs,
      medianMs: medianMs,
      p95Ms: p95Ms,
      deviceName: engine.info.deviceName,
      llmCompareElapsedMs: llmMs,
      llmCompareModelName: llmModel,
      llmCompareSummary: llmPreview,
    );
  }

  @override
  Future<List<InspectedToken>> inspectTokens(String text) async {
    if (text.isEmpty) {
      return const <InspectedToken>[];
    }
    final sharedPort = _sharedChatPort;
    if (sharedPort != null && sharedPort.isEngineReady) {
      return sharedPort.runExclusiveOnEngine(
        'Token inspection',
        (LlamaEngine engine) => _tokenizeWithEngine(engine, text),
      );
    }
    final dedicated = _embeddingEngine;
    if (dedicated == null || !dedicated.isReady) {
      throw LlamaStateException('Load a model first to inspect tokenization.');
    }
    return _tokenizeWithEngine(dedicated, text);
  }

  Future<List<InspectedToken>> _tokenizeWithEngine(
    LlamaEngine engine,
    String text,
  ) async {
    final ids = await engine.tokenize(text, addSpecial: false);
    final tokens = <InspectedToken>[];
    for (final id in ids) {
      final piece = await engine.detokenize(<int>[id]);
      tokens.add(InspectedToken(id: id, piece: piece));
    }
    return tokens;
  }

  @override
  Future<BenchmarkRunSummary> runBenchmark({
    int targetDecodeTokens = 64,
  }) async {
    final chatPort = _sharedChatPort;
    if (chatPort == null || !chatPort.isEngineReady) {
      throw LlamaStateException(
        'Load a Chat model in Model Hub before running a benchmark.',
      );
    }

    return chatPort.runExclusiveOnEngine('Playground throughput benchmark', (
      LlamaEngine engine,
    ) async {
      const benchmarkPrompt =
          'Explain in concise technical prose how quantized matrix-vector '
          'multiplication accelerates on-device transformer inference across '
          'CPU SIMD and GPU shader pipelines.';
      final promptTokens = await engine.getTokenCount(benchmarkPrompt);
      final watch = Stopwatch()..start();
      int? firstTokenMs;
      var generated = 0;

      await for (final chunk in engine.create(
        const <LlamaChatMessage>[
          LlamaChatMessage.fromText(
            role: LlamaChatRole.user,
            text: benchmarkPrompt,
          ),
        ],
        params: GenerationParams(
          maxTokens: targetDecodeTokens,
          temp: 0.0,
          streamBatchTokenThreshold: 1,
        ),
        enableThinking: false,
        chatTemplateKwargs: const <String, dynamic>{
          'enable_thinking': false,
          'thinking': false,
          'reasoning': false,
        },
      )) {
        if (chunk.text.isNotEmpty) {
          firstTokenMs ??= watch.elapsedMilliseconds;
          generated++;
        }
        if (chunk.usage != null && chunk.usage!.completionTokens > 0) {
          generated = chunk.usage!.completionTokens;
        }
      }
      watch.stop();

      final prefillMs = firstTokenMs ?? watch.elapsedMilliseconds;
      final decodeMs = (watch.elapsedMilliseconds - prefillMs).clamp(
        1,
        watch.elapsedMilliseconds,
      );
      final runtimeState = chatPort.runtimeStore.state;

      return BenchmarkRunSummary(
        modelName: runtimeState.activeModelLabel ?? 'Loaded Model',
        backendName: runtimeState.backendName,
        promptTokens: promptTokens,
        generatedTokens: generated,
        prefillLatencyMs: prefillMs,
        decodeElapsedMs: decodeMs,
      );
    });
  }

  @override
  Future<void> dispose() async {
    await _embeddingEngine?.dispose();
    _embeddingEngine = null;
    await _reranker?.dispose();
    _reranker = null;
    await _decisionEngine?.dispose();
    _decisionEngine = null;
  }

  Future<T> _withEmbedEngine<T>(
    String label,
    Future<T> Function(LlamaEngine engine, bool isDedicated) action,
  ) async {
    final dedicated = _embeddingEngine;
    if (dedicated != null && dedicated.isReady) {
      return action(dedicated, true);
    }
    final sharedPort = _sharedChatPort;
    if (sharedPort != null && sharedPort.isEngineReady) {
      return sharedPort.runExclusiveOnEngine(
        label,
        (LlamaEngine engine) => action(engine, false),
      );
    }
    throw LlamaStateException(
      'Load an Embedding model (or a Chat GGUF supporting embeddings) first.',
    );
  }
}
