import 'package:dio/dio.dart';

import '../models/live_speech_model.dart';
import 'live_speech_model_service.dart';

class _UnsupportedLiveSpeechModelService implements LiveSpeechModelService {
  @override
  bool get isSupported => false;

  @override
  Future<InstalledLiveSpeechModel?> resolve(LiveSpeechModel model) async =>
      null;

  @override
  Future<InstalledLiveSpeechModel> install(
    LiveSpeechModel model, {
    required CancelToken cancelToken,
    required void Function(double progress) onProgress,
    required void Function() onVerifying,
  }) {
    throw UnsupportedError('Live speech model installation is native-only.');
  }

  @override
  Future<void> delete(LiveSpeechModel model) async {}
}

/// Creates the unsupported non-IO implementation.
LiveSpeechModelService createLiveSpeechModelService() =>
    _UnsupportedLiveSpeechModelService();
