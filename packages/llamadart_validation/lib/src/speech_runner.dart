import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';

import 'process_memory.dart';
import 'runner.dart' show redactDiagnostic;
import 'speech_edge_fixtures.dart';

/// Word edit distance divided by reference words; insertions can exceed 1.0.
/// Normalization lowercases, replaces `.,!?:;"—–` with spaces, then splits on
/// whitespace.
double speechWordErrorRate(String reference, String actual) {
  List<String> words(String text) => text
      .toLowerCase()
      .replaceAll(RegExp(r'''[.,!?:;"—–]'''), ' ')
      .trim()
      .split(RegExp(r'\s+'))
      .where((word) => word.isNotEmpty)
      .toList();
  final expected = words(reference);
  final received = words(actual);
  if (expected.isEmpty) throw ArgumentError('Reference must contain words');
  var previous = List.generate(received.length + 1, (index) => index);
  for (var i = 1; i <= expected.length; i++) {
    final current = <int>[i];
    for (var j = 1; j <= received.length; j++) {
      final costs = [
        previous[j] + 1,
        current[j - 1] + 1,
        previous[j - 1] + (expected[i - 1] == received[j - 1] ? 0 : 1),
      ]..sort();
      current.add(costs.first);
    }
    previous = current;
  }
  return previous.last / expected.length;
}

/// Validates generated audio, returning measurements without claiming quality.
Map<String, Object?> inspectSpeechAudio(TextToSpeechResult result) {
  if (result.sampleRateHz != 24000 ||
      result.channelCount != 1 ||
      result.samples.isEmpty ||
      result.samples.any((sample) => !sample.isFinite) ||
      result.samples.every((sample) => sample == 0) ||
      result.truncated) {
    throw StateError('Invalid, silent, nonfinite or truncated TTS output');
  }
  final seconds = result.samples.length / result.sampleRateHz;
  return {
    'sample_rate_hz': result.sampleRateHz,
    'channels': result.channelCount,
    'samples': result.samples.length,
    'audio_seconds': seconds,
    'truncated': result.truncated,
    'listening_check': 'NOT_RUN',
    'intelligibility': 'UNVERIFIED',
  };
}

/// Speech-only public API adapter; independent of chat-model generation.
abstract interface class SpeechValidationAdapter {
  Future<void> load();
  Future<void> dispose();

  /// With `cancel`, cancels after a wait and reports `cancel_latency_ms`,
  /// `cancel_after_ms` and `cancel_in_flight`, which is true only if the
  /// adapter had not seen the task finish when it cancelled. With
  /// `cancelImmediately`, cancels as soon as the task is handed back, without
  /// yielding first, and reports `cancel_latency_ms`, `cancel_after_ms` and
  /// `cancel_immediate`. Setting both throws [ArgumentError].
  Future<Map<String, Object?>> execute({
    bool cancel = false,
    bool cancelImmediately = false,
    bool invalid = false,
    bool bytesInput = false,
  });
}

/// Opt-in synthetic edge-case recognition; adapters without it keep their
/// existing check count.
abstract interface class SpeechEdgeCaseAdapter {
  /// Recognizes one synthetic fixture and reports the measured outcome.
  Future<Map<String, Object?>> executeEdge(SpeechEdgeFixture fixture);
}

