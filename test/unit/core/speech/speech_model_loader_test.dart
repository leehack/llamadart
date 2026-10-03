import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/core/speech/speech_model_loader.dart';
import 'package:test/test.dart';

import '../engine/engine_test.dart' show MockLlamaBackend;

void main() {
  group('loadSpeechLlamaEngine', () {
    late _LoaderBackend backend;
    late _FakeDownloadManager manager;
    late bool verified;

    setUp(() {
      backend = _LoaderBackend();
      manager = _FakeDownloadManager();
      verified = false;
    });

    Future<LlamaEngine> load(
      ModelSource source,
      ModelSource? projector, {
      ModelLoadOptions download = ModelLoadOptions.defaults,
      ModelParams params = const ModelParams(),
    }) => loadSpeechLlamaEngine(
      engineName: 'SpeechToTextEngine',
      source: source,
      projector: projector,
      params: params,
      download: download,
      onProgress: null,
      store: ModelFileStore(downloadManager: manager),
      backend: backend,
      verify: (_) async => verified = true,
    );

    test('gives a remote model the load options and a local projector only '
        'the cancel token', () async {
      final token = ModelDownloadCancelToken();
      final download = ModelLoadOptions(
        bearerToken: 'secret',
        cacheDirectory: '/models',
        cancelToken: token,
      );

      final engine = await load(
        ModelSource.parse('https://models.example.com/asr.gguf'),
        ModelSource.path('/models/mmproj-asr.gguf'),
        download: download,
      );

      expect(backend.modelPath, '/cache/asr.gguf');
      expect(backend.projectorPath, '/models/mmproj-asr.gguf');
      expect(manager.remoteOptions('asr.gguf'), [same(download)]);
      expect(manager.localOptions, isNotEmpty);
      for (final options in manager.localOptions) {
        expect(options.bearerToken, isNull);
        expect(options.cacheDirectory, isNull);
        expect(options.cancelToken, same(token));
      }
      expect(verified, isTrue);
      await engine.dispose();
    });

    test('gives a remote projector the load options and a local model only '
        'the cancel token', () async {
      final download = ModelLoadOptions(cacheDirectory: '/models');

      final engine = await load(
        ModelSource.path('/models/asr.gguf'),
        ModelSource.parse('https://models.example.com/mmproj-asr.gguf'),
        download: download,
      );

      expect(backend.modelPath, '/models/asr.gguf');
      expect(backend.projectorPath, '/cache/mmproj-asr.gguf');
      expect(manager.remoteOptions('mmproj-asr.gguf'), [same(download)]);
      expect(manager.localOptions, isNotEmpty);
      for (final options in manager.localOptions) {
        expect(options.cacheDirectory, isNull);
      }
      await engine.dispose();
    });

    test('never sends credentials to a second host', () async {
      await expectLater(
        load(
          ModelSource.parse('https://models.example.com/asr.gguf'),
          ModelSource.parse('https://other.example.com/mmproj-asr.gguf'),
          download: ModelLoadOptions(bearerToken: 'secret'),
        ),
        throwsA(
          isA<LlamaArgumentException>().having(
            (error) => error.message,
            'message',
            allOf(contains('other.example.com'), isNot(contains('secret'))),
          ),
        ),
      );
      expect(manager.calls, isEmpty);
      expect(backend.modelPath, isNull);
      expect(backend.disposeCalls, 1);
    });

    test('a load cancelled while the projector loads stops before verify '
        'and is disposed', () async {
      final token = ModelDownloadCancelToken();
      backend.onProjectorLoad = token.cancel;

      await expectLater(
        load(
          ModelSource.path('/models/asr.gguf'),
          ModelSource.path('/models/mmproj-asr.gguf'),
          download: ModelLoadOptions(cancelToken: token),
        ),
        throwsA(
          isA<LlamaStateException>().having(
            (error) => error.message,
            'message',
            'SpeechToTextEngine model loading was cancelled.',
          ),
        ),
      );
      expect(backend.projectorPath, '/models/mmproj-asr.gguf');
      expect(verified, isFalse);
      expect(backend.disposeCalls, 1);
    });

    test('remote LoRA adapters without their own options take only the '
        'non-secret load options', () async {
      final token = ModelDownloadCancelToken();
      final own = ModelLoadOptions(bearerToken: 'adapter-token');

      final engine = await load(
        ModelSource.path('/models/asr.gguf'),
        null,
        download: ModelLoadOptions(
          bearerToken: 'secret',
          cacheDirectory: '/models',
          maxRetries: 7,
          cancelToken: token,
        ),
        params: ModelParams(
          loras: [
            LoraAdapterConfig.source(
              ModelSource.parse('https://models.example.com/inherits.gguf'),
            ),
            LoraAdapterConfig.source(
              ModelSource.parse('https://adapters.example.com/own.gguf'),
              download: own,
            ),
            LoraAdapterConfig.source(ModelSource.path('/models/local.gguf')),
          ],
        ),
      );

      final inherited = manager.remoteOptions('inherits.gguf').single;
      expect(inherited.bearerToken, isNull);
      expect(inherited.cacheDirectory, '/models');
      expect(inherited.maxRetries, 7);
      expect(inherited.cancelToken, same(token));
      final ownOptions = manager.remoteOptions('own.gguf').single;
      expect(ownOptions.bearerToken, 'adapter-token');
      expect(ownOptions.cacheDirectory, isNull);
      for (final options in manager.localOptions) {
        expect(options.cacheDirectory, isNull);
        expect(options.cancelToken, same(token));
      }
      expect(backend.modelParams!.loras.map((lora) => lora.path), [
        '/cache/inherits.gguf',
        '/cache/own.gguf',
        '/models/local.gguf',
      ]);
      await engine.dispose();
    });
  });
}

class _LoaderBackend extends MockLlamaBackend {
  ModelParams? modelParams;
  void Function()? onProjectorLoad;

  String? get modelPath => lastModelPath;

  String? get projectorPath => lastMultimodalProjectorPath;

  @override
  Future<int> modelLoad(String path, ModelParams params) {
    modelParams = params;
    return super.modelLoad(path, params);
  }

  @override
  Future<int?> multimodalContextCreate(int modelHandle, String mmProjPath) {
    onProjectorLoad?.call();
    return super.multimodalContextCreate(modelHandle, mmProjPath);
  }
}

class _FakeDownloadManager implements ModelDownloadManager {
  final List<(ModelSource, ModelLoadOptions)> calls =
      <(ModelSource, ModelLoadOptions)>[];

  List<ModelLoadOptions> remoteOptions(String fileName) => [
    for (final (source, options) in calls)
      if (source.isRemote && source.fileName == fileName) options,
  ];

  List<ModelLoadOptions> get localOptions => [
    for (final (source, options) in calls)
      if (source.isLocal) options,
  ];

  @override
  Future<ModelCacheEntry> ensureModel(
    ModelSource source, {
    ModelLoadOptions options = ModelLoadOptions.defaults,
    ModelDownloadProgressCallback? onProgress,
  }) async {
    calls.add((source, options));
    final fileName = source.fileName;
    final now = DateTime.utc(2026);
    return ModelCacheEntry(
      sourceCanonicalKey: fileName,
      cacheKey: fileName,
      fileName: fileName,
      filePath: source.path ?? '/cache/$fileName',
      createdAt: now,
      updatedAt: now,
      bytes: 100,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
