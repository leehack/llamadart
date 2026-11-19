@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:llamadart/backend.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/backends/backend.dart'
    show BackendGenerationLimit, BackendGenerationLimitReporting;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('Qwen3WindowedAsrAdapter session lifecycle', () {
    late Directory directory;
    late String modelPath;
    late String projectorPath;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp(
        'llamadart_qwen_lifecycle_',
      );
      modelPath = p.join(directory.path, 'qwen.gguf');
      projectorPath = p.join(directory.path, 'mmproj-qwen.gguf');
      await File(modelPath).writeAsBytes(<int>[1, 2, 3]);
      await File(
        projectorPath,
      ).writeAsBytes(_ggufHeader({'clip.audio.projector_type': 'qwen3a'}));
    });

    tearDown(() async {
      await directory.delete(recursive: true);
    });

    Future<SpeechToTextEngine> loadRecognizer(_WindowedFakeBackend backend) {
      return SpeechToTextEngine.load(
        SpeechToTextModel(
          ModelSource.path(modelPath),
          projector: ModelSource.path(projectorPath),
          adapter: const Qwen3WindowedAsrAdapter(),
        ),
        backend: backend,
      );
    }

    test(
      'rejects overlapping pushes and concurrent startStream calls',
      () async {
        final decodeGate = Completer<void>();
        final backend = _WindowedFakeBackend(decodeGate: decodeGate);
        final recognizer = await loadRecognizer(backend);

        final session = await recognizer.startStream();
        await expectLater(
          recognizer.startStream(),
          throwsA(isA<LlamaStateException>()),
        );

        final firstPush = session.addPcm(
          Float32List(32000)..fillRange(0, 32000, 0.2),
        );
        await Future<void>.delayed(Duration.zero);

        await expectLater(
          session.addPcm(Float32List(100)),
          throwsA(
            isA<LlamaStateException>().having(
              (e) => e.message,
              'message',
              contains('already in progress'),
            ),
          ),
        );

        decodeGate.complete();
        await firstPush;
        await session.finish();
        final completion = await session.done;
        expect(completion.state, SpeechToTextCompletionState.completed);
        await recognizer.dispose();
      },
    );

    test(
      'cancel interrupts in-flight decode, wakes blocked push, and allows immediate reuse',
      () async {
        final decodeStarted = Completer<void>();
        final decodeGate = Completer<void>();
        final backend = _WindowedFakeBackend(
          decodeStarted: decodeStarted,
          decodeGate: decodeGate,
        );
        final recognizer = await loadRecognizer(backend);

        final session = await recognizer.startStream();
        final events = <SpeechToTextEvent>[];
        final sub = session.events.listen(events.add);

        final push = session.addPcm(
          Float32List(32000)..fillRange(0, 32000, 0.2),
        );
        await decodeStarted.future;

        final cancelFuture = session.cancel();
        await cancelFuture;
        await push;

        final completion = await session.done;
        await sub.cancel();
        expect(completion.state, SpeechToTextCompletionState.cancelled);
        expect(events.whereType<SpeechToTextFinalEvent>(), isEmpty);

        // Immediate reuse after cancel succeeds once the lease is released.
        backend.decodeStarted = null;
        backend.decodeGate = null;
        final reused = await recognizer.startStream();
        await reused.addPcm(Float32List(16000)..fillRange(0, 16000, 0.2));
        await reused.finish();
        final reusedCompletion = await reused.done;
        expect(reusedCompletion.state, SpeechToTextCompletionState.completed);
        await recognizer.dispose();
      },
    );

    test(
      'cancels during quiet verification without publishing and can restart',
      () async {
        final verificationStarted = Completer<void>();
        final backend = _WindowedFakeBackend(
          decodeStarted: verificationStarted,
          decodeGate: Completer<void>(),
          gatedCall: 2,
        );
        final recognizer = await loadRecognizer(backend);
        addTearDown(recognizer.dispose);

        final session = await recognizer.startStream();
        final events = <SpeechToTextEvent>[];
        final sub = session.events.listen(events.add);
        addTearDown(sub.cancel);
        final push = session.addPcm(
          Float32List(32000)..fillRange(0, 32000, 0.001),
        );
        // The push must stay blocked until the second decode settles.
        final started = await Future.any([
          verificationStarted.future.then((_) => true),
          push.then((_) => false),
        ]);
        expect(started, isTrue);
        await expectLater(
          session.addPcm(Float32List(1)),
          throwsA(isA<LlamaStateException>()),
        );
        expect(events, isEmpty);

        await session.cancel();
        await push;
        expect(
          (await session.done).state,
          SpeechToTextCompletionState.cancelled,
        );
        expect(events, isEmpty);

        final reused = await recognizer.startStream();
        await reused.addPcm(Float32List(16000)..fillRange(0, 16000, 0.2));
        await reused.finish();
        expect(
          (await reused.done).state,
          SpeechToTextCompletionState.completed,
        );
      },
    );

    test(
      'propagates errors and truncation during quiet verification',
      () async {
        for (final (failure, limit, errorMatcher) in [
          (
            StateError('verification decoder exploded'),
            <int>{},
            isA<LlamaInferenceException>(),
          ),
          (null, {2}, isA<LlamaSpeechTranscriptTruncatedException>()),
        ]) {
          final backend = _WindowedFakeBackend(
            failWith: failure,
            failAtCall: 2,
            limitAtCalls: limit,
          );
          final recognizer = await loadRecognizer(backend);
          final session = await recognizer.startStream();
          final events = <SpeechToTextEvent>[];
          final errors = <Object>[];
          final sub = session.events.listen(events.add, onError: errors.add);
          try {
            await expectLater(
              session.addPcm(Float32List(32000)..fillRange(0, 32000, 0.001)),
              throwsA(errorMatcher),
            );
            final done = await session.done;
            expect(done.state, SpeechToTextCompletionState.failed);
            expect(done.error, errorMatcher);
            expect(errors, [same(done.error)]);
            expect(events, isEmpty);
          } finally {
            await sub.cancel();
            await recognizer.dispose();
          }
        }
      },
    );

    test(
      'coalesces partials while paused or unlistened and delivers terminal result without listener',
      () async {
        final backend = _WindowedFakeBackend();
        final recognizer = await loadRecognizer(backend);

        // 1. Unlistened session still completes with terminal result.
        final unlistened = await recognizer.startStream();
        await unlistened.addPcm(Float32List(64000)..fillRange(0, 64000, 0.2));
        await unlistened.finish();
        final unlistenedDone = await unlistened.done;
        expect(unlistenedDone.state, SpeechToTextCompletionState.completed);
        expect(unlistenedDone.result!.text, isNotEmpty);

        // 2. Paused listener coalesces intermediate partials to the latest one.
        final session = await recognizer.startStream();
        final received = <SpeechToTextEvent>[];
        final sub = session.events.listen(received.add);
        sub.pause();

        await session.addPcm(Float32List(32000)..fillRange(0, 32000, 0.2));
        await session.addPcm(Float32List(32000)..fillRange(0, 32000, 0.2));
        expect(received, isEmpty);

        sub.resume();
        await Future<void>.delayed(Duration.zero);
        expect(received.whereType<SpeechToTextPartialEvent>(), hasLength(1));

        await session.finish();
        await session.done;
        await sub.cancel();
        await recognizer.dispose();
      },
    );

    test(
      'rejects invalid floats, bad PCM formats, context prompts, and non-PCM requests',
      () async {
        final backend = _WindowedFakeBackend();
        final recognizer = await loadRecognizer(backend);

        await expectLater(
          recognizer.transcribe(
            const SpeechToTextRequest(
              audio: SpeechAudioFileInput('speech.wav'),
            ),
          ),
          throwsA(isA<LlamaUnsupportedException>()),
        );
        await expectLater(
          recognizer.transcribe(
            SpeechToTextRequest(
              audio: SpeechAudioPcmInput(Float32List(1600)),
              contextPrompt: 'hint',
            ),
          ),
          throwsA(isA<LlamaUnsupportedException>()),
        );
        await expectLater(
          recognizer.startStream(
            format: const SpeechAudioFormat(
              sampleRateHz: 8000,
              channelCount: 1,
              encoding: 'pcm-f32le',
            ),
          ),
          throwsA(isA<LlamaAudioFormatException>()),
        );

        final session = await recognizer.startStream();
        final errors = <Object>[];
        final sub = session.events.listen((_) {}, onError: errors.add);
        await expectLater(
          session.addPcm(Float32List.fromList(<double>[0.0, double.nan])),
          throwsA(isA<LlamaAudioFormatException>()),
        );
        final completion = await session.done;
        await sub.cancel();
        expect(completion.state, SpeechToTextCompletionState.failed);
        expect(errors, hasLength(1));
        await recognizer.dispose();
      },
    );

    test(
      'transcribe enforces maxOutputTokens per decode and reports partial in truncation error',
      () async {
        final backend = _WindowedFakeBackend(limitAtCalls: {5});
        final recognizer = await loadRecognizer(backend);

        // 10s -> window 1 commits at call 4 ("w4"), then 2s tail hits maxTokens at call 5 ("w5").
        final audio = Float32List(160000)..fillRange(0, 160000, 0.2);
        final task = await recognizer.transcribe(
          SpeechToTextRequest(
            audio: SpeechAudioPcmInput(audio),
            maxOutputTokens: 16,
          ),
        );
        final completion = await task.done;

        expect(backend.seenMaxTokens, everyElement(16));
        expect(completion.state, SpeechToTextCompletionState.failed);
        expect(
          completion.error,
          isA<LlamaSpeechTranscriptTruncatedException>()
              .having(
                (e) => e.limit,
                'limit',
                LlamaSpeechTranscriptLimit.maxOutputTokens,
              )
              .having(
                (e) => e.partialTranscript,
                'partialTranscript',
                'w4\nw5',
              ),
        );
        await recognizer.dispose();
      },
    );

    test(
      'propagates backend failure instead of treating it as silence',
      () async {
        final backend = _WindowedFakeBackend(
          failWith: StateError('decoder exploded'),
        );
        final recognizer = await loadRecognizer(backend);

        final session = await recognizer.startStream();
        final errors = <Object>[];
        final sub = session.events.listen((_) {}, onError: errors.add);

        await expectLater(
          session.addPcm(Float32List(32000)..fillRange(0, 32000, 0.2)),
          throwsA(isA<LlamaInferenceException>()),
        );
        final completion = await session.done;
        await sub.cancel();

        expect(completion.state, SpeechToTextCompletionState.failed);
        expect(completion.error, isA<LlamaInferenceException>());
        expect(errors, hasLength(1));
        await recognizer.dispose();
      },
    );

    test(
      'dispose cancels active windowed session and awaits cleanup',
      () async {
        final decodeStarted = Completer<void>();
        final decodeGate = Completer<void>();
        final backend = _WindowedFakeBackend(
          decodeStarted: decodeStarted,
          decodeGate: decodeGate,
        );
        final recognizer = await loadRecognizer(backend);

        final session = await recognizer.startStream();
        final push = session.addPcm(
          Float32List(32000)..fillRange(0, 32000, 0.2),
        );
        await decodeStarted.future;

        await recognizer.dispose();
        await push;

        expect(
          (await session.done).state,
          SpeechToTextCompletionState.cancelled,
        );
        expect(backend.disposeCalls, 1);
      },
    );
  });
}

