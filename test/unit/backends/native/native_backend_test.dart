@TestOn('vm')
library;

import 'dart:io';

import 'package:llamadart/src/backends/backend.dart';
import 'package:llamadart/src/backends/native/native_backend.dart';
import 'package:llamadart/src/core/engine/engine.dart';
import 'package:llamadart/src/core/exceptions.dart';
import 'package:llamadart/src/core/models/chat/chat_message.dart';
import 'package:llamadart/src/core/models/chat/chat_role.dart';
import 'package:llamadart/src/core/models/config/gpu_backend.dart';
import 'package:llamadart/src/core/models/config/log_level.dart';
import 'package:llamadart/src/core/models/download/model_download_manager.dart';
import 'package:llamadart/src/core/models/inference/generation_params.dart';
import 'package:llamadart/src/core/models/inference/model_params.dart';
import 'package:llamadart/src/core/models/model_load_options.dart';
import 'package:llamadart/src/core/models/model_source.dart';
import 'package:llamadart/src/core/template/chat_format.dart';
import 'package:test/test.dart';

void main() {
  test('default native backend factory returns the format router', () async {
    final backend = LlamaBackend();

    try {
      expect(backend, isA<NativeAutoBackend>());
      expect(await backend.getBackendName(), 'Native auto');
      expect(backend.supportsUrlLoading, isFalse);
    } finally {
      await backend.dispose();
    }
  });

  test('routes GGUF and unknown formats to llama.cpp', () async {
    final llama = _FakeBackend(handle: 11);
    final litert = _FakeBackend(handle: 22);
    final backend = NativeAutoBackend(
      llamaCppFactory: () => llama,
      liteRtLmFactory: () => litert,
    );

    try {
      await backend.setLogLevel(LlamaLogLevel.debug);

      expect(
        await backend.modelLoad(
          '/models/gemma-4-E2B-it-Q4_K_S.gguf',
          const ModelParams(),
        ),
        11,
      );
      expect(llama.loadedPaths, ['/models/gemma-4-E2B-it-Q4_K_S.gguf']);
      expect(llama.logLevels, [LlamaLogLevel.debug]);
      expect(litert.loadedPaths, isEmpty);

      expect(
        await backend.modelLoad('/models/model.bin', const ModelParams()),
        11,
      );
      expect(llama.loadedPaths, [
        '/models/gemma-4-E2B-it-Q4_K_S.gguf',
        '/models/model.bin',
      ]);
      expect(llama.disposeCount, 0);
    } finally {
      await backend.dispose();
    }
  });

  test(
    'routes litertlm bundles to LiteRT-LM and disposes switched delegate',
    () async {
      final llama = _FakeBackend(handle: 11);
      final litert = _FakeBackend(handle: 22);
      final backend = NativeAutoBackend(
        llamaCppFactory: () => llama,
        liteRtLmFactory: () => litert,
      );

      try {
        await backend.modelLoad('/models/model.gguf', const ModelParams());
        expect(llama.loadedPaths, ['/models/model.gguf']);

        expect(
          await backend.modelLoad(
            '/models/gemma-4-E2B-it.litertlm',
            const ModelParams(),
          ),
          22,
        );
        expect(llama.disposeCount, 1);
        expect(litert.loadedPaths, ['/models/gemma-4-E2B-it.litertlm']);
        expect(await backend.getBackendName(), 'fake-22');
      } finally {
        await backend.dispose();
      }
    },
  );

  test('forwards LiteRT-LM backend preference through the router', () async {
    final llama = _FakeBackend(handle: 11);
    final litert = _FakeBackend(handle: 22);
    final backend = NativeAutoBackend(
      llamaCppFactory: () => llama,
      liteRtLmFactory: () => litert,
    );

    try {
      await backend.modelLoad(
        '/models/gemma-4-E2B-it.litertlm',
        const ModelParams(liteRtLmBackend: LiteRtLmBackendPreference.npu),
      );

      expect(litert.loadedPaths, ['/models/gemma-4-E2B-it.litertlm']);
      expect(
        litert.loadedParams.single.liteRtLmBackend,
        LiteRtLmBackendPreference.npu,
      );
      expect(llama.loadedPaths, isEmpty);
    } finally {
      await backend.dispose();
    }
  });

  test(
    'loadModelSource downloads litertlm bundles and routes them to LiteRT-LM',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'llamadart_native_auto_litert_source_',
      );
      final modelFile = File('${tempDir.path}/gemma-4-E2B-it.litertlm');
      await modelFile.writeAsString('fake model');

      final source = ModelSource.parse(
        'hf://litert-community/gemma-4-E2B-it-litert-lm/gemma-4-E2B-it.litertlm',
      );
      final entry = ModelCacheEntry(
        sourceCanonicalKey: source.metadataSourceKey,
        cacheKey: source.cacheKey,
        fileName: source.fileName,
        filePath: modelFile.path,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
        bytes: await modelFile.length(),
      );
      final downloadManager = _FakeModelDownloadManager(entry);
      final llama = _FakeBackend(handle: 11);
      final litert = _FakeBackend(handle: 22);
      final backend = NativeAutoBackend(
        llamaCppFactory: () => llama,
        liteRtLmFactory: () => litert,
      );
      final engine = LlamaEngine(
        backend,
        modelDownloadManager: downloadManager,
      );
      final options = ModelLoadOptions(
        cachePolicy: ModelCachePolicy.refresh,
        bearerToken: 'secret-token',
      );

      try {
        await engine.loadModelSource(
          source,
          modelParams: const ModelParams(
            liteRtLmBackend: LiteRtLmBackendPreference.npu,
          ),
          options: options,
        );

        expect(downloadManager.ensureModelCalls, 1);
        expect(downloadManager.lastSource?.resolvedUri, source.resolvedUri);
        expect(downloadManager.lastSource?.fileName, 'gemma-4-E2B-it.litertlm');
        expect(downloadManager.lastOptions, same(options));
        expect(llama.loadedPaths, isEmpty);
        expect(litert.loadedPaths, [modelFile.path]);
        expect(
          litert.loadedParams.single.liteRtLmBackend,
          LiteRtLmBackendPreference.npu,
        );
        expect(
          litert.contextParams.single.liteRtLmBackend,
          LiteRtLmBackendPreference.npu,
        );
        expect(engine.isReady, isTrue);
      } finally {
        await engine.dispose();
        await tempDir.delete(recursive: true);
      }
    },
  );

  test('high-level engine loads litertlm with the default backend', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'llamadart_native_auto_litert_',
    );
    final modelFile = File('${tempDir.path}/model.litertlm');
    await modelFile.writeAsString('fake model');
    final engine = LlamaEngine(LlamaBackend());

    try {
      await engine.loadModel(
        modelFile.path,
        modelParams: const ModelParams(preferredBackend: GpuBackend.cpu),
      );

      expect(await engine.getBackendName(), 'LiteRT-LM cpu');
      expect(engine.isReady, isTrue);
    } finally {
      await engine.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test('high-level engine routes uppercase litertlm extensions', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'llamadart_native_auto_litert_upper_',
    );
    final modelFile = File('${tempDir.path}/MODEL.LITERTLM');
    await modelFile.writeAsString('fake model');
    final engine = LlamaEngine(LlamaBackend());

    try {
      await engine.loadModel(
        modelFile.path,
        modelParams: const ModelParams(preferredBackend: GpuBackend.cpu),
      );

      expect(await engine.getBackendName(), 'LiteRT-LM cpu');
      expect((await engine.getMetadata())['general.name'], 'MODEL.LITERTLM');
    } finally {
      await engine.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'high-level engine applies Gemma 4 template for litertlm bundles',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'llamadart_native_auto_gemma4_litert_',
      );
      final modelFile = File('${tempDir.path}/gemma-4-E2B-it.litertlm');
      await modelFile.writeAsString('fake model');
      final engine = LlamaEngine(LlamaBackend());

      try {
        await engine.loadModel(
          modelFile.path,
          modelParams: const ModelParams(preferredBackend: GpuBackend.cpu),
        );

        final metadata = await engine.getMetadata();
        expect(metadata['tokenizer.chat_template'], contains('<|turn>'));

        final template = await engine.chatTemplate(const [
          LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'hi'),
        ], includeTokenCount: false);

        expect(template.format, ChatFormat.gemma4.index);
        expect(template.prompt, contains('<|turn>user\nhi<turn|>'));
        expect(template.prompt, endsWith('<|turn>model\n'));
      } finally {
        await engine.dispose();
        await tempDir.delete(recursive: true);
      }
    },
  );

  test('high-level engine rejects unsupported litertlm load params', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'llamadart_native_auto_load_params_litert_',
    );
    final modelFile = File('${tempDir.path}/gemma-4-E2B-it.litertlm');
    await modelFile.writeAsString('fake model');
    final engine = LlamaEngine(LlamaBackend());

    try {
      await expectLater(
        () => engine.loadModel(
          modelFile.path,
          modelParams: const ModelParams(
            preferredBackend: GpuBackend.cpu,
            batchSize: 128,
          ),
        ),
        throwsA(
          isA<LlamaModelException>().having(
            (error) => error.details.toString(),
            'details',
            contains('batchSize'),
          ),
        ),
      );
      expect(engine.isReady, isFalse);
    } finally {
      await engine.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'high-level engine rejects LoRA operations for litertlm bundles',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'llamadart_native_auto_lora_litert_',
      );
      final modelFile = File('${tempDir.path}/gemma-4-E2B-it.litertlm');
      await modelFile.writeAsString('fake model');
      final engine = LlamaEngine(LlamaBackend());

      try {
        await engine.loadModel(
          modelFile.path,
          modelParams: const ModelParams(preferredBackend: GpuBackend.cpu),
        );

        await expectLater(
          engine.setLora('adapter.bin'),
          throwsA(isA<LlamaUnsupportedException>()),
        );
        await expectLater(
          engine.removeLora('adapter.bin'),
          throwsA(isA<LlamaUnsupportedException>()),
        );
        await expectLater(
          engine.clearLoras(),
          throwsA(isA<LlamaUnsupportedException>()),
        );
      } finally {
        await engine.dispose();
        await tempDir.delete(recursive: true);
      }
    },
  );

  test('high-level engine delegates litertlm tokenization APIs', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'llamadart_native_auto_token_litert_',
    );
    final modelFile = File('${tempDir.path}/gemma-4-E2B-it.litertlm');
    await modelFile.writeAsString('fake model');
    final litert = _FakeBackend(handle: 22)
      ..tokenizeResult = const <int>[2, 10, 11]
      ..detokenizeResult = 'hello';
    final backend = NativeAutoBackend(
      llamaCppFactory: () => _FakeBackend(handle: 11),
      liteRtLmFactory: () => litert,
    );
    final engine = LlamaEngine(backend);

    try {
      await engine.loadModel(
        modelFile.path,
        modelParams: const ModelParams(preferredBackend: GpuBackend.cpu),
      );

      expect(await engine.tokenize('hello'), [2, 10, 11]);
      expect(await engine.detokenize([10, 11]), 'hello');
      expect(await engine.getTokenCount('hello'), 3);
      expect(litert.lastTokenizeText, 'hello');
      expect(litert.lastTokenizeAddSpecial, isFalse);
      expect(litert.lastDetokenizeTokens, [10, 11]);
    } finally {
      await engine.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'high-level engine reports embeddings unsupported for litertlm bundles',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'llamadart_native_auto_embed_litert_',
      );
      final modelFile = File('${tempDir.path}/gemma-4-E2B-it.litertlm');
      await modelFile.writeAsString('fake model');
      final backend = LlamaBackend();
      final engine = LlamaEngine(backend);

      try {
        await engine.loadModel(
          modelFile.path,
          modelParams: const ModelParams(preferredBackend: GpuBackend.cpu),
        );

        expect(backend, isA<BackendEmbeddingsSupport>());
        expect(
          (backend as BackendEmbeddingsSupport).supportsEmbeddings,
          isFalse,
        );
        await expectLater(
          engine.embed('hello'),
          throwsA(isA<LlamaUnsupportedException>()),
        );
        await expectLater(
          engine.embedBatch(['hello']),
          throwsA(isA<LlamaUnsupportedException>()),
        );
      } finally {
        await engine.dispose();
        await tempDir.delete(recursive: true);
      }
    },
  );

  test(
    'high-level engine reports state persistence unsupported for litertlm bundles',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'llamadart_native_auto_state_litert_',
      );
      final modelFile = File('${tempDir.path}/gemma-4-E2B-it.litertlm');
      await modelFile.writeAsString('fake model');
      final engine = LlamaEngine(LlamaBackend());

      try {
        await engine.loadModel(
          modelFile.path,
          modelParams: const ModelParams(preferredBackend: GpuBackend.cpu),
        );

        expect(engine.supportsStatePersistence, isFalse);
        await expectLater(
          engine.stateSaveFile('${tempDir.path}/state.bin', tokens: const []),
          throwsA(isA<LlamaUnsupportedException>()),
        );
        await expectLater(
          engine.stateLoadFile('${tempDir.path}/state.bin', tokenCapacity: 16),
          throwsA(isA<LlamaUnsupportedException>()),
        );
      } finally {
        await engine.dispose();
        await tempDir.delete(recursive: true);
      }
    },
  );

  test(
    'high-level engine rejects multimodal projectors for litertlm bundles',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'llamadart_native_auto_mm_litert_',
      );
      final modelFile = File('${tempDir.path}/gemma-4-E2B-it.litertlm');
      await modelFile.writeAsString('fake model');
      final engine = LlamaEngine(LlamaBackend());

      try {
        await engine.loadModel(
          modelFile.path,
          modelParams: const ModelParams(preferredBackend: GpuBackend.cpu),
        );

        await expectLater(
          engine.loadMultimodalProjector('mmproj.bin'),
          throwsA(isA<LlamaUnsupportedException>()),
        );
      } finally {
        await engine.dispose();
        await tempDir.delete(recursive: true);
      }
    },
  );

  test(
    'high-level engine rejects unsupported litertlm generation options',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'llamadart_native_auto_generate_litert_',
      );
      final modelFile = File('${tempDir.path}/gemma-4-E2B-it.litertlm');
      await modelFile.writeAsString('fake model');
      final engine = LlamaEngine(LlamaBackend());

      try {
        await engine.loadModel(
          modelFile.path,
          modelParams: const ModelParams(preferredBackend: GpuBackend.cpu),
        );

        await expectLater(
          engine
              .generate(
                'hello',
                params: const GenerationParams(grammar: 'root ::= "x"'),
              )
              .join(),
          throwsA(isA<LlamaUnsupportedException>()),
        );
        await expectLater(
          engine
              .generate('hello', params: const GenerationParams(minP: 0.1))
              .join(),
          throwsA(isA<LlamaUnsupportedException>()),
        );
      } finally {
        await engine.dispose();
        await tempDir.delete(recursive: true);
      }
    },
  );
}

