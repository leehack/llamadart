import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:llamadart/llamadart.dart';
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

int stableResidentBytes() => 1000;

const mib = 1024 * 1024;

List<int> mibs(Iterable<double> values) => [
  for (final value in values) (value * mib).round(),
];

List<double> parseMib(String values) => [
  for (final value in values.split(' ')) double.parse(value),
];

/// Returns one sample per check in a [FakeSpeech] run's order, then repeats
/// the last: `load` … `after_invalid` (7), `reload`, the cleanup cycles, the
/// two latency bounds, `peak_memory_bound`, `leak_slope_bound`, `dispose`.
int? Function() replay(List<int> bytes) {
  var index = 0;
  return () => bytes[math.min(index++, bytes.length - 1)];
}

/// Seven flat single-shot samples at [base], then `reload` and each cycle
/// growing by [perCycle] bytes.
List<int> linearCycles(int perCycle, {int base = 1000 * mib}) => [
  for (var i = 0; i < 7; i++) base,
  for (var cycle = 0; cycle <= speechCleanupCycles; cycle++)
    base + cycle * perCycle,
];

Map<String, Object?> checkRow(Map<String, Object?> result, String id) =>
    (result['checks'] as List).cast<Map<String, Object?>>().singleWhere(
      (row) => row['id'] == id,
    );

/// Resident MiB after `load` … `after_invalid`, then after each of the next
/// seven checks, which dispose and reload or cancel, in measured order, from
/// `tts` runs on GCE g2-standard-8 + NVIDIA L4, Linux CUDA, native v0.5.0
/// (#686). T1/T2 ran `reload` and three cycles first, the others after the
/// #668 interrupt checks. Replayed onto `reload` and cycles 1-6.
const linuxCudaTtsMib = {
  'T1':
      '837.7 1134.1 1134.1 1141.2 1148.1 1148.1 1150.3 1159.3 1159.5 1175.7 '
      '1175.8 1199.7 1299.1 1299.1',
  'T2':
      '849.8 1141.8 1141.8 1154.0 1160.9 1160.9 1163.0 1250.8 1255.3 1302.6 '
      '1325.7 1287.2 1293.5 1282.4',
  'B3':
      '840.1 1132.1 1132.1 1135.1 1142.0 1142.0 1143.5 1237.1 1248.3 1261.1 '
      '1267.8 1303.3 1303.6 1303.7',
  'B4':
      '840.9 1137.9 1137.9 1140.5 1145.0 1145.0 1148.9 1214.1 1246.3 1248.2 '
      '1254.0 1228.2 1265.5 1283.6',
  'L08':
      '847.4 1143.7 1143.8 1150.8 1150.9 1150.9 1158.9 1219.9 1231.2 1231.3 '
      '1274.3 1273.9 1252.7 1258.5',
  'L10':
      '853.8 1149.3 1149.3 1151.9 1159.0 1159.1 1160.6 1193.5 1252.9 1254.8 '
      '1260.5 1259.1 1219.1 1219.3',
  'L11':
      '852.5 1144.9 1145.0 1151.0 1157.8 1157.8 1159.9 1181.1 1217.3 1219.2 '
      '1221.7 1227.1 1259.5 1240.8',
};

/// Resident MiB after `load` … `after_invalid`, `reload` and 14 cleanup
/// cycles, macOS arm64 (Apple M4 Max), load average 3.5-6.1, 2026-09-25 (#686).
/// `stt` omits its `bytes_input` and edge-fixture samples.
const macosMib = {
  'tts/cpu':
      '3129.1 5446.5 5446.5 5446.8 5446.6 5446.6 5447.0 5458.0 5460.2 5462.2 '
      '5462.4 5464.5 5467.7 5469.7 5470.9 5476.9 5477.7 5451.8 5451.8 5452.0 '
      '5452.1 5452.2',
  'tts/metal':
      '2479.2 3925.0 3925.0 3925.1 3925.5 3925.5 3927.4 3935.6 3936.4 3936.9 '
      '3947.5 3951.8 3955.1 3957.0 3957.7 3958.4 3960.7 3961.2 3962.5 3963.1 '
      '3963.8 3965.0',
  'stt/cpu':
      '2339.7 2527.5 2529.3 2529.5 2529.6 2529.6 2529.6 2542.9 2552.8 2554.5 '
      '2556.4 2556.4 2556.4 2556.4 2556.4 2556.4 2556.4 2556.4 2556.4 2556.4 '
      '2556.4 2556.4',
};

