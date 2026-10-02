import '../exceptions.dart';
import 'download/model_download_manager_base.dart';
import 'model_file_store.dart';
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
        ModelSource.path(path, format: source.format),
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
          : ModelSource.url(
              url,
              fileName: source.fileName,
              format: source.format,
            );
      return manager.ensureModel(
        downloadSource,
        options: options,
        onProgress: onProgress,
      );
  }
}

/// Local paths of [sources], in order, resolved one at a time through
/// [store]'s resolver and download manager.
///
/// A remote source downloads with [download]; a local one takes only its
/// cancel token, since [ModelLoadOptions] rejects download options for local
/// files. [onProgress] reports the files together: `receivedBytes` counts
/// every file resolved so far plus the bytes of the current download, and
/// `totalBytes` is their combined size once every size is known, from
/// [knownSizes] (by index) or each download, and null before.
Future<List<String>> resolveModelSourceFiles(
  List<ModelSource> sources, {
  required ModelFileStore store,
  required ModelLoadOptions download,
  ModelDownloadProgressCallback? onProgress,
  Map<int, int> knownSizes = const <int, int>{},
  String assetType = 'model',
}) async {
  final sizes = Map<int, int>.of(knownSizes);
  var resolvedBytes = 0;
  void report(int currentBytes) {
    if (onProgress == null) {
      return;
    }
    final total = sizes.length == sources.length
        ? sizes.values.fold<int>(0, (sum, size) => sum + size)
        : null;
    onProgress(
      ModelDownloadProgress(
        receivedBytes: resolvedBytes + currentBytes,
        totalBytes: total,
      ),
    );
  }

  final localOptions = ModelLoadOptions(cancelToken: download.cancelToken);
  final files = <String>[];
  for (final (index, source) in sources.indexed) {
    final fileOptions = source.isLocal ? localOptions : download;
    final fileProgress = onProgress == null
        ? null
        : (ModelDownloadProgress progress) {
            if (progress.totalBytes case final total?) {
              sizes.putIfAbsent(index, () => total);
            }
            report(progress.receivedBytes);
          };
    final target = await store.resolver.resolve(
      source,
      ModelResolveRequest(options: fileOptions, onProgress: fileProgress),
    );
    final entry = await ensureModelTargetFile(
      store.downloadManager,
      source,
      target,
      options: fileOptions,
      onProgress: fileProgress,
      assetType: assetType,
    );
    files.add(entry.filePath);
    final bytes = entry.bytes ?? sizes[index];
    if (bytes != null) {
      sizes[index] = bytes;
    }
    resolvedBytes += bytes ?? 0;
    report(0);
  }
  return files;
}
