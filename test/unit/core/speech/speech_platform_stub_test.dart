@TestOn('vm')
library;

import 'package:llamadart/src/core/speech/speech_platform_stub.dart';
import 'package:test/test.dart';

void main() {
  test('native platform enables dedicated speech-to-text', () {
    expect(isSpeechToTextPlatformSupported, isTrue);
    expect(speechToTextPlatformUnsupportedReason, isNull);
  });
}