/// Public GGUF speech adapter used by the portable speech runner.
class PublicSpeechValidationAdapter
    implements SpeechValidationAdapter, SpeechEdgeCaseAdapter {
  PublicSpeechValidationAdapter({
    required this.model,
    required this.projector,
    required this.backend,
    required this.pack,
    required this.saveAudio,
    this.audio,
    this.audioSeconds,
    this.audioPath,
    this.reference,
    this.text = 'Hello from llamadart. The answer is forty two.',
    LlamaEngine Function()? createEngine,
  }) : _createEngine = createEngine ?? (() => LlamaEngine(LlamaBackend()));

  final String model;
  final String projector;
  final GpuBackend backend;
  final String pack;
  final Uint8List? audio;
  final double? audioSeconds;
  final String? audioPath;
  final String? reference;
  final String text;
  final Future<void> Function(Uint8List) saveAudio;
  final LlamaEngine Function() _createEngine;
  LlamaEngine? _engine;
  double? _lastGenerationMs;

  /// Public diagnostics are selector hints, not accelerator execution proof.
  Map<String, Object?> observedRuntime = {};

  @override
  Future<void> load() async {
    if (!['stt', 'tts'].contains(pack)) {
      throw ArgumentError('Unknown speech pack');
    }
    if (pack == 'stt' &&
        (audio == null ||
            reference == null ||
            audioSeconds == null ||
            !audioSeconds!.isFinite ||
            audioSeconds! <= 0)) {
      throw ArgumentError(
        'STT requires audio, transcript and measured duration',
      );
    }
    final engine = _engine = _createEngine();
    await engine.setLogLevel(LlamaLogLevel.info);
    await engine.loadModel(
      model,
      modelParams: ModelParams(
        contextSize: 4096,
        preferredBackend: backend,
        gpuLayers: backend == GpuBackend.cpu ? 0 : 99,
      ),
    );
    await engine.loadMultimodalProjector(projector);
    observedRuntime = {
      'backend_name': await engine.getBackendName(),
      'resolved_gpu_layers': await engine.getResolvedGpuLayers(),
    };
  }

  @override
  Future<void> dispose() async {
    final engine = _engine;
    _engine = null;
    await engine?.dispose();
  }

  @override
  Future<Map<String, Object?>> executeEdge(SpeechEdgeFixture fixture) async {
    if (pack != 'stt') {
      throw StateError('Speech edge fixtures require the STT pack');
    }
    final engine = _engine ?? (throw StateError('Speech engine is not loaded'));
    final measured = <String, Object?>{
      'contract': fixture.contract.name,
      'rationale': fixture.rationale,
      'fixture_bytes': fixture.bytes.length,
      'sample_rate_hz': fixture.sampleRateHz,
      'channels': fixture.channelCount,
      'audio_seconds': fixture.seconds,
    };
    final recognizer = SpeechToTextEngine(
      engine,
      modelProfile: SpeechToTextModelProfile.qwen3Asr,
    );
    final watch = Stopwatch()..start();
    final String transcript;
    try {
      final task = await recognizer.transcribe(
        SpeechToTextRequest(
          audio: SpeechAudioBytesInput(
            fixture.bytes,
            format: const SpeechAudioFormat(encoding: 'wav'),
          ),
          maxOutputTokens: 512,
        ),
      );
      final events = await task.events.toList();
      final completion = await task.done;
      if (completion.state != SpeechToTextCompletionState.completed ||
          events.whereType<SpeechToTextFinalEvent>().length != 1) {
        throw StateError('Edge fixture did not emit one completed result');
      }
      transcript = completion.result!.text;
    } on LlamaSpeechException catch (error) {
      return {
        ...measured,
        'rejected_with': '${error.runtimeType}',
        'message': redactDiagnostic(error.message),
        'elapsed_ms': watch.elapsedMicroseconds / 1000,
        'predicate_passed': speechEdgeRejectionHolds(
          fixture,
          message: error.message,
          isAudioFormat: error is LlamaAudioFormatException,
        ),
      };
    }
    final expected = List.filled(
      fixture.referenceRepeats < 1 ? 1 : fixture.referenceRepeats,
      reference!,
    ).join(' ');
    final wer = speechWordErrorRate(expected, transcript);
    return {
      ...measured,
      'transcript': transcript,
      'reference_repeats': fixture.referenceRepeats,
      'wer': wer,
      'elapsed_ms': watch.elapsedMicroseconds / 1000,
      'predicate_passed': speechEdgeTranscriptHolds(fixture, wer),
    };
  }

  Future<Map<String, Object?>> _cancelTask(
    Stopwatch watch,
    Stopwatch cancelWatch,
    Future<Object?> done,
    void Function() cancelTask, {
    required bool immediately,
  }) async {
    if (immediately) {
      final afterMs = watch.elapsedMicroseconds / 1000;
      cancelWatch.start();
      cancelTask();
      return {'cancel_after_ms': afterMs, 'cancel_immediate': true};
    }
    final reference = _lastGenerationMs;
    if (reference == null) {
      throw StateError('No measured generation to cancel into');
    }
    var settled = false;
    unawaited(
      done.then<void>(
        (_) => settled = true,
        onError: (Object _) => settled = true,
      ),
    );
    await Future<void>.delayed(
      Duration(
        microseconds: (reference * speechCancelInFlightLeadFraction * 1000)
            .round(),
      ),
    );
    final afterMs = watch.elapsedMicroseconds / 1000;
    final inFlight = !settled;
    cancelWatch.start();
    cancelTask();
    return {
      'cancel_after_ms': afterMs,
      'cancel_in_flight': inFlight,
      'reference_generation_ms': reference,
    };
  }

  @override
  Future<Map<String, Object?>> execute({
    bool cancel = false,
    bool cancelImmediately = false,
    bool invalid = false,
    bool bytesInput = false,
  }) async {
    if (cancel && cancelImmediately) {
      throw ArgumentError('cancel and cancelImmediately are exclusive');
    }
    final engine = _engine ?? (throw StateError('Speech engine is not loaded'));
    final watch = Stopwatch()..start();
    if (pack == 'stt') {
      final recognizer = SpeechToTextEngine(
        engine,
        modelProfile: SpeechToTextModelProfile.qwen3Asr,
      );
      final capability = await recognizer.capabilities;
      if (!capability.isSupported) {
        throw StateError(capability.unsupportedReason ?? 'Speech unsupported');
      }
      final task = await recognizer.transcribe(
        SpeechToTextRequest(
          audio: !invalid && !bytesInput && audioPath != null
              ? SpeechAudioFileInput(audioPath!)
              : SpeechAudioBytesInput(
                  invalid ? Uint8List(0) : audio!,
                  format: const SpeechAudioFormat(encoding: 'wav'),
                ),
          maxOutputTokens: 512,
        ),
      );
      final cancelWatch = Stopwatch();
      final cancellation = cancel || cancelImmediately
          ? await _cancelTask(
              watch,
              cancelWatch,
              task.done,
              task.cancel,
              immediately: cancelImmediately,
            )
          : null;
      final events = await task.events.toList();
      final completion = await task.done;
      if (cancellation != null) {
        cancelWatch.stop();
        if (completion.state != SpeechToTextCompletionState.cancelled ||
            events.whereType<SpeechToTextFinalEvent>().isNotEmpty) {
          throw StateError('STT cancellation emitted a final result');
        }
        return {
          'cancelled': true,
          'cancel_latency_ms': cancelWatch.elapsedMicroseconds / 1000,
          ...cancellation,
        };
      }
      if (completion.state != SpeechToTextCompletionState.completed ||
          events.whereType<SpeechToTextFinalEvent>().length != 1) {
        throw StateError('STT did not emit exactly one completed result');
      }
      final transcript = completion.result!.text;
      final wer = speechWordErrorRate(reference!, transcript);
      final elapsedMs = _lastGenerationMs = watch.elapsedMicroseconds / 1000;
      return {
        'transcript': transcript,
        'reference': reference,
        'wer': wer,
        'predicate_passed': wer == 0,
        'elapsed_ms': elapsedMs,
        'audio_seconds': audioSeconds,
        'real_time_factor': watch.elapsedMicroseconds / 1e6 / audioSeconds!,
        'first_partial_ms': null,
        'streaming_input': false,
      };
    }
    final synthesizer = TextToSpeechEngine(
      engine,
      modelProfile: TextToSpeechModelProfile.qwen3Tts,
    );
    final capability = await synthesizer.capabilities;
    if (!capability.isSupported) {
      throw StateError(capability.unsupportedReason ?? 'Speech unsupported');
    }
    final task = await synthesizer.synthesize(
      TextToSpeechRequest(
        text: invalid ? '' : text,
        language: 'English',
        maxFrames: 384,
        seed: 1,
      ),
    );
    final cancelWatch = Stopwatch();
    final cancellation = cancel || cancelImmediately
        ? await _cancelTask(
            watch,
            cancelWatch,
            task.done,
            task.cancel,
            immediately: cancelImmediately,
          )
        : null;
    double? firstAudioMs;
    var finals = 0;
    await for (final event in task.events) {
      if (event is TextToSpeechFinalEvent) {
        firstAudioMs ??= watch.elapsedMicroseconds / 1000;
        finals++;
      }
    }
    final completion = await task.done;
    if (cancellation != null) {
      cancelWatch.stop();
      if (completion.state != TextToSpeechCompletionState.cancelled ||
          finals != 0) {
        throw StateError('TTS cancellation emitted a final result');
      }
      return {
        'cancelled': true,
        'cancel_latency_ms': cancelWatch.elapsedMicroseconds / 1000,
        ...cancellation,
      };
    }
    if (completion.state != TextToSpeechCompletionState.completed ||
        finals != 1) {
      throw StateError('TTS did not emit exactly one completed result');
    }
    watch.stop();
    _lastGenerationMs = watch.elapsedMicroseconds / 1000;
    final result = completion.result!;
    final metrics = inspectSpeechAudio(result);
    await saveAudio(result.toWavBytes());
    return {
      ...metrics,
      'predicate_passed': true,
      'elapsed_ms': watch.elapsedMicroseconds / 1000,
      'first_playable_audio_ms': firstAudioMs,
      'real_time_factor':
          watch.elapsedMicroseconds /
          1e6 /
          (metrics['audio_seconds'] as double),
      'streaming_audio': false,
    };
  }
}

