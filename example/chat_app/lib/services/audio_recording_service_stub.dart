import 'audio_recording_service.dart';

class _UnsupportedAudioRecordingService implements AudioRecordingService {
  @override
  bool get isSupported => false;

  @override
  Future<void> start() async {
    throw const AudioRecordingException(
      AudioRecordingFailure.unsupported,
      'Microphone recording is unavailable on this platform.',
    );
  }

  @override
  Future<String> stop() async {
    throw const AudioRecordingException(
      AudioRecordingFailure.unsupported,
      'Microphone recording is unavailable on this platform.',
    );
  }

  @override
  Future<void> cancel() async {}

  @override
  Future<void> deleteRecording(String path) async {}

  @override
  Future<void> dispose() async {}
}

/// Creates the unsupported-platform recorder implementation.
AudioRecordingService createAudioRecordingService() =>
    _UnsupportedAudioRecordingService();
