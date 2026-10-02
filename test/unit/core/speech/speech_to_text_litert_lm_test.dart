@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/core/speech/litert_lm_speech_to_text_driver.dart';
import 'package:test/test.dart';

void main() {
  late _FakeLiteRtLmSpeechDriver driver;
  late Directory directory;
  late String modelPath;
  late String tokenizerPath;

  const config = LiteRtLmAsrRuntimeConfig(
    modelPath: '/models/moonshine.tflite',
    tokenizerPath: '/models/tokenizer.json',
    modelPreset: LiteRtLmAsrModelPreset.moonshineTiny,
  );

  SpeechToTextModel model({
    LiteRtLmAsrAdapter adapter = const LiteRtLmAsrAdapter(
      LiteRtLmAsrModelPreset.moonshineTiny,
    ),
  }) => SpeechToTextModel(
    ModelSource.path(modelPath),
    tokenizer: ModelSource.path(tokenizerPath),
    adapter: adapter,
  );

  Future<SpeechToTextEngine> load() => SpeechToTextEngine.load(model());

  setUp(() async {
    driver = _FakeLiteRtLmSpeechDriver();
    debugLiteRtLmSpeechToTextDriverOverride = driver;
    directory = await Directory.systemTemp.createTemp('llamadart_asr_');
    modelPath = '${directory.path}/moonshine.tflite';
    tokenizerPath = '${directory.path}/tokenizer.json';
    await File(modelPath).writeAsBytes(<int>[1, 2, 3]);
    await File(tokenizerPath).writeAsString('{}');
  });

  tearDown(() async {
    debugLiteRtLmSpeechToTextDriverOverride = null;
    await driver.close();
    await directory.delete(recursive: true);
  });

  test('reports dedicated streaming PCM capabilities', () async {
    final engine = await load();

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

  test('refuses a version-skewed runtime before resolving files', () async {
    driver.support = const LiteRtLmSpeechToTextSupport(
      isSupported: false,
      unsupportedReason: 'missing v0.16 ASR ABI',
    );
    await File(modelPath).delete();

    await expectLater(
      load(),
      throwsA(
        isA<LlamaUnsupportedException>().having(
          (error) => error.message,
          'message',
          'missing v0.16 ASR ABI',
        ),
      ),
    );
    expect(driver.startCalls, 0);
  });

  test('starts sessions on the resolved files with adapter settings', () async {
    final engine = await SpeechToTextEngine.load(
      model(
        adapter: const LiteRtLmAsrAdapter(
          LiteRtLmAsrModelPreset.whisperTiny,
          numberOfThreads: 2,
          maxBufferedAudio: Duration(seconds: 10),
          overlapRatio: 0.25,
          libraryPath: '/runtime/libLiteRtLm.so',
        ),
      ),
    );

    await engine.capabilities;
    final session = await engine.startStream();
    await session.cancel();

    final started = driver.lastConfig!;
    expect(started.modelPath, modelPath);
    expect(started.tokenizerPath, tokenizerPath);
    expect(started.modelPreset, LiteRtLmAsrModelPreset.whisperTiny);
    expect(started.numberOfThreads, 2);
    expect(started.maxBufferedAudio, const Duration(seconds: 10));
    expect(started.overlapRatio, 0.25);
    expect(driver.lastProbeLibraryPath, '/runtime/libLiteRtLm.so');
    expect(driver.lastStartLibraryPath, '/runtime/libLiteRtLm.so');
    expect(driver.probeCalls, 1);
    expect(engine.adapter, isA<LiteRtLmAsrAdapter>());
    await engine.dispose();
  });

  test('reports combined progress for the model and tokenizer', () async {
    final progress = <ModelDownloadProgress>[];

    final engine = await SpeechToTextEngine.load(
      model(),
      onProgress: progress.add,
    );

    expect(progress, isNotEmpty);
    expect(progress.last.receivedBytes, 5);
    expect(progress.last.totalBytes, 5);
    await engine.dispose();
  });

  test('rejects a model without a tokenizer or with a projector', () async {
    await expectLater(
      SpeechToTextEngine.load(
        SpeechToTextModel(
          ModelSource.path(modelPath),
          adapter: const LiteRtLmAsrAdapter(
            LiteRtLmAsrModelPreset.moonshineTiny,
          ),
        ),
      ),
      throwsA(
        isA<LlamaArgumentException>().having(
          (error) => error.name,
          'name',
          'model.tokenizer',
        ),
      ),
    );
    await expectLater(
      SpeechToTextEngine.load(
        SpeechToTextModel(
          ModelSource.path(modelPath),
          tokenizer: ModelSource.path(tokenizerPath),
          projector: ModelSource.path(tokenizerPath),
          adapter: const LiteRtLmAsrAdapter(
            LiteRtLmAsrModelPreset.moonshineTiny,
          ),
        ),
      ),
      throwsA(
        isA<LlamaArgumentException>().having(
          (error) => error.name,
          'name',
          'model.projector',
        ),
      ),
    );
    expect(driver.probeCalls, 0);
  });

  test('rejects LlamaEngine params and backends', () async {
    await expectLater(
      SpeechToTextEngine.load(model(), params: const ModelParams()),
      throwsA(
        isA<LlamaArgumentException>().having(
          (error) => error.name,
          'name',
          'params',
        ),
      ),
    );
    expect(driver.probeCalls, 0);
  });

  test('rejects a checksum for the two files', () async {
    await expectLater(
      SpeechToTextEngine.load(
        model(),
        download: ModelLoadOptions(sha256: 'a' * 64),
      ),
      throwsA(isA<LlamaUnsupportedException>()),
    );
    expect(driver.startCalls, 0);
  });

  test('fails the load when a local file is missing', () async {
    await File(tokenizerPath).delete();

    await expectLater(load(), throwsA(isA<LlamaException>()));
    expect(driver.startCalls, 0);
  });

  test('a cancelled load leaves no engine', () async {
    final token = ModelDownloadCancelToken()..cancel();

    await expectLater(
      SpeechToTextEngine.load(
        model(),
        download: ModelLoadOptions(cancelToken: token),
      ),
      throwsA(isA<LlamaException>()),
    );
    expect(driver.startCalls, 0);
  });

  test('dispose cancels an active stream and is idempotent', () async {
    final engine = await load();
    final session = await engine.startStream();

    await Future.wait<void>(<Future<void>>[engine.dispose(), engine.dispose()]);

    expect(engine.isDisposed, isTrue);
    expect((await session.done).state, SpeechToTextCompletionState.cancelled);
    expect(driver.worker.cancelCalls, 1);
    expect(driver.worker.disposeCalls, 1);
    final capabilities = await engine.capabilities;
    expect(capabilities.isSupported, isFalse);
    expect(capabilities.unsupportedReason, contains('disposed'));
    await expectLater(
      engine.startStream(),
      throwsA(isA<LlamaStateException>()),
    );
    await expectLater(
      engine.transcribe(
        SpeechToTextRequest(audio: SpeechAudioPcmInput(Float32List(16))),
      ),
      throwsA(isA<LlamaStateException>()),
    );
  });

  test('dispose ends an active transcription task', () async {
    final engine = await load();
    driver.blockWorkerPush = true;
    final task = await engine.transcribe(
      SpeechToTextRequest(audio: SpeechAudioPcmInput(Float32List(16))),
    );
    final events = task.events.toList();
    await Future<void>.delayed(Duration.zero);

    await engine.dispose();

    expect((await task.done).state, SpeechToTextCompletionState.cancelled);
    await events;
    expect(driver.worker.disposed, isTrue);
  });

  test('a stream started while disposing is cancelled', () async {
    final engine = await load();
    driver.blockStart = true;
    final starting = engine.startStream();
    await Future<void>.delayed(Duration.zero);

    final disposal = engine.dispose();
    driver.releaseStart();

    await expectLater(starting, throwsA(isA<LlamaStateException>()));
    await disposal;
    expect(driver.worker.cancelCalls, 1);
    expect(driver.worker.disposed, isTrue);
  });

  test('transcribeOnce returns the final result', () async {
    final engine = await load();

    final result = await engine.transcribeOnce(
      SpeechToTextRequest(audio: SpeechAudioPcmInput(Float32List(16000))),
    );

    expect(result.text, 'hello world');
    expect(result.audioDuration, const Duration(seconds: 1));
    await engine.dispose();
  });

  group('deprecated liteRtLm constructor', () {
    test('reports a version-skewed native runtime as unsupported', () async {
      driver.support = const LiteRtLmSpeechToTextSupport(
        isSupported: false,
        unsupportedReason: 'missing v0.16 ASR ABI',
      );
      // ignore: deprecated_member_use_from_same_package
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

    test('forwards the config and native library override', () async {
      // ignore: deprecated_member_use_from_same_package
      final engine = SpeechToTextEngine.liteRtLm(
        config,
        libraryPath: '/runtime/libLiteRtLm.so',
      );

      final session = await engine.startStream();
      await session.cancel();

      expect(driver.lastConfig, same(config));
      expect(driver.lastProbeLibraryPath, '/runtime/libLiteRtLm.so');
      expect(driver.lastStartLibraryPath, '/runtime/libLiteRtLm.so');
      expect(
        (engine.adapter as LiteRtLmAsrAdapter).preset,
        LiteRtLmAsrModelPreset.moonshineTiny,
      );
      expect(
        // ignore: deprecated_member_use_from_same_package
        engine.modelProfile,
        // ignore: deprecated_member_use_from_same_package
        SpeechToTextModelProfile.liteRtLmDedicated,
      );
      await engine.dispose();
    });
  });

  test('streams partial text and produces a final result', () async {
    final engine = await load();
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
    final engine = await load();

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
    final engine = await load();
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
    final engine = await load();
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
      final engine = await load();
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
    final engine = await load();
    final session = await engine.startStream();

    await session.cancel();
    await session.cancel();

    expect((await session.done).state, SpeechToTextCompletionState.cancelled);
    expect(driver.worker.cancelCalls, 1);
    expect(driver.worker.disposeCalls, 1);
  });

  test('rejects encoded inputs and incompatible PCM metadata', () async {
    final engine = await load();

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
  LiteRtLmAsrRuntimeConfig? lastConfig;
  bool blockStart = false;
  bool blockWorkerPush = false;
  final Completer<void> _startRelease = Completer<void>();
  _FakeLiteRtLmSpeechWorker worker = _FakeLiteRtLmSpeechWorker();

  void releaseStart() {
    if (!_startRelease.isCompleted) {
      _startRelease.complete();
    }
  }

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
    lastConfig = config;
    worker = _FakeLiteRtLmSpeechWorker()..blockPush = blockWorkerPush;
    if (blockStart) {
      await _startRelease.future;
    }
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
