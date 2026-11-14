import 'dart:async';

import 'package:llamadart/llamadart.dart';

import '../../domain/studio_model_descriptor.dart';
import '../../ports/model_storage_port.dart';
import '../../services/discovery/local_model_scanner.dart';

/// Default [StudioModelStoragePort] backed by `llamadart`'s
/// [DefaultModelDownloadManager], [LocalModelScanner], and cooperative
/// [ModelDownloadCancelToken]s.
class DefaultStudioModelStorageAdapter implements StudioModelStoragePort {
  /// Creates a [DefaultStudioModelStorageAdapter].
  DefaultStudioModelStorageAdapter({
    ModelDownloadManager? downloadManager,
    LocalModelScanner? localScanner,
  }) : _manager = downloadManager ?? DefaultModelDownloadManager.auto(),
       _scanner = localScanner ?? LocalModelScanner();

  final ModelDownloadManager _manager;
  final LocalModelScanner _scanner;
  final Map<String, ModelDownloadCancelToken> _activeTokens =
      <String, ModelDownloadCancelToken>{};
  final StreamController<StudioModelDownloadProgress> _progressController =
      StreamController<StudioModelDownloadProgress>.broadcast();

  LocalModelScanResult _latestScan = const LocalModelScanResult();

  /// Underlying `llamadart` [ModelDownloadManager].
  ModelDownloadManager get downloadManager => _manager;

  /// Underlying [LocalModelScanner].
  LocalModelScanner get localScanner => _scanner;

  @override
  Stream<StudioModelDownloadProgress> get progressStream =>
      _progressController.stream;

  @override
  List<StudioModelDescriptor> get discoveredLocalModels =>
      _latestScan.standaloneModels;

  @override
  int get discoveredLocalBytes => _latestScan.totalUniqueBytes;

  @override
  Future<List<StudioModelDescriptor>> refreshLocalModels({
    List<String> extraDirectories = const <String>[],
  }) async {
    _latestScan = await _scanner.scan(extraDirectories: extraDirectories);
    return _latestScan.standaloneModels;
  }

  @override
  Future<List<ModelCacheEntry>> listCachedEntries() async {
    try {
      return await _manager.list();
    } on LlamaUnsupportedException {
      return const <ModelCacheEntry>[];
    }
  }

  @override
  Future<bool> isCached(
    StudioModelDescriptor descriptor, {
    required bool isWeb,
  }) async {
    if (isWeb) {
      return false;
    }
    final primary = descriptor.primarySource(isWeb: false);
    if (_latestScan.curatedAssetsById.containsKey(descriptor.id)) {
      return true;
    }
    try {
      if (primary.isRemote) {
        final primaryEntry = await _manager.get(primary.cacheKey);
        if (primaryEntry == null) {
          return false;
        }
      }
      for (final companion in descriptor.companions) {
        final compSource = companion.toModelSource(isWeb: false);
        if (compSource.isRemote) {
          final compEntry = await _manager.get(compSource.cacheKey);
          if (compEntry == null) {
            return false;
          }
        }
      }
      return true;
    } on LlamaUnsupportedException {
      return false;
    }
  }

