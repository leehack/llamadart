@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';
import 'package:test/test.dart';

void main() {
  test('old or unvalidated Web bridge remains unsupported', () async {
    final engine = await _loadedEngine(promptSpeechToTextSupported: false);
    final recognizer = SpeechToTextEngine(
      engine,
      modelProfile: SpeechToTextModelProfile.qwen3Asr,
    );

    final capabilities = await recognizer.capabilities;

    expect(capabilities.isSupported, isFalse);
    expect(capabilities.unsupportedReason, contains('v0.1.30'));
    await engine.dispose();
  });

  test('validated Web bridge advertises WAV byte input only', () async {
    final engine = await _loadedEngine(promptSpeechToTextSupported: true);
    final recognizer = SpeechToTextEngine(
      engine,
      modelProfile: SpeechToTextModelProfile.qwen3Asr,
    );

    final capabilities = await recognizer.capabilities;

    expect(capabilities.isSupported, isTrue);
    expect(
      capabilities.implementation,
      SpeechToTextImplementation.multimodalPromptAdapter,
    );
    expect(
      capabilities.inputKinds,
      equals(<SpeechAudioInputKind>{SpeechAudioInputKind.encodedBytes}),
    );
    expect(capabilities.encodedAudioFormats, equals(<String>{'wav'}));
    await engine.dispose();
  });

  test('validated Web bridge transcribes encoded WAV bytes', () async {
    final engine = await _loadedEngine(promptSpeechToTextSupported: true);
    final recognizer = SpeechToTextEngine(
      engine,
      modelProfile: SpeechToTextModelProfile.qwen3Asr,
    );

    final task = await recognizer.transcribe(
      SpeechToTextRequest(
        audio: SpeechAudioBytesInput(
          Uint8List.fromList(<int>[0x52, 0x49, 0x46, 0x46]),
          format: const SpeechAudioFormat(encoding: 'wav'),
        ),
      ),
    );
    final events = await task.events.toList();
    final completion = await task.done;

    expect(events, hasLength(1));
    expect((events.single as SpeechToTextFinalEvent).result.text, 'Hello.');
    expect(completion.state, SpeechToTextCompletionState.completed);
    await engine.dispose();
  });

  test('validated Web bridge cancels an active transcription', () async {
    final generationGate = Completer<void>();
    final backend = _WebSpeechBackend(
      promptSpeechToTextSupported: true,
      generationGate: generationGate,
    );
    final engine = LlamaEngine(backend);
    await engine.loadModel('https://example.com/qwen3-asr.gguf');
    await engine.loadMultimodalProjector(
      'https://example.com/qwen3-asr-mmproj.gguf',
    );
    final recognizer = SpeechToTextEngine(
      engine,
      modelProfile: SpeechToTextModelProfile.qwen3Asr,
    );

    final task = await recognizer.transcribe(
      SpeechToTextRequest(
        audio: SpeechAudioBytesInput(
          Uint8List.fromList(<int>[0x52, 0x49, 0x46, 0x46]),
          format: const SpeechAudioFormat(encoding: 'wav'),
        ),
      ),
    );
    task.cancel();
    final completion = await task.done;

    expect(backend.cancelCalled, isTrue);
    expect(completion.state, SpeechToTextCompletionState.cancelled);
    expect(await task.events.toList(), isEmpty);
    await engine.dispose();
  });

  test('Web rejects local paths and unvalidated encoded formats', () async {
    final engine = await _loadedEngine(promptSpeechToTextSupported: true);
    final recognizer = SpeechToTextEngine(
      engine,
      modelProfile: SpeechToTextModelProfile.qwen3Asr,
    );

    await expectLater(
      recognizer.transcribe(
        SpeechToTextRequest(
          audio: SpeechAudioBytesInput(Uint8List.fromList(<int>[1])),
        ),
      ),
      throwsA(
        isA<LlamaAudioFormatException>().having(
          (error) => error.toString(),
          'message',
          contains('SpeechAudioFormat.encoding'),
        ),
      ),
    );
    await expectLater(
      recognizer.transcribe(
        const SpeechToTextRequest(
          audio: SpeechAudioFileInput('/tmp/fixture.wav'),
        ),
      ),
      throwsA(
        isA<LlamaUnsupportedException>().having(
          (error) => error.toString(),
          'message',
          contains('encoded audio bytes only'),
        ),
      ),
    );
    await expectLater(
      recognizer.transcribe(
        SpeechToTextRequest(
          audio: SpeechAudioBytesInput(
            Uint8List.fromList(<int>[1]),
            format: const SpeechAudioFormat(encoding: 'mp3'),
          ),
        ),
      ),
      throwsA(isA<LlamaAudioFormatException>()),
    );
    await engine.dispose();
  });

  test('dedicated LiteRT-LM speech remains unsupported on Web', () async {
    final engine = SpeechToTextEngine.liteRtLm(
      const LiteRtLmAsrRuntimeConfig(
        modelPath: '/models/moonshine.tflite',
        tokenizerPath: '/models/tokenizer.json',
        modelPreset: LiteRtLmAsrModelPreset.moonshineTiny,
      ),
    );

    final capabilities = await engine.capabilities;

    expect(capabilities.isSupported, isFalse);
    expect(capabilities.unsupportedReason, contains('native runtime'));
    await expectLater(
      engine.startStream(),
      throwsA(isA<LlamaUnsupportedException>()),
    );
  });
}

