@TestOn('browser')
library;

import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';
import 'package:test/test.dart';

void main() {
  test('typed text-to-speech exposes byte-only Web capabilities', () async {
    final backend = _WebBackend();
    final engine = LlamaEngine(backend);
    addTearDown(engine.dispose);
    await engine.loadModelFromUrl('https://example.com/qwen3-tts.gguf');
    await engine.loadMultimodalProjector(
      'https://example.com/qwen3-tts-mmproj.gguf',
    );
    final speechEngine = TextToSpeechEngine(
      engine,
      modelProfile: TextToSpeechModelProfile.qwen3Tts,
    );

    final capabilities = await speechEngine.capabilities;
    final task = await speechEngine.synthesize(
      TextToSpeechRequest(
        text: 'Hello from Web.',
        speakerReference: SpeechAudioBytesInput(
          Uint8List.fromList(<int>[82, 73, 70, 70]),
        ),
      ),
    );
    final completion = await task.done;

    expect(capabilities.isSupported, isTrue);
    expect(
      capabilities.implementation,
      TextToSpeechImplementation.webAudioGeneration,
    );
    expect(capabilities.speakerReferenceInputKinds, {
      SpeechAudioInputKind.encodedBytes,
    });
    expect(completion.state, TextToSpeechCompletionState.completed);
    expect(completion.result?.samples, <double>[0.25, -0.25]);
    expect(backend.lastRequest?.speakerAudioBytes, isNotEmpty);
  });

  test('typed text-to-speech rejects browser-local speaker paths', () async {
    final speechEngine = TextToSpeechEngine(
      LlamaEngine(_WebBackend()),
      modelProfile: TextToSpeechModelProfile.qwen3Tts,
    );

    await expectLater(
      speechEngine.synthesize(
        const TextToSpeechRequest(
          text: 'Hello.',
          speakerReference: SpeechAudioFileInput('/tmp/speaker.wav'),
        ),
      ),
      throwsA(
        isA<LlamaUnsupportedException>().having(
          (error) => error.message,
          'message',
          contains('encoded bytes'),
        ),
      ),
    );
  });
}

class _WebBackend implements LlamaBackend, BackendTextToSpeech {
  bool _ready = false;
  BackendTextToSpeechRequest? lastRequest;

  @override
  bool get isReady => _ready;

  @override
  bool get supportsUrlLoading => true;

  @override
  Future<int> modelLoadFromUrl(
    String url,
    ModelParams params, {
    void Function(double progress)? onProgress,
  }) async {
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
  Future<void> multimodalContextFree(int mmContextHandle) async {}

  @override
  Future<void> contextFree(int contextHandle) async {}

  @override
  Future<void> modelFree(int modelHandle) async {}

  @override
  Future<String> getBackendName() async => 'WebGPU';

  @override
  Future<void> setLogLevel(LlamaLogLevel level) async {}

  @override
  Future<BackendTextToSpeechCapabilities> textToSpeechCapabilities(
    int contextHandle,
    int mmContextHandle,
  ) async => const BackendTextToSpeechCapabilities(
    isSupported: true,
    model: BackendTextToSpeechModel.qwen3Tts,
    sampleRateHz: 24000,
    channelCount: 1,
    supportsLanguage: true,
    supportsSpeakerReference: true,
    supportsCancellation: true,
  );

  @override
  Future<BackendTextToSpeechResult> synthesizeTextToSpeech(
    int contextHandle,
    int mmContextHandle,
    BackendTextToSpeechRequest request, {
    void Function(BackendTextToSpeechProgress progress)? onProgress,
  }) async {
    lastRequest = request;
    return BackendTextToSpeechResult(
      samples: Float32List.fromList(<double>[0.25, -0.25]),
      sampleRateHz: 24000,
      channelCount: 1,
      framesGenerated: 1,
      truncated: false,
    );
  }

  @override
  void cancelTextToSpeech() {}

  @override
  void cancelGeneration() {}

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
