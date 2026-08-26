@TestOn('vm')
library;

import 'package:llamadart/src/core/speech/speech_platform_stub.dart';
import 'package:test/test.dart';

void main() {
  test('native platform accepts file input and unencoded audio', () {
    expect(speechToTextRequiresBackendCapability, isFalse);
    expect(speechToTextUsesChatTemplate, isTrue);
    expect(speechToTextSupportsFileInput, isTrue);
    expect(speechToTextRequiresEncodedAudioFormat, isFalse);
    expect(
      speechToTextEncodedAudioFormats,
      equals(<String>{'wav', 'mp3', 'flac'}),
    );
  });
}
