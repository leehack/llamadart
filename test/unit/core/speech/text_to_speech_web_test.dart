@TestOn('browser')
library;

import 'package:llamadart/llamadart.dart';
import 'package:test/test.dart';

void main() {
  test('typed text-to-speech is explicitly unsupported on Web', () async {
    final speechEngine = TextToSpeechEngine(
      LlamaEngine(_WebBackend()),
      modelProfile: TextToSpeechModelProfile.qwen3Tts,
    );

    final capabilities = await speechEngine.capabilities;

    expect(capabilities.isSupported, isFalse);
    expect(capabilities.unsupportedReason, contains('not available on Web'));
    await expectLater(
      speechEngine.synthesize(const TextToSpeechRequest(text: 'Hello.')),
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
  void cancelGeneration() {}

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
