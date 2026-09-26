@TestOn('browser')
library;

import 'package:llamadart/src/core/speech/speech_platform_web.dart';
import 'package:test/test.dart';

void main() {
  test('web platform exposes byte-only WAV, MP3 and FLAC prompt speech', () {
    expect(speechToTextRequiresBackendCapability, isTrue);
    expect(speechToTextUsesChatTemplate, isFalse);
    expect(speechToTextSupportsFileInput, isFalse);
    expect(speechToTextRequiresEncodedAudioFormat, isTrue);
    expect(
      speechToTextEncodedAudioFormats,
      equals(<String>{'wav', 'mp3', 'flac'}),
    );
  });
}
