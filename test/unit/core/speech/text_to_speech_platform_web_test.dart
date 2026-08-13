@TestOn('browser')
library;

import 'package:llamadart/src/core/speech/text_to_speech_platform_web.dart';
import 'package:test/test.dart';

void main() {
  test('web platform reports typed text-to-speech as unsupported', () {
    expect(isTextToSpeechPlatformSupported, isFalse);
    expect(textToSpeechPlatformUnsupportedReason, contains('not available'));
    expect(textToSpeechPlatformUnsupportedReason, contains('audio-generation'));
  });
}
