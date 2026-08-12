@TestOn('browser')
library;

import 'package:llamadart/src/core/speech/speech_platform_web.dart';
import 'package:test/test.dart';

void main() {
  test('web platform reports dedicated speech-to-text as unsupported', () {
    expect(isSpeechToTextPlatformSupported, isFalse);
    expect(speechToTextPlatformUnsupportedReason, contains('not available'));
  });
}
