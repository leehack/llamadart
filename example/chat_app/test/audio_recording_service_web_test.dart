@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_chat_example/services/audio_recording_service.dart';

void main() {
  test('browser recorder is exposed from a secure test origin', () async {
    final recorder = AudioRecordingService();
    addTearDown(recorder.dispose);

    expect(recorder.isSupported, isTrue);
  });
}
