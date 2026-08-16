@TestOn('vm')
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';
import 'package:test/test.dart';

void main() {
  group('TextToSpeechEngine', () {
    late _TextToSpeechBackend backend;
    late LlamaEngine llamaEngine;
    late TextToSpeechEngine speechEngine;

    setUp(() {
      backend = _TextToSpeechBackend();
      llamaEngine = LlamaEngine(backend);
      speechEngine = TextToSpeechEngine(
        llamaEngine,
        modelProfile: TextToSpeechModelProfile.qwen3Tts,
      );
    });

    tearDown(() => llamaEngine.dispose());

    test('reports an unloaded engine as unsupported', () async {
      final capabilities = await speechEngine.capabilities;

      expect(capabilities.isSupported, isFalse);
      expect(capabilities.unsupportedReason, contains('Load a model'));
    });

    test('reports exact native Qwen3-TTS capabilities', () async {
      await _loadTextToSpeechModel(llamaEngine);

      final capabilities = await speechEngine.capabilities;

      expect(capabilities.isSupported, isTrue);
      expect(capabilities.backendName, 'Metal');
      expect(
        capabilities.implementation,
        TextToSpeechImplementation.nativeAudioGeneration,
      );
      expect(capabilities.sampleRateHz, 24000);
      expect(capabilities.channelCount, 1);
      expect(capabilities.supportsLanguage, isTrue);
      expect(
        capabilities.supportedLanguages,
        containsAll(<String>[
          'en',
          'zh',
          'ja',
          'ko',
          'de',
          'fr',
          'ru',
          'pt',
          'es',
          'it',
        ]),
      );
      expect(capabilities.supportsSpeakerReference, isTrue);
      expect(capabilities.speakerReferenceInputKinds, {
        SpeechAudioInputKind.file,
        SpeechAudioInputKind.encodedBytes,
      });
      expect(capabilities.supportsIncrementalAudio, isFalse);
      expect(capabilities.supportsCancellation, isTrue);
      expect(capabilities.supportsOutputBackpressure, isFalse);
      expect(capabilities.maxConcurrentTasks, 1);
    });

    test('emits progress then final PCM and encodes a valid WAV', () async {
      await _loadTextToSpeechModel(llamaEngine);
      final speakerBytes = Uint8List.fromList(<int>[82, 73, 70, 70]);

      final task = await speechEngine.synthesize(
        TextToSpeechRequest(
          text: 'Hello from llamadart.',
          language: 'English',
          speakerReference: SpeechAudioBytesInput(speakerBytes),
          maxFrames: 64,
          seed: 7,
        ),
      );
      final events = await task.events.toList();
      final completion = await task.done;

      expect(events, hasLength(3));
      expect(events[0], isA<TextToSpeechProgressEvent>());
      expect(events[1], isA<TextToSpeechProgressEvent>());
      final finalEvent = events[2] as TextToSpeechFinalEvent;
      expect(completion.state, TextToSpeechCompletionState.completed);
      expect(completion.result, same(finalEvent.result));
      expect(finalEvent.result.sampleRateHz, 24000);
      expect(finalEvent.result.channelCount, 1);
      expect(finalEvent.result.samples, <double>[-1, -0.5, 0, 0.5, 1]);
      expect(finalEvent.result.duration.inMicroseconds, 208);
      expect(backend.lastRequest?.text, 'Hello from llamadart.');
      expect(backend.lastRequest?.language, 'en');
      expect(backend.lastRequest?.speakerAudioBytes, speakerBytes);
      expect(backend.lastRequest?.maxFrames, 64);
      expect(backend.lastRequest?.seed, 7);

      final wav = finalEvent.result.toWavBytes();
      expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
      expect(ByteData.sublistView(wav).getUint32(24, Endian.little), 24000);
      expect(ByteData.sublistView(wav).getUint16(22, Endian.little), 1);
      expect(ByteData.sublistView(wav).getUint32(40, Endian.little), 10);
      expect(ByteData.sublistView(wav).getInt16(44, Endian.little), -32768);
      expect(ByteData.sublistView(wav).getInt16(52, Endian.little), 32767);
    });

    test('accepts a speaker reference file', () async {
      await _loadTextToSpeechModel(llamaEngine);

      final task = await speechEngine.synthesize(
        const TextToSpeechRequest(
          text: 'Clone this voice.',
          speakerReference: SpeechAudioFileInput('/tmp/speaker.wav'),
        ),
      );
      await task.done;

      expect(backend.lastRequest?.speakerAudioPath, '/tmp/speaker.wav');
      expect(backend.lastRequest?.speakerAudioBytes, isNull);
    });

    test('reserves the engine before asynchronous preflight', () async {
      await _loadTextToSpeechModel(llamaEngine);
      backend.blockCapabilities = true;

      final first = speechEngine.synthesize(
        const TextToSpeechRequest(text: 'First.'),
      );
      await backend.capabilityProbeStarted.future;

      await expectLater(
        speechEngine.synthesize(const TextToSpeechRequest(text: 'Second.')),
        throwsA(isA<LlamaStateException>()),
      );
      backend.releaseCapabilities();
      await (await first).done;
    });

    test('shares the lease across separate TTS wrappers', () async {
      await _loadTextToSpeechModel(llamaEngine);
      backend.blockSynthesis = true;
      final other = TextToSpeechEngine(
        llamaEngine,
        modelProfile: TextToSpeechModelProfile.qwen3Tts,
      );

      final first = await speechEngine.synthesize(
        const TextToSpeechRequest(text: 'First.'),
      );
      await backend.synthesisStarted.future;
      await expectLater(
        other.synthesize(const TextToSpeechRequest(text: 'Second.')),
        throwsA(isA<LlamaStateException>()),
      );
      backend.releaseSynthesis();
      await first.done;
    });

    test('shares the engine lease with typed speech recognition', () async {
      await _loadTextToSpeechModel(llamaEngine);
      backend.blockSynthesis = true;
      final recognizer = SpeechToTextEngine(
        llamaEngine,
        modelProfile: SpeechToTextModelProfile.qwen3Asr,
      );

      final synthesis = await speechEngine.synthesize(
        const TextToSpeechRequest(text: 'First.'),
      );
      await backend.synthesisStarted.future;
      await expectLater(
        recognizer.transcribe(
          SpeechToTextRequest(
            audio: SpeechAudioBytesInput(Uint8List.fromList(<int>[1])),
          ),
        ),
        throwsA(isA<LlamaStateException>()),
      );

      backend.releaseSynthesis();
      await synthesis.done;
    });

    test('cancels active synthesis idempotently', () async {
      await _loadTextToSpeechModel(llamaEngine);
      backend.blockSynthesis = true;
      final task = await speechEngine.synthesize(
        const TextToSpeechRequest(text: 'Cancel me.'),
      );
      await backend.synthesisStarted.future;

      task.cancel();
      task.cancel();
      final completion = await task.done;

      expect(backend.cancelCalls, 1);
      expect(completion.state, TextToSpeechCompletionState.cancelled);
      expect(await task.events.toList(), isEmpty);
    });

    test('validates input and sampling before capability lookup', () async {
      await _loadTextToSpeechModel(llamaEngine);

      await expectLater(
        speechEngine.synthesize(const TextToSpeechRequest(text: '   ')),
        throwsA(isA<LlamaTextToSpeechException>()),
      );
      await expectLater(
        speechEngine.synthesize(
          TextToSpeechRequest(
            text: 'Speaker.',
            speakerReference: SpeechAudioBytesInput(Uint8List(0)),
          ),
        ),
        throwsA(isA<LlamaAudioFormatException>()),
      );
      await expectLater(
        speechEngine.synthesize(
          const TextToSpeechRequest(text: 'Bad.', topP: 2),
        ),
        throwsA(isA<LlamaTextToSpeechException>()),
      );
      for (final request in const <TextToSpeechRequest>[
        TextToSpeechRequest(text: 'Bad top p.', topP: double.nan),
        TextToSpeechRequest(text: 'Bad min p.', minP: double.infinity),
        TextToSpeechRequest(
          text: 'Bad temperature.',
          temperature: double.negativeInfinity,
        ),
      ]) {
        await expectLater(
          speechEngine.synthesize(request),
          throwsA(isA<LlamaTextToSpeechException>()),
        );
      }
      await expectLater(
        speechEngine.synthesize(
          const TextToSpeechRequest(
            text: 'Unknown language.',
            language: 'Klingon',
          ),
        ),
        throwsA(
          isA<LlamaTextToSpeechException>().having(
            (error) => error.message,
            'message',
            contains('zh, en'),
          ),
        ),
      );
    });

    test('reports unsupported model capability without starting', () async {
      backend.capabilities = const BackendTextToSpeechCapabilities(
        isSupported: false,
        unsupportedReason: 'old native bundle',
      );
      await _loadTextToSpeechModel(llamaEngine);

      expect(
        (await speechEngine.capabilities).unsupportedReason,
        'old native bundle',
      );
      await expectLater(
        speechEngine.synthesize(const TextToSpeechRequest(text: 'Hello.')),
        throwsA(isA<LlamaUnsupportedException>()),
      );
      expect(backend.lastRequest, isNull);
    });

    test('returns typed task failure and releases the lease', () async {
      backend.synthesisError = StateError('codec failed');
      await _loadTextToSpeechModel(llamaEngine);
      final task = await speechEngine.synthesize(
        const TextToSpeechRequest(text: 'Fail.'),
      );
      final streamError = Completer<Object>();
      task.events.listen(
        (_) {},
        onError: (Object error) => streamError.complete(error),
      );

      final completion = await task.done;
      expect(await streamError.future, isA<LlamaTextToSpeechException>());
      expect(completion.state, TextToSpeechCompletionState.failed);

      backend.synthesisError = null;
      final retry = await speechEngine.synthesize(
        const TextToSpeechRequest(text: 'Retry.'),
      );
      expect((await retry.done).state, TextToSpeechCompletionState.completed);
    });
  });
}