/// Lifecycle checks every [runSpeechValidation] run executes.
const speechLifecycleCheckCount = 15;

/// Cancel/dispose/load/generate cycles run after the single-shot checks.
const speechCleanupCycles = 3;

/// How long [PublicSpeechValidationAdapter] waits before cancelling with
/// `cancel`, as a fraction of the elapsed time of its most recent completed
/// generation.
///
/// [PublicDedicatedSpeechAdapter] does not use it: that adapter pushes PCM
/// until the first partial transcript arrives, or until the fixture is
/// exhausted, and cancels there.
const speechCancelInFlightLeadFraction = 0.5;

/// Milliseconds allowed from a `cancel` cancellation to the speech task's
/// terminal state.
///
/// It bounds when the task becomes terminal to its caller, not when native
/// work stops, so a cancellation honoured only after the generation finishes
/// can still pass it.
const speechCancelLatencyBudgetMs = 500.0;

/// Milliseconds allowed from a `cancelImmediately` cancellation to the speech
/// task's terminal state.
///
/// As with [speechCancelLatencyBudgetMs], a cancellation honoured only after
/// the generation finishes can still pass it.
const speechImmediateCancelLatencyBudgetMs = 500.0;

/// Ceiling on the largest resident set sampled after the checks between
/// `generate` and `peak_memory_bound`, as a multiple of the resident set
/// sampled right after `generate`. Growth equal to it passes.
///
/// Every check in that span contributes a sample, whatever phase it exercised,
/// so the peak is the maximum over heterogeneous phases rather than over
/// generations alone.
const speechPeakRssGrowthBudget = 1.10;

