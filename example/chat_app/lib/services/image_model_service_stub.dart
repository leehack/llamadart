import 'package:dio/dio.dart';

import '../models/image_model_profile.dart';
import 'image_model_service.dart';

class _UnsupportedImageModelService implements ImageModelService {
  @override
  bool get isSupported => false;

  @override
  Future<InstalledImageModel?> resolve(ImageModelProfile profile) async => null;

  @override
  Future<InstalledImageModel> install(
    ImageModelProfile profile, {
    required CancelToken cancelToken,
    required void Function(double progress) onProgress,
    required void Function() onVerifying,
  }) {
    throw UnsupportedError('Image model installation is native-only.');
  }

  @override
  Future<void> delete(ImageModelProfile profile) async {}
}

/// Creates the unsupported non-IO implementation.
ImageModelService createImageModelService() => _UnsupportedImageModelService();
