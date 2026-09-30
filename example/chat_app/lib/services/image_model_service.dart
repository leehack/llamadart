import 'package:dio/dio.dart';

import '../models/image_model_profile.dart';
import 'image_model_service_stub.dart'
    if (dart.library.io) 'image_model_service_io.dart';

/// Downloads and resolves the managed files of image-generation models.
abstract class ImageModelService {
  /// Creates the platform implementation.
  factory ImageModelService() => createImageModelService();

  /// Whether image models can be installed on this platform.
  bool get isSupported;

  /// Returns installed paths when every file passes its integrity check.
  Future<InstalledImageModel?> resolve(ImageModelProfile profile);

  /// Downloads, resuming partial files, and verifies every file.
  Future<InstalledImageModel> install(
    ImageModelProfile profile, {
    required CancelToken cancelToken,
    required void Function(double progress) onProgress,
    required void Function() onVerifying,
  });

  /// Removes every managed file of [profile].
  Future<void> delete(ImageModelProfile profile);
}
