@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';
import 'package:test/test.dart';

void main() {
  group('SpeechToTextEngine', () {
    late _SpeechBackend backend;
    late LlamaEngine llamaEngine;
    late SpeechToTextEngine speechEngine;

    setUp(() async {
      backend = _SpeechBackend();
      llamaEngine = LlamaEngine(backend);
      speechEngine = SpeechToTextEngine(llamaEngine);
    });

    tearDown(() => llamaEngine.dispose());

    test('reports the unloaded engine as unsupported', () async {
      final capabilities = await speechEngine.capabilities;

      expect(capabilities.isSupported, isFalse);
      expect(capabilities.unsupportedReason, contains('Load a model'));
    });

    test('reports exact first-backend capabilities', () async {
      await _loadSpeechModel(llamaEngine);

      final capabilities = await speechEngine.capabilities;

      expect(capabilities.isSupported, isTrue);
      expect(capabilities.backendName, 'CPU');
      expect(capabilities.inputKinds, containsAll(SpeechAudioInputKind.values));
      expect(capabilities.encodedAudioFormats, {'wav', 'mp3', 'flac'});
      expect(capabilities.pcmSampleRatesHz, {16000});
      expect(capabilities.supportsPartialResults, isFalse);
      expect(capabilities.supportsStreamingInput, isFalse);
      expect(capabilities.supportsTimestamps, isFalse);
      expect(capabilities.supportsSegmentTimestamps, isFalse);
      expect(capabilities.supportsWordTimestamps, isFalse);
      expect(capabilities.supportsConfidence, isFalse);
      expect(capabilities.supportsSpeakerDiarization, isFalse);
      expect(capabilities.supportsLanguageDetection, isTrue);
      expect(capabilities.supportsCancellation, isTrue);
      expect(capabilities.supportsOutputBackpressure, isFalse);
      expect(capabilities.maxConcurrentTasks, 1);
    });

    test(
      'normalizes Qwen3-ASR language prefix and emits one final event',
      () async {
        backend.generationChunks = const <String>[
          'language English<asr_text>Local speech ',
          'recognition works.',
        ];
        await _loadSpeechModel(llamaEngine);

        final task = await speechEngine.transcribe(
          const SpeechToTextRequest(
            audio: SpeechAudioFileInput('/tmp/test.wav'),
            languageHint: 'en',
            contextPrompt: 'llamadart',
            maxOutputTokens: 64,
          ),
        );
        final events = await task.events.toList();
        final completion = await task.done;

        expect(events, hasLength(1));
        final finalEvent = events.single as SpeechToTextFinalEvent;
        expect(finalEvent.result.text, 'Local speech recognition works.');
        expect(finalEvent.result.language, 'English');
        expect(finalEvent.result.segments.single.text, finalEvent.result.text);
        expect(completion.state, SpeechToTextCompletionState.completed);
        expect(completion.result, same(finalEvent.result));
        expect(backend.lastParts, hasLength(2));
        expect(backend.lastParts![1], isA<LlamaAudioContent>());
        expect(
          (backend.lastParts![1] as LlamaAudioContent).path,
          '/tmp/test.wav',
        );
        expect(
          backend.lastGenerationPrompt,
          contains('requested language is en'),
        );
        expect(backend.lastGenerationPrompt, contains('Context: llamadart'));
        expect(backend.lastGenerationParams?.temp, 0);
        expect(backend.lastGenerationParams?.topK, 1);
        expect(backend.lastGenerationParams?.maxTokens, 64);
      },
    );

    test('accepts encoded bytes and strips a bare transcript marker', () async {
      backend.generationText = ' <asr_text> Byte-backed transcript. ';
      await _loadSpeechModel(llamaEngine);

      final task = await speechEngine.transcribe(
        SpeechToTextRequest(
          audio: SpeechAudioBytesInput(Uint8List.fromList(<int>[1, 2, 3])),
        ),
      );
      final result = (await task.done).result!;

      expect(result.text, 'Byte-backed transcript.');
      expect(result.language, isNull);
      final audio = backend.lastParts![1] as LlamaAudioContent;
      expect(audio.bytes, <int>[1, 2, 3]);
    });

    test('passes valid 16 kHz mono Float32 PCM', () async {
      await _loadSpeechModel(llamaEngine);
      final samples = Float32List.fromList(<double>[0, 0.25, -0.25]);

      final task = await speechEngine.transcribe(
        SpeechToTextRequest(
          audio: SpeechPcmInput(
            samples,
            format: const SpeechAudioFormat(
              sampleRateHz: 16000,
              channelCount: 1,
              sampleFormat: SpeechAudioSampleFormat.float32,
            ),
          ),
        ),
      );
      await task.done;

      final audio = backend.lastParts![1] as LlamaAudioContent;
      expect(audio.samples, same(samples));
    });

    test('rejects PCM outside the first backend contract', () async {
      await _loadSpeechModel(llamaEngine);

      expect(
        () => speechEngine.transcribe(
          SpeechToTextRequest(
            audio: SpeechPcmInput(
              Float32List(4),
              format: const SpeechAudioFormat(
                sampleRateHz: 48000,
                channelCount: 2,
                sampleFormat: SpeechAudioSampleFormat.float32,
              ),
            ),
          ),
        ),
        throwsA(
          isA<LlamaAudioFormatException>().having(
            (error) => error.message,
            'message',
            contains('16 kHz mono Float32'),
          ),
        ),
      );
    });

    test('rejects current LiteRT-LM runtimes explicitly', () async {
      backend.backendName = 'LiteRT-LM CPU';
      await _loadSpeechModel(llamaEngine);

      final capabilities = await speechEngine.capabilities;

      expect(capabilities.isSupported, isFalse);
      expect(capabilities.unsupportedReason, contains('not exported'));
      expect(
        () => speechEngine.transcribe(
          const SpeechToTextRequest(
            audio: SpeechAudioFileInput('/tmp/test.wav'),
          ),
        ),
        throwsA(isA<LlamaUnsupportedException>()),
      );
    });

    test('cancels an active recognition task idempotently', () async {
      backend.blockGeneration = true;
      await _loadSpeechModel(llamaEngine);

      final task = await speechEngine.transcribe(
        const SpeechToTextRequest(audio: SpeechAudioFileInput('/tmp/test.wav')),
      );
      await backend.generationStarted.future;
      task.cancel();
      task.cancel();
      backend.releaseGeneration();

      expect(await task.events.toList(), isEmpty);
      expect((await task.done).state, SpeechToTextCompletionState.cancelled);
      expect(backend.cancelGenerationCalls, 1);
    });

    test('allows only one active task per wrapper', () async {
      backend.blockGeneration = true;
      await _loadSpeechModel(llamaEngine);
      final first = await speechEngine.transcribe(
        const SpeechToTextRequest(
          audio: SpeechAudioFileInput('/tmp/first.wav'),
        ),
      );
      await backend.generationStarted.future;

      expect(
        () => speechEngine.transcribe(
          const SpeechToTextRequest(
            audio: SpeechAudioFileInput('/tmp/second.wav'),
          ),
        ),
        throwsA(isA<LlamaStateException>()),
      );

      first.cancel();
      backend.releaseGeneration();
      await first.done;
    });

    test('returns typed failure completion and stream error', () async {
      backend.generationError = StateError('decoder failed');
      await _loadSpeechModel(llamaEngine);
      final task = await speechEngine.transcribe(
        const SpeechToTextRequest(audio: SpeechAudioFileInput('/tmp/test.wav')),
      );

      final streamError = Completer<Object>();
      task.events.listen(
        (_) {},
        onError: (Object error) => streamError.complete(error),
      );
      final completion = await task.done;

      expect(await streamError.future, isA<LlamaSpeechException>());
      expect(completion.state, SpeechToTextCompletionState.failed);
      expect(completion.error, isA<LlamaSpeechException>());
    });
  });
}

