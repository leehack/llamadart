import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/downloadable_model.dart';
import 'model_service_base.dart';

class ModelServiceWeb implements ModelService, WebCachePrefetchModelService {
  static const String _downloadedModelsKey = 'web_cached_models';
  static const String _modelCacheName = 'llamadart-webgpu-model-cache-v1';
  static const String _hfToken = String.fromEnvironment('HF_TOKEN');

  final Dio _dio = Dio();

  Map<String, Object>? _requestHeaders() {
    final token = _hfToken.trim();
    if (token.isEmpty) {
      return null;
    }
    return <String, Object>{'authorization': 'Bearer $token'};
  }

  @override
  Future<String> getModelsDirectory() async => 'browser-cache';

  @override
  Future<Set<String>> getDownloadedModels(
    List<DownloadableModel> models,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final downloaded = prefs.getStringList(_downloadedModelsKey) ?? const [];
    final downloadedSet = downloaded.toSet();
    final cachedModels = <String>{};
    var migratedLegacyMarkers = false;

    for (final model in models) {
      if (_isProfileCached(model, downloadedSet)) {
        cachedModels.add(model.filename);
        continue;
      }

      final sources = _remoteSourcesFor(model);
      if (downloadedSet.contains(model.filename) &&
          sources.length == _assetSourcesFor(model).length) {
        downloadedSet.remove(model.filename);
        for (final source in sources) {
          downloadedSet.add(source.cacheKey);
        }
        cachedModels.add(model.filename);
        migratedLegacyMarkers = true;
      }
    }

    if (migratedLegacyMarkers) {
      await prefs.setStringList(_downloadedModelsKey, downloadedSet.toList());
    }

    return cachedModels;
  }

  bool _isProfileCached(DownloadableModel model, Set<String> downloaded) {
    final sources = _remoteSourcesFor(model);
    if (sources.length != _assetSourcesFor(model).length) {
      return false;
    }

    return sources.every((source) => downloaded.contains(source.cacheKey));
  }

  List<ModelAssetSource> _assetSourcesFor(DownloadableModel model) {
    return <ModelAssetSource>[
      model.modelSource,
      if (model.multimodalProjectorSource != null)
        model.multimodalProjectorSource!,
    ];
  }

  List<RemoteModelAssetSource> _remoteSourcesFor(DownloadableModel model) {
    return _assetSourcesFor(
      model,
    ).whereType<RemoteModelAssetSource>().toList(growable: false);
  }