/// Executes bounded speech lifecycle checks; cleanup failures remain failures.
///
/// [edgeFixtures] adds one check per synthetic fixture and requires an adapter
/// that also implements [SpeechEdgeCaseAdapter]. Runs that pass none keep their
/// previous check count.
///
/// The single-shot checks and every cleanup cycle each call
/// [SpeechValidationAdapter.execute] once with `cancelImmediately`, which must
/// report `cancel_immediate` as true, and once with `cancel`, which must report
/// `cancel_in_flight` as true. Each must report `cancelled` as true and a
/// finite, non-negative `cancel_latency_ms` and `cancel_after_ms`, and the
/// second a nonzero `cancel_after_ms`; otherwise that check fails.
///
/// [residentBytes] is called after each check. If any call made before
/// `peak_memory_bound` runs returns null, that check records `SKIP` with a
/// reason. It is the only check that may `SKIP` in a run whose
/// `functional_pass` is true.
///
/// The result deliberately cannot assert hardware or perceptual qualification.
Future<Map<String, Object?>> runSpeechValidation(
  SpeechValidationAdapter adapter, {
  bool checkBytes = false,
  List<SpeechEdgeFixture> edgeFixtures = const [],
  int? Function() residentBytes = residentSetBytes,
}) async {
  if (edgeFixtures.isNotEmpty && adapter is! SpeechEdgeCaseAdapter) {
    throw ArgumentError('Adapter cannot execute speech edge fixtures');
  }
  final expectedChecks =
      speechLifecycleCheckCount + (checkBytes ? 1 : 0) + edgeFixtures.length;
  final results = <Map<String, Object?>>[];
  final cancelLatencies = <double>[];
  final cancelLeads = <double>[];
  final immediateLatencies = <double>[];
  final immediateLeads = <double>[];
  final residentSamples = <Map<String, Object?>>[];
  var residentMeasurable = true;
  Future<void> check(
    String id,
    Future<Map<String, Object?>> Function() action,
  ) async {
    try {
      final result = await action();
      results.add({
        'id': id,
        'status': result['predicate_passed'] == false
            ? 'FAIL'
            : result['skipped'] == true
            ? 'SKIP'
            : 'PASS',
        ...result,
      });
    } catch (error) {
      // Error classes are safe diagnostics; raw errors may contain local paths.
      results.add({
        'id': id,
        'status': 'FAIL',
        'error_type': '${error.runtimeType}',
        'message': redactDiagnostic('$error'),
      });
    }
    final sampled = residentBytes();
    if (sampled == null) {
      residentMeasurable = false;
    } else {
      residentSamples.add({'id': id, 'rss_bytes': sampled});
    }
  }

  Map<String, Object?> recordCancellation(
    Map<String, Object?> result, {
    bool immediate = false,
  }) {
    if (result['cancelled'] != true) {
      throw StateError('Cancellation not confirmed');
    }
    if (immediate && result['cancel_immediate'] != true) {
      throw StateError('Cancellation was not issued on hand-back');
    }
    if (!immediate && result['cancel_in_flight'] != true) {
      throw StateError('Cancellation did not reach a running generation');
    }
    final latency = result['cancel_latency_ms'];
    if (latency is! num || !latency.isFinite || latency < 0) {
      throw StateError('Cancellation latency was not measured');
    }
    final lead = result['cancel_after_ms'];
    if (lead is! num || !lead.isFinite || lead < 0 || !immediate && lead == 0) {
      throw StateError('Cancellation lead time was not measured');
    }
    (immediate ? immediateLatencies : cancelLatencies).add(latency.toDouble());
    (immediate ? immediateLeads : cancelLeads).add(lead.toDouble());
    return result;
  }

  Map<String, Object?> latencyBound(
    List<double> samples,
    List<double> leads,
    double budget,
  ) {
    if (samples.length != speechCleanupCycles + 1) {
      throw StateError('Cancellation latency samples are incomplete');
    }
    final worst = samples.reduce(math.max);
    return {
      'samples_ms': [...samples],
      'lead_ms': [...leads],
      'worst_ms': worst,
      'budget_ms': budget,
      'predicate_passed': worst <= budget,
    };
  }

  try {
    await check('load', () async {
      await adapter.load();
      return {};
    });
    if (results.last['status'] == 'PASS') {
      await check('generate', () => adapter.execute());
      if (checkBytes) {
        await check('bytes_input', () => adapter.execute(bytesInput: true));
      }
      await check(
        'cancel_immediate',
        () async => recordCancellation(
          await adapter.execute(cancelImmediately: true),
          immediate: true,
        ),
      );
      await check(
        'cancel',
        () async => recordCancellation(await adapter.execute(cancel: true)),
      );
      await check('after_cancel', () => adapter.execute());
      await check('invalid_input', () async {
        try {
          await adapter.execute(invalid: true);
        } on ArgumentError {
          return {'rejected': true};
        } on LlamaAudioFormatException {
          return {'rejected': true};
        } on LlamaTextToSpeechException catch (error) {
          // This exception also represents synthesis failures. Only the exact
          // empty-text contract exercised by this case is an input rejection.
          if (error.message != 'Text to synthesize must not be empty.') rethrow;
          return {'rejected': true};
        } on LlamaUnsupportedException {
          return {'rejected': true};
        }
        throw StateError('Invalid input did not produce a typed rejection');
      });
      await check('after_invalid', () => adapter.execute());
      for (final fixture in edgeFixtures) {
        await check(
          fixture.id,
          () => (adapter as SpeechEdgeCaseAdapter).executeEdge(fixture),
        );
      }
      await check('reload', () async {
        await adapter.dispose();
        await adapter.load();
        return await adapter.execute();
      });
      for (var cycle = 1; cycle <= speechCleanupCycles; cycle++) {
        await check('cleanup_cycle_$cycle', () async {
          final immediate = recordCancellation(
            await adapter.execute(cancelImmediately: true),
            immediate: true,
          );
          final cancelled = recordCancellation(
            await adapter.execute(cancel: true),
          );
          await adapter.dispose();
          await adapter.load();
          return {
            ...await adapter.execute(),
            'immediate_cancel_latency_ms': immediate['cancel_latency_ms'],
            'cancel_latency_ms': cancelled['cancel_latency_ms'],
            'cancel_after_ms': cancelled['cancel_after_ms'],
            'cancel_in_flight': cancelled['cancel_in_flight'],
          };
        });
      }
      await check(
        'cancel_latency_bound',
        () async => {
          ...latencyBound(
            cancelLatencies,
            cancelLeads,
            speechCancelLatencyBudgetMs,
          ),
          'lead_fraction': speechCancelInFlightLeadFraction,
        },
      );
      await check(
        'immediate_cancel_latency_bound',
        () async => latencyBound(
          immediateLatencies,
          immediateLeads,
          speechImmediateCancelLatencyBudgetMs,
        ),
      );
      await check('peak_memory_bound', () async {
        final baselineIndex = residentSamples.indexWhere(
          (sample) => sample['id'] == 'generate',
        );
        if (!residentMeasurable || baselineIndex < 0) {
          return {
            'skipped': true,
            'measurement': residentSetSource,
            'skip_reason': 'Resident set size was not measurable',
          };
        }
        final baseline = residentSamples[baselineIndex]['rss_bytes']! as int;
        final later = residentSamples.skip(baselineIndex + 1);
        if (later.isEmpty) {
          throw StateError('No resident samples follow the first generation');
        }
        final peak = later
            .map((sample) => sample['rss_bytes']! as int)
            .reduce(math.max);
        return {
          'measurement': residentSetSource,
          'baseline_rss_bytes': baseline,
          'peak_rss_bytes': peak,
          'peak_rss_growth': peak / baseline,
          'growth_budget': speechPeakRssGrowthBudget,
          'samples': [...residentSamples],
          'predicate_passed': peak / baseline <= speechPeakRssGrowthBudget,
        };
      });
    }
  } finally {
    await check('dispose', () async {
      await adapter.dispose();
      return {};
    });
  }
  Map<String, Object?> row(String id) => results.firstWhere(
    (entry) => entry['id'] == id,
    orElse: () => const <String, Object?>{},
  );
  final latencyRow = row('cancel_latency_bound');
  final immediateRow = row('immediate_cancel_latency_bound');
  final memoryRow = row('peak_memory_bound');
  final memoryMeasured = memoryRow.isNotEmpty && memoryRow['skipped'] != true;
  return {
    'schema_version': 1,
    'kind': 'speech_validation',
    'functional_pass':
        results.length == expectedChecks &&
        results.every(
          (entry) =>
              entry['status'] == 'PASS' ||
              (entry['id'] == 'peak_memory_bound' && entry['status'] == 'SKIP'),
        ),
    'expected_checks': expectedChecks,
    'edge_fixture_ids': [for (final fixture in edgeFixtures) fixture.id],
    'bounds': {
      'cleanup_cycles': speechCleanupCycles,
      'cancel_latency_ms': {
        'budget': speechCancelLatencyBudgetMs,
        'samples': [...cancelLatencies],
        'lead': [...cancelLeads],
        'lead_fraction': speechCancelInFlightLeadFraction,
        'worst': latencyRow['worst_ms'],
        'within_budget': latencyRow.isEmpty
            ? null
            : latencyRow['status'] == 'PASS',
      },
      'immediate_cancel_latency_ms': {
        'budget': speechImmediateCancelLatencyBudgetMs,
        'samples': [...immediateLatencies],
        'lead': [...immediateLeads],
        'worst': immediateRow['worst_ms'],
        'within_budget': immediateRow.isEmpty
            ? null
            : immediateRow['status'] == 'PASS',
      },
      'peak_resident_bytes': {
        'measurement': residentSetSource,
        'measured': memoryMeasured,
        'skip_reason': memoryRow['skip_reason'],
        'baseline': memoryRow['baseline_rss_bytes'],
        'peak': memoryRow['peak_rss_bytes'],
        'growth': memoryRow['peak_rss_growth'],
        'growth_budget': speechPeakRssGrowthBudget,
        'within_budget': memoryMeasured ? memoryRow['status'] == 'PASS' : null,
      },
    },
    'qualified': false,
    'qualification_reason':
        'Requires reference, platform/accelerator and perceptual evidence; see individual cases.',
    'checks': results,
  };
}

