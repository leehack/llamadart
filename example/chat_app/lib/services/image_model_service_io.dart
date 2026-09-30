import 'package:dio/dio.dart';

import '../models/downloadable_model.dart';
import '../models/image_model_profile.dart';
import 'image_model_service.dart';
import 'model_service_io.dart';

class _IoImageModelService implements ImageModelService {
  final ModelServiceIO _modelService;

  _IoImageModelService({ModelServiceIO? modelService})
    : _modelService = modelService ?? ModelServiceIO();

  @override
  bool get isSupported => true;

  @override
  Future<InstalledImageModel?> resolve(ImageModelProfile profile) async {
    final modelsDir = await _modelService.getModelsDirectory();
    for (final source in profile.sources) {
      final ready = await _modelService.isManagedAssetAvailable(
        modelsDir,
        source,
        role: ModelAssetRole.model,
      );
      if (!ready) {
        return null;
      }
    }
    return _installed(profile, modelsDir);
  }

  @override
  Future<InstalledImageModel> install(
    ImageModelProfile profile, {
    required CancelToken cancelToken,
    required void Function(double progress) onProgress,
    required void Function() onVerifying,
  }) async {
    final modelsDir = await _modelService.getModelsDirectory();
    final totalBytes = profile.sizeBytes;
    var completedBytes = 0;
    for (final source in profile.sources) {
      final sourceBytes = source.sizeBytes ?? 0;
      await _modelService.downloadManagedAsset(
        modelsDir: modelsDir,
        source: source,
        role: ModelAssetRole.model,
        cancelToken: cancelToken,
        onProgress: (downloadedBytes, _, _) {
          if (totalBytes > 0) {
            final current =
                completedBytes + downloadedBytes.clamp(0, sourceBytes);
            onProgress((current / totalBytes).clamp(0.0, 1.0));
          }
        },
        onVerifying: onVerifying,
      );
      completedBytes += sourceBytes;
    }
    onProgress(1);

    final installed = await resolve(profile);
    if (installed == null) {
      throw StateError(
        'Image model download completed, but integrity validation failed.',
      );
    }
    return installed;
  }

  @override
  Future<void> delete(ImageModelProfile profile) async {
    final modelsDir = await _modelService.getModelsDirectory();
    for (final source in profile.sources) {
      await _modelService.deleteManagedAsset(modelsDir, source);
    }
  }

  InstalledImageModel _installed(ImageModelProfile profile, String modelsDir) =>
      InstalledImageModel(
        profile: profile,
        modelPath: _modelService.resolveManagedAssetPath(
          modelsDir,
          profile.modelSource,
        ),
        taesdPath: profile.taesdSource == null
            ? null
            : _modelService.resolveManagedAssetPath(
                modelsDir,
                profile.taesdSource!,
              ),
      );
}

/// Creates the native image model service.
ImageModelService createImageModelService() => _IoImageModelService();
