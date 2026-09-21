@TestOn('browser')
library;

import 'package:llamadart/src/core/speech/text_to_speech_platform_web.dart';
import 'package:test/test.dart';

void main() {
  test('web platform rejects speaker-reference file input', () {
    expect(textToSpeechSupportsFileInput, isFalse);
  });
}
