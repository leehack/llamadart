import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:dio/dio.dart';
import 'package:llamadart/llamadart.dart' as llama;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web/web.dart' show URL, document;

import '../models/downloadable_model.dart';
import 'model_service_base.dart';

class ModelServiceWeb implements ModelService, WebCachePrefetchModelService {
  static const String _downloadedModelsKey = 'web_cached_models';
  static const String _modelCacheName = 'llamadart-webgpu-model-cache-v1';

  @override
  Future<String> getModelsDirectory() async => 'browser-cache';

  @override
  Future<Set<String>> getDownloadedModels(
    List<DownloadableModel> models,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final downloaded = prefs.getStringList(_downloadedModelsKey) ?? const [];
    final markers = ModelAssetCacheMarkers(downloaded);
    final confirmed = ModelAssetCacheMarkers(const []);
    final cachedModels = <String>{};
    final sources = models.expand(_remoteSourcesFor).toList();
    final markersChanged = await _withCacheScan(sources, (lookup) async {
      var changed = false;
      for (final model in models) {
        if (!markers.isProfileCached(model, web: true)) {
          changed =
              markers.migrateLegacyProfileMarker(model, web: true) || changed;
        }
        changed =
            await _syncMarkersWithCache(
              markers,
              confirmed,
              _remoteSourcesFor(model),
              lookup,
            ) ||
            changed;
        if (confirmed.isProfileCached(model, web: true)) {
          cachedModels.add(model.filename);
        }
      }
      return changed;
    });

    if (markersChanged) {
      await prefs.setStringList(_downloadedModelsKey, markers.toSet().toList());
    }

    return cachedModels;
  }

  @override
  Future<ModelProfileCacheState> getModelCacheState(
    DownloadableModel model,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final downloaded = prefs.getStringList(_downloadedModelsKey) ?? const [];
    final markers = ModelAssetCacheMarkers(downloaded);
    final confirmed = ModelAssetCacheMarkers(const []);
    final sources = _remoteSourcesFor(model);
    final changed = await _withCacheScan(
      sources,
      (lookup) => _syncMarkersWithCache(markers, confirmed, sources, lookup),
    );
    if (changed) {
      await prefs.setStringList(_downloadedModelsKey, markers.toSet().toList());
    }
    return confirmed.modelCacheState(model, web: true);
  }