Future<LlamaEngine> _loadedEngine({
  required bool promptSpeechToTextSupported,
}) async {
  final engine = LlamaEngine(
    _WebSpeechBackend(promptSpeechToTextSupported: promptSpeechToTextSupported),
  );
  await engine.loadModel('https://example.com/qwen3-asr.gguf');
  await engine.loadMultimodalProjector(
    'https://example.com/qwen3-asr-mmproj.gguf',
  );
  return engine;
}

class _WebSpeechBackend
    implements LlamaBackend, BackendPromptSpeechToTextSupport {
  @override
  final bool supportsPromptSpeechToText;
  final Completer<void>? generationGate;
  bool cancelCalled = false;

  _WebSpeechBackend({
    required bool promptSpeechToTextSupported,
    this.generationGate,
  }) : supportsPromptSpeechToText = promptSpeechToTextSupported;

  @override
  String? get promptSpeechToTextUnsupportedReason => supportsPromptSpeechToText
      ? null
      : 'Web typed speech-to-text requires bridge v0.1.30 or newer.';

  @override
  bool get isReady => true;

  @override
  bool get supportsUrlLoading => true;

  @override
  Future<int> modelLoadFromUrl(
    String url,
    ModelParams params, {
    Function(double progress)? onProgress,
  }) async => 1;

  @override
  Future<int> contextCreate(int modelHandle, ModelParams params) async => 2;

  @override
  Future<int?> multimodalContextCreate(
    int modelHandle,
    String mmProjPath,
  ) async => 3;

  @override
  Future<bool> supportsAudio(int mmContextHandle) async => true;

  @override
  Future<bool> supportsVision(int mmContextHandle) async => false;

  @override
  Future<String> getBackendName() async => 'WebGPU test';

  @override
  Future<void> setLogLevel(LlamaLogLevel level) async {}

  @override
  Future<int> getContextSize(int contextHandle) async => 4096;

  @override
  Future<Map<String, String>> modelMetadata(int modelHandle) async => const {
    'llm.context_length': '4096',
  };

  @override
  Future<String> applyChatTemplate(
    int modelHandle,
    List<Map<String, dynamic>> messages, {
    String? customTemplate,
    bool addAssistant = true,
  }) async => 'prompt';

  @override
  Stream<List<int>> generate(
    int contextHandle,
    String prompt,
    GenerationParams params, {
    List<LlamaContentPart>? parts,
  }) async* {
    final gate = generationGate;
    if (gate != null) {
      await gate.future;
    }
    if (!cancelCalled) {
      yield utf8.encode('Hello.');
    }
  }

  @override
  Future<void> modelFree(int modelHandle) async {}

  @override
  Future<void> contextFree(int contextHandle) async {}

  @override
  Future<void> multimodalContextFree(int mmContextHandle) async {}

  @override
  void cancelGeneration() {
    cancelCalled = true;
    final gate = generationGate;
    if (gate != null && !gate.isCompleted) {
      gate.complete();
    }
  }

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
