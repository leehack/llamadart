@TestOn('vm')
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/core/speech/litert_lm_speech_to_text_driver.dart';
import 'package:test/test.dart';

void main() {
  late _FakeLiteRtLmSpeechDriver driver;

  const config = LiteRtLmAsrRuntimeConfig(
    modelPath: '/models/moonshine.tflite',
    tokenizerPath: '/models/tokenizer.json',
    modelPreset: LiteRtLmAsrModelPreset.moonshineTiny,
  );

  setUp(() {
    driver = _FakeLiteRtLmSpeechDriver();
    debugLiteRtLmSpeechToTextDriverOverride = driver;
  });

  tearDown(() async {
    debugLiteRtLmSpeechToTextDriverOverride = null;
    await driver.close();
  });

  test('reports dedicated streaming PCM capabilities', () async {
    final engine = SpeechToTextEngine.liteRtLm(config);

    final capabilities = await engine.capabilities;

    expect(capabilities.isSupported, isTrue);
    expect(capabilities.backendName, 'LiteRT-LM ASR CPU');
    expect(
      capabilities.implementation,
      SpeechToTextImplementation.dedicatedBackend,
    );
    expect(capabilities.inputKinds, {SpeechAudioInputKind.pcmFloat32});
    expect(capabilities.encodedAudioFormats, isEmpty);
    expect(capabilities.supportsPartialResults, isTrue);
    expect(capabilities.supportsStreamingInput, isTrue);
    expect(capabilities.supportsInputBackpressure, isTrue);
    expect(capabilities.supportsOutputBackpressure, isFalse);
    expect(capabilities.supportsCancellation, isTrue);
    expect(capabilities.maxConcurrentTasks, 1);
    expect(driver.probeCalls, 1);
  });

  test('reports a version-skewed native runtime as unsupported', () async {
    driver.support = const LiteRtLmSpeechToTextSupport(
      isSupported: false,
      unsupportedReason: 'missing v0.16 ASR ABI',
    );
    final engine = SpeechToTextEngine.liteRtLm(config);

    final capabilities = await engine.capabilities;

    expect(capabilities.isSupported, isFalse);
    expect(capabilities.unsupportedReason, contains('v0.16'));
    await expectLater(
      engine.startStream(),
      throwsA(isA<LlamaUnsupportedException>()),
    );
    expect(driver.startCalls, 0);
  });

  test('forwards an advanced native library override', () async {
    final engine = SpeechToTextEngine.liteRtLm(
      config,
      libraryPath: '/runtime/libLiteRtLm.so',
    );

    await engine.capabilities;
    final session = await engine.startStream();
    await session.cancel();

    expect(driver.lastProbeLibraryPath, '/runtime/libLiteRtLm.so');
    expect(driver.lastStartLibraryPath, '/runtime/libLiteRtLm.so');
    expect(driver.probeCalls, 1);
  });

  test('streams partial text and produces a final result', () async {
    final engine = SpeechToTextEngine.liteRtLm(config);
    final session = await engine.startStream();
    final eventsFuture = session.events.toList();

    await session.addPcm(Float32List.fromList(<double>[0.25, -0.25]));
    await session.finish();

    final completion = await session.done;
    final events = await eventsFuture;
    expect(events.whereType<SpeechToTextPartialEvent>(), hasLength(1));
    final first = events.first as SpeechToTextPartialEvent;
    expect(first.confirmedText, 'hello');
    expect(first.pendingText, 'wor');
    expect(first.text, 'hello wor');
    expect(first.acceptedAudioDuration, const Duration(microseconds: 125));
    final finalEvent = events.last as SpeechToTextFinalEvent;
    expect(finalEvent.result.text, 'hello world');
    expect(finalEvent.result.audioDuration, const Duration(microseconds: 125));
    expect(completion.state, SpeechToTextCompletionState.completed);
    expect(completion.result, same(finalEvent.result));
    expect(driver.worker.pushedSamples, <double>[0.25, -0.25]);
    expect(driver.worker.disposed, isTrue);
  });

  test('transcribes complete PCM through the dedicated backend', () async {
    final engine = SpeechToTextEngine.liteRtLm(config);

    final task = await engine.transcribe(
      SpeechToTextRequest(audio: SpeechAudioPcmInput(Float32List(16000))),
    );
    final events = await task.events.toList();
    final completion = await task.done;

    expect(events.whereType<SpeechToTextPartialEvent>(), hasLength(1));
    expect((events.last as SpeechToTextFinalEvent).result.text, 'hello world');
    expect(completion.result?.text, 'hello world');
    expect(completion.result?.audioDuration, const Duration(seconds: 1));
  });

  test('applies async input backpressure and preserves push order', () async {
    final engine = SpeechToTextEngine.liteRtLm(config);
    final session = await engine.startStream();
    driver.worker.blockPush = true;

    final first = session.addPcm(Float32List.fromList(<double>[1]));
    final second = session.addPcm(Float32List.fromList(<double>[2]));
    await Future<void>.delayed(Duration.zero);

    expect(driver.worker.pushCalls, 1);
    driver.worker.releasePushes();
    await Future.wait<void>(<Future<void>>[first, second]);
    await session.cancel();
    expect(driver.worker.pushedSamples, <double>[1, 2]);
  });

  test('allows only one active dedicated task per engine', () async {
    final engine = SpeechToTextEngine.liteRtLm(config);
    final first = await engine.startStream();

    await expectLater(
      engine.startStream(),
      throwsA(isA<LlamaStateException>()),
    );

    await first.cancel();
    final second = await engine.startStream();
    await second.cancel();
    expect(driver.startCalls, 2);
  });

  test(
    'turns a push failure into terminal state and releases the engine',
    () async {
      final engine = SpeechToTextEngine.liteRtLm(config);
      final session = await engine.startStream();
      driver.worker.pushError = StateError('native inference failed');

      await expectLater(
        session.addPcm(Float32List(1)),
        throwsA(isA<StateError>()),
      );
      final completion = await session.done;

      expect(completion.state, SpeechToTextCompletionState.failed);
      expect(completion.error, isA<LlamaSpeechException>());
      expect(
        completion.error?.details.toString(),
        contains('native inference failed'),
      );
      final next = await engine.startStream();
      await next.cancel();
    },
  );

  test('cancels a dedicated session idempotently', () async {
    final engine = SpeechToTextEngine.liteRtLm(config);
    final session = await engine.startStream();

    await session.cancel();
    await session.cancel();

    expect((await session.done).state, SpeechToTextCompletionState.cancelled);
    expect(driver.worker.cancelCalls, 1);
    expect(driver.worker.disposeCalls, 1);
  });

  test('rejects encoded inputs and incompatible PCM metadata', () async {
    final engine = SpeechToTextEngine.liteRtLm(config);

    await expectLater(
      engine.transcribe(
        SpeechToTextRequest(
          audio: SpeechAudioBytesInput(Uint8List.fromList(<int>[1, 2])),
        ),
      ),
      throwsA(isA<LlamaUnsupportedException>()),
    );
    await expectLater(
      engine.transcribe(
        SpeechToTextRequest(
          audio: SpeechAudioPcmInput(
            Float32List(1),
            format: const SpeechAudioFormat(
              sampleRateHz: 48000,
              channelCount: 2,
              encoding: 'pcm-f32le',
            ),
          ),
        ),
      ),
      throwsA(isA<LlamaAudioFormatException>()),
    );
    await expectLater(
      engine.startStream(
        format: const SpeechAudioFormat(
          sampleRateHz: 16000,
          channelCount: 1,
          encoding: 'pcm-s16le',
        ),
      ),
      throwsA(isA<LlamaAudioFormatException>()),
    );
    await expectLater(
      engine.transcribe(
        SpeechToTextRequest(
          audio: SpeechAudioPcmInput(Float32List(1), format: null),
        ),
      ),
      throwsA(isA<LlamaAudioFormatException>()),
    );
  });
}

