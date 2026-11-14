import 'package:llamadart/llamadart.dart';
import 'package:meta/meta.dart';

import '../domain/studio_model_descriptor.dart';

/// Immutable download progress state for a single [StudioModelDescriptor].
@immutable
class StudioModelDownloadProgress {
  /// Creates a [StudioModelDownloadProgress].
  const StudioModelDownloadProgress({
    required this.modelId,
    required this.stage,
    this.receivedBytes = 0,
    this.totalBytes = 0,
    this.fraction,
    this.statusLabel,
    this.errorMessage,
  });

  /// Target model identifier.
  final String modelId;

  /// Current download lifecycle stage.
  final ModelDownloadTaskStage stage;

  /// Received bytes across primary + companion files.
  final int receivedBytes;

  /// Expected total bytes when known.
  final int totalBytes;

  /// Progress fraction in `0.0 .. 1.0`, or `null` when indeterminate.
  final double? fraction;

  /// Human-readable step label (`Downloading mmproj...`, `Verifying SHA-256...`).
  final String? statusLabel;

  /// Actionable error message when [stage] is `failed`.
  final String? errorMessage;

  /// Whether this download task is actively running.
  bool get isActive =>
      stage == ModelDownloadTaskStage.resolving ||
      stage == ModelDownloadTaskStage.checkingCache ||
      stage == ModelDownloadTaskStage.downloading ||
      stage == ModelDownloadTaskStage.verifying;
}

/// Resolved local cache paths (or Web remote URLs) ready to load into an engine.
@immutable
class ResolvedModelAssets {
  /// Creates [ResolvedModelAssets].
  const ResolvedModelAssets({
    required this.descriptor,
    required this.primarySource,
    this.companionSources = const <String, ModelSource>{},
  });

  /// Original model descriptor.
  final StudioModelDescriptor descriptor;

  /// Resolved primary [ModelSource] (local path on native, URL on Web).
  final ModelSource primarySource;

  /// Resolved companion [ModelSource]s keyed by companion `role`
  /// (`projector`, `taesd`, `tokenizer`, `decisionHead`).
  final Map<String, ModelSource> companionSources;
}

/// Port managing package-cached model downloads, SHA-256 verification, cache
/// inspection, and disk pruning.
abstract interface class StudioModelStoragePort {
  /// Broadcast stream of download progress snapshots.
  Stream<StudioModelDownloadProgress> get progressStream;

  /// Standalone local models found during the most recent directory scan.
  List<StudioModelDescriptor> get discoveredLocalModels;

  /// Total unique bytes across all local model files found in the latest scan.
  int get discoveredLocalBytes;

  /// Scans configured local cache directories plus [extraDirectories] for
  /// existing `.gguf` and `.litertlm` weights.
  Future<List<StudioModelDescriptor>> refreshLocalModels({
    List<String> extraDirectories = const <String>[],
  });

  /// Lists all cached model entries currently stored on disk.
  Future<List<ModelCacheEntry>> listCachedEntries();

  /// Checks whether [descriptor] and all its companions are already cached.
  Future<bool> isCached(
    StudioModelDescriptor descriptor, {
    required bool isWeb,
  });

  /// Ensures [descriptor] and all companions are downloaded and verified.
  Future<ResolvedModelAssets> ensureDownloaded(
    StudioModelDescriptor descriptor, {
    required bool isWeb,
    String? bearerToken,
  });

  /// Cancels an active download for [modelId].
  void cancelDownload(String modelId);

  /// Deletes cached files associated with [descriptor].
  Future<void> removeCachedModel(
    StudioModelDescriptor descriptor, {
    required bool isWeb,
  });

  /// Removes a single [ModelCacheEntry] by cache key.
  Future<void> removeCacheEntry(String cacheKey);

  /// Prunes cached models exceeding [maxAge] or [maxBytes].
  Future<List<ModelCacheEntry>> pruneCache({Duration? maxAge, int? maxBytes});

  /// Releases internal controllers and streams.
  Future<void> dispose();
}
