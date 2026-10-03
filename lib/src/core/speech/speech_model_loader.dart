import '../../backends/backend.dart';
import '../engine/engine.dart';
import '../exceptions.dart';
import '../models/config/lora_config.dart';
import '../models/download/model_download_manager.dart';
import '../models/inference/model_params.dart';
import '../models/model_file_store.dart';
import '../models/model_load_options.dart';
import '../models/model_source.dart';
import '../models/model_target_file.dart';

/// Loads [source] and then [projector] into a new [LlamaEngine] that the
/// caller owns, then runs [verify] on it.
///
/// On a backend that loads files, both files resolve first through
/// [resolveModelSourceFiles], so a local file takes only [download]'s cancel
/// token and credentials never go to more than one host. A URL-loading
/// backend fetches each file itself, as `LlamaEngine.loadModelSource` does.
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
  final fileStore = store ?? ModelFileStore();
  final engine = LlamaEngine(
    backend ?? LlamaBackend(),
    modelResolver: fileStore.resolver,
    modelDownloadManager: fileStore.downloadManager,
  );
  try {
    if (engine.backend.supportsUrlLoading) {
      await _loadFromUrls(
        engine,
        source,
        projector,
        params,
        download,
        onProgress,
      );
    } else {
      final paths = await resolveModelSourceFiles(
        [source, ?projector],
        store: fileStore,
        download: download,
        operation: '$engineName model loading',
        onProgress: onProgress,
      );
      final localOptions = ModelLoadOptions(cancelToken: download.cancelToken);
      await engine.loadModelSource(
        ModelSource.path(paths[0], format: source.format),
        modelParams: _withLoraDownloads(params, download),
        options: localOptions,
      );
      if (projector != null) {
        await engine.loadMultimodalProjectorSource(
          ModelSource.path(paths[1]),
          options: localOptions,
        );
      }
    }
    if (download.cancelToken?.isCancelled ?? false) {
      throw LlamaStateException('$engineName model loading was cancelled.');
    }
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

Future<void> _loadFromUrls(
  LlamaEngine engine,
  ModelSource source,
  ModelSource? projector,
  ModelParams params,
  ModelLoadOptions download,
  ModelDownloadProgressCallback? onProgress,
) async {
  final fileCount = projector == null ? 1 : 2;
  ModelDownloadProgressCallback? fileProgress(int index) => onProgress == null
      ? null
      : (progress) => onProgress(
          ModelDownloadProgress.fraction(
            (index + (progress.fraction ?? 0)) / fileCount,
          ),
        );
  await engine.loadModelSource(
    source,
    modelParams: params,
    options: download,
    onProgress: fileProgress(0),
  );
  if (projector != null) {
    await engine.loadMultimodalProjectorSource(
      projector,
      options: download,
      onProgress: fileProgress(1),
    );
  }
}

/// [params] whose remote [ModelParams.loras] sources without their own
/// download options take the non-secret parts of [download], as they would
/// from `LlamaEngine.loadModelSource` with [download].
ModelParams _withLoraDownloads(ModelParams params, ModelLoadOptions download) {
  if (!params.loras.any(_inheritsDownload)) return params;
  final adapterDownload = ModelLoadOptions(
    cachePolicy: download.cachePolicy,
    cacheDirectory: download.cacheDirectory,
    cancelToken: download.cancelToken,
    resume: download.resume,
    maxRetries: download.maxRetries,
  );
  return params.copyWith(
    loras: [
      for (final lora in params.loras)
        _inheritsDownload(lora)
            ? LoraAdapterConfig.source(
                lora.source!,
                scale: lora.scale,
                download: adapterDownload,
              )
            : lora,
    ],
  );
}

bool _inheritsDownload(LoraAdapterConfig lora) =>
    lora.download == null && (lora.source?.isRemote ?? false);
