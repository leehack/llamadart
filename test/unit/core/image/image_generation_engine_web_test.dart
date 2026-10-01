@TestOn('browser')
library;

import 'package:test/test.dart';

import 'package:llamadart/llamadart.dart';

void main() {
  test('the web reports image generation unsupported', () {
    final capabilities = ImageGenerationEngine.runtimeCapabilities();

    expect(capabilities.isSupported, isFalse);
    expect(capabilities.unsupportedReason, contains('web'));
  });

  test('checkRuntime reports the same reason on the web', () async {
    final capabilities = await ImageGenerationEngine.checkRuntime();

    expect(capabilities.isSupported, isFalse);
    expect(
      capabilities.unsupportedReason,
      ImageGenerationEngine.runtimeCapabilities().unsupportedReason,
    );
  });

  test('load throws LlamaUnsupportedException on the web', () async {
    await expectLater(
      ImageGenerationEngine.load(ImageGenerationModel.sdxs('sdxs.gguf')),
      throwsA(
        isA<LlamaUnsupportedException>().having(
          (error) => error.message,
          'message',
          contains('not available on the web'),
        ),
      ),
    );
  });
}