/// Duration from validated mono 16 kHz PCM16 RIFF/WAVE fixture bytes.
double speechFixtureSeconds(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  String tag(int start) =>
      String.fromCharCodes(bytes.sublist(start, start + 4));
  if (bytes.length < 44 ||
      bytes.length > speechFixtureByteCap ||
      tag(0) != 'RIFF' ||
      tag(8) != 'WAVE' ||
      data.getUint32(4, Endian.little) + 8 != bytes.length) {
    throw const FormatException('Invalid bounded RIFF/WAVE fixture');
  }
  var formatSeen = false;
  int? pcmBytes;
  var offset = 12;
  while (offset + 8 <= bytes.length) {
    final size = data.getUint32(offset + 4, Endian.little);
    final start = offset + 8;
    if (start + size > bytes.length) {
      throw const FormatException('Truncated WAV chunk');
    }
    if (tag(offset) == 'fmt ') {
      if (formatSeen ||
          size < 16 ||
          data.getUint16(start, Endian.little) != 1 ||
          data.getUint16(start + 2, Endian.little) != 1 ||
          data.getUint32(start + 4, Endian.little) != 16000 ||
          data.getUint32(start + 8, Endian.little) != 32000 ||
          data.getUint16(start + 12, Endian.little) != 2 ||
          data.getUint16(start + 14, Endian.little) != 16) {
        throw const FormatException('Expected mono 16 kHz PCM16 WAV');
      }
      formatSeen = true;
    }
    if (tag(offset) == 'data') {
      if (pcmBytes != null || size == 0 || size.isOdd) {
        throw const FormatException('Invalid PCM data');
      }
      pcmBytes = size;
    }
    offset = start + size + (size.isOdd ? 1 : 0);
  }
  if (!formatSeen || pcmBytes == null || offset != bytes.length) {
    throw const FormatException('Incomplete WAV fixture');
  }
  return pcmBytes / 32000;
}