  List<ModelAssetSource> _assetSourcesFor(DownloadableModel model) {
    final projector = model.multimodalProjectorSourceFor(web: true);
    return <ModelAssetSource>[model.modelSourceFor(web: true), ?projector];
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
    required void Function(double progress) onProgress,
    Function(ModelDownloadProgress progress)? onProgressDetail,
    required Function(String filename) onSuccess,
    required Function(dynamic error) onError,
  }) async {
    final modelSource = model.modelSourceFor(web: true);
    final assetSources = _assetSourcesFor(model);
    if (assetSources.any((source) => source is! RemoteModelAssetSource)) {
      onError(
        UnsupportedError('Web downloads require remote URLs for all assets'),
      );
      return;
    }
    final remoteModelSource = modelSource as RemoteModelAssetSource;
    final remoteMmprojSource =
        model.multimodalProjectorSourceFor(web: true)
            as RemoteModelAssetSource?;
    final prefs = await SharedPreferences.getInstance();
    final downloaded =
        prefs.getStringList(_downloadedModelsKey)?.toSet() ?? <String>{};
    final markers = ModelAssetCacheMarkers(downloaded);
    final confirmed = ModelAssetCacheMarkers(const []);
    final sources = _remoteSourcesFor(model);
    var markersChanged = markers.migrateLegacyProfileMarker(model, web: true);
    markersChanged =
        await _withCacheScan(
          sources,
          (lookup) =>
              _syncMarkersWithCache(markers, confirmed, sources, lookup),
        ) ||
        markersChanged;
    if (markersChanged) {
      await prefs.setStringList(_downloadedModelsKey, markers.toSet().toList());
    }
    final pendingAssets = <_PendingWebCacheAsset>[
      if (!confirmed.containsAsset(remoteModelSource))
        _PendingWebCacheAsset(
          source: remoteModelSource,
          stage: ModelDownloadStage.model,
        ),
      if (remoteMmprojSource != null &&
          !confirmed.containsAsset(remoteMmprojSource))
        _PendingWebCacheAsset(
          source: remoteMmprojSource,
          stage: ModelDownloadStage.multimodalProjector,
        ),
    ];
    final stageCount = pendingAssets.length;
    final aggregate = ModelDownloadProgressTracker(
      includeMmproj: pendingAssets.any(
        (asset) => asset.stage == ModelDownloadStage.multimodalProjector,
      ),
      providedTotalBytes: _providedDownloadTotalBytes(
        model: model,
        pendingAssets: pendingAssets,
      ),
    );
    if (pendingAssets.isEmpty) {
      onSuccess(model.filename);
      return;
    }
    final pendingUrls = [
      for (final asset in pendingAssets) _persistentCacheUrl(asset.source.url),
    ];
    if (pendingUrls.contains(null)) {
      onError(
        UnsupportedError(
          'Browser cache prefetch skipped for a non-HTTP(S) or credentialed URL; load the model directly to avoid storing sensitive URL parts.',
        ),
      );
      return;
    }
    final cache = await _openModelCache();
    if (cache == null) {
      onError(
        UnsupportedError(
          'Browser CacheStorage is unavailable; remote models can still be loaded directly.',
        ),
      );
      return;
    }

    // Wait for the bridge runtime to actually finish loading before deciding
    // whether prefetch is possible. Without this, an early download tap raced
    // the async bridge import and silently "succeeded" without caching bytes.
    final ready = await _awaitBridgeReady();
    final bridge = ready ? _tryCreateBridge() : null;
    if (bridge == null) {
      final detail = _bridgeLoadError();
      onError(
        StateError(
          'Web model caching requires the WebGPU bridge runtime, which did not '
          'become available${detail != null ? ': $detail' : ''}. Reload the '
          'page and try again, or load the model directly without prefetch.',
        ),
      );
      return;
    }

    var finished = false;
    try {
      unawaited(
        cancelToken.whenCancel.then((_) {
          if (finished) return;
          try {
            bridge.cancel();
          } catch (_) {
            // best-effort cancellation only
          }
        }),
      );

      // A prefetch failure (including an old bridge that lacks
      // prefetchModelToCache) now surfaces as a real error instead of silently
      // marking the model cached.
      for (var i = 0; i < pendingAssets.length; i++) {
        if (cancelToken.isCancelled) {
          throw _cancelledException(remoteModelSource.url);
        }
        final asset = pendingAssets[i];
        await _prefetchStage(
          bridge,
          pendingUrls[i]!,
          stage: asset.stage,
          stageIndex: i + 1,
          stageCount: stageCount,
          aggregate: aggregate,
          updateStage: asset.stage == ModelDownloadStage.model
              ? aggregate.updateModel
              : aggregate.updateMmproj,
          onProgress: onProgress,
          onProgressDetail: onProgressDetail,
        );
        final cached = await _isRemoteAssetInCache(
          pendingUrls[i],
          bridge: bridge,
          cache: cache,
        );
        if (cancelToken.isCancelled) {
          throw _cancelledException(remoteModelSource.url);
        }
        if (cached != true) {
          throw StateError(
            'Browser cache prefetch completed, but ${asset.source.filename} '
            'was not found in Cache Storage. Reload the page and try again.',
          );
        }
        markers.markAssetCached(asset.source);
        await prefs.setStringList(
          _downloadedModelsKey,
          markers.toSet().toList(),
        );
      }

      final finalDetail = aggregate.finalProgress(stageCount: stageCount);
      onProgress(finalDetail.overallProgress);
      onProgressDetail?.call(finalDetail);

      onSuccess(model.filename);
    } catch (error) {
      if (_looksCancelled(error) || cancelToken.isCancelled) {
        onError(_cancelledException(remoteModelSource.url));
      } else {
        onError(error);
      }
    } finally {
      finished = true;
      await _disposeBridge(bridge);
    }
  }

  @override
  Future<bool> supportsWebCachePrefetch() async {
    if (!_hasCacheStorageApi()) {
      return false;
    }

    final ready = await _awaitBridgeReady();
    final bridge = ready ? _tryCreateBridge() : null;
    if (bridge == null) {
      return false;
    }

    try {
      final prefetchMember = bridge.getProperty<JSAny?>(
        'prefetchModelToCache'.toJS,
      );
      return prefetchMember != null && prefetchMember.isA<JSFunction>();
    } finally {
      await _disposeBridge(bridge);
    }
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

  Future<T> _withCacheScan<T>(
    List<RemoteModelAssetSource> sources,
    Future<T> Function(_CacheLookup lookup) scan,
  ) async {
    final cache =
        sources.any((source) => _persistentCacheUrl(source.url) != null)
        ? await _openModelCache()
        : null;
    final bridge = cache != null && await _awaitBridgeReady()
        ? _tryCreateBridge()
        : null;
    try {
      return await scan(
        (source) => _isRemoteAssetInCache(
          _persistentCacheUrl(source.url),
          bridge: bridge,
          cache: cache,
        ),
      );
    } finally {
      await _disposeBridge(bridge);
    }
  }

  Future<bool> _syncMarkersWithCache(
    ModelAssetCacheMarkers markers,
    ModelAssetCacheMarkers confirmed,
    Iterable<RemoteModelAssetSource> sources,
    _CacheLookup lookup,
  ) async {
    var changed = false;
    for (final source in sources) {
      final marked = markers.containsAsset(source);
      final cached = await lookup(source);
      if (cached == true) {
        confirmed.markAssetCached(source);
        if (!marked) {
          markers.markAssetCached(source);
          changed = true;
        }
      } else if (cached == false && marked) {
        markers.removeAssets(<RemoteModelAssetSource>[source]);
        changed = true;
      }
    }
    return changed;
  }

  Future<_BrowserCache?> _openModelCache() async {
    if (!_hasCacheStorageApi()) {
      return null;
    }

    try {
      final caches = globalContext.getProperty<JSAny?>('caches'.toJS);
      if (caches == null || !caches.isA<JSObject>()) {
        return null;
      }
      final cacheStorage = caches as _BrowserCacheStorage;
      return await cacheStorage.open(_modelCacheName).toDart;
    } catch (_) {
      return null;
    }
  }

  String? _persistentCacheUrl(String reference) {
    final scheme = Uri.tryParse(reference)?.scheme;
    if (scheme != 'http' && scheme != 'https') return null;
    try {
      final url = URL(reference, document.baseURI);
      final parsed = Uri.tryParse(url.href);
      if ((url.protocol == 'http:' || url.protocol == 'https:') &&
          url.host.isNotEmpty &&
          parsed != null &&
          parsed.host.isNotEmpty &&
          !llama.hasPersistentCacheSensitiveUrlParts(url.href)) {
        return url.href;
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  Future<bool?> _isRemoteAssetInCache(
    String? url, {
    required _WebModelCacheBridge? bridge,
    required _BrowserCache? cache,
  }) async {
    if (url == null) return false;
    if (bridge == null || cache == null) return null;

    try {
      final capability = _WebModelCacheBridge.supportsModelCacheQuery;
      if (capability.isA<JSBoolean>() && (capability as JSBoolean).toDart) {
        final hit = await bridge
            .isModelCached(
              url,
              _WebModelCacheOptions(cacheName: _modelCacheName.toJS),
            )
            .toDart;
        return hit.isA<JSBoolean>() ? (hit as JSBoolean).toDart : null;
      }

      final response = await cache.match(url).toDart;
      return response != null && response.ok && response.status != 204;
    } catch (_) {
      return null;
    }
  }

  Future<void> _disposeBridge(_WebModelCacheBridge? bridge) async {
    try {
      await bridge?.dispose()?.toDart;
    } catch (_) {
      // Cache checks and downloads already have an outcome.
    }
  }

  int? _providedDownloadTotalBytes({
    required DownloadableModel model,
    required List<_PendingWebCacheAsset> pendingAssets,
  }) {
    if (pendingAssets.length > 1 && model.sizeBytesFor(web: true) > 0) {
      return model.sizeBytesFor(web: true);
    }
    if (pendingAssets.length == 1) {
      return pendingAssets.single.source.sizeBytes;
    }
    return null;
  }

  /// Awaits the bridge-readiness signal published by `web/index.html`.
  ///
  /// Returns true once the `LlamaWebGpuBridge` global is available, false if it
  /// failed to load or did not become ready within [timeout]. Falls back to
  /// polling for older `index.html` builds without the readiness promise.
  Future<bool> _awaitBridgeReady({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (globalContext.has('LlamaWebGpuBridge')) {
      return true;
    }
    final promise = globalContext.getProperty<JSAny?>(
      '__llamadartBridgeReadyPromise'.toJS,
    );
    if (promise != null && promise.isA<JSPromise>()) {
      try {
        await (promise as JSPromise).toDart.timeout(timeout);
      } catch (_) {
        // Rejected or timed out; the global check below is authoritative.
      }
      return globalContext.has('LlamaWebGpuBridge');
    }
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (globalContext.has('LlamaWebGpuBridge')) {
        return true;
      }
      if (_bridgeLoadError() != null) {
        return false;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return false;
  }

  String? _bridgeLoadError() {
    final value = globalContext.getProperty<JSAny?>(
      '__llamadartBridgeLoadError'.toJS,
    );
    if (value != null && value.isA<JSString>()) {
      return (value as JSString).toDart;
    }
    return null;
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
    required void Function(double progress) onProgress,
    Function(ModelDownloadProgress progress)? onProgressDetail,
  }) async {
    var stageDownloadedBytes = 0;
    var reportedProgress = false;
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
          reportedProgress = true;
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

    if (prefetchPromise == null) {
      throw StateError('The Web bridge did not start cache prefetch.');
    }
    await prefetchPromise.toDart;

    // The bridge can commit an empty response before rejecting it on load.
    if (reportedProgress && stageDownloadedBytes == 0) {
      await bridge
          .evictModelFromCache(
            url,
            _WebModelCacheOptions(cacheName: _modelCacheName.toJS),
          )
          ?.toDart;
      throw StateError('Web cache prefetch received an empty model response.');
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

    try {
      final name = (error as JSObject).getProperty<JSAny?>('name'.toJS);
      return name.isA<JSString>() && (name as JSString).toDart == 'AbortError';
    } catch (_) {
      return false;
    }
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

  @override
  Future<void> deleteModel(String modelsDir, DownloadableModel model) async {
    final prefs = await SharedPreferences.getInstance();
    final downloaded =
        prefs.getStringList(_downloadedModelsKey)?.toSet() ?? <String>{};
    final markers = ModelAssetCacheMarkers(downloaded)
      ..removeAssets(_remoteSourcesFor(model));
    await prefs.setStringList(_downloadedModelsKey, markers.toSet().toList());

    final bridge = _tryCreateBridge();
    if (bridge == null) {
      return;
    }

    try {
      for (final source in _remoteSourcesFor(model)) {
        final url = _persistentCacheUrl(source.url);
        if (url == null) continue;
        final evictPromise = bridge.evictModelFromCache(
          url,
          _WebModelCacheOptions(cacheName: _modelCacheName.toJS),
        );
        if (evictPromise != null) {
          await evictPromise.toDart;
        }
      }
    } catch (_) {
      // best-effort cache eviction
    } finally {
      await _disposeBridge(bridge);
    }
  }
}

typedef _CacheLookup = Future<bool?> Function(RemoteModelAssetSource source);

class _BridgeProgressSnapshot {
  final int loaded;
  final int? total;

  const _BridgeProgressSnapshot({required this.loaded, required this.total});
}

class _PendingWebCacheAsset {
  final RemoteModelAssetSource source;
  final ModelDownloadStage stage;

  const _PendingWebCacheAsset({required this.source, required this.stage});
}

@JS('LlamaWebGpuBridge')
extension type _WebModelCacheBridge._(JSObject _) implements JSObject {
  external factory _WebModelCacheBridge([_WebModelCacheBridgeConfig? config]);

  external static JSAny? get supportsModelCacheQuery;

  external JSPromise<JSAny?> isModelCached(
    String url, [
    _WebModelCacheOptions? options,
  ]);

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

extension type _BrowserCacheStorage._(JSObject _) implements JSObject {
  external JSPromise<_BrowserCache> open(String cacheName);
}

extension type _BrowserCache._(JSObject _) implements JSObject {
  external JSPromise<_BrowserCacheResponse?> match(String request);
}

ModelService createModelService() => ModelServiceWeb();

@JS()
extension type _BrowserCacheResponse._(JSObject _) implements JSObject {
  external bool get ok;
  external int get status;
}