class _WindowedFakeBackend
    implements
        LlamaBackend,
        BackendMultimodalSupport,
        BackendGenerationLimitReporting {
  Completer<void>? decodeStarted;
  Completer<void>? decodeGate;
  final int? gatedCall;
  final Set<int> limitAtCalls;
  final Object? failWith;
  final int? failAtCall;
  final List<int> seenMaxTokens = <int>[];

  int _decodeCalls = 0;
  int disposeCalls = 0;
  bool _modelLoaded = false;
  bool _projectorLoaded = false;

  _WindowedFakeBackend({
    this.decodeStarted,
    this.decodeGate,
    this.gatedCall,
    this.limitAtCalls = const <int>{},
    this.failWith,
    this.failAtCall,
  });

  @override
  bool get isReady => _modelLoaded;

  @override
  bool get supportsUrlLoading => false;

  @override
  Future<void> setLogLevel(LlamaLogLevel level) async {}

  @override
  Future<int> getContextSize(int contextHandle) async => 4096;

  @override
  Future<Map<String, String>> modelMetadata(int modelHandle) async =>
      const <String, String>{};

  @override
  Future<String> applyChatTemplate(
    int modelHandle,
    List<Map<String, dynamic>> messages, {
    String? customTemplate,
    bool addAssistant = true,
  }) async => 'prompt';

  @override
  Future<int> modelLoad(String path, ModelParams params) async {
    _modelLoaded = true;
    return 1;
  }

  @override
  Future<int> modelLoadFromUrl(
    String url,
    ModelParams params, {
    Function(double progress)? onProgress,
  }) async {
    _modelLoaded = true;
    return 1;
  }

  @override
  Future<void> modelFree(int modelHandle) async {
    _modelLoaded = false;
  }

  @override
  Future<int> contextCreate(int modelHandle, ModelParams params) async => 2;

  @override
  Future<void> contextFree(int contextHandle) async {}

  @override
  Future<int?> multimodalContextCreate(
    int modelHandle,
    String mmprojPath,
  ) async {
    _projectorLoaded = true;
    return 3;
  }

  @override
  Future<void> multimodalContextFree(int mmContextHandle) async {
    _projectorLoaded = false;
  }

  @override
  Future<bool> supportsAudio(int mmContextHandle) async => _projectorLoaded;

  @override
  Future<bool> supportsVision(int mmContextHandle) async => false;

  @override
  Future<String> getBackendName() async => 'llama.cpp (CPU)';

  @override
  Future<void> dispose() async {
    disposeCalls++;
  }

  Future<String> getChatTemplate(int modelHandle) async => '';

  @override
  void cancelGeneration() {}

  @override
  BackendGenerationLimit? generationLimitOf(Stream<List<int>> generation) {
    if (limitAtCalls.contains(_decodeCalls)) {
      return BackendGenerationLimit.maxTokens;
    }
    return null;
  }

  @override
  Stream<List<int>> generate(
    int contextHandle,
    String prompt,
    GenerationParams params, {
    List<LlamaContentPart>? parts,
  }) {
    final call = ++_decodeCalls;
    final gate = gatedCall == null || gatedCall == call ? decodeGate : null;
    final started = gatedCall == null || gatedCall == call
        ? decodeStarted
        : null;
    seenMaxTokens.add(params.maxTokens);
    late final StreamController<List<int>> controller;
    var cancelled = false;
    controller = StreamController<List<int>>(
      onListen: () async {
        if (failWith != null && (failAtCall == null || failAtCall == call)) {
          controller.addError(failWith!);
          await controller.close();
          return;
        }
        if (started != null && !started.isCompleted) {
          started.complete();
        }
        if (gate != null) {
          await gate.future;
        }
        if (!cancelled && !controller.isClosed) {
          controller.add(utf8.encode('language English<asr_text> w$call'));
          await controller.close();
        }
      },
      onCancel: () {
        cancelled = true;
        if (gate != null && !gate.isCompleted) {
          gate.complete();
        }
      },
    );
    return controller.stream;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Uint8List _ggufHeader(Map<String, Object> metadata) {
  final bytes = BytesBuilder();
  void u32(int value) => bytes.add(
    (ByteData(4)..setUint32(0, value, Endian.little)).buffer.asUint8List(),
  );
  void u64(int value) => bytes.add(
    (ByteData(8)..setUint64(0, value, Endian.little)).buffer.asUint8List(),
  );
  void string(String value) {
    final encoded = utf8.encode(value);
    u64(encoded.length);
    bytes.add(encoded);
  }

  bytes.add(ascii.encode('GGUF'));
  u32(3);
  u64(0);
  u64(metadata.length);
  for (final MapEntry(:key, :value) in metadata.entries) {
    string(key);
    u32(8); // GGUF_TYPE_STRING
    string(value as String);
  }
  return bytes.toBytes();
}