  @override
  Future<ResolvedModelAssets> ensureDownloaded(
    StudioModelDescriptor descriptor, {
    required bool isWeb,
    String? bearerToken,
  }) async {
    final primary = descriptor.primarySource(isWeb: isWeb);
    if (isWeb) {
      // On WebGPU, engines stream remote URLs directly via browser Fetch/Cache.
      final webCompanions = <String, ModelSource>{
        for (final companion in descriptor.companions)
          companion.role: companion.toModelSource(isWeb: true),
      };
      _emit(
        StudioModelDownloadProgress(
          modelId: descriptor.id,
          stage: ModelDownloadTaskStage.ready,
          fraction: 1.0,
          statusLabel: 'Ready via WebGPU URL loader',
        ),
      );
      return ResolvedModelAssets(
        descriptor: descriptor,
        primarySource: primary,
        companionSources: webCompanions,
      );
    }

    // Pure local assets need no download task. Mixed sources share the same
    // progress and cancellation path as fully remote models below.
    if (primary.isLocal &&
        descriptor.companions.every(
          (StudioModelCompanionAsset asset) =>
              asset.toModelSource(isWeb: false).isLocal,
        )) {
      final localCompanions = <String, ModelSource>{
        for (final companion in descriptor.companions)
          companion.role: companion.toModelSource(isWeb: false),
      };
      _emit(
        StudioModelDownloadProgress(
          modelId: descriptor.id,
          stage: ModelDownloadTaskStage.ready,
          fraction: 1.0,
          statusLabel: 'Loaded from local path',
        ),
      );
      return ResolvedModelAssets(
        descriptor: descriptor,
        primarySource: primary,
        companionSources: localCompanions,
      );
    }

    // Zero-copy fast path 2: Curated model already matched on local disk.
    final scannedCurated = _latestScan.curatedAssetsById[descriptor.id];
    if (scannedCurated != null) {
      _emit(
        StudioModelDownloadProgress(
          modelId: descriptor.id,
          stage: ModelDownloadTaskStage.ready,
          fraction: 1.0,
          statusLabel: 'Cached locally',
        ),
      );
      return scannedCurated;
    }

    _activeTokens[descriptor.id]?.cancel();
    final cancelToken = ModelDownloadCancelToken();
    _activeTokens[descriptor.id] = cancelToken;

    final totalExpected = descriptor.effectiveSizeBytes(isWeb: false);
    var completedBytes = 0;

    try {
      _emit(
        StudioModelDownloadProgress(
          modelId: descriptor.id,
          stage: ModelDownloadTaskStage.checkingCache,
          totalBytes: totalExpected,
          statusLabel: 'Checking cache for ${descriptor.filename}...',
        ),
      );

      final primaryEntry = await _manager.ensureModel(
        primary,
        options: ModelLoadOptions(
          sha256: descriptor.sha256,
          bearerToken: bearerToken,
          cancelToken: cancelToken,
        ),
        onProgress: (ModelDownloadProgress p) {
          final received = completedBytes + p.receivedBytes;
          final total = totalExpected > 0 ? totalExpected : (p.totalBytes ?? 0);
          _emit(
            StudioModelDownloadProgress(
              modelId: descriptor.id,
              stage: ModelDownloadTaskStage.downloading,
              receivedBytes: received,
              totalBytes: total,
              fraction: total > 0
                  ? (received / total).clamp(0.0, 1.0)
                  : p.fraction,
              statusLabel: 'Downloading ${descriptor.filename}...',
            ),
          );
        },
      );
      completedBytes += primaryEntry.bytes ?? 0;

      final resolvedCompanions = <String, ModelSource>{};
      for (final companion in descriptor.companions) {
        if (cancelToken.isCancelled) {
          throw LlamaStateException('Model download cancelled.');
        }
        final compSource = companion.toModelSource(isWeb: false);
        final compEntry = await _manager.ensureModel(
          compSource,
          options: ModelLoadOptions(
            sha256: companion.sha256,
            bearerToken: bearerToken,
            cancelToken: cancelToken,
          ),
          onProgress: (ModelDownloadProgress p) {
            final received = completedBytes + p.receivedBytes;
            final total = totalExpected > 0
                ? totalExpected
                : (completedBytes + (p.totalBytes ?? 0));
            _emit(
              StudioModelDownloadProgress(
                modelId: descriptor.id,
                stage: ModelDownloadTaskStage.downloading,
                receivedBytes: received,
                totalBytes: total,
                fraction: total > 0
                    ? (received / total).clamp(0.0, 1.0)
                    : p.fraction,
                statusLabel: 'Downloading ${companion.filename}...',
              ),
            );
          },
        );
        completedBytes += compEntry.bytes ?? 0;
        resolvedCompanions[companion.role] = ModelSource.path(
          compEntry.filePath,
        );
      }

      _emit(
        StudioModelDownloadProgress(
          modelId: descriptor.id,
          stage: ModelDownloadTaskStage.ready,
          receivedBytes: completedBytes,
          totalBytes: completedBytes,
          fraction: 1.0,
          statusLabel: 'Cached locally',
        ),
      );

      return ResolvedModelAssets(
        descriptor: descriptor,
        primarySource: ModelSource.path(
          primaryEntry.filePath,
          format: descriptor.format,
        ),
        companionSources: resolvedCompanions,
      );
    } catch (error) {
      final isCancelled = cancelToken.isCancelled;
      _emit(
        StudioModelDownloadProgress(
          modelId: descriptor.id,
          stage: isCancelled
              ? ModelDownloadTaskStage.cancelled
              : ModelDownloadTaskStage.failed,
          errorMessage: error.toString(),
        ),
      );
      rethrow;
    } finally {
      if (identical(_activeTokens[descriptor.id], cancelToken)) {
        _activeTokens.remove(descriptor.id);
      }
    }
  }

  @override
  void cancelDownload(String modelId) {
    _activeTokens.remove(modelId)?.cancel();
    _emit(
      StudioModelDownloadProgress(
        modelId: modelId,
        stage: ModelDownloadTaskStage.cancelled,
        statusLabel: 'Download cancelled',
      ),
    );
  }

  @override
  Future<void> removeCachedModel(
    StudioModelDescriptor descriptor, {
    required bool isWeb,
  }) async {
    if (isWeb) {
      return;
    }
    final primary = descriptor.primarySource(isWeb: false);
    if (primary.isRemote) {
      await _manager.remove(primary.cacheKey);
    }
    for (final companion in descriptor.companions) {
      final compSource = companion.toModelSource(isWeb: false);
      if (compSource.isRemote) {
        await _manager.remove(compSource.cacheKey);
      }
    }
    _emit(
      StudioModelDownloadProgress(
        modelId: descriptor.id,
        stage: ModelDownloadTaskStage.idle,
      ),
    );
  }

  @override
  Future<void> removeCacheEntry(String cacheKey) async {
    await _manager.remove(cacheKey);
  }

  @override
  Future<List<ModelCacheEntry>> pruneCache({
    Duration? maxAge,
    int? maxBytes,
  }) async {
    try {
      return await _manager.prune(maxAge: maxAge, maxBytes: maxBytes);
    } on LlamaUnsupportedException {
      return const <ModelCacheEntry>[];
    }
  }

  @override
  Future<void> dispose() async {
    for (final token in _activeTokens.values) {
      token.cancel();
    }
    _activeTokens.clear();
    await _progressController.close();
  }

  void _emit(StudioModelDownloadProgress progress) {
    if (!_progressController.isClosed) {
      _progressController.add(progress);
    }
  }
}
