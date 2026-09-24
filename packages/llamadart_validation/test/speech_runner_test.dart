import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/core/speech/speech_engine_lease.dart';
import 'package:llamadart_validation/llamadart_validation.dart';
import 'package:llamadart_validation/src/process_memory.dart';
import 'package:llamadart_validation/src/speech_edge_fixtures.dart';
import 'package:llamadart_validation/src/speech_runner.dart';
import 'package:test/test.dart';

class FakeSpeech implements SpeechValidationAdapter {
  final calls = <String>[];
  bool ignoreInvalid = false;
  bool wrongWords = false;
  bool failLoad = false;
  bool failCleanup = false;
  bool reportCancelLatency = true;
  bool reportInFlight = true;
  bool reportImmediate = true;
  bool skipGenerate = false;
  double cancelLatencyMs = 1;
  double immediateCancelLatencyMs = 1;
  List<double>? cancelLatenciesMs;
  List<double>? immediateCancelLatenciesMs;
  Map<String, Object?> inFlightReport = {};
  double inFlightLeadMs = 100;
  int? unmeasuredInFlightCancel;
  int inFlightCancels = 0;
  int immediateCancels = 0;
  Object? invalidError;
  @override
  Future<void> load() async {
    calls.add('load');
    if (failLoad) throw StateError('load failure');
  }

  @override
  Future<void> dispose() async {
    calls.add('dispose');
    if (failCleanup) throw StateError('cleanup failure');
  }

  @override
  Future<Map<String, Object?>> execute({
    bool cancel = false,
    bool cancelImmediately = false,
    bool invalid = false,
    bool bytesInput = false,
  }) async {
    calls.add(
      cancel
          ? 'cancel'
          : cancelImmediately
          ? 'cancel_immediate'
          : invalid
          ? 'invalid'
          : 'execute',
    );
    if (invalid && !ignoreInvalid) {
      throw invalidError ?? ArgumentError('invalid');
    }
    if (cancelImmediately) {
      final index = immediateCancels++;
      return {
        'cancelled': true,
        if (reportCancelLatency)
          'cancel_latency_ms':
              immediateCancelLatenciesMs?[index] ?? immediateCancelLatencyMs,
        'cancel_after_ms': 0.0,
        'cancel_immediate': reportImmediate,
      };
    }
    if (skipGenerate && !cancel && !invalid) {
      return {'skipped': true, if (wrongWords) 'predicate_passed': false};
    }
    final unmeasured = cancel && ++inFlightCancels == unmeasuredInFlightCancel;
    return {
      'predicate_passed': !wrongWords,
      if (cancel) 'cancelled': true,
      if (cancel && reportCancelLatency && !unmeasured)
        'cancel_latency_ms':
            cancelLatenciesMs?[inFlightCancels - 1] ?? cancelLatencyMs,
      if (cancel) 'cancel_after_ms': inFlightLeadMs,
      if (cancel) 'cancel_in_flight': reportInFlight,
      if (cancel) ...inFlightReport,
    };
  }
}

class FakeEdgeSpeech extends FakeSpeech implements SpeechEdgeCaseAdapter {
  FakeEdgeSpeech({this.failEdge});
  final String? failEdge;

  @override
  Future<Map<String, Object?>> executeEdge(SpeechEdgeFixture fixture) async {
    calls.add('edge:${fixture.id}');
    return {'predicate_passed': fixture.id != failEdge};
  }
}

class FakeSpeechEngine implements LlamaEngine {
  FakeSpeechEngine({
    this.deltas = const <String>[],
    this.failure,
    this.tokenDelay = Duration.zero,
    this.laterTokenDelay,
  });
  final List<String> deltas;
  final Object? failure;
  final Duration tokenDelay;
  final Duration? laterTokenDelay;
  final loaded = <String>[];
  final audioParts = <LlamaAudioContent>[];
  var generations = 0;
  var disposals = 0;

  @override
  bool get isReady => true;

  @override
  Future<bool> get supportsAudio async => true;

  @override
  Future<String> getBackendName() async => 'cpu';

  @override
  Future<int?> getResolvedGpuLayers() async => 0;

  @override
  Future<void> setLogLevel(LlamaLogLevel level) async {}

  @override
  Future<void> loadModel(
    String path, {
    ModelParams modelParams = const ModelParams(),
  }) async => loaded.add(path);

  @override
  Future<void> loadMultimodalProjector(String mmProjPath) async =>
      loaded.add(mmProjPath);

  @override
  void cancelGeneration() {}

  @override
  Future<void> dispose() async => disposals++;