class _FakeLiteRtLmSpeechDriver implements LiteRtLmSpeechToTextDriver {
  LiteRtLmSpeechToTextSupport support = const LiteRtLmSpeechToTextSupport(
    isSupported: true,
  );
  int probeCalls = 0;
  int startCalls = 0;
  String? lastProbeLibraryPath;
  String? lastStartLibraryPath;
  _FakeLiteRtLmSpeechWorker worker = _FakeLiteRtLmSpeechWorker();

  @override
  Future<LiteRtLmSpeechToTextSupport> probeSupport({
    String? libraryPath,
  }) async {
    probeCalls++;
    lastProbeLibraryPath = libraryPath;
    return support;
  }

  @override
  Future<LiteRtLmSpeechToTextWorker> start(
    LiteRtLmAsrRuntimeConfig config, {
    String? libraryPath,
  }) async {
    startCalls++;
    lastStartLibraryPath = libraryPath;
    worker = _FakeLiteRtLmSpeechWorker();
    return worker;
  }

  Future<void> close() => worker.close();
}

class _FakeLiteRtLmSpeechWorker implements LiteRtLmSpeechToTextWorker {
  final StreamController<LiteRtLmSpeechToTextUpdate> _updates =
      StreamController<LiteRtLmSpeechToTextUpdate>();
  final List<double> pushedSamples = <double>[];
  final List<Completer<void>> _pushBlockers = <Completer<void>>[];
  bool blockPush = false;
  Object? pushError;
  bool disposed = false;
  int pushCalls = 0;
  int cancelCalls = 0;
  int disposeCalls = 0;
  int _acceptedSamples = 0;

  @override
  Stream<LiteRtLmSpeechToTextUpdate> get updates => _updates.stream;

  @override
  Future<int> pushAudio(Float32List samples) async {
    pushCalls++;
    final error = pushError;
    if (error != null) {
      throw error;
    }
    if (blockPush) {
      final blocker = Completer<void>();
      _pushBlockers.add(blocker);
      await blocker.future;
    }
    pushedSamples.addAll(samples);
    _acceptedSamples += samples.length;
    _updates.add(
      LiteRtLmSpeechToTextUpdate(
        confirmedText: 'hello',
        pendingText: 'wor',
        isFinal: false,
        acceptedSamples: _acceptedSamples,
      ),
    );
    return samples.length;
  }

  void releasePushes() {
    blockPush = false;
    for (final blocker in _pushBlockers) {
      if (!blocker.isCompleted) {
        blocker.complete();
      }
    }
  }

  @override
  Future<String> finish() async {
    _updates.add(
      LiteRtLmSpeechToTextUpdate(
        confirmedText: 'hello world',
        pendingText: '',
        isFinal: true,
        acceptedSamples: _acceptedSamples,
      ),
    );
    return 'hello world';
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
    releasePushes();
  }

  @override
  Future<void> dispose() async {
    if (disposed) {
      return;
    }
    disposeCalls++;
    disposed = true;
    unawaited(_updates.close());
  }

  Future<void> close() async {
    if (!disposed) {
      await dispose();
    }
  }
}