Future<void> _loadTextToSpeechModel(LlamaEngine engine) async {
  await engine.loadModel('qwen3-tts.gguf');
  await engine.loadMultimodalProjector('qwen3-tts-mmproj.gguf');
}

class _TextToSpeechBackend implements LlamaBackend, BackendTextToSpeech {
  bool _ready = false;
  BackendTextToSpeechCapabilities capabilities =
      const BackendTextToSpeechCapabilities(
        isSupported: true,
        model: BackendTextToSpeechModel.qwen3Tts,
        sampleRateHz: 24000,
        channelCount: 1,
        supportsLanguage: true,
        supportsSpeakerReference: true,
        supportsCancellation: true,
      );
  bool blockCapabilities = false;
  bool blockSynthesis = false;
  Object? synthesisError;
  Completer<void> capabilityProbeStarted = Completer<void>();
  Completer<void> synthesisStarted = Completer<void>();
  final Completer<void> _capabilityRelease = Completer<void>();
  final Completer<void> _synthesisRelease = Completer<void>();
  int cancelCalls = 0;
  BackendTextToSpeechRequest? lastRequest;

  @override
  bool get isReady => _ready;

  @override
  bool get supportsUrlLoading => false;

  @override
  Future<int> modelLoad(String path, ModelParams params) async {
    _ready = true;
    return 1;
  }

