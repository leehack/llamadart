import '../../backends/backend.dart';
import '../engine/engine.dart';
import '../exceptions.dart';
import '../models/download/model_download_manager.dart';
import '../models/inference/model_params.dart';
import '../models/model_file_store.dart';
import '../models/model_load_options.dart';
import '../models/model_resolver.dart';
import '../models/model_source.dart';
import '../models/model_target_file.dart';

/// Loads [source] and then [projector] into a new [LlamaEngine] that the
/// caller owns, then runs [verify] on it.
///
/// The load is atomic: when a file, [verify] or [download]'s cancel token
/// fails it, the engine is disposed and the error rethrown.
Future<LlamaEngine> loadSpeechLlamaEngine({
  required String engineName,
  required ModelSource source,
  required ModelSource? projector,
  required ModelParams params,
  required ModelLoadOptions download,
  required ModelDownloadProgressCallback? onProgress,
  required ModelFileStore? store,
  required LlamaBackend? backend,
  required Future<void> Function(LlamaEngine engine) verify,
}) async {
  rejectMultiFileSha256(
    engineName,
    download,
    fileCount: projector == null ? 1 : 2,
  );
  final engine = LlamaEngine(
    backend ?? LlamaBackend(),
    modelResolver: store?.resolver,
    modelDownloadManager: store?.downloadManager,
  );
  final progress = SpeechFilesProgress(
    onProgress,
    fileCount: projector == null ? 1 : 2,
  );
  try {
    await engine.loadModelSource(
      source,
      modelParams: params,
      options: download,
      onProgress: progress.file(0),
    );
    if (projector != null) {
      await engine.loadMultimodalProjectorSource(
        projector,
        options: download,
        onProgress: progress.file(1),
      );
    }
    throwIfSpeechLoadCancelled(engineName, download);
    await verify(engine);
    return engine;
  } catch (_) {
    try {
      await engine.dispose();
    } catch (_) {
      // The load failure is the error the caller needs.
    }
    rethrow;
  }
}

/// Local paths of [sources], in order, resolved one at a time through
/// [store]. Local files take only [download]'s cancel token.
Future<List<String>> resolveSpeechModelFiles({
  required String engineName,
  required List<ModelSource> sources,
  required ModelLoadOptions download,
  required ModelDownloadProgressCallback? onProgress,
  required ModelFileStore store,
  required String assetType,
}) async {
  rejectMultiFileSha256(engineName, download, fileCount: sources.length);
  final progress = SpeechFilesProgress(onProgress, fileCount: sources.length);
  final localOptions = ModelLoadOptions(cancelToken: download.cancelToken);
  final paths = <String>[];
  for (final (index, source) in sources.indexed) {
    final options = source.isLocal ? localOptions : download;
    final fileProgress = progress.file(index);
    final target = await store.resolver.resolve(
      source,
      ModelResolveRequest(options: options, onProgress: fileProgress),
    );
    final entry = await ensureModelTargetFile(
      store.downloadManager,
      source,
      target,
      options: options,
      onProgress: fileProgress,
      assetType: assetType,
    );
    throwIfSpeechLoadCancelled(engineName, download);
    paths.add(entry.filePath);
  }
  return paths;
}

/// Throws [LlamaUnsupportedException] when [download] sets a checksum for a
/// load of more than one file.
void rejectMultiFileSha256(
  String engineName,
  ModelLoadOptions download, {
  required int fileCount,
}) {
  if (fileCount > 1 && download.sha256 != null) {
    throw LlamaUnsupportedException(
      '$engineName.load loads $fileCount files, so ModelLoadOptions.sha256 '
      'cannot apply to them. Leave it unset.',
    );
  }
}

/// Throws [LlamaStateException] when [download]'s cancel token is cancelled.
void throwIfSpeechLoadCancelled(String engineName, ModelLoadOptions download) {
  if (download.cancelToken?.isCancelled ?? false) {
    throw LlamaStateException('$engineName model loading was cancelled.');
  }
}

/// Combines the progress of files loaded one after another into one
/// callback.
///
/// Byte progress counts the bytes of earlier files plus the current one;
/// the total is known once the last file reports its size and every earlier
/// file reported its own. A file that reports only a fraction, as a web
/// backend does, makes the combined progress a fraction of all files.
class SpeechFilesProgress {
  final ModelDownloadProgressCallback? _onProgress;
  final int _fileCount;
  final Map<int, int> _sizes = <int, int>{};

  /// Creates a combiner reporting to [onProgress] for [fileCount] files.
  SpeechFilesProgress(
    ModelDownloadProgressCallback? onProgress, {
    required int fileCount,
  }) : _onProgress = onProgress,
       _fileCount = fileCount;

  /// The callback for the file at [index], or null without a callback.
  ModelDownloadProgressCallback? file(int index) {
    final onProgress = _onProgress;
    if (onProgress == null) {
      return null;
    }
    if (_fileCount == 1) {
      return onProgress;
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
      _sizes[index] = progress.totalBytes ?? progress.receivedBytes;
      var earlierBytes = 0;
      var earlierKnown = true;
      for (var earlier = 0; earlier < index; earlier++) {
        final size = _sizes[earlier];
        if (size == null) {
          earlierKnown = false;
        } else {
          earlierBytes += size;
        }
      }
      final total = progress.totalBytes;
      onProgress(
        ModelDownloadProgress(
          receivedBytes: earlierBytes + progress.receivedBytes,
          totalBytes: index == _fileCount - 1 && earlierKnown && total != null
              ? earlierBytes + total
              : null,
        ),
      );
    };
  }
}
