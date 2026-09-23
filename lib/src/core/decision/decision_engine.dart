import 'dart:async';
import 'dart:typed_data';

import '../../backends/backend.dart';
import '../engine/engine.dart';
import '../exceptions.dart';
import 'decision_decoder.dart';
import 'decision_key.dart';
import 'decision_question.dart';
import 'decision_result.dart';
import 'decision_sequence.dart';

/// Decision-model support of a [LlamaEngine].
class DecisionCapabilities {
  /// Creates a capability snapshot.
  const DecisionCapabilities({
    required this.isSupported,
    this.unsupportedReason,
    this.backendName,
  });

  /// Whether the engine's backend and loaded model can run decision heads.
  final bool isSupported;

  /// Actionable reason when [isSupported] is false.
  final String? unsupportedReason;

  /// Active runtime backend label, when the backend reports one.
  final String? backendName;
}

/// Limits and placement of a loaded decision model.
class DecisionModelInfo {
  /// Creates a model description.
  const DecisionModelInfo({
    required this.hiddenSize,
    required this.maxTokens,
    required this.headMaxTokens,
    required this.deviceName,
  });

  /// Hidden size shared by the encoder and the head.
  final int hiddenSize;

  /// Maximum tokens per question sequence, Laya's `max_len`.
  final int maxTokens;

  /// Token budget for the question text and options, Laya's `head_max_len`.
  final int headMaxTokens;

  /// Name of the device the head runs on.
  final String deviceName;
}

/// Answers typed questions about a state with a Laya-style decision model.
///
/// A decision model is a bidirectional encoder, loaded into the
/// [LlamaEngine] as a GGUF, plus a decision head loaded by [load]. Each
/// question is answered in one encoder pass without generating text. Load the
/// engine with the backbone GGUF; `ModelParams(contextSize: 512)` is
/// recommended because the decision path does not use the engine's own
/// context.
///
/// Supported on native llama.cpp backends. On Web and with the native
/// LiteRT-LM backend, [load] throws [LlamaUnsupportedException].
///
/// ```dart
/// final engine = LlamaEngine(LlamaBackend());
/// await engine.loadModel(
///   'laya-Q8_0.gguf',
///   modelParams: const ModelParams(contextSize: 512),
/// );
/// final decisions = await DecisionEngine.load(
///   engine,
///   headPath: 'laya-head.safetensors',
/// );
/// final result = await decisions.systemOne(
///   state: 'Billed twice for March.',
///   questions: {
///     'refund': DecisionQuestion.noul('Does the user request a refund?'),
///   },
/// );
/// print(result.nouls['refund']!.noul);
/// await decisions.dispose();
/// ```
class DecisionEngine {
  DecisionEngine._(this._engine, this._head, this._config, this._modelHandle)
    : info = DecisionModelInfo(
        hiddenSize: _head.hiddenSize,
        maxTokens: _config.maxTokens,
        headMaxTokens: _config.headMaxTokens,
        deviceName: _head.deviceName,
      ),
      _spec = DecisionSequenceSpec(
        clsToken: _head.clsToken,
        sepToken: _head.sepToken,
        maskToken: _head.maskToken,
        maskText: _head.maskText,
        maxTokens: _config.maxTokens,
        headMaxTokens: _config.headMaxTokens,
      );

  final LlamaEngine _engine;
  final BackendDecisionHeadInfo _head;
  final DecisionHeadConfig _config;
  final int? _modelHandle;
  final DecisionSequenceSpec _spec;
  int _activeCalls = 0;
  Completer<void>? _idle;
  Future<void>? _disposal;

  /// Reports whether [load] can load a decision head on [engine] now.
  ///
  /// A failed probe is reported as unsupported with its error.
  static Future<DecisionCapabilities> capabilitiesFor(
    LlamaEngine engine,
  ) async {
    final backendName = await _backendNameOf(engine);
    final BackendDecisionCapabilities capabilities;
    try {
      capabilities = await engine.backendDecisionCapabilities;
    } catch (error) {
      return DecisionCapabilities(
        isSupported: false,
        unsupportedReason: 'The decision capability probe failed: $error',
        backendName: backendName,
      );
    }
    return DecisionCapabilities(
      isSupported: capabilities.isSupported,
      unsupportedReason: capabilities.isSupported
          ? null
          : _unsupportedReason(capabilities),
      backendName: backendName,
    );
  }

