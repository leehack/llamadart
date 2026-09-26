@TestOn('browser')
library;

import 'dart:typed_data';

import 'package:llamadart/src/backends/backend.dart';
import 'package:llamadart/src/backends/web/web_backend.dart';
import 'package:llamadart/src/core/decision/decision_question.dart';
import 'package:llamadart/src/core/engine/chat_completion_request_planner.dart';
import 'package:llamadart/src/core/engine/engine.dart';
import 'package:llamadart/src/core/engine/engine_observer.dart';
import 'package:llamadart/src/core/exceptions.dart';
import 'package:llamadart/src/core/models/chat/chat_message.dart';
import 'package:llamadart/src/core/models/chat/chat_role.dart';
import 'package:llamadart/src/core/models/chat/chat_template_result.dart';
import 'package:llamadart/src/core/models/config/log_level.dart';
import 'package:llamadart/src/core/models/inference/generation_usage.dart';
import 'package:llamadart/src/core/models/inference/model_params.dart';
import 'package:llamadart/src/core/models/inference/next_token_scores.dart';
import 'package:llamadart/src/core/models/inference/tool_choice.dart';
import 'package:test/test.dart';

void main() {
  test('createBackend returns WebAutoBackend', () {
    final backend = createBackend();

    expect(backend, isA<LlamaBackend>());
    expect(backend, isA<WebAutoBackend>());
    expect(backend, isA<BackendEmbeddings>());
    expect(backend, isA<BackendEmbeddingsSupport>());
    expect(backend, isA<BackendBatchEmbeddings>());
    expect(backend, isA<BackendStatePersistence>());
    expect(backend, isA<BackendStatePersistenceSupport>());
    expect(backend, isA<BackendPromptSpeechToTextSupport>());
    expect(backend, isA<BackendTextToSpeech>());
    expect(backend, isA<BackendDecision>());
    expect(backend, isA<BackendNextTokenScoring>());
    expect(backend, isA<BackendNextTokenScoringSupport>());
    expect((backend as WebAutoBackend).supportsStatePersistence, isFalse);
    expect(backend.supportsNextTokenScoring, isFalse);
    expect(backend.supportsEmbeddings, isFalse);
  });

  test('WebAutoBackend reports the runtime of its delegate', () {
    expect(
      WebAutoBackend(
        webBackend: _RuntimeBackend(LlamaRuntime.llamaCpp),
      ).runtime,
      LlamaRuntime.llamaCpp,
    );
    expect(WebAutoBackend(webBackend: _NoStateBackend()).runtime, isNull);
    expect(WebAutoBackend().runtime, isNull);
  });

  test('WebAutoBackend forwards generation usage from its delegate', () {
    final generation = Stream<List<int>>.empty();
    const usage = LlamaGenerationUsage(promptTokens: 4, completionTokens: 2);

    expect(
      WebAutoBackend(
        webBackend: _UsageBackend({generation: usage}),
      ).generationUsageOf(generation),
      same(usage),
    );
    expect(
      WebAutoBackend(
        webBackend: _NoStateBackend(),
      ).generationUsageOf(generation),
      isNull,
    );
  });

  test('WebAutoBackend forwards grammar support from its delegate', () {
    final unsupported = WebAutoBackend(
      webBackend: _GrammarSupportBackend(supportsGrammarConstraints: false),
    );
    final supported = WebAutoBackend(
      webBackend: _GrammarSupportBackend(supportsGrammarConstraints: true),
    );
    final legacy = WebAutoBackend(webBackend: _NoStateBackend());

    expect(unsupported, isA<BackendGrammarConstraintsSupport>());
    expect(unsupported.supportsGrammarConstraints, isFalse);
    expect(supported.supportsGrammarConstraints, isTrue);
    expect(legacy.supportsGrammarConstraints, isTrue);
  });

  test('WebAutoBackend forwards lazy grammar support from its delegate', () {
    final eager = WebAutoBackend(webBackend: _EagerGrammarBackend());
    final legacy = WebAutoBackend(webBackend: _NoStateBackend());

    expect(eager, isA<BackendLazyGrammarSupport>());
    expect(eager.supportsLazyGrammar, isFalse);
    expect(legacy.supportsLazyGrammar, isTrue);
  });

  test(
    'WebAutoBackend forwards deferred engine creation from its delegate',
    () {
      final deferred = WebAutoBackend(webBackend: _DeferredEngineBackend());
      final legacy = WebAutoBackend(webBackend: _NoStateBackend());

      expect(deferred, isA<BackendDeferredEngineCreation>());
      expect(deferred.defersEngineCreation, isTrue);
      expect(legacy.defersEngineCreation, isFalse);
    },
  );

  test('WebAutoBackend rejects strict output for unsupported delegates', () {
    final backend = WebAutoBackend(
      webBackend: _GrammarSupportBackend(supportsGrammarConstraints: false),
    );

    expect(
      () => ChatCompletionRequestPlanner.build(
        backend: backend,
        templateResult: const LlamaChatTemplateResult(prompt: 'prompt'),
        messages: const [
          LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'hello'),
        ],
        toolChoice: ToolChoice.auto,
        parallelToolCalls: false,
        responseFormat: const {'type': 'json_object'},
      ),
      throwsA(
        isA<LlamaUnsupportedException>().having(
          (error) => error.message,
          'message',
          contains('active backend does not support grammar constraints'),
        ),
      ),
    );
  });

  test('WebAutoBackend forwards prompt speech runtime support', () async {
    final unsupported = WebAutoBackend(webBackend: _NoStateBackend());
    expect(unsupported.supportsPromptSpeechToText, isFalse);
    expect(
      unsupported.promptSpeechToTextUnsupportedReason,
      contains('does not expose'),
    );

    final supported = WebAutoBackend(webBackend: _SpeechSupportBackend());
    expect(supported.supportsPromptSpeechToText, isTrue);
    expect(supported.promptSpeechToTextUnsupportedReason, isNull);
  });

  test(
    'WebAutoBackend forwards typed text-to-speech to its delegate',
    () async {
      final delegate = _TextToSpeechBackend();
      final backend = WebAutoBackend(webBackend: delegate);

      final capabilities = await backend.textToSpeechCapabilities(3, 4);
      expect(capabilities.isSupported, isTrue);
      expect(capabilities.sampleRateHz, 24000);

      final result = await backend.synthesizeTextToSpeech(
        3,
        4,
        const BackendTextToSpeechRequest(text: 'Hello'),
      );
      expect(result.samples, <double>[0.25, -0.25]);
      expect(delegate.lastText, 'Hello');

      backend.cancelTextToSpeech();
      expect(delegate.cancelCalls, 1);
    },
  );

  test('WebAutoBackend throws typed unsupported TTS errors', () {
    final backend = WebAutoBackend(webBackend: _NoStateBackend());

    expect(
      () => backend.synthesizeTextToSpeech(
        3,
        4,
        const BackendTextToSpeechRequest(text: 'Hello'),
      ),
      throwsA(
        isA<LlamaUnsupportedException>().having(
          (error) => error.message,
          'message',
          contains('active Web runtime'),
        ),
      ),
    );
  });

  test(
    'WebAutoBackend reports embedding support from active delegate',
    () async {
      final unsupported = WebAutoBackend(
        webBackend: _EmbeddingSupportBackend(supportsEmbeddings: false),
      );
      expect(unsupported.supportsEmbeddings, isFalse);

      final supported = WebAutoBackend(
        webBackend: _EmbeddingSupportBackend(supportsEmbeddings: true),
      );
      expect(supported.supportsEmbeddings, isTrue);
      expect(await supported.embed(1, 'hello'), <double>[1, 2, 3]);
    },
  );

  test('WebAutoBackend reports state support from injected delegate', () async {
    final backend = WebAutoBackend(webBackend: _NoStateBackend());
    final engine = LlamaEngine(backend);

    expect(backend.supportsStatePersistence, isFalse);
    expect(engine.supportsStatePersistence, isFalse);

    await engine.loadModel('/model.gguf');
    expect(engine.supportsStatePersistence, isFalse);
    await expectLater(
      () =>
          engine.stateSaveFile('/prompt-prefix.state', tokens: const <int>[1]),
      throwsA(
        isA<LlamaUnsupportedException>().having(
          (error) => error.message,
          'message',
          contains('v0.1.15'),
        ),
      ),
    );
  });

  test('WebAutoBackend forwards next-token scoring to its delegate', () async {
    final scoring = _ScoringBackend(supportsNextTokenScoring: true);
    final backend = WebAutoBackend(webBackend: scoring);
    expect(backend.supportsNextTokenScoring, isTrue);
    expect(
      WebAutoBackend(
        webBackend: _ScoringBackend(supportsNextTokenScoring: false),
      ).supportsNextTokenScoring,
      isFalse,
    );

    final scores = await backend.scoreNextToken(
      1,
      'prompt',
      candidates: const <int>[4, 2],
      topK: 3,
      reusePromptPrefix: false,
    );
    final request = scoring.lastRequest!;
    expect(request.$1, 1);
    expect(request.$2, 'prompt');
    expect(request.$3, <int>[4, 2]);
    expect(request.$4, 3);
    expect(request.$5, isFalse);
    expect(scores.promptTokens, 5);

    final legacy = WebAutoBackend(webBackend: _NoStateBackend());
    expect(legacy.supportsNextTokenScoring, isFalse);
    final engine = LlamaEngine(legacy);
    await engine.loadModel('/model.gguf');
    expect(engine.supportsNextTokenScoring, isFalse);
    await expectLater(
      () => engine.scoreNextToken('prompt', topK: 1),
      throwsA(isA<LlamaUnsupportedException>()),
    );
  });

  test('WebAutoBackend forwards decision calls to its delegate', () async {
    final delegate = _DecisionBackend();
    final backend = WebAutoBackend(webBackend: delegate);
    final sequence = BackendDecisionSequence(
      tokens: Int32List.fromList([1, 3, 2]),
      markers: Int32List.fromList([1]),
      questionType: DecisionQuestionType.noul,
    );

    final capabilities = await backend.decisionCapabilities(1);
    final head = await backend.decisionHeadLoad(
      1,
      'laya-head.safetensors',
      configPath: 'rl_agent_config.json',
    );
    final outputs = await backend.decisionRun(head.handle, [sequence]);
    await backend.decisionHeadFree(head.handle);

    expect(capabilities.isSupported, isTrue);
    expect(outputs.single.logits, [0.5]);
    expect(delegate.calls, [
      'capabilities 1',
      'load 1 laya-head.safetensors rl_agent_config.json',
      'run 9 1',
      'free 9',
    ]);
  });

  test('WebAutoBackend reports decision models unsupported on LiteRT-LM '
      'Web', () async {
    const reason =
        'The active Web runtime does not run decision models. Load a '
        'ModernBERT encoder GGUF, which uses the llama.cpp WebGPU bridge.';
    final liteRtLm = _RecordingBackend('litert');
    final backend = WebAutoBackend(
      webGpuFactory: _DecisionBackend.new,
      liteRtLmFactory: () => liteRtLm,
    );
    await backend.modelLoadFromUrl(
      'https://example.com/gemma-4-E2B-it-web.litertlm',
      const ModelParams(),
    );

    final capabilities = await backend.decisionCapabilities(1);

    expect(capabilities.isSupported, isFalse);
    expect(capabilities.unsupportedReason, reason);
    expect(
      () => backend.decisionHeadLoad(1, 'laya-head.safetensors'),
      throwsA(
        isA<LlamaUnsupportedException>().having(
          (error) => error.message,
          'message',
          reason,
        ),
      ),
    );
    expect(
      () => backend.decisionRun(1, const []),
      throwsA(isA<LlamaUnsupportedException>()),
    );
    await backend.decisionHeadFree(1);
  });

  test('WebAutoBackend rejects decision calls before a model load', () async {
    final backend = WebAutoBackend(webGpuFactory: _DecisionBackend.new);

    expect(() => backend.decisionCapabilities(1), throwsStateError);
    expect(
      () => backend.decisionHeadLoad(1, 'laya-head.safetensors'),
      throwsStateError,
    );
    expect(() => backend.decisionRun(1, const []), throwsStateError);
    await backend.decisionHeadFree(1);
  });

  test('WebAutoBackend routes .litertlm URLs to LiteRT-LM delegate', () async {
    final webGpu = _RecordingBackend('webgpu');
    final liteRtLm = _RecordingBackend('litert');
    final backend = WebAutoBackend(
      webGpuFactory: () => webGpu,
      liteRtLmFactory: () => liteRtLm,
    );

    await backend.modelLoadFromUrl(
      'https://example.com/model.gguf',
      const ModelParams(),
    );
    expect(webGpu.loadedUrls, ['https://example.com/model.gguf']);
    expect(liteRtLm.loadedUrls, isEmpty);
    expect(await backend.getBackendName(), 'webgpu');

    await backend.modelLoadFromUrl(
      'https://example.com/gemma-4-E2B-it-web.litertlm?download=1',
      const ModelParams(),
    );
    expect(liteRtLm.loadedUrls, [
      'https://example.com/gemma-4-E2B-it-web.litertlm?download=1',
    ]);
    expect(webGpu.disposeCalls, 1);
    expect(await backend.getBackendName(), 'litert');
  });
}