  @override
  Future<void> downloadModel({
    required DownloadableModel model,
    required String modelsDir,
    required CancelToken cancelToken,
    required Function(double progress) onProgress,
    Function(ModelDownloadProgress progress)? onProgressDetail,
    required Function(String filename) onSuccess,
    required Function(dynamic error) onError,
  }) async {
    final modelSource = model.modelSource;
    final assetSources = _assetSourcesFor(model);
    if (assetSources.any((source) => source is! RemoteModelAssetSource)) {
      onError(
        UnsupportedError('Web downloads require remote URLs for all assets'),
      );
      return;
    }
    final remoteModelSource = modelSource as RemoteModelAssetSource;
    final mmprojUrl =
        (model.multimodalProjectorSource as RemoteModelAssetSource?)?.url;
    final stageCount = mmprojUrl == null ? 1 : 2;
    final aggregate = ModelDownloadProgressTracker(
      includeMmproj: mmprojUrl != null,
      providedTotalBytes: model.sizeBytes > 0 ? model.sizeBytes : null,
    );
    if (_remoteSourcesFor(
      model,
    ).any((source) => _hasPersistentCacheSensitiveUrlParts(source.url))) {
      onError(
        UnsupportedError(
          'Browser cache prefetch skipped for credentialed remote URL; load the model directly to avoid storing sensitive URL parts.',
        ),
      );
      return;
    }
    if (!_hasCacheStorageApi()) {
      onError(
        UnsupportedError(
          'Browser CacheStorage is unavailable; remote models can still be loaded directly.',
        ),
      );
      return;
    }

    final bridge = _tryCreateBridge();

    try {
      var usedBridgePrefetch = false;
      if (bridge != null) {
        try {
          unawaited(
            cancelToken.whenCancel.then((_) {
              try {
                bridge.cancel();
              } catch (_) {
                // best-effort cancellation only
              }
            }),
          );

          await _prefetchStage(
            bridge,
            remoteModelSource.url,
            stage: ModelDownloadStage.model,
            stageIndex: 1,
            stageCount: stageCount,
            aggregate: aggregate,
            updateStage: aggregate.updateModel,
            onProgress: onProgress,
            onProgressDetail: onProgressDetail,
          );

          if (mmprojUrl != null) {
            await _prefetchStage(
              bridge,
              mmprojUrl,
              stage: ModelDownloadStage.multimodalProjector,
              stageIndex: 2,
              stageCount: stageCount,
              aggregate: aggregate,
              updateStage: aggregate.updateMmproj,
              onProgress: onProgress,
              onProgressDetail: onProgressDetail,
            );
          }

          usedBridgePrefetch = true;
        } catch (error) {
          if (!_looksLikePrefetchUnavailable(error)) {
            rethrow;
          }
        }
      }

      if (!usedBridgePrefetch) {
        await _verifyRemoteStage(
          remoteModelSource.url,
          stage: ModelDownloadStage.model,
          stageIndex: 1,
          stageCount: stageCount,
          cancelToken: cancelToken,
          aggregate: aggregate,
          updateStage: aggregate.updateModel,
          onProgress: onProgress,
          onProgressDetail: onProgressDetail,
        );

        if (mmprojUrl != null) {
          await _verifyRemoteStage(
            mmprojUrl,
            stage: ModelDownloadStage.multimodalProjector,
            stageIndex: 2,
            stageCount: stageCount,
            cancelToken: cancelToken,
            aggregate: aggregate,
            updateStage: aggregate.updateMmproj,
            onProgress: onProgress,
            onProgressDetail: onProgressDetail,
          );
        }
      }

      final finalDetail = aggregate.finalProgress(stageCount: stageCount);
      onProgress(finalDetail.overallProgress);
      onProgressDetail?.call(finalDetail);

      final prefs = await SharedPreferences.getInstance();
      final downloaded =
          prefs.getStringList(_downloadedModelsKey)?.toSet() ?? <String>{};
      for (final source in _remoteSourcesFor(model)) {
        downloaded.add(source.cacheKey);
      }
      await prefs.setStringList(_downloadedModelsKey, downloaded.toList());

      onSuccess(model.filename);
    } catch (error) {
      if (_looksCancelled(error) || cancelToken.isCancelled) {
        onError(_cancelledException(remoteModelSource.url));
      } else {
        onError(error);
      }
    } finally {
      if (bridge != null) {
        try {
          final disposePromise = bridge.dispose();
          if (disposePromise != null) {
            await disposePromise.toDart;
          }
        } catch (_) {
          // best-effort bridge disposal
        }
      }
    }
  }

  @override
  Future<bool> supportsWebCachePrefetch() async {
    if (!_hasCacheStorageApi()) {
      return false;
    }

    final bridge = _tryCreateBridge();
    if (bridge == null) {
      return false;
    }

    try {
      final prefetchMember = bridge.getProperty<JSAny?>(
        'prefetchModelToCache'.toJS,
      );
      return prefetchMember != null && prefetchMember.isA<JSFunction>();
    } finally {
      try {
        final disposePromise = bridge.dispose();
        if (disposePromise != null) {
          await disposePromise.toDart;
        }
      } catch (_) {
        // best-effort bridge disposal
      }
    }
  }

  bool _looksLikePrefetchUnavailable(dynamic error) {
    final normalized = '$error'.toLowerCase();
    return normalized.contains('prefetchmodeltocache') &&
        normalized.contains('not a function');
  }

  bool _hasCacheStorageApi() {
    try {
      final caches = globalContext.getProperty<JSAny?>('caches'.toJS);
      if (caches == null || !caches.isA<JSObject>()) {
        return false;
      }
      final openMember = (caches as JSObject).getProperty<JSAny?>('open'.toJS);
      return openMember != null && openMember.isA<JSFunction>();
    } catch (_) {
      return false;
    }
  }

  bool _hasPersistentCacheSensitiveUrlParts(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        (uri.userInfo.isNotEmpty ||
            uri.query.isNotEmpty ||
            uri.fragment.isNotEmpty);
  }