  /// Loads the decision head at [headPath] for the model loaded in [engine].
  ///
  /// [configPath] names Laya's `rl_agent_config.json` for head files without
  /// `laya.config` metadata, such as the official checkpoint. Throws
  /// [LlamaUnsupportedException] when the backend or model cannot run
  /// decision heads; [LlamaModelException] when the head file or its config
  /// cannot be read, is malformed, or does not fit the encoder;
  /// [LlamaContextException] when the head's encoder context cannot be
  /// created; and [LlamaStateException] when the model is unloaded during the
  /// load. When a backend returns a head whose config or mask text fails
  /// validation, the head is freed and [LlamaDecisionException] is thrown.
  static Future<DecisionEngine> load(
    LlamaEngine engine, {
    required String headPath,
    String? configPath,
  }) async {
    final modelHandle = engine.isReady ? engine.modelHandle : null;
    final BackendDecisionHeadInfo head;
    try {
      final capabilities = await engine.backendDecisionCapabilities;
      if (modelHandle != null && !_hasModel(engine, modelHandle)) {
        throw LlamaStateException(_loadInterruptedMessage);
      }
      if (!capabilities.isSupported) {
        throw LlamaUnsupportedException(_unsupportedReason(capabilities));
      }
      head = await engine.loadDecisionHeadBackend(
        headPath,
        configPath: configPath,
      );
    } on LlamaStateException {
      rethrow;
    } catch (error, stackTrace) {
      if (modelHandle != null && !_hasModel(engine, modelHandle)) {
        Error.throwWithStackTrace(
          LlamaStateException(_loadInterruptedMessage, error),
          stackTrace,
        );
      }
      rethrow;
    }
    try {
      if (head.maskText.isEmpty) {
        throw LlamaDecisionException(
          'The decision head reports an empty mask token text; decision '
          'sequences need it to strip the mask token from user text.',
        );
      }
      return DecisionEngine._(
        engine,
        head,
        decodeDecisionHeadConfig(head.configJson),
        modelHandle,
      );
    } catch (error, stackTrace) {
      await engine
          .freeDecisionHeadBackend(head.handle)
          .catchError((Object _) {});
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  /// Limits and device of the loaded model.
  final DecisionModelInfo info;

  /// Whether [dispose] has been called.
  bool get isDisposed => _disposal != null;

  /// Answers [questions] about [state], as Laya's `system_one`.
  ///
  /// [state] is text, or a JSON-like value encoded as JSON text. Throws
  /// [LlamaDecisionException] for invalid questions and for text that
  /// contains U+0000, which the llama.cpp tokenizer would cut off there; JSON
  /// encoding escapes it in non-string states. Throws [LlamaStateException]
  /// after [dispose] or once the engine's model is unloaded. A call running
  /// during an unload throws it too, unless its sequences already reached the
  /// backend; that call returns answers from the unloaded model.
  ///
  /// To read answers as typed values, build [questions] with
  /// [DecisionKey.questionsOf] and read them with
  /// [DecisionResultKeys.answerOf].
  Future<DecisionResult> systemOne({
    required Object? state,
    required Map<String, DecisionQuestion> questions,
  }) => _track(() async {
    final results = await _answer([
      DecisionRequest(state: state, questions: questions),
    ]);
    return results.single;
  });

  /// Answers every request in [requests], in order.
  ///
  /// All questions are validated and tokenized before the model runs, and
  /// all sequences run in one backend call. The call answers [requests] as
  /// they are when it starts; later changes to the list do not affect it. An
  /// empty [requests] gives an empty list. Throws like [systemOne].
  Future<List<DecisionResult>> systemOneBatch(List<DecisionRequest> requests) {
    final snapshot = List<DecisionRequest>.unmodifiable(requests);
    return _track(() => _answer(snapshot));
  }

  /// Frees the decision head after in-flight calls finish.
  ///
  /// Idempotent. Calls made after it throw [LlamaStateException]. The
  /// [LlamaEngine] and its model stay loaded.
  Future<void> dispose() => _disposal ??= _dispose();

  Future<void> _dispose() async {
    if (_activeCalls > 0) {
      await (_idle = Completer<void>()).future;
    }
    await _engine.freeDecisionHeadBackend(_head.handle);
  }

  Future<T> _track<T>(Future<T> Function() call) async {
    if (isDisposed) {
      throw LlamaStateException(
        'This DecisionEngine was disposed. Load a new one with '
        'DecisionEngine.load.',
      );
    }
    _activeCalls++;
    try {
      return await call();
    } finally {
      if (--_activeCalls == 0) {
        _idle?.complete();
        _idle = null;
      }
    }
  }

  Future<List<DecisionResult>> _answer(List<DecisionRequest> requests) async {
    if (requests.isEmpty) return const <DecisionResult>[];
    if (!_hasModel(_engine, _modelHandle)) {
      throw LlamaStateException(_modelUnloadedMessage);
    }
    try {
      return await _run(requests);
    } on LlamaDecisionException {
      rethrow;
    } on LlamaStateException {
      rethrow;
    } catch (error, stackTrace) {
      if (!_hasModel(_engine, _modelHandle)) {
        Error.throwWithStackTrace(
          LlamaStateException(_modelUnloadedMessage, error),
          stackTrace,
        );
      }
      rethrow;
    }
  }

  Future<List<DecisionResult>> _run(List<DecisionRequest> requests) async {
    final tokenCache = <String, Future<List<int>>>{};
    Future<List<int>> tokenize(String text) {
      if (text.contains('\u0000')) {
        throw LlamaDecisionException(
          'Decision text contains U+0000, where native tokenization would cut '
          'it off. Remove it from the state, instructions and options, or pass '
          'the state as a JSON value.',
        );
      }
      return tokenCache.putIfAbsent(
        text,
        () => _engine.tokenize(text, addSpecial: false),
      );
    }

    final sequences = <List<DecisionSequence>>[
      for (final request in requests)
        await buildDecisionSequences(request, _spec, tokenize),
    ];

    final inputs = <BackendDecisionSequence>[
      for (var r = 0; r < requests.length; r++)
        for (final (q, question) in requests[r].questions.values.indexed)
          BackendDecisionSequence(
            tokens: Int32List.fromList(sequences[r][q].tokens),
            markers: Int32List.fromList(sequences[r][q].markers),
            questionType: question.type,
          ),
    ];
    final outputs = await _engine.runDecisionBackend(_head.handle, inputs);
    if (outputs.length != inputs.length) {
      throw LlamaDecisionException(
        'The decision backend returned ${outputs.length} outputs for '
        '${inputs.length} sequences.',
      );
    }

    final results = <DecisionResult>[];
    var next = 0;
    for (var r = 0; r < requests.length; r++) {
      final answers = <String, DecisionAnswer>{};
      for (final MapEntry(key: id, value: question)
          in requests[r].questions.entries) {
        final output = outputs[next++];
        answers[id] = decodeDecisionAnswer(
          question,
          output.logits,
          output.actLogits,
          _config,
        );
      }
      results.add(
        DecisionResult(
          model: decisionResponseModel,
          answers: answers,
          questions: requests[r].questions,
          usage: DecisionUsage(
            inputTokens: sequences[r].fold(
              0,
              (total, sequence) => total + sequence.tokens.length,
            ),
            outputTokens: 0,
          ),
        ),
      );
    }
    return results;
  }

  static const String _loadInterruptedMessage =
      'The model was unloaded while the DecisionEngine was loading. Load the '
      'model and the DecisionEngine again.';

  static const String _modelUnloadedMessage =
      'The model this DecisionEngine was loaded for was unloaded. Load the '
      'DecisionEngine again.';

  static bool _hasModel(LlamaEngine engine, int? modelHandle) =>
      engine.isReady && engine.modelHandle == modelHandle;

  static Future<String?> _backendNameOf(LlamaEngine engine) async {
    try {
      return await engine.getBackendName();
    } catch (_) {
      return null;
    }
  }

  static String _unsupportedReason(BackendDecisionCapabilities capabilities) =>
      capabilities.unsupportedReason ??
      'The active backend cannot run decision models.';
}
