import '../../exceptions.dart';
import 'model_download_manager_base.dart';

/// Non-IO placeholder for the package-managed model download manager.
class DefaultModelDownloadManager extends ThrowingModelDownloadManager {
  /// Creates a non-IO placeholder download manager.
  const DefaultModelDownloadManager({String? defaultCacheDirectory});

  @override
  Object unsupported(String operation) => LlamaUnsupportedException(
    'Model download manager $operation is not supported on this platform.',
  );
}
