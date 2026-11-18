@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:llamadart/backend.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/backends/native/native_backend.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late String modelPath;
  late String projectorPath;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('llamadart_live_asr_');
    modelPath = p.join(directory.path, 'live-asr.gguf');
    projectorPath = p.join(directory.path, 'mmproj-live-asr.gguf');
    await File(modelPath).writeAsBytes(<int>[1, 2, 3, 4]);
    await File(projectorPath).writeAsBytes(<int>[5, 6, 7, 8]);
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  SpeechToTextModel makeModel({
    bool withProjector = true,
    bool withTokenizer = false,
  }) => SpeechToTextModel(
    ModelSource.path(modelPath),
    projector: withProjector ? ModelSource.path(projectorPath) : null,
    tokenizer: withTokenizer ? ModelSource.path(projectorPath) : null,
    adapter: const LlamaCppLiveAsrAdapter(),
  );

  test(
    'loads, probes capabilities, streams two pushes, and runs transcribeOnce without prompt generation',
    () async {
      final backend = _FakeStreamingSpeechBackend();
      final recognizer = await SpeechToTextEngine.load(
        makeModel(),
        backend: backend,
      );

      final capabilities = await recognizer.capabilities;
      expect(capabilities.isSupported, isTrue);
      expect(
        capabilities.implementation,
        SpeechToTextImplementation.dedicatedBackend,
      );
      expect(capabilities.inputKinds, {SpeechAudioInputKind.pcmFloat32});
      expect(capabilities.encodedAudioFormats, isEmpty);
      expect(capabilities.supportsPartialResults, isTrue);
      expect(capabilities.supportsStreamingInput, isTrue);
      expect(capabilities.streamingInputUnsupportedReason, isNull);
      expect(capabilities.supportsInputBackpressure, isTrue);
      expect(capabilities.supportsOutputBackpressure, isFalse);
      expect(capabilities.supportsCancellation, isTrue);
      expect(capabilities.supportsSegmentTimestamps, isFalse);
      expect(capabilities.supportsWordTimestamps, isFalse);
      expect(capabilities.supportsConfidence, isFalse);
      expect(capabilities.supportsSpeakerDiarization, isFalse);
      expect(capabilities.supportsLanguageDetection, isFalse);
      expect(capabilities.supportsLanguageHints, isFalse);
      expect(capabilities.maxConcurrentTasks, 1);

      expect(
        () => recognizer.modelProfile,
        throwsA(isA<LlamaStateException>()),
      );

      final session = await recognizer.startStream();
      final events = <SpeechToTextEvent>[];
      final subscription = session.events.listen(events.add);

      await session.addPcm(Float32List(1600));
      backend.session!.emitUpdate(' And so', 1600);
      await Future<void>.delayed(Duration.zero);

      await session.addPcm(Float32List(3200));
      backend.session!.emitUpdate(' And so my fellow', 4800);
      await Future<void>.delayed(Duration.zero);

      backend.session!.finishResult = ' And so my fellow Americans';
      await session.finish();
      final completion = await session.done;
      await subscription.cancel();

      expect(completion.state, SpeechToTextCompletionState.completed);
      expect(completion.result!.text, ' And so my fellow Americans');
      expect(
        completion.result!.audioDuration,
        const Duration(milliseconds: 300),
      );
      expect(completion.result!.segments, hasLength(1));
      expect(
        completion.result!.segments.single.text,
        ' And so my fellow Americans',
      );
      expect(events.whereType<SpeechToTextPartialEvent>(), hasLength(2));
      final firstPartial = events[0] as SpeechToTextPartialEvent;
      expect(firstPartial.text, ' And so');
      expect(firstPartial.confirmedText, ' And so');
      expect(firstPartial.pendingText, '');
      expect(
        firstPartial.acceptedAudioDuration,
        const Duration(milliseconds: 100),
      );
      final secondPartial = events[1] as SpeechToTextPartialEvent;
      expect(secondPartial.text, ' And so my fellow');
      expect(secondPartial.confirmedText, ' And so my fellow');
      expect(secondPartial.pendingText, '');
      expect(
        secondPartial.acceptedAudioDuration,
        const Duration(milliseconds: 300),
      );
      expect(events.last, isA<SpeechToTextFinalEvent>());

      // Complete-PCM transcribeOnce uses the same streaming session.
      backend.nextSession = _FakeBackendStreamingSession(
        finishResult: 'Ask not',
      );
      final result = await recognizer.transcribeOnce(
        SpeechToTextRequest(audio: SpeechAudioPcmInput(Float32List(8000))),
      );
      expect(result.text, 'Ask not');
      expect(result.audioDuration, const Duration(milliseconds: 500));
      expect(backend.generateCalls, 0);

      await recognizer.dispose();
      expect(backend.disposed, isTrue);
    },
  );

  test(
    'NativeAutoBackend delegates streaming SPI to llama.cpp and rejects non-llama delegates',
    () async {
      final llamaCppFake = _FakeStreamingSpeechBackend();
      final autoLlama = NativeAutoBackend(
        llamaCppFactory: () => llamaCppFake,
        liteRtLmFactory: () => _NonStreamingNativeDelegate(),
      );
      final recognizer = await SpeechToTextEngine.load(
        makeModel(),
        backend: autoLlama,
      );
      final session = await recognizer.startStream();
      await session.addPcm(Float32List(800));
      llamaCppFake.session!.finishResult = 'delegated';
      await session.finish();
      final completion = await session.done;
      expect(completion.result!.text, 'delegated');
      await recognizer.dispose();

      final autoLiteRt = NativeAutoBackend(
        llamaCppFactory: () => _FakeStreamingSpeechBackend(),
        liteRtLmFactory: () => _NonStreamingNativeDelegate(),
      );
      await autoLiteRt.modelLoad('unused.litertlm', const ModelParams());
      expect(
        await autoLiteRt.streamingSpeechToTextUnsupportedReason(1, 2),
        contains('does not expose streaming speech-to-text'),
      );
      expect(
        () => autoLiteRt.startStreamingSpeechToText(1, 2),
        throwsA(isA<LlamaUnsupportedException>()),
      );
      await autoLiteRt.dispose();
    },
  );

  test(
    'rejects missing projector, tokenizer, and unsupported runtime probe while disposing backend',
    () async {
      final missingProjBackend = _FakeStreamingSpeechBackend();
      await expectLater(
        () => SpeechToTextEngine.load(
          makeModel(withProjector: false),
          backend: missingProjBackend,
        ),
        throwsA(isA<LlamaArgumentException>()),
      );
      expect(missingProjBackend.disposed, isTrue);

      final tokenizerBackend = _FakeStreamingSpeechBackend();
      await expectLater(
        () => SpeechToTextEngine.load(
          makeModel(withTokenizer: true),
          backend: tokenizerBackend,
        ),
        throwsA(isA<LlamaArgumentException>()),
      );
      expect(tokenizerBackend.disposed, isTrue);

      final unsupportedBackend = _FakeStreamingSpeechBackend(
        unsupportedReason:
            'The loaded projector is qwen3a; live ASR requires voxtral_rt or lfm3a.',
      );
      await expectLater(
        () => SpeechToTextEngine.load(makeModel(), backend: unsupportedBackend),
        throwsA(
          isA<LlamaUnsupportedException>().having(
            (e) => e.message,
            'message',
            contains('qwen3a'),
          ),
        ),
      );
      expect(unsupportedBackend.disposed, isTrue);
    },
  );

  test(
    'rejects overlapping addPcm without failing session and treats empty addPcm as no-op while open',
    () async {
      final backend = _FakeStreamingSpeechBackend();
      final pushGate = Completer<int>();
      final recognizer = await SpeechToTextEngine.load(
        makeModel(),
        backend: backend,
      );

      final session = await recognizer.startStream();
      backend.session!.onPush = (_) => pushGate.future;
      await session.addPcm(Float32List(0));

      final firstPush = session.addPcm(Float32List(800));
      await expectLater(
        () => session.addPcm(Float32List(800)),
        throwsA(isA<LlamaStateException>()),
      );

      pushGate.complete(800);
      await firstPush;

      backend.session!.finishResult = 'still alive';
      await session.finish();
      final completion = await session.done;
      expect(completion.state, SpeechToTextCompletionState.completed);
      expect(completion.result!.text, 'still alive');

      await expectLater(
        () => session.addPcm(Float32List(0)),
        throwsA(isA<LlamaStateException>()),
      );
      await recognizer.dispose();
    },
  );

  test(
    'terminates session explicitly on invalid PCM slice and validates complete-input requests',
    () async {
      final backend = _FakeStreamingSpeechBackend();
      final recognizer = await SpeechToTextEngine.load(
        makeModel(),
        backend: backend,
      );

      expect(
        () => recognizer.transcribe(
          SpeechToTextRequest(audio: SpeechAudioPcmInput(Float32List(0))),
        ),
        throwsA(isA<LlamaAudioFormatException>()),
      );
      expect(
        () => recognizer.transcribe(
          SpeechToTextRequest(
            audio: SpeechAudioPcmInput(Float32List(160)),
            languageHint: 'en',
          ),
        ),
        throwsA(isA<LlamaUnsupportedException>()),
      );
      expect(
        () => recognizer.transcribe(
          SpeechToTextRequest(
            audio: SpeechAudioPcmInput(Float32List(160)),
            contextPrompt: 'hint',
          ),
        ),
        throwsA(isA<LlamaUnsupportedException>()),
      );
      expect(
        () => recognizer.transcribe(
          SpeechToTextRequest(audio: const SpeechAudioFileInput('speech.wav')),
        ),
        throwsA(isA<LlamaUnsupportedException>()),
      );
      expect(
        () => recognizer.transcribe(
          SpeechToTextRequest(
            audio: SpeechAudioPcmInput(Float32List(160)),
            maxOutputTokens: 0,
          ),
        ),
        throwsA(isA<LlamaSpeechException>()),
      );
      expect(
        () => recognizer.transcribe(
          SpeechToTextRequest(
            audio: SpeechAudioPcmInput(Float32List.fromList(<double>[1.5])),
          ),
        ),
        throwsA(isA<LlamaAudioFormatException>()),
      );

      final session = await recognizer.startStream();
      final errors = <Object>[];
      final sub = session.events.listen((_) {}, onError: errors.add);

      await expectLater(
        () => session.addPcm(Float32List.fromList(<double>[0.0, double.nan])),
        throwsA(isA<LlamaAudioFormatException>()),
      );
      final completion = await session.done;
      await sub.cancel();

      expect(completion.state, SpeechToTextCompletionState.failed);
      expect(completion.error, isA<LlamaAudioFormatException>());
      expect(errors.single, isA<LlamaAudioFormatException>());
      expect(backend.session!.cancelCalls, 1);

      await recognizer.dispose();
    },
  );

  test(
    'awaits pending startStream during dispose and cancels before engine disposal',
    () async {
      final backend = _FakeStreamingSpeechBackend();
      final startGate = Completer<void>();
      backend.startGate = startGate;
      final recognizer = await SpeechToTextEngine.load(
        makeModel(),
        backend: backend,
      );

      final startFuture = recognizer.startStream();
      await Future<void>.delayed(Duration.zero);

      final disposeFuture = recognizer.dispose();
      expect(backend.disposed, isFalse);

      startGate.complete();
      await expectLater(startFuture, throwsA(isA<LlamaStateException>()));
      await disposeFuture;

      expect(backend.session!.cancelCalls, 1);
      expect(backend.disposed, isTrue);
    },
  );

  test(
    'coalesces partials while paused or unlistened and does not block finish/dispose',
    () async {
      final backend = _FakeStreamingSpeechBackend();
      final recognizer = await SpeechToTextEngine.load(
        makeModel(),
        backend: backend,
      );

      // Unlistened events stream: finish still completes promptly.
      final unlistenedSession = await recognizer.startStream();
      await unlistenedSession.addPcm(Float32List(1600));
      for (var i = 1; i <= 5; i++) {
        backend.session!.emitUpdate('word $i', 1600);
      }
      backend.session!.finishResult = 'word 5';
      await unlistenedSession.finish();
      final unlistenedCompletion = await unlistenedSession.done;
      expect(unlistenedCompletion.result!.text, 'word 5');

      // Paused subscription: only latest partial is retained and delivered on resume.
      backend.nextSession = _FakeBackendStreamingSession(
        finishResult: 'final text',
      );
      final pausedSession = await recognizer.startStream();
      final received = <SpeechToTextEvent>[];
      final sub = pausedSession.events.listen(received.add);
      sub.pause();

      await pausedSession.addPcm(Float32List(1600));
      backend.session!.emitUpdate('first', 1600);
      backend.session!.emitUpdate('second', 1600);
      backend.session!.emitUpdate('third', 1600);
      await Future<void>.delayed(Duration.zero);
      expect(received, isEmpty);

      sub.resume();
      await Future<void>.delayed(Duration.zero);
      expect(received.whereType<SpeechToTextPartialEvent>(), hasLength(1));
      expect((received.single as SpeechToTextPartialEvent).text, 'third');

      await pausedSession.finish();
      await pausedSession.done;
      await sub.cancel();
      await recognizer.dispose();
    },
  );

  test(
    'forwards typed truncation errors and suppresses late updates after cancel',
    () async {
      final backend = _FakeStreamingSpeechBackend();
      final recognizer = await SpeechToTextEngine.load(
        makeModel(),
        backend: backend,
      );

      backend.nextSession = _FakeBackendStreamingSession(
        finishError: LlamaSpeechTranscriptTruncatedException(
          'Context full',
          limit: LlamaSpeechTranscriptLimit.contextSize,
          partialTranscript: 'partial words',
        ),
      );

      await expectLater(
        () => recognizer.transcribeOnce(
          SpeechToTextRequest(audio: SpeechAudioPcmInput(Float32List(1600))),
        ),
        throwsA(
          isA<LlamaSpeechTranscriptTruncatedException>()
              .having(
                (e) => e.limit,
                'limit',
                LlamaSpeechTranscriptLimit.contextSize,
              )
              .having((e) => e.partialTranscript, 'partial', 'partial words'),
        ),
      );

      // Cancel suppresses any subsequent updates/finals.
      backend.nextSession = _FakeBackendStreamingSession();
      final session = await recognizer.startStream();
      final events = <SpeechToTextEvent>[];
      final sub = session.events.listen(events.add);

      final cancelFuture = session.cancel();
      backend.session!.emitUpdate('late', 1600);
      await Future.wait([cancelFuture, session.cancel()]);
      final completion = await session.done;
      await sub.cancel();

      expect(completion.state, SpeechToTextCompletionState.cancelled);
      expect(events, isEmpty);

      await recognizer.dispose();
    },
  );

  test(
    'surfaces targeted backend cancellation and unexpected stream end as typed errors on SpeechToTextEngine stream',
    () async {
      final backend = _FakeStreamingSpeechBackend();
      final recognizer = await SpeechToTextEngine.load(
        makeModel(),
        backend: backend,
      );

      final cancelledSession = await recognizer.startStream();
      final eventsDone = expectLater(
        cancelledSession.events,
        emitsInOrder([
          emitsError(
            isA<LlamaSpeechException>().having(
              (e) => e.message,
              'message',
              contains('cancelled'),
            ),
          ),
          emitsDone,
        ]),
      );
      await backend.session!.emitErrorAndClose(
        LlamaSpeechException('Live speech recognition was cancelled.'),
      );
      await eventsDone;
      final failed = await cancelledSession.done;
      expect(failed.state, SpeechToTextCompletionState.failed);
      expect(failed.error, isA<LlamaSpeechException>());

      // Lease is released so another stream can start, and unexpected close
      // also surfaces a typed error/end.
      backend.nextSession = _FakeBackendStreamingSession();
      final closedSession = await recognizer.startStream();
      final unexpectedDone = expectLater(
        closedSession.events,
        emitsInOrder([emitsError(isA<LlamaSpeechException>()), emitsDone]),
      );
      await backend.session!.closeUnexpectedly();
      await unexpectedDone;
      final closedCompletion = await closedSession.done;
      expect(closedCompletion.state, SpeechToTextCompletionState.failed);
      expect(closedCompletion.error, isA<LlamaSpeechException>());

      await recognizer.dispose();
    },
  );
}