class _FakeBackend implements LlamaBackend {
  final int handle;
  final List<String> loadedPaths = <String>[];
  final List<ModelParams> loadedParams = <ModelParams>[];
  final List<ModelParams> contextParams = <ModelParams>[];
  final List<int> freedModels = <int>[];
  final List<int> freedContexts = <int>[];
  final List<LlamaLogLevel> logLevels = <LlamaLogLevel>[];
  List<int> tokenizeResult = const <int>[];
  String detokenizeResult = '';
  String? lastTokenizeText;
  bool? lastTokenizeAddSpecial;
  List<int>? lastDetokenizeTokens;
  int disposeCount = 0;

  _FakeBackend({required this.handle});

  @override
  bool get isReady => loadedPaths.isNotEmpty && disposeCount == 0;

  @override
  bool get supportsUrlLoading => false;

  @override
  Future<int> modelLoad(String path, ModelParams params) async {
    loadedPaths.add(path);
    loadedParams.add(params);
    return handle;
  }

  @override
  Future<void> modelFree(int modelHandle) async {
    freedModels.add(modelHandle);
  }

  @override
  Future<int> contextCreate(int modelHandle, ModelParams params) async {
    contextParams.add(params);
    return handle + 100;
  }

  @override
  Future<void> contextFree(int contextHandle) async {
    freedContexts.add(contextHandle);
  }

