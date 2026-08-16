@TestOn('browser')
library;

import 'package:llamadart/llamadart.dart';
import 'package:test/test.dart';

void main() {
  test('dedicated speech-to-text is explicitly unsupported on Web', () async {
    final engine = SpeechToTextEngine(
      LlamaEngine(_WebBackend()),
      modelProfile: SpeechToTextModelProfile.qwen3Asr,
    );

    final capabilities = await engine.capabilities;

    expect(capabilities.isSupported, isFalse);
    expect(capabilities.unsupportedReason, contains('not available on Web'));
    expect(capabilities.unsupportedReason, contains('generic audio input'));
    await expectLater(
      engine.transcribe(
        const SpeechToTextRequest(
          audio: SpeechAudioFileInput('/tmp/fixture.wav'),
        ),
      ),
      throwsA(isA<LlamaUnsupportedException>()),
    );
  });

  test('dedicated LiteRT-LM speech is explicitly unsupported on Web', () async {
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

class _WebBackend implements LlamaBackend {
  @override
  bool get isReady => false;

  @override
  bool get supportsUrlLoading => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