final class _FakeStreamingSpeechBackend
    implements
        LlamaBackend,
        BackendMultimodalSupport,
        BackendStreamingSpeechToText {
  final String? unsupportedReason;
  _FakeBackendStreamingSession? session;
  _FakeBackendStreamingSession? nextSession;
  Completer<void>? startGate;
  bool disposed = false;
  int generateCalls = 0;

  _FakeStreamingSpeechBackend({this.unsupportedReason});

  @override
  bool get isReady => !disposed;

  @override
  bool get supportsUrlLoading => false;

  @override
  Future<int> modelLoad(String path, ModelParams params) async => 1;

  @override
  Future<int> modelLoadFromUrl(
    String url,
    ModelParams params, {
    void Function(double progress)? onProgress,
  }) async => 1;

  @override
  Future<void> modelFree(int modelHandle) async {}

  @override
  Future<int> contextCreate(int modelHandle, ModelParams params) async => 2;

  @override
  Future<void> contextFree(int contextHandle) async {}

  @override
  Future<int> getContextSize(int contextHandle) async => 4096;

  @override
  Future<int?> multimodalContextCreate(
    int modelHandle,
    String mmProjPath,
  ) async => 3;

  @override
  Future<void> multimodalContextFree(int mmContextHandle) async {}

  @override
  Future<String> getBackendName() async => 'FakeStreamingSpeech';

  @override
  Future<bool> isGpuSupported() async => false;

  @override
  Future<({int total, int free})> getVramInfo() async => (total: 0, free: 0);

  @override
  Future<bool> supportsAudio(int mmContextHandle) async => true;

  @override
  Future<bool> supportsVision(int mmContextHandle) async => false;

  @override
  Future<String?> streamingSpeechToTextUnsupportedReason(
    int contextHandle,
    int mmContextHandle,
  ) async => unsupportedReason;

  @override
  Future<BackendStreamingSpeechToTextSession> startStreamingSpeechToText(
    int contextHandle,
    int mmContextHandle,
  ) async {
    if (startGate != null) {
      await startGate!.future;
      startGate = null;
    }
    final created = nextSession ?? _FakeBackendStreamingSession();
    nextSession = null;
    session = created;
    return created;
  }

  @override
  Stream<List<int>> generate(
    int contextHandle,
    String prompt,
    GenerationParams params, {
    List<LlamaContentPart>? parts,
  }) {
    generateCalls++;
    return const Stream<List<int>>.empty();
  }

  @override
  void cancelGeneration() {}

  @override
  Future<List<int>> tokenize(
    int modelHandle,
    String text, {
    bool addSpecial = true,
  }) async => const <int>[];

  @override
  Future<String> detokenize(
    int modelHandle,
    List<int> tokens, {
    bool special = false,
  }) async => '';

  @override
  Future<Map<String, String>> modelMetadata(int modelHandle) async =>
      const <String, String>{};

  @override
  Future<String> applyChatTemplate(
    int modelHandle,
    List<Map<String, dynamic>> messages, {
    String? customTemplate,
    bool addAssistant = true,
  }) async => '';

  @override
  Future<void> setLogLevel(LlamaLogLevel level) async {}

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

final class _FakeBackendStreamingSession
    implements BackendStreamingSpeechToTextSession {
  final StreamController<BackendStreamingSpeechToTextUpdate> _updates =
      StreamController<BackendStreamingSpeechToTextUpdate>.broadcast();
  Future<int> Function(Float32List samples)? onPush;
  String finishResult;
  Object? finishError;
  int acceptedSamples = 0;
  int cancelCalls = 0;

  _FakeBackendStreamingSession({this.finishResult = '', this.finishError});

  @override
  Stream<BackendStreamingSpeechToTextUpdate> get updates => _updates.stream;

  void emitUpdate(String confirmedText, int samples) {
    acceptedSamples = samples;
    if (!_updates.isClosed) {
      _updates.add(
        BackendStreamingSpeechToTextUpdate(
          confirmedText: confirmedText,
          acceptedSamples: samples,
        ),
      );
    }
  }

  Future<void> emitErrorAndClose(Object error) async {
    if (!_updates.isClosed) {
      _updates.addError(error);
      await _updates.close();
    }
  }

  Future<void> closeUnexpectedly() async {
    if (!_updates.isClosed) {
      await _updates.close();
    }
  }

  @override
  Future<int> pushAudio(Float32List samples) async {
    if (onPush != null) {
      return onPush!(samples);
    }
    acceptedSamples += samples.length;
    return acceptedSamples;
  }

  @override
  Future<String> finish() async {
    if (finishError != null) {
      throw finishError!;
    }
    if (!_updates.isClosed) {
      await _updates.close();
    }
    return finishResult;
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
    if (!_updates.isClosed) {
      await _updates.close();
    }
  }
}

final class _NonStreamingNativeDelegate implements LlamaBackend {
  @override
  bool get isReady => true;

  @override
  bool get supportsUrlLoading => false;

  @override
  Future<int> modelLoad(String path, ModelParams params) async => 1;

  @override
  Future<int> modelLoadFromUrl(
    String url,
    ModelParams params, {
    void Function(double progress)? onProgress,
  }) async => 1;

  @override
  Future<void> modelFree(int modelHandle) async {}

  @override
  Future<int> contextCreate(int modelHandle, ModelParams params) async => 2;

  @override
  Future<void> contextFree(int contextHandle) async {}

  @override
  Future<int> getContextSize(int contextHandle) async => 1024;

  @override
  Future<String> getBackendName() async => 'FakeNonStreaming';

  @override
  Future<bool> isGpuSupported() async => false;

  @override
  Future<({int total, int free})> getVramInfo() async => (total: 0, free: 0);

  @override
  Stream<List<int>> generate(
    int contextHandle,
    String prompt,
    GenerationParams params, {
    List<LlamaContentPart>? parts,
  }) => const Stream<List<int>>.empty();

  @override
  void cancelGeneration() {}

  @override
  Future<List<int>> tokenize(
    int modelHandle,
    String text, {
    bool addSpecial = true,
  }) async => const <int>[];

  @override
  Future<String> detokenize(
    int modelHandle,
    List<int> tokens, {
    bool special = false,
  }) async => '';

  @override
  Future<Map<String, String>> modelMetadata(int modelHandle) async =>
      const <String, String>{};

  @override
  Future<String> applyChatTemplate(
    int modelHandle,
    List<Map<String, dynamic>> messages, {
    String? customTemplate,
    bool addAssistant = true,
  }) async => '';

  @override
  Future<void> setLogLevel(LlamaLogLevel level) async {}

  @override
  Future<void> dispose() async {}
}
