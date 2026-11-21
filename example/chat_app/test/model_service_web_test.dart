@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:dio/dio.dart' show CancelToken, DioException, DioExceptionType;
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_chat_example/models/downloadable_model.dart';
import 'package:llamadart_chat_example/services/model_service_web.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web/web.dart' show Response, ResponseInit, window;

@JS('Function')
external JSFunction _jsFunction(String body);

void main() {
  const name = 'llamadart-webgpu-model-cache-v1';
  const profile = DownloadableModel(
    name: 'Multimodal',
    description: 'Test model and projector',
    url: 'https://example.invalid/model-00001-of-00002.gguf',
    filename: 'model.gguf',
    mmprojUrl: 'https://example.invalid/mmproj.gguf',
    mmprojFilename: 'mmproj.gguf',
    sizeBytes: 200,
    supportsVision: true,
  );
  const markersKey = 'web_cached_models';
  final service = ModelServiceWeb();
  late JSFunction constructor;
  late Set<String> committed;
  late List<String> queries;
  late List<String> prefetches;
  late int creates;
  late int disposals;
  late bool queryUnavailable;
  late bool emptyResponse;

  setUp(() async {
    await window.caches.delete(name).toDart;
    SharedPreferences.setMockInitialValues({});
    committed = {};
    queries = [];
    prefetches = [];
    creates = 0;
    disposals = 0;
    queryUnavailable = false;
    emptyResponse = false;
    final bridge = JSObject()
      ..setProperty(
        'isModelCached'.toJS,
        ((String url, JSObject options) {
          expect(options.getProperty<JSString>('cacheName'.toJS).toDart, name);
          queries.add(url);
          if (queryUnavailable) return Future<JSAny?>.value().toJS;
          return Future<JSAny?>.value(committed.contains(url).toJS).toJS;
        }).toJS,
      )
      ..setProperty(
        'prefetchModelToCache'.toJS,
        ((String url, JSObject options) {
          expect(options.getProperty<JSString>('cacheName'.toJS).toDart, name);
          prefetches.add(url);
          committed.add(url);
          final bytes = emptyResponse ? 0 : 100;
          final progress = JSObject()
            ..setProperty('loaded'.toJS, bytes.toJS)
            ..setProperty('total'.toJS, bytes.toJS);
          options
              .getProperty<JSFunction>('progressCallback'.toJS)
              .callAsFunction(null, progress);
          return Future<JSNumber>.value(1.toJS).toJS;
        }).toJS,
      )
      ..setProperty(
        'evictModelFromCache'.toJS,
        ((String url, JSObject options) {
          return Future<JSBoolean>.value(committed.remove(url).toJS).toJS;
        }).toJS,
      )
      ..setProperty('cancel'.toJS, (() {}).toJS)
      ..setProperty(
        'dispose'.toJS,
        (() {
          disposals += 1;
          return Future<JSAny?>.value().toJS;
        }).toJS,
      );
    globalContext.setProperty(
      '__testCacheBridgeFactory'.toJS,
      ((JSObject options) {
        expect(
          options.getProperty<JSBoolean>('disableWorker'.toJS).toDart,
          isTrue,
        );
        creates += 1;
        return bridge;
      }).toJS,
    );
    constructor = _jsFunction(
      'return globalThis.__testCacheBridgeFactory(arguments[0]);',
    )..setProperty('supportsModelCacheQuery'.toJS, true.toJS);
    globalContext.setProperty('LlamaWebGpuBridge'.toJS, constructor);
  });

  tearDown(() async {
    globalContext.delete('LlamaWebGpuBridge'.toJS);
    globalContext.delete('__testCacheBridgeFactory'.toJS);
    await window.caches.delete(name).toDart;
  });

  test(
    'a scan uses one direct bridge and trusts the shard-aware query',
    () async {
      committed.add(profile.mmprojUrl!);
      expect(await service.getDownloadedModels([profile]), isEmpty);
      expect(queries, [profile.url, profile.mmprojUrl]);
      expect(creates, 1);
      expect(disposals, 1);
      committed.add(profile.url);
      expect(await service.getDownloadedModels([profile]), {profile.filename});
    },
  );

  test('an invalid query response preserves existing markers', () async {
    final prefs = await SharedPreferences.getInstance();
    final keys = [
      profile.modelSourceFor(web: true).cacheKey,
      profile.multimodalProjectorSourceFor(web: true)!.cacheKey,
    ];
    await prefs.setStringList(markersKey, keys);
    queryUnavailable = true;
    expect(await service.getDownloadedModels([profile]), {profile.filename});
    expect(prefs.getStringList(markersKey), unorderedEquals(keys));
  });

  test('older bridges can recognize legacy whole responses', () async {
    constructor.delete('supportsModelCacheQuery'.toJS);
    final cache = await window.caches.open(name).toDart;
    for (final url in [profile.url, profile.mmprojUrl!]) {
      await cache.put(url.toJS, Response('GGUF'.toJS)).toDart;
    }
    expect(await service.getDownloadedModels([profile]), {profile.filename});
    expect(queries, isEmpty);
  });

  test('legacy prefetch can commit whole responses without progress', () async {
    constructor.delete('supportsModelCacheQuery'.toJS);
    final cache = await window.caches.open(name).toDart;
    var completed = false;
    final bridge =
        globalContext
                .getProperty<JSFunction>('__testCacheBridgeFactory'.toJS)
                .callAsFunction(
                  null,
                  JSObject()..setProperty('disableWorker'.toJS, true.toJS),
                )
            as JSObject;
    bridge.setProperty(
      'prefetchModelToCache'.toJS,
      ((String url, JSObject options) => cache.put(
        url.toJS,
        Response('GGUF'.toJS),
      )).toJS,
    );
    await service.downloadModel(
      model: profile,
      modelsDir: 'browser-cache',
      cancelToken: CancelToken(),
      onProgress: (_) {},
      onSuccess: (_) => completed = true,
      onError: (failure) => fail('$failure'),
    );
    expect(completed, isTrue);
  });

  test('a legacy empty response is not a cached model', () async {
    constructor.delete('supportsModelCacheQuery'.toJS);
    final cache = await window.caches.open(name).toDart;
    await cache
        .put(profile.url.toJS, Response(null, ResponseInit(status: 204)))
        .toDart;
    expect(
      (await service.getModelCacheState(profile)).model.isAvailable,
      isFalse,
    );
  });

  test(
    'cancellation leaves no markers and the next prefetch can complete',
    () async {
      final token = CancelToken();
      Object? error;
      await service.downloadModel(
        model: profile,
        modelsDir: 'browser-cache',
        cancelToken: token,
        onProgress: (_) => token.cancel(),
        onSuccess: (_) => fail('a cancelled prefetch completed'),
        onError: (failure) => error = failure,
      );
      expect(
        error,
        isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.cancel,
        ),
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList(markersKey), anyOf(isNull, isEmpty));
      expect(disposals, creates);

      await service.downloadModel(
        model: profile,
        modelsDir: 'browser-cache',
        cancelToken: CancelToken(),
        onProgress: (_) {},
        onSuccess: (_) {},
        onError: (failure) => fail('$failure'),
      );
      expect(await service.getDownloadedModels([profile]), {profile.filename});
      expect(disposals, creates);
    },
  );

  for (final empty in [false, true]) {
    test(
      'prefetch validates cache and progress (empty response: $empty)',
      () async {
        emptyResponse = empty;
        String? success;
        Object? error;
        await service.downloadModel(
          model: profile,
          modelsDir: 'browser-cache',
          cancelToken: CancelToken(),
          onProgress: (_) {},
          onSuccess: (name) => success = name,
          onError: (failure) => error = failure,
        );
        if (empty) {
          expect(error, isA<StateError>());
          expect(success, isNull);
          expect(prefetches, [profile.url]);
          expect(committed, isEmpty);
        } else {
          expect(error, isNull);
          expect(success, profile.filename);
          expect(prefetches, [profile.url, profile.mmprojUrl]);
          expect(await service.getDownloadedModels([profile]), {
            profile.filename,
          });
        }
        expect(disposals, creates);
      },
    );
  }
}