  @override
  Future<int> contextCreate(int modelHandle, ModelParams params) async => 2;

  @override
  Future<int?> multimodalContextCreate(
    int modelHandle,
    String mmProjPath,
  ) async => 3;

  @override
  Future<String> getBackendName() async => 'Metal';

  @override
  Future<BackendTextToSpeechCapabilities> textToSpeechCapabilities(
    int contextHandle,
    int mmContextHandle,
  ) async {
    if (!capabilityProbeStarted.isCompleted) {
      capabilityProbeStarted.complete();
    }
    if (blockCapabilities) {
      await _capabilityRelease.future;
    }
    return capabilities;
  }

  @override
  Future<BackendTextToSpeechResult> synthesizeTextToSpeech(
    int contextHandle,
    int mmContextHandle,
    BackendTextToSpeechRequest request, {
    void Function(BackendTextToSpeechProgress progress)? onProgress,
  }) async {
    lastRequest = request;
    if (!synthesisStarted.isCompleted) {
      synthesisStarted.complete();
    }
    if (blockSynthesis) {
      await _synthesisRelease.future;
    }
    final error = synthesisError;
    if (error != null) {
      throw error;
    }
    onProgress?.call(
      const BackendTextToSpeechProgress(
        phase: BackendTextToSpeechPhase.processingPrompt,
        promptTokensRemaining: 2,
        framesGenerated: 0,
        truncated: false,
      ),
    );
    onProgress?.call(
      const BackendTextToSpeechProgress(
        phase: BackendTextToSpeechPhase.generating,
        promptTokensRemaining: 0,
        framesGenerated: 3,
        truncated: false,
      ),
    );
    return BackendTextToSpeechResult(
      samples: Float32List.fromList(<double>[-1, -0.5, 0, 0.5, 1]),
      sampleRateHz: 24000,
      channelCount: 1,
      framesGenerated: 3,
      truncated: false,
    );
  }

  @override
  void cancelTextToSpeech() {
    cancelCalls += 1;
    releaseSynthesis();
  }

  @override
  void cancelGeneration() {}

  void releaseCapabilities() {
    if (!_capabilityRelease.isCompleted) {
      _capabilityRelease.complete();
    }
  }

  void releaseSynthesis() {
    if (!_synthesisRelease.isCompleted) {
      _synthesisRelease.complete();
    }
  }

  @override
  Future<void> modelFree(int modelHandle) async {}

  @override
  Future<void> contextFree(int contextHandle) async {}

  @override
  Future<void> multimodalContextFree(int mmContextHandle) async {}

  @override
  Future<void> dispose() async {
    _ready = false;
  }

  @override
  Future<void> setLogLevel(LlamaLogLevel level) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
