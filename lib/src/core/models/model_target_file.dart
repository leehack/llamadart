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
/// [store]'s resolver and download manager, for a load of several files
/// named [operation] (such as `Image model loading`).
///
/// [download] applies to every remote file, its bearer token and headers
/// included, so callers must document that every file's host receives them.
/// A local file takes only its cancel token, since [ModelLoadOptions]
/// rejects download options for local files.
///
/// [onProgress] reports the files together. Byte progress counts every file
/// resolved so far plus the bytes of the current one; `totalBytes` is their
/// combined size once every size is known, from [knownSizes] (by index), a
/// download or a resolved file, and null before. A file that reports only a
/// fraction, as a URL-loading backend does, makes the combined progress a
/// fraction of all the files.
///
/// Throws [LlamaUnsupportedException] before resolving anything when
/// [download] sets [ModelLoadOptions.sha256] for more than one file, and
/// [LlamaStateException] when [download]'s cancel token is cancelled after a
/// file resolves.
Future<List<String>> resolveModelSourceFiles(
  List<ModelSource> sources, {
  required ModelFileStore store,
  required ModelLoadOptions download,
  required String operation,
  ModelDownloadProgressCallback? onProgress,
  Map<int, int> knownSizes = const <int, int>{},
  String assetType = 'model',
}) async {
  if (sources.length > 1 && download.sha256 != null) {
    throw LlamaUnsupportedException(
      '$operation uses ${sources.length} files, so ModelLoadOptions.sha256 '
      'cannot apply to them. Leave it unset.',
    );
  }
  final progress = _FilesProgress(onProgress, sources.length, knownSizes);
  final localOptions = ModelLoadOptions(cancelToken: download.cancelToken);
  final files = <String>[];
  for (final (index, source) in sources.indexed) {
    final fileOptions = source.isLocal ? localOptions : download;
    final fileProgress = progress.file(index);
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
    if (download.cancelToken?.isCancelled ?? false) {
      throw LlamaStateException('$operation was cancelled.');
    }
    progress.resolved(index, entry.bytes);
    files.add(entry.filePath);
  }
  return files;
}

/// Combines the progress of files resolved one after another into one
/// callback; see [resolveModelSourceFiles].
class _FilesProgress {
  final ModelDownloadProgressCallback? _onProgress;
  final int _fileCount;
  final Map<int, int> _sizes;

  _FilesProgress(this._onProgress, this._fileCount, Map<int, int> knownSizes)
    : _sizes = Map<int, int>.of(knownSizes);

  ModelDownloadProgressCallback? file(int index) {
    final onProgress = _onProgress;
    if (onProgress == null) {
      return null;
    }
    return (ModelDownloadProgress progress) {
      final fraction = progress.fraction;
      if (progress.receivedBytes == 0 &&
          progress.totalBytes == null &&
          fraction != null) {
        onProgress(
          ModelDownloadProgress.fraction((index + fraction) / _fileCount),
        );
        return;
      }
      if (progress.totalBytes case final total?) {
        _sizes[index] = total;
      }
      _report(index, progress.receivedBytes);
    };
  }

  void resolved(int index, int? bytes) {
    if (_onProgress == null) {
      return;
    }
    if (bytes != null) {
      _sizes[index] = bytes;
    }
    _report(index, _sizes[index] ?? 0);
  }

  void _report(int index, int currentBytes) {
    var earlierBytes = 0;
    for (var earlier = 0; earlier < index; earlier++) {
      earlierBytes += _sizes[earlier] ?? 0;
    }
    final total = _sizes.length == _fileCount
        ? _sizes.values.fold<int>(0, (sum, size) => sum + size)
        : null;
    _onProgress!(
      ModelDownloadProgress(
        receivedBytes: earlierBytes + currentBytes,
        totalBytes: total,
      ),
    );
  }
}
