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
    late _SpeechLlamaEngine llamaEngine;
    late SpeechToTextEngine speechEngine;

    setUp(() async {
      backend = _SpeechBackend();
      llamaEngine = _SpeechLlamaEngine(backend);
      speechEngine = SpeechToTextEngine(
        llamaEngine,
        modelProfile: SpeechToTextModelProfile.qwen3Asr,
      );
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
      expect(
        capabilities.implementation,
        SpeechToTextImplementation.multimodalPromptAdapter,
      );
      expect(capabilities.inputKinds, {
        SpeechAudioInputKind.file,
        SpeechAudioInputKind.encodedBytes,
      });
      expect(capabilities.encodedAudioFormats, {'wav', 'mp3', 'flac'});
      expect(capabilities.supportsPartialResults, isFalse);
      expect(capabilities.supportsStreamingInput, isFalse);
      expect(capabilities.supportsTimestamps, isFalse);
      expect(capabilities.supportsSegmentTimestamps, isFalse);
      expect(capabilities.supportsWordTimestamps, isFalse);
      expect(capabilities.supportsConfidence, isFalse);
      expect(capabilities.supportsSpeakerDiarization, isFalse);
      expect(capabilities.supportsLanguageDetection, isFalse);
      expect(capabilities.supportsLanguageHints, isFalse);
      expect(capabilities.supportsCancellation, isTrue);
      expect(capabilities.supportsOutputBackpressure, isFalse);
      expect(capabilities.maxConcurrentTasks, 1);
    });

    test('reports a projector without audio support as unsupported', () async {
      backend.audioSupported = false;
      await _loadSpeechModel(llamaEngine);

      final capabilities = await speechEngine.capabilities;

      expect(capabilities.isSupported, isFalse);
      expect(capabilities.unsupportedReason, contains('does not report audio'));
    });

    test('turns an audio probe failure into capability diagnostics', () async {
      backend.audioProbeError = StateError('old native symbols');
      await _loadSpeechModel(llamaEngine);

      final capabilities = await speechEngine.capabilities;

      expect(capabilities.isSupported, isFalse);
      expect(capabilities.unsupportedReason, contains('probe failed'));
      expect(capabilities.unsupportedReason, contains('old native symbols'));
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
            contextPrompt: 'llamadart',
            maxOutputTokens: 64,
          ),
        );
        final events = await task.events.toList();
        final completion = await task.done;

        expect(events, hasLength(1));
        final finalEvent = events.single as SpeechToTextFinalEvent;
        expect(finalEvent.result.text, 'Local speech recognition works.');
        expect(finalEvent.result.language, isNull);
        expect(finalEvent.result.segments.single.text, finalEvent.result.text);
        expect(completion.state, SpeechToTextCompletionState.completed);
        expect(completion.result, same(finalEvent.result));
        expect(backend.lastParts, hasLength(2));
        expect(backend.lastParts!.first, isA<LlamaTextContent>());
        expect(
          (backend.lastParts!.first as LlamaTextContent).text,
          'Transcribe this audio accurately. Context: llamadart',
        );
        expect(backend.lastParts![1], isA<LlamaAudioContent>());
        expect(
          (backend.lastParts![1] as LlamaAudioContent).path,
          '/tmp/test.wav',
        );
        expect(backend.lastGenerationPrompt, contains('Context: llamadart'));
        expect(backend.lastGenerationParams?.temp, 0);
        expect(backend.lastGenerationParams?.topK, 1);
        expect(backend.lastGenerationParams?.topP, 1);
        expect(backend.lastGenerationParams?.penalty, 1);
        expect(backend.lastGenerationParams?.seed, 1);
        expect(backend.lastGenerationParams?.maxTokens, 64);
        expect(backend.lastGenerationParams?.streamBatchTokenThreshold, 1);
      },
    );

    test(
      'renders the native audio turn with the model chat template',
      () async {
        await _loadSpeechModel(llamaEngine);

        final task = await speechEngine.transcribe(
          const SpeechToTextRequest(
            audio: SpeechAudioFileInput('/tmp/test.wav'),
          ),
        );
        await task.done;

        expect(backend.lastGenerationPrompt, startsWith('user: '));
        expect(backend.lastGenerationPrompt, endsWith('assistant: '));
        expect(
          backend.lastGenerationPrompt,
          isNot('Transcribe this audio accurately.'),
        );
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

    test('reports an empty transcript as a typed failure', () async {
      backend.generationText = ' <asr_text> ';
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

      expect(
        await streamError.future,
        isA<LlamaSpeechException>().having(
          (error) => error.message,
          'message',
          contains('empty transcript'),
        ),
      );
      expect(completion.state, SpeechToTextCompletionState.failed);
      expect(completion.result, isNull);
      expect(completion.error, isA<LlamaSpeechException>());

      backend.generationText = 'Recovered transcript.';
      final retry = await speechEngine.transcribe(
        const SpeechToTextRequest(audio: SpeechAudioFileInput('/tmp/test.wav')),
      );
      expect((await retry.done).result?.text, 'Recovered transcript.');
    });

    test('rejects unsupported encoded file formats before inference', () async {
      await _loadSpeechModel(llamaEngine);

      expect(
        () => speechEngine.transcribe(
          const SpeechToTextRequest(
            audio: SpeechAudioFileInput('/tmp/recording.m4a'),
          ),
        ),
        throwsA(
          isA<LlamaAudioFormatException>()
              .having(
                (error) => error.message,
                'message',
                contains('WAV, MP3, or FLAC'),
              )
              .having((error) => error.details, 'details', 'm4a'),
        ),
      );
    });

    test('reports an unsupported explicit encoding', () async {
      await _loadSpeechModel(llamaEngine);

      await expectLater(
        speechEngine.transcribe(
          const SpeechToTextRequest(
            audio: SpeechAudioFileInput(
              '/tmp/content-addressed-audio',
              format: SpeechAudioFormat(encoding: 'AAC'),
            ),
          ),
        ),
        throwsA(
          isA<LlamaAudioFormatException>()
              .having(
                (error) => error.message,
                'message',
                contains('WAV, MP3, or FLAC'),
              )
              .having((error) => error.details, 'details', 'aac'),
        ),
      );

      await expectLater(
        speechEngine.transcribe(
          SpeechToTextRequest(
            audio: SpeechAudioBytesInput(
              Uint8List.fromList(<int>[1, 2, 3]),
              format: const SpeechAudioFormat(encoding: 'AAC'),
            ),
          ),
        ),
        throwsA(
          isA<LlamaAudioFormatException>()
              .having(
                (error) => error.message,
                'message',
                contains('WAV, MP3, or FLAC'),
              )
              .having((error) => error.details, 'details', 'aac'),
        ),
      );
    });

    test('accepts an extensionless file with an explicit encoding', () async {
      await _loadSpeechModel(llamaEngine);
      backend.generationText = 'Transcript.';

      final task = await speechEngine.transcribe(
        const SpeechToTextRequest(
          audio: SpeechAudioFileInput(
            '/tmp/content-addressed-audio',
            format: SpeechAudioFormat(encoding: 'wav'),
          ),
        ),
      );

      expect((await task.done).result?.text, 'Transcript.');
      final audio = backend.lastParts![1] as LlamaAudioContent;
      expect(audio.path, '/tmp/content-addressed-audio');
    });

    test('validates empty inputs and token limits synchronously', () async {
      await _loadSpeechModel(llamaEngine);

      await expectLater(
        speechEngine.transcribe(
          const SpeechToTextRequest(audio: SpeechAudioFileInput('')),
        ),
        throwsA(isA<LlamaAudioFormatException>()),
      );
      await expectLater(
        speechEngine.transcribe(
          SpeechToTextRequest(audio: SpeechAudioBytesInput(Uint8List(0))),
        ),
        throwsA(isA<LlamaAudioFormatException>()),
      );
      await expectLater(
        speechEngine.transcribe(
          const SpeechToTextRequest(
            audio: SpeechAudioFileInput('/tmp/test.wav'),
            maxOutputTokens: 0,
          ),
        ),
        throwsA(isA<LlamaSpeechException>()),
      );
      await expectLater(
        speechEngine.transcribe(
          const SpeechToTextRequest(
            audio: SpeechAudioFileInput('/tmp/test.wav'),
            languageHint: 'en',
          ),
        ),
        throwsA(isA<LlamaUnsupportedException>()),
      );
    });

    test('rejects current LiteRT-LM runtimes explicitly', () async {
      backend.backendName = 'LiteRT-LM CPU';
      await _loadSpeechModel(llamaEngine);

      final capabilities = await speechEngine.capabilities;

      expect(capabilities.isSupported, isFalse);
      expect(capabilities.unsupportedReason, contains('not a dedicated ASR'));
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

    test(
      'keeps cancellation authoritative when backend cancel throws',
      () async {
        backend
          ..blockGeneration = true
          ..onCancelGeneration = () {
            throw StateError('synchronous backend cancellation failure');
          };
        await _loadSpeechModel(llamaEngine);

        final task = await speechEngine.transcribe(
          const SpeechToTextRequest(
            audio: SpeechAudioFileInput('/tmp/test.wav'),
          ),
        );
        await backend.generationStarted.future;

        expect(task.cancel, returnsNormally);
        backend.releaseGeneration();

        expect(await task.events.toList(), isEmpty);
        expect((await task.done).state, SpeechToTextCompletionState.cancelled);
        expect(backend.cancelGenerationCalls, 1);

        backend.onCancelGeneration = null;
        final retry = await speechEngine.transcribe(
          const SpeechToTextRequest(
            audio: SpeechAudioFileInput('/tmp/retry.wav'),
          ),
        );
        expect((await retry.done).result?.text, 'transcript');
      },
    );

    test('cancels while the native chat template is being prepared', () async {
      await _loadSpeechModel(llamaEngine);
      backend.blockMetadata = true;

      final task = await speechEngine.transcribe(
        const SpeechToTextRequest(audio: SpeechAudioFileInput('/tmp/test.wav')),
      );
      await backend.metadataStarted.future;

      task.cancel();
      backend.releaseMetadata();

      expect(await task.events.toList(), isEmpty);
      expect((await task.done).state, SpeechToTextCompletionState.cancelled);
      expect(backend.generationStarted.isCompleted, isFalse);
      expect(backend.cancelGenerationCalls, 1);

      final retry = await speechEngine.transcribe(
        const SpeechToTextRequest(audio: SpeechAudioFileInput('/tmp/test.wav')),
      );
      expect((await retry.done).result?.text, 'transcript');
    });

    test('awaits stream cleanup before releasing the backend lease', () async {
      await _loadSpeechModel(llamaEngine);
      final generationRelease = Completer<void>();
      final cleanupStarted = Completer<void>();
      final cleanupRelease = Completer<void>();
      Stream<List<int>> generationStream() async* {
        try {
          await generationRelease.future;
        } finally {
          cleanupStarted.complete();
          await cleanupRelease.future;
        }
      }

      backend
        ..generationStream = generationStream()
        ..onCancelGeneration = () => generationRelease.complete();

      final task = await speechEngine.transcribe(
        const SpeechToTextRequest(audio: SpeechAudioFileInput('/tmp/test.wav')),
      );
      await backend.generationStarted.future;

      task.cancel();
      await cleanupStarted.future;

      var taskCompleted = false;
      unawaited(task.done.whenComplete(() => taskCompleted = true));
      await Future<void>.delayed(Duration.zero);
      expect(taskCompleted, isFalse);
      await expectLater(
        speechEngine.transcribe(
          const SpeechToTextRequest(
            audio: SpeechAudioFileInput('/tmp/retry.wav'),
          ),
        ),
        throwsA(isA<LlamaStateException>()),
      );

      cleanupRelease.complete();
      expect((await task.done).state, SpeechToTextCompletionState.cancelled);

      backend
        ..generationStream = null
        ..onCancelGeneration = null;
      final retry = await speechEngine.transcribe(
        const SpeechToTextRequest(
          audio: SpeechAudioFileInput('/tmp/retry.wav'),
        ),
      );
      expect((await retry.done).result?.text, 'transcript');
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

    test(
      'reserves the engine before asynchronous capability discovery',
      () async {
        backend.blockAudioProbe = true;
        await _loadSpeechModel(llamaEngine);

        final firstFuture = speechEngine.transcribe(
          const SpeechToTextRequest(
            audio: SpeechAudioFileInput('/tmp/first.wav'),
          ),
        );
        await backend.audioProbeStarted.future;

        await expectLater(
          speechEngine.transcribe(
            const SpeechToTextRequest(
              audio: SpeechAudioFileInput('/tmp/second.wav'),
            ),
          ),
          throwsA(isA<LlamaStateException>()),
        );

        backend.releaseAudioProbe();
        final first = await firstFuture;
        await first.done;
      },
    );

    test('shares the task reservation across wrappers', () async {
      backend.blockGeneration = true;
      await _loadSpeechModel(llamaEngine);
      final otherWrapper = SpeechToTextEngine(
        llamaEngine,
        modelProfile: SpeechToTextModelProfile.qwen3Asr,
      );
      final first = await speechEngine.transcribe(
        const SpeechToTextRequest(
          audio: SpeechAudioFileInput('/tmp/first.wav'),
        ),
      );
      await backend.generationStarted.future;

      await expectLater(
        otherWrapper.transcribe(
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

    test('releases the task reservation after preflight failure', () async {
      backend.audioSupported = false;
      await _loadSpeechModel(llamaEngine);

      await expectLater(
        speechEngine.transcribe(
          const SpeechToTextRequest(
            audio: SpeechAudioFileInput('/tmp/first.wav'),
          ),
        ),
        throwsA(isA<LlamaUnsupportedException>()),
      );

      backend.audioSupported = true;
      final task = await speechEngine.transcribe(
        const SpeechToTextRequest(
          audio: SpeechAudioFileInput('/tmp/second.wav'),
        ),
      );
      expect((await task.done).state, SpeechToTextCompletionState.completed);
    });

    test('preserves typed backend failures', () async {
      backend.generationError = LlamaUnsupportedException('missing symbol');
      await _loadSpeechModel(llamaEngine);
      final task = await speechEngine.transcribe(
        const SpeechToTextRequest(audio: SpeechAudioFileInput('/tmp/test.wav')),
      );

      task.events.listen((_) {}, onError: (_) {});
      final completion = await task.done;

      expect(completion.error, isA<LlamaUnsupportedException>());
    });

    test(
      'preserves the generation failure when stream cleanup also fails',
      () async {
        await _loadSpeechModel(llamaEngine);
        late final StreamController<LlamaCompletionChunk> generation;
        generation = StreamController<LlamaCompletionChunk>(
          onListen: () {
            scheduleMicrotask(() {
              generation.addError(
                LlamaUnsupportedException('first generation failure'),
              );
            });
          },
          onCancel: () => Future<void>.error(
            StateError('secondary stream cleanup failure'),
          ),
        );
        llamaEngine.chatCompletionStream = generation.stream;

        final task = await speechEngine.transcribe(
          const SpeechToTextRequest(
            audio: SpeechAudioFileInput('/tmp/test.wav'),
          ),
        );
        final streamError = Completer<Object>();
        task.events.listen(
          (_) {},
          onError: (Object error) => streamError.complete(error),
        );
        final completion = await task.done;

        expect(
          await streamError.future,
          isA<LlamaUnsupportedException>().having(
            (error) => error.message,
            'message',
            'first generation failure',
          ),
        );
        expect(
          completion.error,
          isA<LlamaUnsupportedException>().having(
            (error) => error.message,
            'message',
            'first generation failure',
          ),
        );

        llamaEngine.chatCompletionStream = null;
        final retry = await speechEngine.transcribe(
          const SpeechToTextRequest(
            audio: SpeechAudioFileInput('/tmp/retry.wav'),
          ),
        );
        expect((await retry.done).result?.text, 'transcript');
      },
    );

    test('cancellation wins over a simultaneous backend failure', () async {
      backend
        ..blockGeneration = true
        ..generationError = StateError('late decoder error');
      await _loadSpeechModel(llamaEngine);
      final task = await speechEngine.transcribe(
        const SpeechToTextRequest(audio: SpeechAudioFileInput('/tmp/test.wav')),
      );
      await backend.generationStarted.future;

      task.cancel();
      backend.releaseGeneration();

      expect(await task.events.toList(), isEmpty);
      expect((await task.done).state, SpeechToTextCompletionState.cancelled);
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

      expect(await streamError.future, isA<LlamaInferenceException>());
      expect(completion.state, SpeechToTextCompletionState.failed);
      expect(completion.error, isA<LlamaInferenceException>());
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
  Object? audioProbeError;
  String backendName = 'CPU';
  String generationText = 'transcript';
  List<String>? generationChunks;
  Object? generationError;
  Stream<List<int>>? generationStream;
  void Function()? onCancelGeneration;
  bool blockGeneration = false;
  bool blockAudioProbe = false;
  bool blockMetadata = false;
  Completer<void> audioProbeStarted = Completer<void>();
  final Completer<void> _audioProbeRelease = Completer<void>();
  Completer<void> metadataStarted = Completer<void>();
  final Completer<void> _metadataRelease = Completer<void>();
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
  Future<bool> supportsAudio(int mmContextHandle) async {
    if (!audioProbeStarted.isCompleted) {
      audioProbeStarted.complete();
    }
    if (blockAudioProbe) {
      await _audioProbeRelease.future;
    }
    final error = audioProbeError;
    if (error != null) {
      throw error;
    }
    return audioSupported;
  }

  @override
  Future<String> getBackendName() async => backendName;

  @override
  Future<void> setLogLevel(LlamaLogLevel level) async {}

  @override
  Future<int> getContextSize(int contextHandle) async => 4096;

  @override
  Future<bool> supportsVision(int mmContextHandle) async => false;

  @override
  Future<Map<String, String>> modelMetadata(int modelHandle) async {
    if (!metadataStarted.isCompleted) {
      metadataStarted.complete();
    }
    if (blockMetadata) {
      await _metadataRelease.future;
    }
    return const {
      'llm.context_length': '4096',
      'tokenizer.chat_template':
          '{% for message in messages %}{{ message["role"] + ": " + '
          'message["content"] }}{% endfor %}{% if add_generation_prompt %}'
          '{{ "assistant: " }}{% endif %}',
    };
  }

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
  }) {
    lastGenerationPrompt = prompt;
    lastGenerationParams = params;
    lastParts = parts;
    if (!generationStarted.isCompleted) {
      generationStarted.complete();
    }
    return generationStream ?? _defaultGenerationStream();
  }

  Stream<List<int>> _defaultGenerationStream() async* {
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

  void releaseAudioProbe() {
    if (!_audioProbeRelease.isCompleted) {
      _audioProbeRelease.complete();
    }
  }

  void releaseGeneration() {
    if (!_generationRelease.isCompleted) {
      _generationRelease.complete();
    }
  }

  void releaseMetadata() {
    if (!_metadataRelease.isCompleted) {
      _metadataRelease.complete();
    }
  }

  @override
  void cancelGeneration() {
    cancelGenerationCalls += 1;
    onCancelGeneration?.call();
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

class _SpeechLlamaEngine extends LlamaEngine {
  Stream<LlamaCompletionChunk>? chatCompletionStream;

  _SpeechLlamaEngine(super.backend);

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
  }) {
    return chatCompletionStream ??
        super.create(
          messages,
          params: params,
          tools: tools,
          toolChoice: toolChoice,
          parallelToolCalls: parallelToolCalls,
          enableThinking: enableThinking,
          responseFormat: responseFormat,
          sourceLangCode: sourceLangCode,
          targetLangCode: targetLangCode,
          chatTemplateKwargs: chatTemplateKwargs,
          templateNow: templateNow,
        );
  }
}
