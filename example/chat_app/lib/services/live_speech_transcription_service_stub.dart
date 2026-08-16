import 'package:llamadart/llamadart.dart';

import 'live_speech_transcription_service.dart';

class _UnsupportedLiveSpeechTranscriptionService
    implements LiveSpeechTranscriptionService {
  @override
  bool get isSupported => false;

  @override
  Future<LiveSpeechTranscriptionTask> start({
    required String modelPath,
    required String tokenizerPath,
    required LiteRtLmAsrModelPreset preset,
  }) {
    throw UnsupportedError('Live speech transcription is native-only.');
  }

  @override
  Future<void> dispose() async {}
}

/// Creates the unsupported non-IO implementation.
LiveSpeechTranscriptionService createLiveSpeechTranscriptionService() =>
    _UnsupportedLiveSpeechTranscriptionService();
