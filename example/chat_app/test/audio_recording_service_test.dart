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

  test('reads a finalized recording as encoded bytes', () async {
    final recorder = AudioRecordingService();
    addTearDown(recorder.dispose);
    final directory = await Directory.systemTemp.createTemp(
      'llamadart_recording_read_test_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/recording.wav');
    const expected = <int>[0x52, 0x49, 0x46, 0x46];
    await file.writeAsBytes(expected);

    expect(await recorder.readRecording(file.path), expected);
  });

  test('reports an actionable finalized-recording read failure', () async {
    final recorder = AudioRecordingService();
    addTearDown(recorder.dispose);

    await expectLater(
      recorder.readRecording('/path/that/does/not/exist/recording.wav'),
      throwsA(
        isA<AudioRecordingException>()
            .having(
              (error) => error.failure,
              'failure',
              AudioRecordingFailure.readFailed,
            )
            .having(
              (error) => error.message,
              'message',
              'The microphone recording could not be read.',
            ),
      ),
    );
  });
}
