import 'package:dio/dio.dart';

import '../models/live_speech_model.dart';
import 'live_speech_model_service_stub.dart'
    if (dart.library.io) 'live_speech_model_service_io.dart';

/// Downloads and resolves managed sidecar models used for live dictation.
abstract class LiveSpeechModelService {
  /// Creates the platform implementation.
  factory LiveSpeechModelService() => createLiveSpeechModelService();

  /// Whether native live-speech model installation is supported.
  bool get isSupported;

  /// Returns installed paths when both model assets pass integrity checks.
  Future<InstalledLiveSpeechModel?> resolve(LiveSpeechModel model);

  /// Downloads and verifies both model assets.
  Future<InstalledLiveSpeechModel> install(
    LiveSpeechModel model, {
    required CancelToken cancelToken,
    required void Function(double progress) onProgress,
    required void Function() onVerifying,
  });

  /// Removes both managed model assets.
  Future<void> delete(LiveSpeechModel model);
}