  @override
  Stream<LlamaCompletionChunk> create(
    List<LlamaChatMessage> messages, {
    GenerationParams? params,
    List<ToolDefinition>? tools,
    ToolChoice? toolChoice,
    bool parallelToolCalls = false,
    bool enableThinking = true,
    Map<String, dynamic>? responseFormat,
    String? sourceLangCode,
    String? targetLangCode,
    Map<String, dynamic>? chatTemplateKwargs,
    DateTime? templateNow,
  }) async* {
    generations++;
    audioParts.addAll(
      messages
          .expand((message) => message.parts)
          .whereType<LlamaAudioContent>(),
    );
    if (failure != null) throw failure!;
    final delay = generations > 1 ? laterTokenDelay ?? tokenDelay : tokenDelay;
    for (final delta in deltas) {
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      yield completionChunk(delta);
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

LlamaCompletionChunk completionChunk(String delta) => LlamaCompletionChunk(
  id: 'edge',
  object: 'chat.completion.chunk',
  created: 0,
  model: 'fake',
  choices: [
    LlamaCompletionChunkChoice(
      index: 0,
      delta: LlamaCompletionChunkDelta(content: delta),
    ),
  ],
);

class CancellableSpeechEngine extends FakeSpeechEngine {
  CancellableSpeechEngine({
    required this.completedTokenDelays,
    this.cancelAckDelay = Duration.zero,
  }) : super(deltas: const ['and ', 'so ', 'my ', 'fellow ', 'americans']);
  final List<Duration> completedTokenDelays;
  final Duration cancelAckDelay;
  Completer<void>? _running;

  Future<bool> _awaitToken(int generation) async {
    if (generation >= completedTokenDelays.length) {
      await (_running = Completer<void>()).future;
      return false;
    }
    final delay = completedTokenDelays[generation];
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    return true;
  }

  void _acknowledgeCancel() {
    final running = _running;
    if (running == null) return;
    Future<void>.delayed(cancelAckDelay, () {
      if (!running.isCompleted) running.complete();
    });
  }

  @override
  void cancelGeneration() => _acknowledgeCancel();

  @override
  void cancelTextToSpeechBackend() => _acknowledgeCancel();

  @override
  Stream<LlamaCompletionChunk> create(
    List<LlamaChatMessage> messages, {
    GenerationParams? params,
    List<ToolDefinition>? tools,
    ToolChoice? toolChoice,
    bool parallelToolCalls = false,
    bool enableThinking = true,
    Map<String, dynamic>? responseFormat,
    String? sourceLangCode,
    String? targetLangCode,
    Map<String, dynamic>? chatTemplateKwargs,
    DateTime? templateNow,
  }) async* {
    final generation = generations++;
    for (final delta in deltas) {
      if (!await _awaitToken(generation)) return;
      yield completionChunk(delta);
    }
  }

  @override
  Future<BackendTextToSpeechCapabilities>
  get backendTextToSpeechCapabilities async =>
      const BackendTextToSpeechCapabilities(
        isSupported: true,
        model: BackendTextToSpeechModel.qwen3Tts,
        sampleRateHz: 24000,
        channelCount: 1,
        supportsLanguage: true,
        supportsCancellation: true,
      );

  @override
  Future<BackendTextToSpeechResult> synthesizeTextToSpeechBackend(
    BackendTextToSpeechRequest request, {
    void Function(BackendTextToSpeechProgress progress)? onProgress,
  }) async {
    final generation = generations++;
    for (var frame = 0; frame < deltas.length; frame++) {
      if (!await _awaitToken(generation)) break;
    }
    return BackendTextToSpeechResult(
      samples: Float32List.fromList([.25, -.25]),
      sampleRateHz: 24000,
      channelCount: 1,
      framesGenerated: deltas.length,
      truncated: false,
    );
  }
}

class FakeInterruptSpeech extends FakeSpeech
    implements SpeechSynthesisInterruptAdapter {
  Map<String, Object?> teardownReport = {};
  Map<String, Object?> decodeReport = {};

  static Map<String, Object?> passingDecode() => {
    'frame_cap': speechDecodeCancelFrameCap,
    'uncapped_frames': speechDecodeCancelFrameCap + 1,
    'references': [
      for (final decode in [500.0, 400.0])
        {
          'frames': speechDecodeCancelFrameCap,
          'truncated': true,
          'decode_ms': decode,
        },
    ],
    'frames_before_cancel': speechDecodeCancelFrameCap,
    'cancel_after_decode_start_ms': 100.0,
    'cancel_in_flight': true,
    'completion_state': 'cancelled',
    'final_events': 0,
    'cancel_latency_ms': 1.0,
  };

  @override
  Future<Map<String, Object?>> executeTeardown({required bool dispose}) async {
    calls.add(dispose ? 'dispose_synthesis' : 'unload_synthesis');
    return {
      'teardown': dispose ? 'dispose' : 'unload',
      'in_flight': true,
      'frames_before_teardown': 1,
      'completion_state': 'cancelled',
      'final_events': 0,
      'teardown_latency_ms': 1.0,
      'teardown_call_ms': 2.0,
      'after_teardown': {'predicate_passed': true},
      ...teardownReport,
    };
  }

  @override
  Future<Map<String, Object?>> executeDecodeCancel() async {
    calls.add('decode_cancel');
    return {...passingDecode(), ...decodeReport};
  }
}

class FakeLimitSpeech extends FakeSpeech
    implements SpeechTranscriptLimitAdapter {
  final reports = <LlamaSpeechTranscriptLimit, Map<String, Object?>>{};

  static Map<String, Object?> passingLimit(LlamaSpeechTranscriptLimit limit) =>
      {
        'max_output_tokens': limit == LlamaSpeechTranscriptLimit.maxOutputTokens
            ? 11
            : 512,
        if (limit == LlamaSpeechTranscriptLimit.maxOutputTokens)
          'transcript_tokens': 12,
        if (limit == LlamaSpeechTranscriptLimit.contextSize)
          'context_size': speechTruncationContextSize,
        'reference': 'and so my fellow americans',
        'reference_repeats': 1,
        'completion_state': 'failed',
        'truncated_limit': limit.name,
        'partial_transcript': 'And so, my',
        'after_truncation': {'predicate_passed': true},
      };

  @override
  Future<Map<String, Object?>> executeTranscriptLimit(
    LlamaSpeechTranscriptLimit limit,
  ) async {
    calls.add('limit:${limit.name}');
    return {...passingLimit(limit), ...?reports[limit]};
  }
}

class DelegatingSpeech extends FakeSpeech
    implements SpeechSynthesisInterruptAdapter, SpeechTranscriptLimitAdapter {
  DelegatingSpeech(this.inner);
  final PublicSpeechValidationAdapter inner;

  @override
  Future<void> load() async {
    await super.load();
    await inner.load();
  }

  @override
  Future<void> dispose() async {
    await super.dispose();
    await inner.dispose();
  }

  @override
  Future<Map<String, Object?>> execute({
    bool cancel = false,
    bool cancelImmediately = false,
    bool invalid = false,
    bool bytesInput = false,
  }) => cancel || cancelImmediately || invalid
      ? super.execute(
          cancel: cancel,
          cancelImmediately: cancelImmediately,
          invalid: invalid,
        )
      : inner.execute(bytesInput: bytesInput);

  @override
  Future<Map<String, Object?>> executeTeardown({required bool dispose}) =>
      inner.executeTeardown(dispose: dispose);

  @override
  Future<Map<String, Object?>> executeDecodeCancel() =>
      inner.executeDecodeCancel();

  @override
  Future<Map<String, Object?>> executeTranscriptLimit(
    LlamaSpeechTranscriptLimit limit,
  ) => inner.executeTranscriptLimit(limit);
}

class SynthesisSpeechEngine extends FakeSpeechEngine {
  SynthesisSpeechEngine({
    this.decodeHonoursCancel = true,
    this.teardownCancels = true,
  });
  final bool decodeHonoursCancel;
  final bool teardownCancels;
  static const naturalFrames = 20;
  static const frameDelay = Duration(milliseconds: 4);
  static const decodeDelay = Duration(milliseconds: 600);
  final teardowns = <String>[];
  final requestedFrames = <int>[];
  var _cancelled = false;
  Completer<void>? _wake;

  Future<void> _wait(Duration delay, {bool interruptible = true}) async {
    if (!interruptible) return Future<void>.delayed(delay);
    final wake = _wake = Completer<void>();
    final timer = Timer(delay, () {
      if (!wake.isCompleted) wake.complete();
    });
    await wake.future;
    timer.cancel();
  }

  @override
  void cancelTextToSpeechBackend() {
    _cancelled = true;
    final wake = _wake;
    if (wake != null && !wake.isCompleted) wake.complete();
  }

  @override
  Future<void> unloadModel() async {
    teardowns.add('unload');
    if (teardownCancels) SpeechEngineLease.cancelActiveTask(this);
  }

  @override
  Future<void> dispose() async {
    teardowns.add('dispose');
    if (teardownCancels) SpeechEngineLease.cancelActiveTask(this);
    disposals++;
  }

  @override
  Future<BackendTextToSpeechCapabilities>
  get backendTextToSpeechCapabilities async =>
      const BackendTextToSpeechCapabilities(
        isSupported: true,
        model: BackendTextToSpeechModel.qwen3Tts,
        sampleRateHz: 24000,
        channelCount: 1,
        supportsLanguage: true,
        supportsCancellation: true,
      );

  @override
  Future<BackendTextToSpeechResult> synthesizeTextToSpeechBackend(
    BackendTextToSpeechRequest request, {
    void Function(BackendTextToSpeechProgress progress)? onProgress,
  }) async {
    _cancelled = false;
    requestedFrames.add(request.maxFrames);
    final frames = math.min(naturalFrames, request.maxFrames);
    var generated = 0;
    while (generated < frames && !_cancelled) {
      await _wait(frameDelay);
      if (_cancelled) break;
      generated++;
      onProgress?.call(
        BackendTextToSpeechProgress(
          phase: BackendTextToSpeechPhase.generating,
          promptTokensRemaining: 0,
          framesGenerated: generated,
          truncated: false,
        ),
      );
    }
    if (!_cancelled) {
      await _wait(decodeDelay, interruptible: decodeHonoursCancel);
    }
    return BackendTextToSpeechResult(
      samples: Float32List.fromList([.25, -.25]),
      sampleRateHz: 24000,
      channelCount: 1,
      framesGenerated: generated,
      truncated: naturalFrames > request.maxFrames,
    );
  }
}

const jfkReference =
    'And so my fellow Americans ask not what your country can do for you ask '
    'what you can do for your country';

List<String> referenceWords(int repeats) =>
    List.filled(repeats, jfkReference).join(' ').split(' ');

class LimitedRecognitionEngine extends FakeSpeechEngine {
  LimitedRecognitionEngine({required this.fixtureBytes, this.typed = true});
  final int fixtureBytes;
  final bool typed;
  final contextSizes = <int>[];
  final maxTokens = <int?>[];
  var _contextSize = 0;

  @override
  Future<void> loadModel(
    String path, {
    ModelParams modelParams = const ModelParams(),
  }) async {
    loaded.add(path);
    contextSizes.add(_contextSize = modelParams.contextSize);
  }

  @override
  Future<int> getContextSize() async => _contextSize;

  @override
  Future<List<int>> tokenize(String text, {bool addSpecial = true}) async =>
      List.filled(text.split(' ').length, 1);

  @override
  Stream<LlamaCompletionChunk> create(
    List<LlamaChatMessage> messages, {
    GenerationParams? params,
    List<ToolDefinition>? tools,
    ToolChoice? toolChoice,
    bool parallelToolCalls = false,
    bool enableThinking = true,
    Map<String, dynamic>? responseFormat,
    String? sourceLangCode,
    String? targetLangCode,
    Map<String, dynamic>? chatTemplateKwargs,
    DateTime? templateNow,
  }) async* {
    generations++;
    final audio = messages
        .expand((message) => message.parts)
        .whereType<LlamaAudioContent>()
        .single;
    audioParts.add(audio);
    maxTokens.add(params!.maxTokens);
    final repeats = (audio.bytes?.length ?? fixtureBytes) > fixtureBytes
        ? 3
        : 1;
    final words = referenceWords(repeats);
    final fits = repeats > 1 && _contextSize < 1024 ? 2 * words.length ~/ 3 : 0;
    final limit = fits > 0 && fits < params.maxTokens ? fits : params.maxTokens;
    for (final word in words.take(limit)) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
      yield completionChunk('$word ');
    }
    if (typed && limit < words.length) {
      throw LlamaSpeechTranscriptTruncatedException(
        'Speech recognition reached a token limit.',
        limit: limit == params.maxTokens
            ? LlamaSpeechTranscriptLimit.maxOutputTokens
            : LlamaSpeechTranscriptLimit.contextSize,
        partialTranscript: words.take(limit).join(' '),
      );
    }
  }
}

int stableResidentBytes() => 1000;

void main() {
  test(
    'speech input rejection accepts contract errors, not inference failures',
    () async {
      for (final error in [
        LlamaAudioFormatException('Encoded audio bytes must not be empty.'),
        LlamaTextToSpeechException('Text to synthesize must not be empty.'),
        LlamaTextToSpeechException('Synthesis failed.'),
        LlamaInferenceException('Generation failed.'),
      ]) {
        final adapter = FakeSpeech()..invalidError = error;
        final result = await runSpeechValidation(
          adapter,
          residentBytes: stableResidentBytes,
        );
        final checks = result['checks'] as List;
        final rejection = checks.singleWhere(
          (item) => item['id'] == 'invalid_input',
        );
        final accepted =
            error is LlamaAudioFormatException ||
            error.message == 'Text to synthesize must not be empty.';
        expect(rejection['status'], accepted ? 'PASS' : 'FAIL');
        expect(result['functional_pass'], accepted);
        expect(result['qualified'], false);
        expect(
          checks.singleWhere((item) => item['id'] == 'after_invalid')['status'],
          'PASS',
        );
        expect(adapter.calls.last, 'dispose');
      }
    },
  );

  test(
    'WER counts substitutions, insertions, deletions and rejects empty oracle',
    () {
      expect(speechWordErrorRate('Hello, WORLD!', 'hello world'), 0);
      expect(speechWordErrorRate('one two', 'one three four'), 1);
      expect(speechWordErrorRate('one two', 'one'), .5);
      expect(speechWordErrorRate('one', 'two three four'), 3);
      expect(speechWordErrorRate('Montréal 한글', 'Montréal 한글'), 0);
      expect(() => speechWordErrorRate(' ', 'hello'), throwsArgumentError);
    },
  );
  TextToSpeechResult audio(List<double> values, {bool truncated = false}) =>
      TextToSpeechResult(
        samples: Float32List.fromList(values),
        sampleRateHz: 24000,
        channelCount: 1,
        framesGenerated: 1,
        truncated: truncated,
      );
  test('nonempty bytes alone cannot qualify invalid or truncated TTS', () {
    for (final result in [
      audio([]),
      audio([0, 0]),
      audio([double.nan]),
      audio([double.infinity]),
      audio([.5], truncated: true),
    ]) {
      expect(() => inspectSpeechAudio(result), throwsStateError);
    }
    final result = inspectSpeechAudio(audio([.25, -.25]));
    expect(result['audio_seconds'], closeTo(2 / 24000, .0000001));
    expect(result['listening_check'], 'NOT_RUN');
  });
  test(
    'locked fixture validates PCM duration and rejects malformed headers',
    () {
      final bytes = File('assets/speech/jfk.wav').readAsBytesSync();
      expect(speechFixtureSeconds(bytes), greaterThan(1));
      for (final bad in [
        Uint8List(0),
        Uint8List.fromList(bytes.sublist(0, 50)),
        Uint8List.fromList(bytes)..[0] = 0,
      ]) {
        expect(() => speechFixtureSeconds(bad), throwsFormatException);
      }
      final lock = jsonDecode(
        File('assets/speech/stt.json').readAsStringSync(),
      );
      expect(sha256.convert(bytes).toString(), lock['fixture']['sha256']);
      expect(bytes.length, lock['fixture']['bytes']);
    },
  );
  test('locks parse as immutable model and projector inputs', () {
    for (final pack in ['stt', 'tts']) {
      final lock = jsonDecode(
        File('assets/speech/$pack.json').readAsStringSync(),
      );
      for (final name in ['model', 'projector']) {
        final profile = ValidationProfile.fromJson({
          'schema_version': 1,
          'id': 'speech-$pack-$name',
          'runtime': 'gguf',
          'backend': 'cpu',
          'model': lock[name],
        });
        profile.requireRunnable();
      }
    }
  });
  test(
    'successful lifecycle includes cancellation, rejection and independent reload',
    () async {
      final adapter = FakeSpeech();
      final result = await runSpeechValidation(
        adapter,
        residentBytes: stableResidentBytes,
      );
      expect(result['functional_pass'], true);
      expect(result['qualified'], false);
      expect(adapter.calls, [
        'load',
        'execute',
        'cancel_immediate',
        'cancel',
        'execute',
        'invalid',
        'execute',
        'dispose',
        'load',
        'execute',
        for (var cycle = 0; cycle < speechCleanupCycles; cycle++) ...[
          'cancel_immediate',
          'cancel',
          'dispose',
          'load',
          'execute',
        ],
        'dispose',
      ]);
    },
  );
  test('wrong transcript and ignored invalid inputs cannot pass', () async {
    for (final adapter in [
      FakeSpeech()..wrongWords = true,
      FakeSpeech()..ignoreInvalid = true,
    ]) {
      expect(
        (await runSpeechValidation(
          adapter,
          residentBytes: stableResidentBytes,
        ))['functional_pass'],
        false,
      );
      expect(adapter.calls.last, 'dispose');
    }
  });
  test('load and cleanup failures remain failures', () async {
    for (final adapter in [
      FakeSpeech()..failLoad = true,
      FakeSpeech()..failCleanup = true,
    ]) {
      expect(
        (await runSpeechValidation(
          adapter,
          residentBytes: stableResidentBytes,
        ))['functional_pass'],
        false,
      );
      expect(adapter.calls.last, 'dispose');
    }
  });
  test(
    'unmeasured or over-budget cancellation latency fails the run',
    () async {
      final silent = FakeSpeech()..reportCancelLatency = false;
      final unmeasured = await runSpeechValidation(
        silent,
        residentBytes: stableResidentBytes,
      );
      expect(unmeasured['functional_pass'], false);
      final unmeasuredChecks = unmeasured['checks'] as List;
      expect(
        unmeasuredChecks.singleWhere((row) => row['id'] == 'cancel')['status'],
        'FAIL',
      );
      expect(
        unmeasuredChecks.singleWhere(
          (row) => row['id'] == 'cancel_latency_bound',
        )['status'],
        'FAIL',
      );

      final slow = FakeSpeech()
        ..cancelLatencyMs = speechCancelLatencyBudgetMs + 1;
      final overBudget = await runSpeechValidation(
        slow,
        residentBytes: stableResidentBytes,
      );
      expect(overBudget['functional_pass'], false);
      final bound = (overBudget['checks'] as List).singleWhere(
        (row) => row['id'] == 'cancel_latency_bound',
      );
      expect(bound['status'], 'FAIL');
      expect(bound['worst_ms'], speechCancelLatencyBudgetMs + 1);
      expect(bound['samples_ms'], hasLength(speechCleanupCycles + 1));
      final reported = overBudget['bounds'] as Map;
      expect(reported['cancel_latency_ms']['within_budget'], false);
      expect(
        reported['cancel_latency_ms']['budget'],
        speechCancelLatencyBudgetMs,
      );

      final fast = FakeSpeech()..cancelLatencyMs = speechCancelLatencyBudgetMs;
      final withinBudget = await runSpeechValidation(
        fast,
        residentBytes: stableResidentBytes,
      );
      expect(withinBudget['functional_pass'], true);
      expect(
        (withinBudget['bounds'] as Map)['cancel_latency_ms']['within_budget'],
        true,
      );
    },
  );
  test('a cancellation far past the budget fails the run', () async {
    final stalled = FakeSpeech()..cancelLatencyMs = 4000;
    final result = await runSpeechValidation(
      stalled,
      residentBytes: stableResidentBytes,
    );
    expect(result['functional_pass'], false);
    final bound = (result['checks'] as List).singleWhere(
      (row) => row['id'] == 'cancel_latency_bound',
    );
    expect(bound['status'], 'FAIL');
    expect(bound['worst_ms'], 4000);
  });
  test('an immediate cancellation far past its budget fails the run', () async {
    final stalled = FakeSpeech()..immediateCancelLatencyMs = 4000;
    final result = await runSpeechValidation(
      stalled,
      residentBytes: stableResidentBytes,
    );
    expect(result['functional_pass'], false);
    final checks = result['checks'] as List;
    final bound = checks.singleWhere(
      (row) => row['id'] == 'immediate_cancel_latency_bound',
    );
    expect(bound['status'], 'FAIL');
    expect(bound['worst_ms'], 4000);
    expect(bound['samples_ms'], hasLength(speechCleanupCycles + 1));
    expect(
      checks.singleWhere(
        (row) => row['id'] == 'cancel_latency_bound',
      )['status'],
      'PASS',
    );
    final reported = (result['bounds'] as Map)['immediate_cancel_latency_ms'];
    expect(reported['within_budget'], false);
    expect(reported['budget'], speechImmediateCancelLatencyBudgetMs);

    final atBudget = await runSpeechValidation(
      FakeSpeech()
        ..immediateCancelLatencyMs = speechImmediateCancelLatencyBudgetMs,
      residentBytes: stableResidentBytes,
    );
    expect(atBudget['functional_pass'], true);
    expect(
      (atBudget['bounds']
          as Map)['immediate_cancel_latency_ms']['within_budget'],
      true,
    );
  });
  test('a cancellation not issued on hand-back fails', () async {
    final waited = FakeSpeech()..reportImmediate = false;
    final result = await runSpeechValidation(
      waited,
      residentBytes: stableResidentBytes,
    );
    expect(result['functional_pass'], false);
    final checks = result['checks'] as List;
    expect(
      checks.singleWhere((row) => row['id'] == 'cancel_immediate')['status'],
      'FAIL',
    );
    expect(
      checks.singleWhere(
        (row) => row['id'] == 'immediate_cancel_latency_bound',
      )['status'],
      'FAIL',
    );
  });
  test('a cancellation not reported in flight fails', () async {
    final early = FakeSpeech()..reportInFlight = false;
    final result = await runSpeechValidation(
      early,
      residentBytes: stableResidentBytes,
    );
    expect(result['functional_pass'], false);
    final checks = result['checks'] as List;
    expect(
      checks.singleWhere((row) => row['id'] == 'cancel')['status'],
      'FAIL',
    );
    expect(
      checks.singleWhere(
        (row) => row['id'] == 'cancel_latency_bound',
      )['status'],
      'FAIL',
    );
  });
  test('an in-flight cancellation issued without a wait fails', () async {
    final result = await runSpeechValidation(
      FakeSpeech()..inFlightLeadMs = 0,
      residentBytes: stableResidentBytes,
    );
    expect(result['functional_pass'], false);
    final cancel = (result['checks'] as List).singleWhere(
      (row) => row['id'] == 'cancel',
    );
    expect(cancel['status'], 'FAIL');
    expect(cancel['message'], contains('lead time was not measured'));
  });
  test('a latency bound missing a sample fails', () async {
    final result = await runSpeechValidation(
      FakeSpeech()..unmeasuredInFlightCancel = 2,
      residentBytes: stableResidentBytes,
    );
    final checks = result['checks'] as List;
    Map<String, Object?> row(String id) =>
        checks.singleWhere((entry) => entry['id'] == id);
    expect(row('cleanup_cycle_1')['status'], 'FAIL');
    expect(row('cancel_latency_bound')['status'], 'FAIL');
    expect(row('cancel_latency_bound')['message'], contains('incomplete'));
    expect(row('immediate_cancel_latency_bound')['status'], 'PASS');
    final bounds = result['bounds'] as Map;
    expect(
      bounds['cancel_latency_ms']['samples'],
      hasLength(speechCleanupCycles),
    );
    expect(bounds['cancel_latency_ms']['within_budget'], false);
  });
  test('one over-budget cancellation among in-budget ones fails', () async {
    List<double> oneOver(double budget, int at) => List.generate(
      speechCleanupCycles + 1,
      (index) => index == at ? budget + 1 : 1,
    );
    final result = await runSpeechValidation(
      FakeSpeech()
        ..cancelLatenciesMs = oneOver(speechCancelLatencyBudgetMs, 1)
        ..immediateCancelLatenciesMs = oneOver(
          speechImmediateCancelLatencyBudgetMs,
          2,
        ),
      residentBytes: stableResidentBytes,
    );
    expect(result['functional_pass'], false);
    final checks = result['checks'] as List;
    for (final (id, budget) in [
      ('cancel_latency_bound', speechCancelLatencyBudgetMs),
      ('immediate_cancel_latency_bound', speechImmediateCancelLatencyBudgetMs),
    ]) {
      final bound = checks.singleWhere((row) => row['id'] == id);
      expect(bound['status'], 'FAIL', reason: id);
      expect(bound['worst_ms'], budget + 1, reason: id);
    }
  });
  test('both cancel bounds pass at 500 ms and fail just past it', () async {
    final adapters = <String, FakeSpeech Function(double)>{
      'cancel_latency': (ms) => FakeSpeech()..cancelLatencyMs = ms,
      'immediate_cancel_latency': (ms) =>
          FakeSpeech()..immediateCancelLatencyMs = ms,
    };
    for (final MapEntry(key: name, value: adapter) in adapters.entries) {
      for (final (latency, within) in [
        (499.999, true),
        (500.0, true),
        (500.001, false),
      ]) {
        final reason = '$name at $latency ms';
        final result = await runSpeechValidation(
          adapter(latency),
          residentBytes: stableResidentBytes,
        );
        final bound = (result['checks'] as List).singleWhere(
          (row) => row['id'] == '${name}_bound',
        );
        expect(bound['budget_ms'], 500.0, reason: reason);
        expect(bound['status'], within ? 'PASS' : 'FAIL', reason: reason);
        final reported = (result['bounds'] as Map)['${name}_ms'] as Map;
        expect(reported['budget'], 500.0, reason: reason);
        expect(reported['within_budget'], within, reason: reason);
        expect(result['functional_pass'], within, reason: reason);
      }
    }
  });
  test('the in-flight cancel bound reports a lead fraction of 0.5', () async {
    final result = await runSpeechValidation(
      FakeSpeech(),
      residentBytes: stableResidentBytes,
    );
    final bound = (result['checks'] as List).singleWhere(
      (row) => row['id'] == 'cancel_latency_bound',
    );
    expect(bound['lead_fraction'], 0.5);
    final reported = (result['bounds'] as Map)['cancel_latency_ms'] as Map;
    expect(reported['lead_fraction'], 0.5);
  });
  test('a cancellation reporting an invalid measurement fails', () async {
    for (final (report, message) in <(Map<String, Object?>, String)>[
      ({'cancelled': false}, 'Cancellation not confirmed'),
      ({'cancel_latency_ms': double.infinity}, 'latency was not measured'),
      ({'cancel_latency_ms': -1.0}, 'latency was not measured'),
      ({'cancel_after_ms': double.nan}, 'lead time was not measured'),
      ({'cancel_after_ms': -1.0}, 'lead time was not measured'),
    ]) {
      final result = await runSpeechValidation(
        FakeSpeech()..inFlightReport = report,
        residentBytes: stableResidentBytes,
      );
      expect(result['functional_pass'], false, reason: '$report');
      final cancel = (result['checks'] as List).singleWhere(
        (row) => row['id'] == 'cancel',
      );
      expect(cancel['status'], 'FAIL', reason: '$report');
      expect(cancel['message'], contains(message), reason: '$report');
    }
  });
  test('only the memory bound may skip and still pass the run', () async {
    final skipping = await runSpeechValidation(
      FakeSpeech()..skipGenerate = true,
      residentBytes: stableResidentBytes,
    );
    final generate = (skipping['checks'] as List).singleWhere(
      (row) => row['id'] == 'generate',
    );
    expect(generate['status'], 'SKIP');
    expect(skipping['functional_pass'], false);
  });
  test('a failed predicate outranks skipped in the status ladder', () async {
    final hiding = await runSpeechValidation(
      FakeSpeech()
        ..skipGenerate = true
        ..wrongWords = true,
      residentBytes: stableResidentBytes,
    );
    final generate = (hiding['checks'] as List).singleWhere(
      (row) => row['id'] == 'generate',
    );
    expect(generate['skipped'], isTrue);
    expect(generate['predicate_passed'], isFalse);
    expect(generate['status'], 'FAIL');
    expect(hiding['functional_pass'], false);
  });
  test('resident growth past the budget fails the run', () async {
    var sample = 1000;
    final growing = await runSpeechValidation(
      FakeSpeech(),
      residentBytes: () => sample += 200,
    );
    expect(growing['functional_pass'], false);
    final bound = (growing['checks'] as List).singleWhere(
      (row) => row['id'] == 'peak_memory_bound',
    );
    expect(bound['status'], 'FAIL');
    expect(bound['peak_rss_growth'], greaterThan(speechPeakRssGrowthBudget));
    expect(bound['growth_budget'], speechPeakRssGrowthBudget);
    expect((growing['bounds'] as Map)['peak_resident_bytes']['measured'], true);

    final flat = await runSpeechValidation(
      FakeSpeech(),
      residentBytes: stableResidentBytes,
    );
    expect(flat['functional_pass'], true);
    final measured = (flat['bounds'] as Map)['peak_resident_bytes'] as Map;
    expect(measured['baseline'], 1000);
    expect(measured['peak'], 1000);
    expect(measured['growth'], 1);
    expect(measured['within_budget'], true);
    expect(measured['measurement'], residentSetSource);
  });
  test('memory growth is measured from the first generation', () async {
    final adapter = FakeSpeech();
    final result = await runSpeechValidation(
      adapter,
      residentBytes: () => adapter.calls.contains('execute') ? 2000 : 1000,
    );
    expect(result['functional_pass'], true);
    final measured = (result['bounds'] as Map)['peak_resident_bytes'] as Map;
    expect(measured['baseline'], 2000);
    expect(measured['growth'], 1);
    expect(measured['within_budget'], true);
  });
  test('memory growth before reload counts toward the peak', () async {
    final adapter = FakeSpeech();
    final spike = ((speechPeakRssGrowthBudget + 1) * 2000).round();
    final result = await runSpeechValidation(
      adapter,
      residentBytes: () => adapter.calls.last == 'invalid' ? spike : 2000,
    );
    expect(result['functional_pass'], false);
    final bound = (result['checks'] as List).singleWhere(
      (row) => row['id'] == 'peak_memory_bound',
    );
    expect(bound['status'], 'FAIL');
    expect(bound['baseline_rss_bytes'], 2000);
    expect(bound['peak_rss_bytes'], spike);
  });
  test('memory growth equal to the budget passes', () async {
    const baseline = 1 << 52;
    final peak = (baseline * speechPeakRssGrowthBudget).toInt();
    final adapter = FakeSpeech();
    final result = await runSpeechValidation(
      adapter,
      residentBytes: () => adapter.calls.last == 'invalid' ? peak : baseline,
    );
    final bound = (result['checks'] as List).singleWhere(
      (row) => row['id'] == 'peak_memory_bound',
    );
    expect(bound['peak_rss_growth'], speechPeakRssGrowthBudget);
    expect(bound['status'], 'PASS');
    expect(result['functional_pass'], true);
  });
  test('memory growth passes at 1.10x and fails just past it', () async {
    const baseline = 1 << 52;
    final atBudget = (baseline * 1.10).toInt();
    for (final (peak, within) in [
      (atBudget - 1, true),
      (atBudget, true),
      (atBudget + 1, false),
    ]) {
      final reason = 'peak offset ${peak - atBudget}';
      final adapter = FakeSpeech();
      final result = await runSpeechValidation(
        adapter,
        residentBytes: () => adapter.calls.last == 'invalid' ? peak : baseline,
      );
      final bound = (result['checks'] as List).singleWhere(
        (row) => row['id'] == 'peak_memory_bound',
      );
      expect(bound['growth_budget'], 1.10, reason: reason);
      expect(bound['status'], within ? 'PASS' : 'FAIL', reason: reason);
      final reported = (result['bounds'] as Map)['peak_resident_bytes'] as Map;
      expect(reported['growth_budget'], 1.10, reason: reason);
      expect(reported['within_budget'], within, reason: reason);
      expect(result['functional_pass'], within, reason: reason);
    }
  });
  test('one unmeasurable resident sample skips the bound', () async {
    final adapter = FakeSpeech();
    final result = await runSpeechValidation(
      adapter,
      residentBytes: () => adapter.calls.last == 'invalid' ? null : 1000,
    );
    final bound = (result['checks'] as List).singleWhere(
      (row) => row['id'] == 'peak_memory_bound',
    );
    expect(bound['status'], 'SKIP');
    expect(bound['skip_reason'], 'Resident set size was not measurable');
    expect(result['functional_pass'], true);
    final reported = (result['bounds'] as Map)['peak_resident_bytes'] as Map;
    expect(reported['measured'], false);
    expect(reported['peak'], isNull);
  });
  test('an unmeasurable resident set skips the bound with a reason', () async {
    final result = await runSpeechValidation(
      FakeSpeech(),
      residentBytes: () => null,
    );
    final bound = (result['checks'] as List).singleWhere(
      (row) => row['id'] == 'peak_memory_bound',
    );
    expect(bound['status'], 'SKIP');
    expect(bound['skip_reason'], 'Resident set size was not measurable');
    expect(bound['measurement'], residentSetSource);
    expect(bound.containsKey('peak_rss_bytes'), isFalse);
    expect(result['functional_pass'], true);
    final reported = (result['bounds'] as Map)['peak_resident_bytes'] as Map;
    expect(reported['measured'], false);
    expect(reported['within_budget'], isNull);
    expect(reported['peak'], isNull);
    expect(reported['skip_reason'], 'Resident set size was not measurable');
  });
  test('the default resident probe measures this platform', () async {
    final result = await runSpeechValidation(FakeSpeech());
    final reported = (result['bounds'] as Map)['peak_resident_bytes'] as Map;
    expect(residentSetBytes(), isNotNull);
    expect(reported['measured'], true);
    expect(reported['measurement'], 'dart:io ProcessInfo.currentRss');
    expect(reported['baseline'], isPositive);
    expect(reported['peak'], isPositive);
    expect(reported['within_budget'], true);
  });
  test('edge fixtures describe the inputs they encode', () {
    final source = File('assets/speech/jfk.wav').readAsBytesSync();
    final fixtures = buildSpeechEdgeFixtures(Uint8List.fromList(source));
    expect(fixtures.map((fixture) => fixture.id), [
      'edge_silence',
      'edge_truncated_riff',
      'edge_stereo_44100',
      'edge_long_boundary',
    ]);
    for (final fixture in fixtures) {
      expect(fixture.bytes.length, lessThanOrEqualTo(speechFixtureByteCap));
      expect(String.fromCharCodes(fixture.bytes.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(fixture.bytes.sublist(8, 12)), 'WAVE');
      expect(
        fixture.rejectionMessage != null,
        fixture.contract == SpeechEdgeContract.typedRejection,
      );
    }
    final byId = {for (final fixture in fixtures) fixture.id: fixture};
    expect(
      byId['edge_silence']!.rejectionMessage,
      'Speech recognition produced an empty transcript.',
    );
    expect(
      byId['edge_truncated_riff']!.contract,
      SpeechEdgeContract.unrelatedTranscriptOrFormatRejection,
    );
    expect(
      speechFixtureSeconds(byId['edge_silence']!.bytes),
      byId['edge_silence']!.seconds,
    );
    expect(
      speechFixtureSeconds(byId['edge_long_boundary']!.bytes),
      byId['edge_long_boundary']!.seconds,
    );
    expect(byId['edge_long_boundary']!.seconds, greaterThan(30));
    expect(
      byId['edge_long_boundary']!.referenceRepeats,
      greaterThanOrEqualTo(2),
    );
    for (final id in ['edge_stereo_44100', 'edge_truncated_riff']) {
      expect(
        () => speechFixtureSeconds(byId[id]!.bytes),
        throwsFormatException,
      );
    }
    final silence = byId['edge_silence']!.bytes;
    expect(silence.sublist(44).every((byte) => byte == 0), isTrue);
    final truncated = byId['edge_truncated_riff']!.bytes;
    expect(truncated, source.sublist(0, truncated.length));
    expect(
      ByteData.sublistView(truncated).getUint32(4, Endian.little) + 8,
      greaterThan(truncated.length),
    );
    final stereo = ByteData.sublistView(byId['edge_stereo_44100']!.bytes);
    expect(stereo.getUint16(22, Endian.little), 2);
    expect(stereo.getUint32(24, Endian.little), 44100);
    for (var frame = 0; frame < 2000; frame++) {
      expect(
        stereo.getInt16(44 + frame * 4, Endian.little),
        stereo.getInt16(46 + frame * 4, Endian.little),
      );
    }
  });
  test('edge contracts credit exactly the outcome they name', () {
    SpeechEdgeFixture fixtureFor(
      SpeechEdgeContract contract, {
      String? rejectionMessage,
    }) => SpeechEdgeFixture(
      id: contract.name,
      bytes: Uint8List(0),
      sampleRateHz: 16000,
      channelCount: 1,
      seconds: 1,
      contract: contract,
      referenceRepeats: 1,
      rationale: 'table',
      rejectionMessage: rejectionMessage,
    );
    const expectedMessage = 'Speech recognition produced an empty transcript.';
    final rejecting = fixtureFor(
      SpeechEdgeContract.typedRejection,
      rejectionMessage: expectedMessage,
    );
    final unrelated = fixtureFor(SpeechEdgeContract.unrelatedTranscript);
    final tolerant = fixtureFor(
      SpeechEdgeContract.unrelatedTranscriptOrFormatRejection,
    );
    final repeated = fixtureFor(SpeechEdgeContract.repeatedReference);

    expect(speechEdgeTranscriptHolds(rejecting, 0), isFalse);
    expect(speechEdgeTranscriptHolds(rejecting, 1), isFalse);
    expect(speechEdgeTranscriptHolds(unrelated, 0), isFalse);
    expect(speechEdgeTranscriptHolds(unrelated, 0.25), isTrue);
    expect(speechEdgeTranscriptHolds(tolerant, 0), isFalse);
    expect(speechEdgeTranscriptHolds(tolerant, 0.25), isTrue);
    expect(speechEdgeTranscriptHolds(repeated, 0), isTrue);
    expect(speechEdgeTranscriptHolds(repeated, 0.25), isFalse);

    bool rejectionHolds(
      SpeechEdgeFixture fixture, {
      required String message,
      required bool isAudioFormat,
    }) => speechEdgeRejectionHolds(
      fixture,
      message: message,
      isAudioFormat: isAudioFormat,
    );
    expect(
      rejectionHolds(rejecting, message: expectedMessage, isAudioFormat: false),
      isTrue,
    );
    expect(
      rejectionHolds(
        rejecting,
        message: 'Speech recognition failed.',
        isAudioFormat: false,
      ),
      isFalse,
    );
    expect(
      rejectionHolds(
        rejecting,
        message: 'Speech recognition failed.',
        isAudioFormat: true,
      ),
      isFalse,
    );
    expect(
      rejectionHolds(tolerant, message: 'bad header', isAudioFormat: true),
      isTrue,
    );
    expect(
      rejectionHolds(tolerant, message: 'bad header', isAudioFormat: false),
      isFalse,
    );
    for (final fixture in [unrelated, repeated]) {
      for (final isAudioFormat in [true, false]) {
        expect(
          rejectionHolds(
            fixture,
            message: expectedMessage,
            isAudioFormat: isAudioFormat,
          ),
          isFalse,
        );
      }
    }
  });
  test('edge fixtures are opt-in and deliberately counted', () async {
    final fixtures = buildSpeechEdgeFixtures(
      Uint8List.fromList(File('assets/speech/jfk.wav').readAsBytesSync()),
    );
    final lifecycleOnly = await runSpeechValidation(
      FakeEdgeSpeech(),
      residentBytes: stableResidentBytes,
    );
    expect(lifecycleOnly['expected_checks'], speechLifecycleCheckCount);
    expect(lifecycleOnly['edge_fixture_ids'], isEmpty);
    expect(lifecycleOnly['functional_pass'], true);
    final adapter = FakeEdgeSpeech();
    final withEdges = await runSpeechValidation(
      adapter,
      checkBytes: true,
      edgeFixtures: fixtures,
      residentBytes: stableResidentBytes,
    );
    expect(
      withEdges['expected_checks'],
      speechLifecycleCheckCount + 1 + fixtures.length,
    );
    expect(withEdges['functional_pass'], true);
    expect(
      (withEdges['checks'] as List),
      hasLength(withEdges['expected_checks']),
    );
    expect(adapter.calls, [
      'load',
      'execute',
      'execute',
      'cancel_immediate',
      'cancel',
      'execute',
      'invalid',
      'execute',
      for (final fixture in fixtures) 'edge:${fixture.id}',
      'dispose',
      'load',
      'execute',
      for (var cycle = 0; cycle < speechCleanupCycles; cycle++) ...[
        'cancel_immediate',
        'cancel',
        'dispose',
        'load',
        'execute',
      ],
      'dispose',
    ]);
  });
  test(
    'a failing edge fixture cannot pass, and unsupported adapters throw',
    () {
      final fixtures = buildSpeechEdgeFixtures(
        Uint8List.fromList(File('assets/speech/jfk.wav').readAsBytesSync()),
      );
      expect(
        () => runSpeechValidation(FakeSpeech(), edgeFixtures: fixtures),
        throwsArgumentError,
      );
      for (final fixture in fixtures) {
        expectLater(
          runSpeechValidation(
            FakeEdgeSpeech(failEdge: fixture.id),
            edgeFixtures: fixtures,
            residentBytes: stableResidentBytes,
          ).then((result) {
            final checks = result['checks'] as List;
            return [
              result['functional_pass'],
              checks.singleWhere((row) => row['id'] == fixture.id)['status'],
            ];
          }),
          completion([false, 'FAIL']),
        );
      }
    },
  );
  const edgeReference = 'and so my fellow americans';
  Map<String, SpeechEdgeFixture> edgeFixturesById() => {
    for (final fixture in buildSpeechEdgeFixtures(
      Uint8List.fromList(File('assets/speech/jfk.wav').readAsBytesSync()),
    ))
      fixture.id: fixture,
  };
  PublicSpeechValidationAdapter edgeAdapter({
    String pack = 'stt',
    List<String> deltas = const <String>[],
    Object? failure,
    FakeSpeechEngine? engine,
    Duration tokenDelay = Duration.zero,
    Duration? laterTokenDelay,
  }) => PublicSpeechValidationAdapter(
    model: 'model.gguf',
    projector: 'mmproj.gguf',
    backend: GpuBackend.cpu,
    pack: pack,
    audio: Uint8List.fromList(List.filled(44, 7)),
    audioSeconds: 1,
    reference: edgeReference,
    saveAudio: (_) async {},
    createEngine: () =>
        engine ??
        FakeSpeechEngine(
          deltas: deltas,
          failure: failure,
          tokenDelay: tokenDelay,
          laterTokenDelay: laterTokenDelay,
        ),
  );
  Future<Map<String, Object?>> recognizeEdge(
    SpeechEdgeFixture fixture, {
    List<String> deltas = const <String>[],
    Object? failure,
  }) async {
    final adapter = edgeAdapter(deltas: deltas, failure: failure);
    await adapter.load();
    try {
      return await adapter.executeEdge(fixture);
    } finally {
      await adapter.dispose();
    }
  }

  test('edge recognition scores the repeats the fixture demands', () async {
    final byId = edgeFixturesById();
    final stereo = byId['edge_stereo_44100']!;
    final long = byId['edge_long_boundary']!;
    expect(stereo.referenceRepeats, 1);
    expect(long.referenceRepeats, greaterThanOrEqualTo(2));

    final single = await recognizeEdge(stereo, deltas: [edgeReference]);
    expect(single['predicate_passed'], isTrue);
    expect(single['wer'], 0);
    expect(single['transcript'], edgeReference);
    expect(single['reference_repeats'], 1);

    final wrongWords = await recognizeEdge(stereo, deltas: ['ask not why']);
    expect(wrongWords['predicate_passed'], isFalse);
    expect(wrongWords['wer'], greaterThan(0));

    final repeated = await recognizeEdge(
      long,
      deltas: [List.filled(long.referenceRepeats, edgeReference).join(' ')],
    );
    expect(repeated['predicate_passed'], isTrue);
    expect(repeated['wer'], 0);
    expect(repeated['reference_repeats'], long.referenceRepeats);

    for (final repeats in [1, long.referenceRepeats + 1]) {
      final mismatched = await recognizeEdge(
        long,
        deltas: [List.filled(repeats, edgeReference).join(' ')],
      );
      expect(mismatched['predicate_passed'], isFalse);
      expect(mismatched['wer'], greaterThan(0));
    }
  });

  test('edge rejection credits only the outcome the contract names', () async {
    final byId = edgeFixturesById();
    final silence = byId['edge_silence']!;
    final truncated = byId['edge_truncated_riff']!;

    final empty = await recognizeEdge(silence);
    expect(empty['predicate_passed'], isTrue);
    expect(empty['rejected_with'], 'LlamaSpeechException');
    expect(empty['message'], silence.rejectionMessage);
    expect(empty.containsKey('transcript'), isFalse);
    expect(empty.containsKey('wer'), isFalse);

    final otherFailure = await recognizeEdge(
      silence,
      failure: LlamaSpeechException('Speech recognition failed.'),
    );
    expect(otherFailure['predicate_passed'], isFalse);
    expect(otherFailure['rejected_with'], 'LlamaSpeechException');
    expect(otherFailure['message'], 'Speech recognition failed.');

    final transcribedSilence = await recognizeEdge(
      silence,
      deltas: [edgeReference],
    );
    expect(transcribedSilence['predicate_passed'], isFalse);
    expect(transcribedSilence['transcript'], edgeReference);

    final formatRejection = await recognizeEdge(
      truncated,
      failure: LlamaAudioFormatException('Unsupported RIFF header.'),
    );
    expect(formatRejection['predicate_passed'], isTrue);
    expect(formatRejection['rejected_with'], 'LlamaAudioFormatException');

    final plainRejection = await recognizeEdge(
      truncated,
      failure: LlamaSpeechException('Speech recognition failed.'),
    );
    expect(plainRejection['predicate_passed'], isFalse);

    final unrelated = await recognizeEdge(truncated, deltas: ['Answer.']);
    expect(unrelated['predicate_passed'], isTrue);
    expect(unrelated['wer'], greaterThan(0));

    final reproduced = await recognizeEdge(truncated, deltas: [edgeReference]);
    expect(reproduced['predicate_passed'], isFalse);
    expect(reproduced['wer'], 0);
  });

  test('the public adapter cancels a generation that is running', () async {
    final adapter = edgeAdapter(
      deltas: const ['and ', 'so ', 'my ', 'fellow ', 'americans'],
      tokenDelay: const Duration(milliseconds: 20),
      laterTokenDelay: const Duration(milliseconds: 250),
    );
    await adapter.load();
    final generated = await adapter.execute();
    expect(generated['predicate_passed'], isTrue);
    final reference = generated['elapsed_ms']! as double;
    final cancelled = await adapter.execute(cancel: true);
    await adapter.dispose();
    expect(cancelled['cancelled'], isTrue);
    expect(cancelled['cancel_in_flight'], isTrue);
    expect(cancelled['reference_generation_ms'], reference);
    expect(cancelled['cancel_after_ms'], greaterThanOrEqualTo(reference * 0.5));
    expect(cancelled['cancel_latency_ms'], isA<double>());
    expect(cancelled['cancel_latency_ms'], greaterThanOrEqualTo(0));
  });

  test('the public adapter cancels on hand-back without waiting', () async {
    final adapter = edgeAdapter(
      deltas: const ['and ', 'so ', 'my ', 'fellow ', 'americans'],
      tokenDelay: const Duration(milliseconds: 40),
    );
    await adapter.load();
    final unreferenced = await adapter.execute(cancelImmediately: true);
    expect(unreferenced['cancel_immediate'], isTrue);
    final generated = await adapter.execute();
    final reference = generated['elapsed_ms']! as double;
    final cancelled = await adapter.execute(cancelImmediately: true);
    await expectLater(
      adapter.execute(cancel: true, cancelImmediately: true),
      throwsArgumentError,
    );
    await adapter.dispose();
    expect(cancelled['cancelled'], isTrue);
    expect(cancelled['cancel_immediate'], isTrue);
    expect(cancelled.containsKey('cancel_in_flight'), isFalse);
    expect(
      cancelled['cancel_after_ms'],
      lessThan(reference * speechCancelInFlightLeadFraction),
    );
    expect(cancelled['cancel_latency_ms'], greaterThanOrEqualTo(0));
  });

  test('the public adapter cancels into its latest generation', () async {
    const cancelAck = Duration(milliseconds: 100);
    for (final pack in ['stt', 'tts']) {
      final adapter = edgeAdapter(
        pack: pack,
        engine: CancellableSpeechEngine(
          completedTokenDelays: const [
            Duration(milliseconds: 40),
            Duration.zero,
          ],
          cancelAckDelay: cancelAck,
        ),
      );
      await adapter.load();
      await adapter.execute();
      final latestWatch = Stopwatch()..start();
      final latest = await adapter.execute();
      latestWatch.stop();
      final cancelled = await adapter.execute(cancel: true);
      await adapter.dispose();
      final reference = latest['elapsed_ms']! as double;
      expect(
        reference,
        lessThanOrEqualTo(latestWatch.elapsedMicroseconds / 1000),
        reason: pack,
      );
      expect(cancelled['reference_generation_ms'], reference, reason: pack);
      expect(cancelled['cancel_in_flight'], isTrue, reason: pack);
      expect(
        cancelled['cancel_latency_ms'],
        greaterThan(cancelAck.inMilliseconds / 2),
        reason: pack,
      );
    }
  });

  test(
    'the public adapter cancels before an instant generation ends',
    () async {
      for (final pack in ['stt', 'tts']) {
        final adapter = edgeAdapter(
          pack: pack,
          engine: CancellableSpeechEngine(
            completedTokenDelays: [Duration.zero],
          ),
        );
        await adapter.load();
        final cancelled = await adapter.execute(cancelImmediately: true);
        await adapter.dispose();
        expect(cancelled['cancelled'], isTrue, reason: pack);
        expect(cancelled['cancel_immediate'], isTrue, reason: pack);
      }
    },
  );

  test('a cancellation with no generation to cancel is refused', () async {
    final adapter = edgeAdapter(deltas: const [edgeReference]);
    await adapter.load();
    await expectLater(adapter.execute(cancel: true), throwsStateError);
    await adapter.dispose();
  });
  test('edge measurement reports the fixture and guards its pack', () async {
    final byId = edgeFixturesById();
    final stereo = byId['edge_stereo_44100']!;
    final engine = FakeSpeechEngine(deltas: [edgeReference]);
    final recorded = edgeAdapter(engine: engine);
    await recorded.load();
    final measured = await recorded.executeEdge(stereo);
    await recorded.dispose();
    expect(engine.audioParts, hasLength(1));
    expect(engine.audioParts.single.bytes, stereo.bytes);
    expect(engine.audioParts.single.path, isNull);
    expect(measured['contract'], stereo.contract.name);
    expect(measured['rationale'], stereo.rationale);
    expect(measured['fixture_bytes'], stereo.bytes.length);
    expect(measured['sample_rate_hz'], 44100);
    expect(measured['channels'], 2);
    expect(measured['audio_seconds'], stereo.seconds);
    expect(measured['elapsed_ms'], isA<double>());

    await expectLater(
      edgeAdapter().executeEdge(stereo),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'Speech engine is not loaded',
        ),
      ),
    );

    final tts = edgeAdapter(pack: 'tts');
    await tts.load();
    await expectLater(
      tts.executeEdge(stereo),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'Speech edge fixtures require the STT pack',
        ),
      ),
    );
    await tts.dispose();
  });

  test(
    'existing output directory is never modified on CLI rejection',
    () async {
      final directory = Directory.systemTemp.createTempSync('speech-output-');
      try {
        final sentinel = File('${directory.path}/failure.json')
          ..writeAsStringSync('keep');
        final result = await Process.run(Platform.resolvedExecutable, [
          'run',
          'bin/speech.dart',
          '--pack',
          'tts',
          '--out',
          directory.path,
        ]);
        expect(result.exitCode, isNot(0));
        expect(sentinel.readAsStringSync(), 'keep');
        expect(directory.listSync(), hasLength(1));
      } finally {
        directory.deleteSync(recursive: true);
      }
    },
  );

  Map<String, Object?> rowOf(Map<String, Object?> result, String id) =>
      (result['checks'] as List).cast<Map<String, Object?>>().singleWhere(
        (row) => row['id'] == id,
      );
  const interruptIds = [
    'unload_during_synthesis',
    'dispose_during_synthesis',
    'decode_cancel',
  ];
  const limitIds = ['max_output_tokens_truncation', 'context_size_truncation'];

  test(
    'interrupt and limit checks are opt-in and deliberately counted',
    () async {
      final tts = FakeInterruptSpeech();
      final interrupted = await runSpeechValidation(
        tts,
        checkSynthesisInterrupts: true,
        residentBytes: stableResidentBytes,
      );
      expect(interrupted['expected_checks'], speechLifecycleCheckCount + 3);
      expect(interrupted['checks'], hasLength(speechLifecycleCheckCount + 3));
      expect(interrupted['functional_pass'], true);
      final ttsIds = [
        for (final row in interrupted['checks'] as List) row['id'] as String,
      ];
      expect(
        ttsIds.sublist(
          ttsIds.indexOf('after_invalid') + 1,
          ttsIds.indexOf('reload'),
        ),
        interruptIds,
      );
      expect(
        tts.calls.sublist(
          tts.calls.indexOf('unload_synthesis'),
          tts.calls.indexOf('decode_cancel') + 1,
        ),
        ['unload_synthesis', 'dispose_synthesis', 'decode_cancel'],
      );

      final stt = FakeLimitSpeech();
      final limited = await runSpeechValidation(
        stt,
        checkTranscriptLimits: true,
        residentBytes: stableResidentBytes,
      );
      expect(limited['expected_checks'], speechLifecycleCheckCount + 2);
      expect(limited['functional_pass'], true);
      final sttIds = [
        for (final row in limited['checks'] as List) row['id'] as String,
      ];
      expect(
        sttIds.sublist(
          sttIds.indexOf('after_invalid') + 1,
          sttIds.indexOf('reload'),
        ),
        limitIds,
      );

      final lifecycleOnly = await runSpeechValidation(
        FakeInterruptSpeech(),
        residentBytes: stableResidentBytes,
      );
      expect(lifecycleOnly['expected_checks'], speechLifecycleCheckCount);
      expect(
        () => runSpeechValidation(FakeSpeech(), checkSynthesisInterrupts: true),
        throwsArgumentError,
      );
      expect(
        () => runSpeechValidation(FakeSpeech(), checkTranscriptLimits: true),
        throwsArgumentError,
      );
    },
  );

  test('a teardown that does not cancel a synthesis in flight fails', () async {
    for (final (report, message) in <(Map<String, Object?>, String?)>[
      ({'in_flight': false}, 'not in flight'),
      ({'frames_before_teardown': 0}, 'not in flight'),
      ({'completion_state': 'completed'}, 'did not cancel'),
      ({'final_events': 1}, 'did not cancel'),
      ({'teardown_latency_ms': double.nan}, 'not measured'),
      ({'teardown_latency_ms': null}, 'not measured'),
      (
        {
          'after_teardown': {'predicate_passed': false},
        },
        null,
      ),
      ({'after_teardown': null}, null),
    ]) {
      final result = await runSpeechValidation(
        FakeInterruptSpeech()..teardownReport = report,
        checkSynthesisInterrupts: true,
        residentBytes: stableResidentBytes,
      );
      expect(result['functional_pass'], false, reason: '$report');
      for (final id in interruptIds.take(2)) {
        final row = rowOf(result, id);
        expect(row['status'], 'FAIL', reason: '$id $report');
        if (message != null) {
          expect(row['message'], contains(message), reason: '$id $report');
        }
      }
    }
  });

  test('teardown checks pass at 500 ms and fail just past it', () async {
    for (final (latency, within) in [
      (499.999, true),
      (500.0, true),
      (500.001, false),
    ]) {
      final result = await runSpeechValidation(
        FakeInterruptSpeech()
          ..teardownReport = {'teardown_latency_ms': latency},
        checkSynthesisInterrupts: true,
        residentBytes: stableResidentBytes,
      );
      for (final id in interruptIds.take(2)) {
        final row = rowOf(result, id);
        expect(row['budget_ms'], 500.0, reason: '$id $latency');
        expect(row['status'], within ? 'PASS' : 'FAIL', reason: '$id $latency');
      }
      expect(result['functional_pass'], within, reason: '$latency');
    }
  });

  test('a decode cancellation without its preconditions fails', () async {
    Map<String, Object?> reference({
      Object? frames = speechDecodeCancelFrameCap,
      Object? truncated = true,
      Object? decode = 400.0,
    }) => {'frames': frames, 'truncated': truncated, 'decode_ms': decode};
    for (final (report, message) in <(Map<String, Object?>, String)>[
      ({'uncapped_frames': speechDecodeCancelFrameCap}, 'does not truncate'),
      ({'uncapped_frames': null}, 'does not truncate'),
      ({'frame_cap': speechDecodeCancelFrameCap + 1}, 'does not truncate'),
      (
        {
          'references': [reference()],
        },
        'did not stop at the frame cap',
      ),
      (
        {
          'references': [reference(), reference(truncated: false)],
        },
        'did not stop at the frame cap',
      ),
      (
        {
          'references': [reference(), reference(frames: 11)],
        },
        'did not stop at the frame cap',
      ),
      (
        {
          'references': [reference(), reference(decode: 0.0)],
        },
        'did not stop at the frame cap',
      ),
      (
        {
          'references': [reference(), reference(decode: null)],
        },
        'did not stop at the frame cap',
      ),
      ({'cancel_after_decode_start_ms': 99.999}, 'inside the reference'),
      ({'cancel_after_decode_start_ms': 400.0}, 'inside the reference'),
      ({'cancel_after_decode_start_ms': null}, 'inside the reference'),
      ({'frames_before_cancel': null}, 'decoding synthesis'),
      ({'cancel_in_flight': false}, 'decoding synthesis'),
      ({'completion_state': 'completed'}, 'final result'),
      ({'final_events': 1}, 'final result'),
      ({'cancel_latency_ms': double.infinity}, 'not measured'),
    ]) {
      final result = await runSpeechValidation(
        FakeInterruptSpeech()..decodeReport = report,
        checkSynthesisInterrupts: true,
        residentBytes: stableResidentBytes,
      );
      final row = rowOf(result, 'decode_cancel');
      expect(row['status'], 'FAIL', reason: '$report');
      expect(row['message'], contains(message), reason: '$report');
      expect(result['functional_pass'], false, reason: '$report');
    }
  });

  test(
    'decode cancellation passes at half the shorter reference remainder',
    () async {
      for (final (latency, within) in [
        (1.0, true),
        (150.0, true),
        (150.001, false),
        (160.0, false),
      ]) {
        final result = await runSpeechValidation(
          FakeInterruptSpeech()..decodeReport = {'cancel_latency_ms': latency},
          checkSynthesisInterrupts: true,
          residentBytes: stableResidentBytes,
        );
        final row = rowOf(result, 'decode_cancel');
        expect(row['reference_decode_ms'], 400.0, reason: '$latency');
        expect(row['reference_remainder_ms'], 300.0, reason: '$latency');
        expect(row['budget_ms'], 150.0, reason: '$latency');
        expect(row['lead_fraction'], 0.25, reason: '$latency');
        expect(row['remainder_budget'], 0.5, reason: '$latency');
        expect(row['status'], within ? 'PASS' : 'FAIL', reason: '$latency');
        expect(result['functional_pass'], within, reason: '$latency');
      }
    },
  );

  test('transcript prefixes credit only a strict cut of the reference', () {
    const reference = 'And so, my fellow Americans';
    expect(speechTranscriptPrefixHolds(reference, 'and so'), isTrue);
    expect(speechTranscriptPrefixHolds(reference, 'And so, my fel'), isTrue);
    expect(
      speechTranscriptPrefixHolds(reference, 'and so my fellow americ'),
      isTrue,
    );
    expect(speechTranscriptPrefixHolds(reference, ''), isFalse);
    expect(speechTranscriptPrefixHolds(reference, reference), isFalse);
    expect(speechTranscriptPrefixHolds(reference, '$reference and'), isFalse);
    expect(speechTranscriptPrefixHolds(reference, 'and to my'), isFalse);
    expect(speechTranscriptPrefixHolds(reference, 'and so mx'), isFalse);
  });

  test('a transcript limit check without its preconditions fails', () async {
    const maxTokens = LlamaSpeechTranscriptLimit.maxOutputTokens;
    const contextSize = LlamaSpeechTranscriptLimit.contextSize;
    for (final (limit, report, message)
        in <(LlamaSpeechTranscriptLimit, Map<String, Object?>, String?)>[
          (maxTokens, {'transcript_tokens': 11}, 'fits in maxOutputTokens'),
          (maxTokens, {'transcript_tokens': null}, 'fits in maxOutputTokens'),
          (maxTokens, {'max_output_tokens': 0}, 'fits in maxOutputTokens'),
          (contextSize, {'context_size': 4096}, 'context size differs'),
          (contextSize, {'max_output_tokens': 511}, 'context size differs'),
          (maxTokens, {'truncated_limit': 'contextSize'}, 'did not fail'),
          (contextSize, {'truncated_limit': null}, 'did not fail'),
          (maxTokens, {'reference': null}, 'no reference'),
          (contextSize, {'reference_repeats': 0}, 'no reference'),
          (maxTokens, {'partial_transcript': ''}, null),
          (
            maxTokens,
            {'partial_transcript': 'and so my fellow americans'},
            null,
          ),
          (contextSize, {'partial_transcript': 'ask not'}, null),
          (
            maxTokens,
            {
              'after_truncation': {'predicate_passed': false},
            },
            null,
          ),
          (contextSize, {'after_truncation': null}, null),
        ]) {
      final reason = '${limit.name} $report';
      final result = await runSpeechValidation(
        FakeLimitSpeech()..reports[limit] = report,
        checkTranscriptLimits: true,
        residentBytes: stableResidentBytes,
      );
      final row = rowOf(
        result,
        limit == maxTokens
            ? 'max_output_tokens_truncation'
            : 'context_size_truncation',
      );
      expect(row['status'], 'FAIL', reason: reason);
      if (message != null) {
        expect(row['message'], contains(message), reason: reason);
      }
      expect(result['functional_pass'], false, reason: reason);
    }
  });

  PublicSpeechValidationAdapter synthesisAdapter(SynthesisSpeechEngine engine) {
    var created = 0;
    return PublicSpeechValidationAdapter(
      model: 'model.gguf',
      projector: 'mmproj.gguf',
      backend: GpuBackend.cpu,
      pack: 'tts',
      saveAudio: (_) async {},
      createEngine: () {
        created++;
        engine.loaded.add('created:$created');
        return engine;
      },
    );
  }

  test('the public adapter interrupts a synthesis in flight', () async {
    final engine = SynthesisSpeechEngine();
    final adapter = synthesisAdapter(engine);
    await adapter.load();
    await adapter.execute();
    final unloaded = await adapter.executeTeardown(dispose: false);
    expect(engine.teardowns, ['unload']);
    expect(unloaded['in_flight'], isTrue);
    expect(unloaded['frames_before_teardown'], 1);
    expect(unloaded['completion_state'], 'cancelled');
    expect(unloaded['final_events'], 0);
    expect(
      unloaded['teardown_latency_ms'],
      lessThan(SynthesisSpeechEngine.decodeDelay.inMilliseconds),
    );
    expect(unloaded['teardown_call_ms'], isA<double>());
    expect((unloaded['after_teardown'] as Map)['predicate_passed'], isTrue);
    expect(engine.loaded.where((path) => path.startsWith('created')), [
      'created:1',
    ]);
    expect(engine.loaded.where((path) => path == 'model.gguf'), hasLength(2));

    final disposed = await adapter.executeTeardown(dispose: true);
    expect(engine.teardowns, ['unload', 'dispose']);
    expect(engine.disposals, 1);
    expect(disposed['completion_state'], 'cancelled');
    expect(engine.loaded.where((path) => path.startsWith('created')), [
      'created:1',
      'created:2',
    ]);

    final decode = await adapter.executeDecodeCancel();
    expect(
      engine.requestedFrames.skip(
        engine.requestedFrames.length - speechDecodeCancelReferenceRuns - 1,
      ),
      List.filled(
        speechDecodeCancelReferenceRuns + 1,
        speechDecodeCancelFrameCap,
      ),
    );
    expect(decode['uncapped_frames'], SynthesisSpeechEngine.naturalFrames);
    final references = decode['references'] as List;
    expect(references, hasLength(speechDecodeCancelReferenceRuns));
    final shortest = references
        .map((reference) => reference['decode_ms'] as double)
        .reduce(math.min);
    for (final reference in references) {
      expect(reference['frames'], speechDecodeCancelFrameCap);
      expect(reference['truncated'], isTrue);
    }
    expect(
      decode['cancel_after_decode_start_ms'],
      greaterThanOrEqualTo(shortest * speechDecodeCancelLeadFraction),
    );
    expect(decode['frames_before_cancel'], speechDecodeCancelFrameCap);
    expect(decode['cancel_in_flight'], isTrue);
    expect(decode['completion_state'], 'cancelled');
    await adapter.dispose();
    final stt = edgeAdapter();
    await stt.load();
    await expectLater(
      stt.executeTeardown(dispose: false),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'Synthesis interrupts require the TTS pack',
        ),
      ),
    );
    await stt.dispose();
  });

  test('interrupt checks pass only when the runtime ends the work', () async {
    for (final (engine, failing) in [
      (SynthesisSpeechEngine(), <String>[]),
      (
        SynthesisSpeechEngine(teardownCancels: false),
        ['unload_during_synthesis', 'dispose_during_synthesis'],
      ),
      (SynthesisSpeechEngine(decodeHonoursCancel: false), ['decode_cancel']),
    ]) {
      final result = await runSpeechValidation(
        DelegatingSpeech(synthesisAdapter(engine)),
        checkSynthesisInterrupts: true,
        residentBytes: stableResidentBytes,
      );
      for (final id in interruptIds) {
        expect(
          rowOf(result, id)['status'],
          failing.contains(id) ? 'FAIL' : 'PASS',
          reason: '$failing ${rowOf(result, id)}',
        );
      }
      expect(result['functional_pass'], failing.isEmpty, reason: '$failing');
    }
  });

  PublicSpeechValidationAdapter limitAdapter(LimitedRecognitionEngine engine) {
    final wav = Uint8List.fromList(
      File('assets/speech/jfk.wav').readAsBytesSync(),
    );
    return PublicSpeechValidationAdapter(
      model: 'model.gguf',
      projector: 'mmproj.gguf',
      backend: GpuBackend.cpu,
      pack: 'stt',
      audio: wav,
      audioSeconds: speechFixtureSeconds(wav),
      reference: jfkReference,
      saveAudio: (_) async {},
      createEngine: () => engine,
    );
  }

  test('the public adapter drives recognition into each limit', () async {
    final wav = File('assets/speech/jfk.wav').readAsBytesSync();
    final engine = LimitedRecognitionEngine(fixtureBytes: wav.length);
    final adapter = limitAdapter(engine);
    await adapter.load();
    await expectLater(
      adapter.executeTranscriptLimit(
        LlamaSpeechTranscriptLimit.maxOutputTokens,
      ),
      throwsStateError,
    );
    await adapter.execute();
    final byTokens = await adapter.executeTranscriptLimit(
      LlamaSpeechTranscriptLimit.maxOutputTokens,
    );
    final referenceTokens = referenceWords(1).length;
    expect(byTokens['reference_tokens'], referenceTokens);
    expect(byTokens['transcript_tokens'], referenceTokens);
    final limit = (referenceTokens * speechTruncationTokenFraction).floor();
    expect(byTokens['max_output_tokens'], limit);
    expect(engine.maxTokens.skip(1), [limit, 512]);
    expect(byTokens['truncated_limit'], 'maxOutputTokens');
    expect(
      byTokens['partial_transcript'],
      referenceWords(1).take(limit).join(' '),
    );
    expect((byTokens['after_truncation'] as Map)['wer'], 0);

    final byContext = await adapter.executeTranscriptLimit(
      LlamaSpeechTranscriptLimit.contextSize,
    );
    final long = edgeFixturesById()['edge_long_boundary']!;
    expect(engine.contextSizes, [4096, speechTruncationContextSize, 4096]);
    expect(byContext['context_size'], speechTruncationContextSize);
    expect(byContext['max_output_tokens'], 512);
    expect(byContext['reference_repeats'], long.referenceRepeats);
    expect(engine.audioParts[engine.audioParts.length - 2].bytes, long.bytes);
    expect(byContext['truncated_limit'], 'contextSize');
    expect((byContext['after_truncation'] as Map)['wer'], 0);
    await adapter.dispose();
    await expectLater(
      edgeAdapter(
        pack: 'tts',
      ).executeTranscriptLimit(LlamaSpeechTranscriptLimit.contextSize),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'Transcript limit checks require the STT pack',
        ),
      ),
    );
  });

  test('limit checks pass only for the typed truncation', () async {
    final wav = File('assets/speech/jfk.wav').readAsBytesSync();
    for (final typed in [true, false]) {
      final result = await runSpeechValidation(
        DelegatingSpeech(
          limitAdapter(
            LimitedRecognitionEngine(fixtureBytes: wav.length, typed: typed),
          ),
        ),
        checkTranscriptLimits: true,
        residentBytes: stableResidentBytes,
      );
      for (final id in limitIds) {
        expect(
          rowOf(result, id)['status'],
          typed ? 'PASS' : 'FAIL',
          reason: '$id typed=$typed',
        );
      }
      expect(result['functional_pass'], typed, reason: 'typed=$typed');
    }
  });
}