  @override
  Future<List<int>> tokenize(
    int modelHandle,
    String text, {
    bool addSpecial = true,
  }) async {
    lastTokenizeText = text;
    lastTokenizeAddSpecial = addSpecial;
    return tokenizeResult;
  }

  @override
  Future<String> detokenize(
    int modelHandle,
    List<int> tokens, {
    bool special = false,
  }) async {
    lastDetokenizeTokens = List<int>.from(tokens);
    return detokenizeResult;
  }

  @override
  Future<String> getBackendName() async => 'fake-$handle';

  @override
  Future<void> setLogLevel(LlamaLogLevel level) async {
    logLevels.add(level);
  }

  @override
  Future<void> dispose() async {
    disposeCount += 1;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeModelDownloadManager implements ModelDownloadManager {
  _FakeModelDownloadManager(this.entry);

  final ModelCacheEntry entry;
  ModelSource? lastSource;
  ModelLoadOptions? lastOptions;
  int ensureModelCalls = 0;

  @override
  Future<ModelCacheEntry> ensureModel(
    ModelSource source, {
    ModelLoadOptions options = ModelLoadOptions.defaults,
    ModelDownloadProgressCallback? onProgress,
  }) async {
    ensureModelCalls += 1;
    lastSource = source;
    lastOptions = options;
    return entry;
  }

  @override
  Future<void> clear({String? cacheDirectory}) async {}

  @override
  Future<ModelCacheEntry?> get(
    String cacheKey, {
    String? cacheDirectory,
  }) async {
    return cacheKey == entry.cacheKey ? entry : null;
  }

  @override
  Future<List<ModelCacheEntry>> list({String? cacheDirectory}) async {
    return <ModelCacheEntry>[entry];
  }

  @override
  Future<List<ModelCacheEntry>> prune({
    Duration? maxAge,
    int? maxBytes,
    String? cacheDirectory,
  }) async {
    return const <ModelCacheEntry>[];
  }

  @override
  Future<void> remove(String cacheKey, {String? cacheDirectory}) async {}
}