class _NoStateBackend implements LlamaBackend {
  @override
  bool get isReady => true;

  @override
  bool get supportsUrlLoading => true;

  @override
  Future<int> modelLoad(String path, ModelParams params) async => 1;

  @override
  Future<int> modelLoadFromUrl(
    String url,
    ModelParams params, {
    Function(double progress)? onProgress,
  }) async => 1;

  @override
  Future<int> contextCreate(int modelHandle, ModelParams params) async => 1;

  @override
  Future<void> contextFree(int contextHandle) async {}

  @override
  Future<void> modelFree(int modelHandle) async {}

  @override
  Future<String> getBackendName() async => 'WebGPU';

  @override
  Future<void> setLogLevel(LlamaLogLevel level) async {}

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RecordingBackend implements LlamaBackend {
  final String name;
  final loadedUrls = <String>[];
  var disposeCalls = 0;

  _RecordingBackend(this.name);

  @override
  bool get isReady => loadedUrls.isNotEmpty;

  @override
  bool get supportsUrlLoading => true;

  @override
  Future<int> modelLoad(String path, ModelParams params) async {
    loadedUrls.add(path);
    return 1;
  }

  @override
  Future<int> modelLoadFromUrl(
    String url,
    ModelParams params, {
    Function(double progress)? onProgress,
  }) async {
    loadedUrls.add(url);
    return 1;
  }

  @override
  Future<String> getBackendName() async => name;

  @override
  Future<bool> isGpuSupported() async => name == 'webgpu';

  @override
  Future<void> setLogLevel(LlamaLogLevel level) async {}

  @override
  Future<void> dispose() async {
    disposeCalls += 1;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SpeechSupportBackend extends _NoStateBackend
    implements BackendPromptSpeechToTextSupport {
  @override
  bool get supportsPromptSpeechToText => true;

  @override
  String? get promptSpeechToTextUnsupportedReason => null;
}

class _EmbeddingSupportBackend
    implements LlamaBackend, BackendEmbeddings, BackendEmbeddingsSupport {
  @override
  final bool supportsEmbeddings;

  _EmbeddingSupportBackend({required this.supportsEmbeddings});

  @override
  bool get isReady => true;

  @override
  bool get supportsUrlLoading => true;

  @override
  Future<List<double>> embed(
    int contextHandle,
    String text, {
    bool normalize = true,
  }) async {
    return const <double>[1, 2, 3];
  }

  @override
  Future<void> setLogLevel(LlamaLogLevel level) async {}

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _DeferredEngineBackend extends _NoStateBackend
    implements BackendDeferredEngineCreation {
  @override
  bool get defersEngineCreation => true;
}

class _RuntimeBackend extends _NoStateBackend
    implements BackendRuntimeIdentity {
  _RuntimeBackend(this.runtime);

  @override
  final LlamaRuntime runtime;
}

class _UsageBackend extends _NoStateBackend
    implements BackendGenerationUsageReporting {
  _UsageBackend(this.usages);

  final Map<Stream<List<int>>, LlamaGenerationUsage> usages;

  @override
  LlamaGenerationUsage? generationUsageOf(Stream<List<int>> generation) =>
      usages[generation];
}

class _GrammarSupportBackend extends _NoStateBackend
    implements BackendGrammarConstraintsSupport {
  _GrammarSupportBackend({required this.supportsGrammarConstraints});

  @override
  final bool supportsGrammarConstraints;
}

class _EagerGrammarBackend extends _NoStateBackend
    implements BackendLazyGrammarSupport {
  @override
  bool get supportsLazyGrammar => false;
}

class _TextToSpeechBackend extends _NoStateBackend
    implements BackendTextToSpeech {
  String? lastText;
  var cancelCalls = 0;

  @override
  Future<BackendTextToSpeechCapabilities> textToSpeechCapabilities(
    int contextHandle,
    int mmContextHandle,
  ) async => const BackendTextToSpeechCapabilities(
    isSupported: true,
    model: BackendTextToSpeechModel.qwen3Tts,
    sampleRateHz: 24000,
    channelCount: 1,
  );

  @override
  Future<BackendTextToSpeechResult> synthesizeTextToSpeech(
    int contextHandle,
    int mmContextHandle,
    BackendTextToSpeechRequest request, {
    void Function(BackendTextToSpeechProgress progress)? onProgress,
  }) async {
    lastText = request.text;
    return BackendTextToSpeechResult(
      samples: Float32List.fromList(<double>[0.25, -0.25]),
      sampleRateHz: 24000,
      channelCount: 1,
      framesGenerated: 1,
      truncated: false,
    );
  }

  @override
  void cancelTextToSpeech() {
    cancelCalls += 1;
  }
}

class _ScoringBackend extends _NoStateBackend
    implements BackendNextTokenScoring, BackendNextTokenScoringSupport {
  _ScoringBackend({required this.supportsNextTokenScoring});

  @override
  final bool supportsNextTokenScoring;

  (int, String, List<int>, int, bool)? lastRequest;

  @override
  Future<LlamaNextTokenScores> scoreNextToken(
    int contextHandle,
    String prompt, {
    required List<int> candidates,
    required int topK,
    required bool reusePromptPrefix,
  }) async {
    lastRequest = (contextHandle, prompt, candidates, topK, reusePromptPrefix);
    return LlamaNextTokenScores(
      candidates: const <LlamaTokenLogprob>[],
      top: const <LlamaTokenLogprob>[],
      promptTokens: 5,
    );
  }
}

class _DecisionBackend extends _NoStateBackend implements BackendDecision {
  final List<String> calls = <String>[];

  @override
  Future<BackendDecisionCapabilities> decisionCapabilities(
    int modelHandle,
  ) async {
    calls.add('capabilities $modelHandle');
    return const BackendDecisionCapabilities(isSupported: true);
  }

  @override
  Future<BackendDecisionHeadInfo> decisionHeadLoad(
    int modelHandle,
    String headPath, {
    String? configPath,
  }) async {
    calls.add('load $modelHandle $headPath $configPath');
    return const BackendDecisionHeadInfo(
      handle: 9,
      hiddenSize: 4,
      clsToken: 1,
      sepToken: 2,
      maskToken: 3,
      maskText: '[MASK]',
      configJson: '{}',
      deviceName: 'WebGPU',
    );
  }

  @override
  Future<List<BackendDecisionOutput>> decisionRun(
    int headHandle,
    List<BackendDecisionSequence> sequences,
  ) async {
    calls.add('run $headHandle ${sequences.length}');
    return [
      BackendDecisionOutput(
        logits: Float32List.fromList([0.5]),
        actLogits: Float32List.fromList([1, 0]),
      ),
    ];
  }

  @override
  Future<void> decisionHeadFree(int headHandle) async {
    calls.add('free $headHandle');
  }
}