/// The #634 LiteRT ASR leak in the same layout and run as [macosMib].
const macosLiteRtAsrMib =
    '364.3 465.5 473.7 479.8 484.6 484.7 489.1 494.3 508.4 556.5 575.7 590.6 '
    '604.7 618.7 632.8 646.9 660.9 674.9 689.0 705.0 719.0 733.0';

/// [series] with `reload` and the cycles taken from [offset] cycles later.
List<double> shifted(List<double> series, int offset) => [
  ...series.take(7),
  ...series.skip(7 + offset).take(speechCleanupCycles + 1),
];

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
  test('a run executes exactly these checks, in order', () async {
    final result = await runSpeechValidation(
      FakeSpeech(),
      residentBytes: stableResidentBytes,
    );
    expect(speechLifecycleCheckCount, 19);
    expect(
      [for (final row in result['checks'] as List) row['id']],
      [
        'load',
        'generate',
        'cancel_immediate',
        'cancel',
        'after_cancel',
        'invalid_input',
        'after_invalid',
        'reload',
        for (var cycle = 1; cycle <= 6; cycle++) 'cleanup_cycle_$cycle',
        'cancel_latency_bound',
        'immediate_cancel_latency_bound',
        'peak_memory_bound',
        'leak_slope_bound',
        'dispose',
      ],
    );
    expect(result['expected_checks'], 19);
    final leak = (result['bounds'] as Map)['leak_slope'] as Map;
    expect(leak['warmup_cycles'], 1);
    expect(leak['window_cycles'], 5);
    expect(leak['growth_threshold_bytes'], 7 * mib);
  });
  test('leak slope passes at 7 MiB per cycle and fails just past it', () async {
    for (final (perCycle, within) in [(7 * mib, true), (7 * mib + 1, false)]) {
      final reason = 'growth $perCycle bytes per cycle';
      final result = await runSpeechValidation(
        FakeSpeech(),
        residentBytes: replay(linearCycles(perCycle)),
      );
      final bound = checkRow(result, 'leak_slope_bound');
      expect(bound['status'], within ? 'PASS' : 'FAIL', reason: reason);
      expect(
        bound['cycle_growth_bytes'],
        List.filled(5, perCycle),
        reason: reason,
      );
      expect(bound['growth_threshold_bytes'], 7 * mib, reason: reason);
      final reported = (result['bounds'] as Map)['leak_slope'] as Map;
      expect(reported['measured'], true, reason: reason);
      expect(reported['within_budget'], within, reason: reason);
      expect(checkRow(result, 'peak_memory_bound')['status'], 'PASS');
      expect(result['functional_pass'], within, reason: reason);
    }
  });
  test(
    'the measured LiteRT ASR leak fails the leak slope everywhere',
    () async {
      final leak = parseMib(macosLiteRtAsrMib);
      for (
        var offset = 0;
        offset + speechCleanupCycles < leak.length - 7;
        offset++
      ) {
        final result = await runSpeechValidation(
          FakeSpeech(),
          residentBytes: replay(mibs(shifted(leak, offset))),
          operatingSystem: 'linux',
          backend: 'cuda',
        );
        final bound = checkRow(result, 'leak_slope_bound');
        expect(bound['status'], 'FAIL', reason: 'offset $offset');
        expect(result['functional_pass'], false, reason: 'offset $offset');
      }
    },
  );
  test(
    'measured Linux CUDA plateaus pass the leak slope and skip only the ratio',
    () async {
      for (final MapEntry(key: run, value: text) in linuxCudaTtsMib.entries) {
        final series = parseMib(text);
        final exempt = await runSpeechValidation(
          FakeSpeech(),
          residentBytes: replay(mibs(series)),
          operatingSystem: 'linux',
          backend: 'cuda',
        );
        expect(checkRow(exempt, 'leak_slope_bound')['status'], 'PASS');
        final ratio = checkRow(exempt, 'peak_memory_bound');
        expect(ratio['status'], 'SKIP', reason: run);
        expect(
          ratio['skip_reason'],
          speechPeakRatioExemption(operatingSystem: 'linux', backend: 'cuda'),
        );
        expect(ratio['peak_rss_growth'], isA<double>(), reason: run);
        final reported =
            (exempt['bounds'] as Map)['peak_resident_bytes'] as Map;
        expect(reported['measured'], true, reason: run);
        expect(reported['applies'], false, reason: run);
        expect(reported['within_budget'], isNull, reason: run);
        expect(exempt['functional_pass'], true, reason: run);

        final unknown = await runSpeechValidation(
          FakeSpeech(),
          residentBytes: replay(mibs(series)),
        );
        final strict = checkRow(unknown, 'peak_memory_bound');
        final over = (strict['peak_rss_growth']! as double) > 1.10;
        expect(strict['status'], over ? 'FAIL' : 'PASS', reason: run);
        expect(unknown['functional_pass'], !over, reason: run);
      }
      final overRatio = [
        for (final series in linuxCudaTtsMib.values.map(parseMib))
          if (series.skip(2).reduce(math.max) / series[1] > 1.10) series,
      ];
      expect(overRatio, hasLength(6));
    },
  );
  test('measured macOS runs pass both memory bounds everywhere', () async {
    for (final MapEntry(key: run, value: text) in macosMib.entries) {
      final series = parseMib(text);
      for (
        var offset = 0;
        offset + speechCleanupCycles < series.length - 7;
        offset++
      ) {
        final reason = '$run offset $offset';
        final result = await runSpeechValidation(
          FakeSpeech(),
          residentBytes: replay(mibs(shifted(series, offset))),
          operatingSystem: 'macos',
          backend: run.split('/').last,
        );
        expect(
          checkRow(result, 'peak_memory_bound')['status'],
          'PASS',
          reason: reason,
        );
        expect(
          checkRow(result, 'leak_slope_bound')['status'],
          'PASS',
          reason: reason,
        );
        expect(result['functional_pass'], true, reason: reason);
      }
    }
  });
  test(
    'a stepped plateau passes and a steady leak of the same growth fails',
    () async {
      // The step sizes are measured Linux CUDA reload steps (#686).
      final stepped = [
        ...List.filled(7, 1150.0),
        1150.0,
        1150.0,
        1197.3,
        1197.3,
        1234.6,
        1234.6,
        1270.1,
      ];
      final total = stepped.last - stepped[8];
      final steady = [
        ...List.filled(7, 1150.0),
        1150.0,
        for (var i = 0; i <= 5; i++) 1150.0 + total * i / 5,
      ];
      for (final (series, pass) in [(stepped, true), (steady, false)]) {
        final result = await runSpeechValidation(
          FakeSpeech(),
          residentBytes: replay(mibs(series)),
          operatingSystem: 'linux',
          backend: 'cuda',
        );
        expect(
          checkRow(result, 'leak_slope_bound')['status'],
          pass ? 'PASS' : 'FAIL',
        );
        expect(result['functional_pass'], pass);
      }
    },
  );
  test('a single spike passes the leak slope but not the ratio', () async {
    final series = [
      ...List.filled(7, 1000.0),
      1000.0,
      1000.0,
      1000.0,
      1500.0,
      1000.0,
      1000.0,
      1000.0,
    ];
    final result = await runSpeechValidation(
      FakeSpeech(),
      residentBytes: replay(mibs(series)),
    );
    final leak = checkRow(result, 'leak_slope_bound');
    expect(leak['status'], 'PASS');
    expect(leak['cycle_growth_bytes'], [0, 500 * mib, -500 * mib, 0, 0]);
    expect(checkRow(result, 'peak_memory_bound')['status'], 'FAIL');
    expect(result['functional_pass'], false);
  });
  test('growth during warm-up does not count toward the leak slope', () async {
    // Measured x64 CPU and Linux CUDA reload steps, arranged as a climb that
    // stops in the last window cycle.
    final series = mibs([...List.filled(7, 3800.0), 3804.6]);
    for (final step in [35.0, 17.2, 39.8, 36.7, 35.5, 0.2]) {
      series.add(series.last + (step * mib).round());
    }
    final result = await runSpeechValidation(
      FakeSpeech(),
      residentBytes: replay(series),
    );
    final leak = checkRow(result, 'leak_slope_bound');
    expect(leak['window_rss_bytes'], series.sublist(8));
    expect(leak['status'], 'PASS');
    expect(result['functional_pass'], true);
  });
  test('the leak window spans five cycles', () async {
    // Measured macOS `tts` CPU run recovering from memory pressure, the #633
    // pattern: four consecutive steps above the threshold, placed inside the
    // window.
    final recovery = mibs([
      ...List.filled(7, 4932.4),
      2493.4,
      2493.4,
      2688.2,
      4789.8,
      4802.4,
      4811.2,
      4811.2,
      4811.2,
    ]);
    // Cycles 2-6 each grow by 8 MiB, then the resident set stays flat.
    final fiveCycleLeak = mibs([
      ...List.filled(9, 1000.0),
      for (var cycle = 2; cycle <= 6; cycle++) 1000.0 + 8 * (cycle - 1),
      1040.0,
    ]);
    for (final (series, pass) in [(recovery, true), (fiveCycleLeak, false)]) {
      final result = await runSpeechValidation(
        FakeSpeech(),
        residentBytes: replay(series),
        operatingSystem: 'linux',
        backend: 'cuda',
      );
      expect(
        checkRow(result, 'leak_slope_bound')['status'],
        pass ? 'PASS' : 'FAIL',
      );
    }
  });
  test('the peak ratio is exempt only on Linux CUDA', () {
    expect(
      speechPeakRatioExemption(operatingSystem: 'linux', backend: 'cuda'),
      isNotNull,
    );
    for (final (os, backend) in [
      ('windows', 'cuda'),
      ('linux', 'cpu'),
      ('linux', 'vulkan'),
      ('linux', 'opencl'),
      ('macos', 'metal'),
      ('macos', 'cpu'),
      ('Linux', 'CUDA'),
      (null, 'cuda'),
      ('linux', null),
      (null, null),
    ]) {
      expect(
        speechPeakRatioExemption(operatingSystem: os, backend: backend),
        isNull,
        reason: '$os/$backend',
      );
    }
  });
  test('the measured low-baseline failure still fails the ratio', () async {
    // #633: macOS CPU `tts` whose `generate` sample was low (GB). The issue
    // gives 5.51-5.52 GB for its three cleanup cycles; cycles 4-6 repeat 5.52.
    final series = mibs([
      for (final gb in [
        3.26, 3.71, 3.71, 5.09, 5.15, 5.15, 5.15, 5.50, //
        5.51, 5.52, 5.52, 5.52, 5.52, 5.52,
      ])
        gb * 1024,
    ]);
    final result = await runSpeechValidation(
      FakeSpeech(),
      residentBytes: replay(series),
      operatingSystem: 'macos',
      backend: 'cpu',
    );
    expect(checkRow(result, 'leak_slope_bound')['status'], 'PASS');
    final ratio = checkRow(result, 'peak_memory_bound');
    expect(ratio['status'], 'FAIL');
    expect(ratio['peak_rss_growth'], closeTo(5.52 / 3.71, 1e-3));
    expect(result['functional_pass'], false);
  });
  test('an unmeasurable sample skips both memory bounds', () async {
    for (final (os, backend) in [('linux', 'cuda'), (null, null)]) {
      final adapter = FakeSpeech();
      final result = await runSpeechValidation(
        adapter,
        residentBytes: () => adapter.calls.last == 'invalid' ? null : 1000,
        operatingSystem: os,
        backend: backend,
      );
      for (final id in ['peak_memory_bound', 'leak_slope_bound']) {
        final row = checkRow(result, id);
        expect(row['status'], 'SKIP', reason: '$id $os');
        expect(row['skip_reason'], 'Resident set size was not measurable');
      }
      final bounds = result['bounds'] as Map;
      expect(bounds['leak_slope']['measured'], false);
      expect(bounds['leak_slope']['within_budget'], isNull);
      expect(bounds['peak_resident_bytes']['measured'], false);
      expect(result['functional_pass'], true);
    }
  });
  test('a skipped memory bound does not hide another failure', () async {
    final result = await runSpeechValidation(
      FakeSpeech()..cancelLatencyMs = speechCancelLatencyBudgetMs + 1,
      residentBytes: () => null,
      operatingSystem: 'linux',
      backend: 'cuda',
    );
    expect(checkRow(result, 'leak_slope_bound')['status'], 'SKIP');
    expect(result['functional_pass'], false);
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
}