/// Dedicated native CPU ASR: PCM streaming is separate from GGUF prompt ASR.
class PublicDedicatedSpeechAdapter implements SpeechValidationAdapter {
  PublicDedicatedSpeechAdapter({
    required this.config,
    required this.wav,
    required this.reference,
    SpeechToTextEngine Function(LiteRtLmAsrRuntimeConfig)? createRecognizer,
  }) : _createRecognizer = createRecognizer ?? SpeechToTextEngine.liteRtLm;
  final SpeechToTextEngine Function(LiteRtLmAsrRuntimeConfig) _createRecognizer;
  final LiteRtLmAsrRuntimeConfig config;
  final Uint8List wav;
  final String reference;
  SpeechToTextEngine? _recognizer;
  SpeechToTextStreamingSession? _active;
  late Float32List _pcm;
  late double _seconds;

  @override
  Future<void> load() async {
    _seconds = speechFixtureSeconds(wav);
    final data = ByteData.sublistView(wav);
    var offset = 12;
    while (offset + 8 <= wav.length) {
      final size = data.getUint32(offset + 4, Endian.little);
      if (String.fromCharCodes(wav.sublist(offset, offset + 4)) == 'data') {
        _pcm = Float32List(size ~/ 2);
        for (var i = 0; i < _pcm.length; i++) {
          _pcm[i] = data.getInt16(offset + 8 + i * 2, Endian.little) / 32768;
        }
        break;
      }
      offset += 8 + size + (size.isOdd ? 1 : 0);
    }
    _recognizer = _createRecognizer(config);
    final capabilities = await _recognizer!.capabilities;
    if (!capabilities.isSupported) {
      throw StateError(capabilities.unsupportedReason ?? 'ASR unsupported');
    }
  }