  _WebModelCacheBridge? _tryCreateBridge() {
    if (!globalContext.has('LlamaWebGpuBridge')) {
      return null;
    }

    try {
      return _WebModelCacheBridge(
        _WebModelCacheBridgeConfig(
          disableWorker: true,
          cacheName: _modelCacheName.toJS,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _prefetchStage(
    _WebModelCacheBridge bridge,
    String url, {
    required ModelDownloadStage stage,
    required int stageIndex,
    required int stageCount,
    required ModelDownloadProgressTracker aggregate,
    required void Function(int downloadedBytes, int? totalBytes) updateStage,
    required Function(double progress) onProgress,
    Function(ModelDownloadProgress progress)? onProgressDetail,
  }) async {
    var stageDownloadedBytes = 0;
    int? stageTotalBytes;

    void emit(bool resumed) {
      updateStage(stageDownloadedBytes, stageTotalBytes);
      final detail = aggregate.buildProgress(
        stage: stage,
        stageIndex: stageIndex,
        stageCount: stageCount,
        stageDownloadedBytes: stageDownloadedBytes,
        stageTotalBytes: stageTotalBytes,
        resumed: resumed,
      );
      onProgress(detail.overallProgress);
      onProgressDetail?.call(detail);
    }

    emit(false);

    final prefetchPromise = bridge.prefetchModelToCache(
      url,
      _WebModelCacheOptions(
        useCache: true,
        force: false,
        cacheName: _modelCacheName.toJS,
        progressCallback: ((JSAny? payload) {
          final snapshot = _parseBridgeProgress(payload);
          if (snapshot.loaded > stageDownloadedBytes) {
            stageDownloadedBytes = snapshot.loaded;
          }
          if (snapshot.total != null && snapshot.total! > 0) {
            stageTotalBytes = snapshot.total;
            if (stageDownloadedBytes > snapshot.total!) {
              stageDownloadedBytes = snapshot.total!;
            }
          }
          emit(false);
        }).toJS,
      ),
    );

    if (prefetchPromise != null) {
      await prefetchPromise.toDart;
    }

    final completedBytes = stageTotalBytes != null && stageTotalBytes! > 0
        ? stageTotalBytes!
        : (stageDownloadedBytes > 0 ? stageDownloadedBytes : 1);
    stageDownloadedBytes = completedBytes;
    stageTotalBytes ??= completedBytes;
    emit(false);
  }

  _BridgeProgressSnapshot _parseBridgeProgress(JSAny? payload) {
    if (payload == null) {
      return const _BridgeProgressSnapshot(loaded: 0, total: null);
    }

    if (payload.isA<JSObject>()) {
      final object = payload as JSObject;
      final loaded = _toNonNegativeInt(object.getProperty('loaded'.toJS)) ?? 0;
      final total = _toNonNegativeInt(object.getProperty('total'.toJS));
      return _BridgeProgressSnapshot(loaded: loaded, total: total);
    }

    if (payload.isA<JSNumber>()) {
      final value = (payload as JSNumber).toDartDouble;
      if (value.isFinite && value >= 0 && value <= 1) {
        final scaled = (value * 1000).round();
        return _BridgeProgressSnapshot(loaded: scaled, total: 1000);
      }
    }

    return const _BridgeProgressSnapshot(loaded: 0, total: null);
  }

  int? _toNonNegativeInt(JSAny? value) {
    if (value == null) {
      return null;
    }

    if (value.isA<JSNumber>()) {
      final number = (value as JSNumber).toDartDouble;
      if (number.isFinite && number >= 0) {
        return number.round();
      }
      return null;
    }

    final text = value.toString();
    if (text.isEmpty || text == 'undefined' || text == 'null') {
      return null;
    }

    final parsed = int.tryParse(text);
    if (parsed == null || parsed < 0) {
      return null;
    }
    return parsed;
  }

  bool _looksCancelled(dynamic error) {
    if (error is DioException && error.type == DioExceptionType.cancel) {
      return true;
    }

    final normalized = '$error'.toLowerCase();
    return normalized.contains('aborterror') ||
        normalized.contains('aborted') ||
        normalized.contains('cancelled') ||
        normalized.contains('canceled');
  }

  DioException _cancelledException(String url) {
    return DioException(
      requestOptions: RequestOptions(path: _redactedUrl(url)),
      type: DioExceptionType.cancel,
      message: 'Download cancelled',
      error: 'Download cancelled',
    );
  }

  String _redactedUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) {
      return url.split('?').first.split('#').first;
    }
    return Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: uri.path,
    ).toString();
  }

  Future<void> _verifyRemoteStage(
    String url, {
    required ModelDownloadStage stage,
    required int stageIndex,
    required int stageCount,
    required CancelToken cancelToken,
    required ModelDownloadProgressTracker aggregate,
    required void Function(int downloadedBytes, int? totalBytes) updateStage,
    required Function(double progress) onProgress,
    Function(ModelDownloadProgress progress)? onProgressDetail,
  }) async {
    final stageTotalBytes = await _resolveRemoteLength(
      url: url,
      cancelToken: cancelToken,
    );

    updateStage(0, stageTotalBytes);
    final initial = aggregate.buildProgress(
      stage: stage,
      stageIndex: stageIndex,
      stageCount: stageCount,
      stageDownloadedBytes: 0,
      stageTotalBytes: stageTotalBytes,
      resumed: false,
    );
    onProgress(initial.overallProgress);
    onProgressDetail?.call(initial);

    final completedBytes = stageTotalBytes != null && stageTotalBytes > 0
        ? stageTotalBytes
        : 1;
    final normalizedStageTotal = stageTotalBytes ?? completedBytes;
    updateStage(completedBytes, normalizedStageTotal);

    final completed = aggregate.buildProgress(
      stage: stage,
      stageIndex: stageIndex,
      stageCount: stageCount,
      stageDownloadedBytes: completedBytes,
      stageTotalBytes: normalizedStageTotal,
      resumed: false,
    );
    onProgress(completed.overallProgress);
    onProgressDetail?.call(completed);
  }

  Future<int?> _resolveRemoteLength({
    required String url,
    required CancelToken cancelToken,
  }) async {
    final response = await _dio.head<void>(
      url,
      cancelToken: cancelToken,
      options: Options(
        headers: _requestHeaders(),
        validateStatus: (status) =>
            status != null && status >= 200 && status < 500,
      ),
    );

    final statusCode = response.statusCode ?? 500;
    if (statusCode >= 400) {
      throw DioException.badResponse(
        statusCode: statusCode,
        requestOptions: response.requestOptions,
        response: response,
      );
    }

    return int.tryParse(
      response.headers.value(Headers.contentLengthHeader) ?? '',
    );
  }

  @override
  Future<void> deleteModel(String modelsDir, DownloadableModel model) async {
    final prefs = await SharedPreferences.getInstance();
    final downloaded =
        prefs.getStringList(_downloadedModelsKey)?.toSet() ?? <String>{};
    for (final source in _remoteSourcesFor(model)) {
      downloaded.remove(source.cacheKey);
    }
    await prefs.setStringList(_downloadedModelsKey, downloaded.toList());

    final bridge = _tryCreateBridge();
    if (bridge == null) {
      return;
    }

    try {
      for (final source in _remoteSourcesFor(model)) {
        final evictPromise = bridge.evictModelFromCache(
          source.url,
          _WebModelCacheOptions(cacheName: _modelCacheName.toJS),
        );
        if (evictPromise != null) {
          await evictPromise.toDart;
        }
      }
    } catch (_) {
      // best-effort cache eviction
    } finally {
      try {
        final disposePromise = bridge.dispose();
        if (disposePromise != null) {
          await disposePromise.toDart;
        }
      } catch (_) {
        // ignore disposal failures
      }
    }
  }
}

class _BridgeProgressSnapshot {
  final int loaded;
  final int? total;

  const _BridgeProgressSnapshot({required this.loaded, required this.total});
}

@JS('LlamaWebGpuBridge')
extension type _WebModelCacheBridge._(JSObject _) implements JSObject {
  external factory _WebModelCacheBridge([_WebModelCacheBridgeConfig? config]);

  external JSPromise<JSAny?>? prefetchModelToCache(
    String url, [
    _WebModelCacheOptions? options,
  ]);

  external JSPromise<JSAny?>? evictModelFromCache(
    String url, [
    _WebModelCacheOptions? options,
  ]);

  external JSAny? cancel();

  external JSPromise<JSAny?>? dispose();
}

@JS()
@anonymous
extension type _WebModelCacheBridgeConfig._(JSObject _) implements JSObject {
  external factory _WebModelCacheBridgeConfig({
    bool? disableWorker,
    JSString? cacheName,
  });
}

@JS()
@anonymous
extension type _WebModelCacheOptions._(JSObject _) implements JSObject {
  external factory _WebModelCacheOptions({
    bool? useCache,
    bool? force,
    JSString? cacheName,
    JSFunction? progressCallback,
  });
}

ModelService createModelService() => ModelServiceWeb();