Future<void> _loadSpeechModel(LlamaEngine engine) async {
  await engine.loadModel('model.gguf');
  await engine.loadMultimodalProjector('mmproj.gguf');
}

class _SpeechBackend implements LlamaBackend {
  bool _ready = false;
  bool audioSupported = true;
  String backendName = 'CPU';
  String generationText = 'transcript';
  List<String>? generationChunks;
  Object? generationError;
  bool blockGeneration = false;
  Completer<void> generationStarted = Completer<void>();
  final Completer<void> _generationRelease = Completer<void>();
  int cancelGenerationCalls = 0;
  String? lastGenerationPrompt;
  GenerationParams? lastGenerationParams;
  List<LlamaContentPart>? lastParts;

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
  Future<bool> supportsAudio(int mmContextHandle) async => audioSupported;

  @override
  Future<String> getBackendName() async => backendName;

  @override
  Future<void> setLogLevel(LlamaLogLevel level) async {}

  @override
  Future<int> getContextSize(int contextHandle) async => 4096;

  @override
  Future<bool> supportsVision(int mmContextHandle) async => false;

  @override
  Future<Map<String, String>> modelMetadata(int modelHandle) async => const {
    'llm.context_length': '4096',
    'tokenizer.chat_template':
        '{% for message in messages %}{{ message["role"] + ": " + '
        'message["content"] }}{% endfor %}{% if add_generation_prompt %}'
        '{{ "assistant: " }}{% endif %}',
  };

  @override
  Future<String> applyChatTemplate(
    int modelHandle,
    List<Map<String, dynamic>> messages, {
    String? customTemplate,
    bool addAssistant = true,
  }) async {
    return messages.map((message) => message['content']).join('\n');
  }

  @override
  Stream<List<int>> generate(
    int contextHandle,
    String prompt,
    GenerationParams params, {
    List<LlamaContentPart>? parts,
  }) async* {
    lastGenerationPrompt = prompt;
    lastGenerationParams = params;
    lastParts = parts;
    if (!generationStarted.isCompleted) {
      generationStarted.complete();
    }
    if (blockGeneration) {
      await _generationRelease.future;
    }
    final error = generationError;
    if (error != null) {
      throw error;
    }
    final chunks = generationChunks ?? <String>[generationText];
    for (final chunk in chunks) {
      yield utf8.encode(chunk);
    }
  }

  void releaseGeneration() {
    if (!_generationRelease.isCompleted) {
      _generationRelease.complete();
    }
  }

  @override
  void cancelGeneration() {
    cancelGenerationCalls += 1;
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
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