  @override
  Future<void> dispose() async {
    await _active?.cancel();
    _active = null;
    _recognizer = null;
  }

  @override
  Future<Map<String, Object?>> execute({
    bool cancel = false,
    bool cancelImmediately = false,
    bool invalid = false,
    bool bytesInput = false,
  }) async {
    if (cancel && cancelImmediately) {
      throw ArgumentError('cancel and cancelImmediately are exclusive');
    }
    final watch = Stopwatch()..start();
    final recognizer = _recognizer ?? (throw StateError('ASR is not loaded'));
    if (invalid) {
      final rejected = await recognizer.startStream(
        format: const SpeechAudioFormat(
          sampleRateHz: 8000,
          channelCount: 1,
          encoding: 'pcm-f32le',
        ),
      );
      await rejected.cancel();
      throw StateError('Unsupported PCM format was accepted');
    }
    final session = _active = await recognizer.startStream();
    double? firstPartial;
    var partials = 0;
    var finals = 0;
    final drained = Completer<void>();
    Object? streamError;
    final events = session.events.listen(
      (event) {
        if (event is SpeechToTextPartialEvent) {
          firstPartial ??= watch.elapsedMicroseconds / 1000;
          partials++;
        }
        if (event is SpeechToTextFinalEvent) finals++;
      },
      onError: (Object error) {
        streamError = error;
      },
      onDone: drained.complete,
    );
    final cancelWatch = Stopwatch();
    var pushed = 0;
    var cancelAfterMs = 0.0;
    var cancelInFlight = false;
    final cancelling = cancel || cancelImmediately;
    try {
      if (cancelling) {
        var settled = false;
        unawaited(
          session.done.then<void>(
            (_) => settled = true,
            onError: (Object _) => settled = true,
          ),
        );
        for (
          var offset = 0;
          !cancelImmediately && offset < _pcm.length && partials == 0;
          offset += 1600
        ) {
          final end = offset + 1600 < _pcm.length ? offset + 1600 : _pcm.length;
          await session.addPcm(Float32List.sublistView(_pcm, offset, end));
          pushed = end;
        }
        cancelAfterMs = watch.elapsedMicroseconds / 1000;
        cancelInFlight = pushed > 0 && !settled;
        cancelWatch.start();
        await session.cancel();
      } else {
        for (var offset = 0; offset < _pcm.length; offset += 1600) {
          final end = offset + 1600 < _pcm.length ? offset + 1600 : _pcm.length;
          await session.addPcm(Float32List.sublistView(_pcm, offset, end));
        }
        await session.finish();
      }
      final completion = await session.done;
      await drained.future;
      if (streamError != null) throw streamError!;
      if (cancelling) {
        cancelWatch.stop();
        if (completion.state != SpeechToTextCompletionState.cancelled ||
            finals != 0) {
          throw StateError('ASR cancellation did not complete cleanly');
        }
        return {
          'cancelled': true,
          'cancel_latency_ms': cancelWatch.elapsedMicroseconds / 1000,
          'cancel_after_ms': cancelAfterMs,
          if (cancelImmediately)
            'cancel_immediate': true
          else
            'cancel_in_flight': cancelInFlight,
          'pcm_samples_before_cancel': pushed,
          'partial_events_before_cancel': partials,
        };
      }
      if (completion.state != SpeechToTextCompletionState.completed ||
          completion.result == null ||
          finals != 1) {
        throw StateError('ASR stream did not complete');
      }
      final text = completion.result!.text;
      final wer = speechWordErrorRate(reference, text);
      return {
        'transcript': text,
        'reference': reference,
        'wer': wer,
        'predicate_passed': wer == 0,
        'first_partial_ms': firstPartial,
        'partial_events': partials,
        'elapsed_ms': watch.elapsedMicroseconds / 1000,
        'audio_seconds': _seconds,
        'real_time_factor': watch.elapsedMicroseconds / 1e6 / _seconds,
        'backend': 'cpu',
        'streaming_input': true,
      };
    } finally {
      await session.cancel();
      await events.cancel();
      _active = null;
    }
  }
}
