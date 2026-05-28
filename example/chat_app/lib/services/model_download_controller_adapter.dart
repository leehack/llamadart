import 'dart:async';

import 'package:dio/dio.dart';
import 'package:llamadart/llamadart.dart' as llama;
import 'package:path/path.dart' as p;

import '../models/downloadable_model.dart';
import 'model_service_base.dart';

/// Adapts the chat app's platform-specific model service to the package-level
/// [llama.ModelDownloadController] contract.
///
/// The example app still owns its multi-asset native/web storage details, while
/// the controller owns the app-facing resolving/cache/download/verify/ready and
/// cancel/retry state machine.
class ChatAppModelDownloadManager implements llama.ModelDownloadManager {
  ChatAppModelDownloadManager({
    required this.modelService,
    required this.model,
    required this.modelsDir,
    this.useWebSources = false,
    this.onProgressDetail,
  }) : source = sourceFor(model, useWebSources: useWebSources);

  final ModelService modelService;
  final DownloadableModel model;
  final String modelsDir;
  final bool useWebSources;
  final void Function(ModelDownloadProgress progress)? onProgressDetail;
  final llama.ModelSource source;

  static llama.ModelSource sourceFor(
    DownloadableModel model, {
    bool useWebSources = false,
  }) {
    return _sourceForAsset(model.modelSourceFor(web: useWebSources));
  }

  @override
  Future<llama.ModelCacheEntry> ensureModel(
    llama.ModelSource source, {
    llama.ModelLoadOptions options = llama.ModelLoadOptions.defaults,
    llama.ModelDownloadProgressCallback? onProgress,
  }) async {
    _checkSource(source);
    _rejectUnsupportedOptions(options);

    final cached = await get(source.cacheKey);
    switch (options.cachePolicy) {
      case llama.ModelCachePolicy.preferCached:
        if (cached != null) {
          return cached;
        }
        break;
      case llama.ModelCachePolicy.cacheOnly:
        if (cached != null) {
          return cached;
        }
        throw StateError('Model is not cached: ${source.displayName}.');
      case llama.ModelCachePolicy.refresh:
      case llama.ModelCachePolicy.noCache:
        break;
    }

    Object? failure;
    String? completedFilename;
    final cancelToken = CancelToken();
    final cancellationPoller = _bridgeCancellation(
      options.cancelToken,
      cancelToken,
    );

    try {
      await modelService.downloadModel(
        model: model,
        modelsDir: modelsDir,
        cancelToken: cancelToken,
        onProgress: (progress) {
          onProgress?.call(llama.ModelDownloadProgress.fraction(progress));
        },
        onProgressDetail: (detail) {
          onProgressDetail?.call(detail);
          onProgress?.call(
            llama.ModelDownloadProgress.fraction(detail.overallProgress),
          );
        },
        onSuccess: (filename) {
          completedFilename = filename;
        },
        onError: (error) {
          failure = error;
        },
      );
    } finally {
      cancellationPoller?.cancel();
    }

    final error = failure;
    if (error != null) {
      Error.throwWithStackTrace(error, StackTrace.current);
    }
    if (completedFilename == null) {
      throw StateError('Model download finished without success or failure.');
    }

    return _cacheEntry(source);
  }

  @override
  Future<List<llama.ModelCacheEntry>> list({String? cacheDirectory}) async {
    final cached = await get(source.cacheKey, cacheDirectory: cacheDirectory);
    return cached == null
        ? const <llama.ModelCacheEntry>[]
        : <llama.ModelCacheEntry>[cached];
  }

  @override
  Future<llama.ModelCacheEntry?> get(
    String cacheKey, {
    String? cacheDirectory,
  }) async {
    if (cacheKey != source.cacheKey) {
      return null;
    }
    final downloaded = await modelService.getDownloadedModels(
      <DownloadableModel>[model],
    );
    if (!downloaded.contains(model.filename)) {
      return null;
    }
    return _cacheEntry(source);
  }

  @override
  Future<void> remove(String cacheKey, {String? cacheDirectory}) async {
    throw UnsupportedError(
      'ChatAppModelDownloadManager delegates deletion to ModelService.deleteModel.',
    );
  }

  @override
  Future<void> clear({String? cacheDirectory}) async {
    throw UnsupportedError(
      'ChatAppModelDownloadManager delegates deletion to the chat app UI.',
    );
  }

  @override
  Future<List<llama.ModelCacheEntry>> prune({
    Duration? maxAge,
    int? maxBytes,
    String? cacheDirectory,
  }) async {
    throw UnsupportedError(
      'ChatAppModelDownloadManager does not manage package cache pruning.',
    );
  }

  void _checkSource(llama.ModelSource requestedSource) {
    if (requestedSource.cacheKey != source.cacheKey) {
      throw ArgumentError.value(
        requestedSource,
        'source',
        'ChatAppModelDownloadManager is bound to ${source.displayName}.',
      );
    }
  }

  void _rejectUnsupportedOptions(llama.ModelLoadOptions options) {
    if (options.sha256 != null) {
      throw UnsupportedError(
        'ChatAppModelDownloadManager cannot verify SHA-256 checksums.',
      );
    }
  }

  Timer? _bridgeCancellation(
    llama.ModelDownloadCancelToken? controllerToken,
    CancelToken cancelToken,
  ) {
    if (controllerToken == null) {
      return null;
    }
    void cancelIfNeeded() {
      if (controllerToken.isCancelled && !cancelToken.isCancelled) {
        cancelToken.cancel('Download cancelled.');
      }
    }

    cancelIfNeeded();
    if (cancelToken.isCancelled) {
      return null;
    }
    return Timer.periodic(const Duration(milliseconds: 100), (_) {
      cancelIfNeeded();
    });
  }

  llama.ModelCacheEntry _cacheEntry(llama.ModelSource source) {
    final now = DateTime.now().toUtc();
    return llama.ModelCacheEntry(
      sourceCanonicalKey: source.canonicalKey,
      cacheKey: source.cacheKey,
      fileName: source.fileName,
      filePath: source.isLocal
          ? source.path!
          : p.join(modelsDir, source.fileName),
      bytes: model.sizeBytes > 0 ? model.sizeBytes : null,
      createdAt: now,
      updatedAt: now,
    );
  }
}

llama.ModelSource _sourceForAsset(ModelAssetSource source) {
  if (source is LocalModelAssetSource) {
    return llama.ModelSource.path(source.path);
  }
  final remote = source as RemoteModelAssetSource;
  return llama.ModelSource.url(
    Uri.parse(remote.url),
    fileName: remote.filename,
  );
}
