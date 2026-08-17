@TestOn('browser')
library;

import 'package:llamadart/src/core/speech/speech_platform_web.dart';
import 'package:test/test.dart';

void main() {
  test('web platform exposes byte-only WAV prompt speech support', () {
    expect(isSpeechToTextPlatformSupported, isTrue);
    expect(speechToTextPlatformUnsupportedReason, isNull);
    expect(speechToTextRequiresBackendCapability, isTrue);
    expect(speechToTextSupportsFileInput, isFalse);
    expect(speechToTextRequiresEncodedAudioFormat, isTrue);
    expect(speechToTextEncodedAudioFormats, equals(<String>{'wav'}));
  });
}
