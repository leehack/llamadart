import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_chat_example/services/audio_recording_service.dart';

void main() {
  test(
    'default recorder exposes only the safe native platform matrix',
    () async {
      final recorder = AudioRecordingService();
      addTearDown(recorder.dispose);

      final expected =
          Platform.isAndroid ||
          Platform.isIOS ||
          Platform.isMacOS ||
          Platform.isWindows;
      expect(recorder.isSupported, expected);
    },
  );
}
