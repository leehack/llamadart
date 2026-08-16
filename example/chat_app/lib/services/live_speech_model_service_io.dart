import 'dart:io';

import 'package:dio/dio.dart';

import '../models/downloadable_model.dart';
import '../models/live_speech_model.dart';
import 'live_speech_model_service.dart';
import 'model_service_io.dart';

class _IoLiveSpeechModelService implements LiveSpeechModelService {
  final ModelServiceIO _modelService;

  _IoLiveSpeechModelService({ModelServiceIO? modelService})
    : _modelService = modelService ?? ModelServiceIO();

  @override
  bool get isSupported =>
      Platform.isAndroid ||
      Platform.isIOS ||
      Platform.isMacOS ||
      Platform.isLinux ||
      Platform.isWindows;

  @override
  Future<InstalledLiveSpeechModel?> resolve(LiveSpeechModel model) async {
    if (!isSupported) {
      return null;
    }
    final modelsDir = await _modelService.getModelsDirectory();
    final modelReady = await _modelService.isManagedAssetAvailable(
      modelsDir,
      model.modelSource,
      role: ModelAssetRole.model,
    );
    final tokenizerReady = await _modelService.isManagedAssetAvailable(
      modelsDir,
      model.tokenizerSource,
      role: ModelAssetRole.tokenizer,
    );
    if (!modelReady || !tokenizerReady) {
      return null;
    }
    return _installed(model, modelsDir);
  }

  @override
  Future<InstalledLiveSpeechModel> install(
    LiveSpeechModel model, {
    required CancelToken cancelToken,
    required void Function(double progress) onProgress,
    required void Function() onVerifying,
  }) async {
    if (!isSupported) {
      throw UnsupportedError('Live speech transcription is native-only.');
    }
    final modelsDir = await _modelService.getModelsDirectory();
    final modelBytes = model.modelSource.sizeBytes ?? 0;
    final tokenizerBytes = model.tokenizerSource.sizeBytes ?? 0;
    final totalBytes = modelBytes + tokenizerBytes;
    var downloadedModelBytes = 0;
    var downloadedTokenizerBytes = 0;

    void reportProgress() {
      if (totalBytes <= 0) {
        onProgress(0);
        return;
      }
      onProgress(
        ((downloadedModelBytes + downloadedTokenizerBytes) / totalBytes).clamp(
          0.0,
          1.0,
        ),
      );
    }

    await _modelService.downloadManagedAsset(
      modelsDir: modelsDir,
      source: model.modelSource,
      role: ModelAssetRole.model,
      cancelToken: cancelToken,
      onProgress: (downloadedBytes, _, _) {
        downloadedModelBytes = downloadedBytes.clamp(0, modelBytes);
        reportProgress();
      },
      onVerifying: onVerifying,
    );
    downloadedModelBytes = modelBytes;
    reportProgress();

    await _modelService.downloadManagedAsset(
      modelsDir: modelsDir,
      source: model.tokenizerSource,
      role: ModelAssetRole.tokenizer,
      cancelToken: cancelToken,
      onProgress: (downloadedBytes, _, _) {
        downloadedTokenizerBytes = downloadedBytes.clamp(0, tokenizerBytes);
        reportProgress();
      },
      onVerifying: onVerifying,
    );
    downloadedTokenizerBytes = tokenizerBytes;
    onProgress(1);

    final installed = await resolve(model);
    if (installed == null) {
      throw StateError(
        'Live speech model download completed, but integrity validation failed.',
      );
    }
    return installed;
  }

  @override
  Future<void> delete(LiveSpeechModel model) async {
    final modelsDir = await _modelService.getModelsDirectory();
    await _modelService.deleteManagedAsset(modelsDir, model.modelSource);
    await _modelService.deleteManagedAsset(modelsDir, model.tokenizerSource);
  }

  InstalledLiveSpeechModel _installed(
    LiveSpeechModel model,
    String modelsDir,
  ) => InstalledLiveSpeechModel(
    model: model,
    modelPath: _modelService.resolveManagedAssetPath(
      modelsDir,
      model.modelSource,
    ),
    tokenizerPath: _modelService.resolveManagedAssetPath(
      modelsDir,
      model.tokenizerSource,
    ),
  );
}

/// Creates the native live-speech model service.
LiveSpeechModelService createLiveSpeechModelService() =>
    _IoLiveSpeechModelService();
