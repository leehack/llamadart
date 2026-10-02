import '../exceptions.dart';
import 'download/model_download_manager_base.dart';
import 'model_load_options.dart';
import 'model_resolver.dart';
import 'model_source.dart';

/// Makes the [target] that a [ModelResolver] returned for [source] a local
/// file through [manager], for backends that load files rather than URLs.
///
/// A local target is checked by [manager]; a remote one is downloaded or
/// taken from its cache under [source]'s cache identity.
///
/// Throws [LlamaUnsupportedException] for a remote target that disallows the
/// browser/backend cache, naming [assetType] in the message.
Future<ModelCacheEntry> ensureModelTargetFile(
  ModelDownloadManager manager,
  ModelSource source,
  ModelLoadTarget target, {
  required ModelLoadOptions options,
  ModelDownloadProgressCallback? onProgress,
  String assetType = 'model',
}) async {
  switch (target) {
    case LocalModelFile(:final path):
      return manager.ensureModel(
        ModelSource.path(path),
        options: options,
        onProgress: onProgress,
      );
    case RemoteModelUrl(:final url, :final useBrowserCache):
      if (!useBrowserCache) {
        throw LlamaUnsupportedException(
          'Remote $assetType loading without browser/backend cache is not '
          'supported yet.',
        );
      }
      final downloadSource = source.isRemote
          ? source.withResolvedUri(url)
          : ModelSource.url(url, fileName: source.fileName);
      return manager.ensureModel(
        downloadSource,
        options: options,
        onProgress: onProgress,
      );
  }
}
