@TestOn('vm')
library;

import 'package:llamadart/src/core/speech/text_to_speech_platform_stub.dart';
import 'package:test/test.dart';

void main() {
  test('native platform accepts speaker-reference file input', () {
    expect(textToSpeechSupportsFileInput, isTrue);
  });
}
