import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_chat_example/models/chat_settings.dart';
import 'package:llamadart_chat_example/services/chat_service.dart';

import 'mocks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ChatService model params', () {
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
    });

    test('bounds automatic Web speech batching', () async {
      if (!kIsWeb) {
        return;
      }
      final engine = MockLlamaEngine();
      final service = ChatService(engine: engine);

      await service.init(
        const ChatSettings(
          modelPath: 'Qwen3-ASR-0.6B-Q8_0.gguf',
          preferredBackend: GpuBackend.cpu,
          contextSize: 4096,
          modelSupportsSpeechToText: true,
        ),
        eagerLoadMultimodalProjector: false,
      );

      expect(engine.lastModelParams!.batchSize, 512);
      expect(engine.lastModelParams!.microBatchSize, 128);
    });

    test(
      'uses less restrictive Android Vulkan batch defaults for Qwen3.5 0.8B',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        final engine = MockLlamaEngine();
        final service = ChatService(engine: engine);

        await service.init(
          const ChatSettings(
            modelPath: 'Qwen3.5-0.8B-Q4_K_M.gguf',
            preferredBackend: GpuBackend.vulkan,
            contextSize: 4096,
            gpuLayers: 99,
          ),
          eagerLoadMultimodalProjector: false,
        );

        expect(engine.lastModelParams, isNotNull);
        expect(engine.lastModelParams!.batchSize, 64);
        expect(engine.lastModelParams!.microBatchSize, 1);
        expect(engine.lastModelParams!.numberOfThreads, 2);
        expect(engine.lastModelParams!.numberOfThreadsBatch, 2);
      },
    );

    test('keeps stricter Android Vulkan defaults for other models', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final engine = MockLlamaEngine();
      final service = ChatService(engine: engine);

      await service.init(
        const ChatSettings(
          modelPath: 'test_model.gguf',
          preferredBackend: GpuBackend.vulkan,
          contextSize: 4096,
          gpuLayers: 99,
        ),
        eagerLoadMultimodalProjector: false,
      );

      expect(engine.lastModelParams, isNotNull);
      expect(engine.lastModelParams!.batchSize, 32);
      expect(engine.lastModelParams!.microBatchSize, 1);
      expect(engine.lastModelParams!.numberOfThreads, 0);
      expect(engine.lastModelParams!.numberOfThreadsBatch, 0);
    });

    test('honors explicit Android Vulkan batch sizes', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final engine = MockLlamaEngine();
      final service = ChatService(engine: engine);

      await service.init(
        const ChatSettings(
          modelPath: 'gemma-4-E2B-it-Q4_K_S.gguf',
          preferredBackend: GpuBackend.vulkan,
          contextSize: 4096,
          gpuLayers: 32,
          batchSize: 128,
          microBatchSize: 16,
        ),
        eagerLoadMultimodalProjector: false,
      );

      expect(engine.lastModelParams!.batchSize, 128);
      expect(engine.lastModelParams!.microBatchSize, 16);
    });

    test(
      'caps an explicit micro-batch to the resolved Android batch',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        final engine = MockLlamaEngine();
        final service = ChatService(engine: engine);

        await service.init(
          const ChatSettings(
            modelPath: 'gemma-4-E2B-it-Q4_K_S.gguf',
            preferredBackend: GpuBackend.vulkan,
            contextSize: 4096,
            gpuLayers: 32,
            microBatchSize: 128,
          ),
          eagerLoadMultimodalProjector: false,
        );

        expect(engine.lastModelParams!.batchSize, 32);
        expect(engine.lastModelParams!.microBatchSize, 32);
      },
    );

    test(
      'keeps roomier Android GPU defaults for non-Vulkan backends',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        final engine = MockLlamaEngine();
        final service = ChatService(engine: engine);

        await service.init(
          const ChatSettings(
            modelPath: 'test_model.gguf',
            preferredBackend: GpuBackend.opencl,
            contextSize: 4096,
            gpuLayers: 32,
          ),
          eagerLoadMultimodalProjector: false,
        );

        expect(engine.lastModelParams, isNotNull);
        expect(engine.lastModelParams!.batchSize, 256);
        expect(engine.lastModelParams!.microBatchSize, 64);
      },
    );

    test('keeps legacy batch defaults for CPU loads', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final engine = MockLlamaEngine();
      final service = ChatService(engine: engine);

      await service.init(
        const ChatSettings(
          modelPath: 'test_model.gguf',
          preferredBackend: GpuBackend.cpu,
          contextSize: 4096,
          gpuLayers: 0,
        ),
        eagerLoadMultimodalProjector: false,
      );

      expect(engine.lastModelParams, isNotNull);
      expect(engine.lastModelParams!.batchSize, 0);
      expect(engine.lastModelParams!.microBatchSize, 0);
      expect(engine.lastModelParams!.numberOfThreads, 0);
      expect(engine.lastModelParams!.numberOfThreadsBatch, 0);
    });

    test('maps the UI Max sentinel to full native GPU offload', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final engine = MockLlamaEngine();
      final service = ChatService(engine: engine);

      await service.init(
        const ChatSettings(
          modelPath: 'gemma-4-31B-it-Q4_K_S.gguf',
          preferredBackend: GpuBackend.metal,
          contextSize: 16384,
          gpuLayers: 99,
        ),
        eagerLoadMultimodalProjector: false,
      );

      expect(engine.lastModelParams, isNotNull);
      expect(engine.lastModelParams!.gpuLayers, ModelParams.maxGpuLayers);
      expect(engine.lastModelParams!.contextSize, 16384);
    });

    test('explicit CPU overrides a stale Max layer value', () async {
      final engine = MockLlamaEngine();
      final service = ChatService(engine: engine);

      await service.init(
        const ChatSettings(
          modelPath: 'model.gguf',
          preferredBackend: GpuBackend.cpu,
          gpuLayers: 99,
        ),
        eagerLoadMultimodalProjector: false,
      );

      expect(engine.lastModelParams!.gpuLayers, 0);
    });

    test(
      'does not apply llama.cpp Android tuning to LiteRT-LM models',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        final engine = MockLlamaEngine();
        final service = ChatService(engine: engine);

        await service.init(
          const ChatSettings(
            modelPath: 'gemma-4-E2B-it.litertlm?download=true',
            preferredBackend: GpuBackend.auto,
            contextSize: 8192,
            gpuLayers: 99,
            numberOfThreads: 8,
            numberOfThreadsBatch: 8,
            batchSize: 256,
            microBatchSize: 64,
          ),
          eagerLoadMultimodalProjector: false,
        );

        expect(engine.lastModelParams, isNotNull);
        expect(engine.lastModelParams!.gpuLayers, ModelParams.maxGpuLayers);
        expect(engine.lastModelParams!.preferredBackend, GpuBackend.auto);
        expect(engine.lastModelParams!.contextSize, 8192);
        expect(engine.lastModelParams!.batchSize, 0);
        expect(engine.lastModelParams!.microBatchSize, 0);
        expect(engine.lastModelParams!.numberOfThreads, 0);
        expect(engine.lastModelParams!.numberOfThreadsBatch, 0);
      },
    );

    test('normalizes LiteRT-LM auto context size to backend default', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final engine = MockLlamaEngine();
      final service = ChatService(engine: engine);

      await service.init(
        const ChatSettings(
          modelPath: 'gemma-4-E2B-it.litertlm',
          preferredBackend: GpuBackend.auto,
          contextSize: 0,
          gpuLayers: 0,
        ),
        eagerLoadMultimodalProjector: false,
      );

      expect(engine.lastModelParams, isNotNull);
      expect(engine.lastModelParams!.contextSize, 4096);
      expect(engine.lastModelParams!.gpuLayers, ModelParams.maxGpuLayers);
      expect(engine.lastModelParams!.preferredBackend, GpuBackend.auto);
    });

    test(
      'keeps LiteRT-LM auto on GPU when saved GPU layers are stale zero',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        final engine = MockLlamaEngine();
        final service = ChatService(engine: engine);

        await service.init(
          const ChatSettings(
            modelPath: 'gemma-4-E2B-it.litertlm',
            preferredBackend: GpuBackend.auto,
            contextSize: 8192,
            maxTokens: 32,
            gpuLayers: 0,
          ),
          eagerLoadMultimodalProjector: false,
        );

        expect(engine.lastModelParams, isNotNull);
        expect(engine.lastModelParams!.gpuLayers, ModelParams.maxGpuLayers);
        expect(engine.lastModelParams!.preferredBackend, GpuBackend.auto);
        expect(engine.createCalls, 1);
        expect(engine.lastCreateParams!.maxTokens, 32);
      },
    );

    test('can skip LiteRT-LM runtime warmup during model load', () async {
      final engine = MockLlamaEngine();
      final service = ChatService(engine: engine);

      await service.init(
        const ChatSettings(
          modelPath: 'gemma-4-E2B-it.litertlm',
          preferredBackend: GpuBackend.auto,
          contextSize: 8192,
          maxTokens: 32,
          gpuLayers: 0,
        ),
        eagerLoadMultimodalProjector: false,
        eagerWarmUpLiteRtLmRuntime: false,
      );

      expect(engine.lastModelParams, isNotNull);
      expect(engine.createCalls, 0);
    });

    test('skips text-only warmup for direct-audio LiteRT-LM models', () async {
      final engine = MockLlamaEngine();
      final service = ChatService(engine: engine);

      await service.init(
        const ChatSettings(
          modelPath: 'gemma-4-E2B-it.litertlm',
          preferredBackend: GpuBackend.auto,
          contextSize: 8192,
          maxTokens: 32,
          gpuLayers: 0,
          modelSupportsAudio: true,
          directMediaInput: true,
        ),
        eagerLoadMultimodalProjector: false,
      );

      expect(engine.lastModelParams, isNotNull);
      expect(engine.createCalls, 0);
    });

    test('keeps explicit CPU loads on LiteRT-LM models', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final engine = MockLlamaEngine();
      final service = ChatService(engine: engine);

      await service.init(
        const ChatSettings(
          modelPath: 'gemma-4-E2B-it.litertlm',
          preferredBackend: GpuBackend.cpu,
          contextSize: 8192,
          gpuLayers: 0,
        ),
        eagerLoadMultimodalProjector: false,
      );

      expect(engine.lastModelParams, isNotNull);
      expect(engine.lastModelParams!.gpuLayers, 0);
      expect(engine.lastModelParams!.preferredBackend, GpuBackend.cpu);
      expect(engine.lastModelParams!.batchSize, 0);
      expect(engine.lastModelParams!.microBatchSize, 0);
    });

    test('uses faster Android CPU thread defaults for Qwen3.5 0.8B', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final engine = MockLlamaEngine();
      final service = ChatService(engine: engine);

      await service.init(
        const ChatSettings(
          modelPath: 'Qwen3.5-0.8B-Q4_K_M.gguf',
          preferredBackend: GpuBackend.cpu,
          contextSize: 4096,
          gpuLayers: 0,
        ),
        eagerLoadMultimodalProjector: false,
      );

      expect(engine.lastModelParams, isNotNull);
      expect(engine.lastModelParams!.batchSize, 0);
      expect(engine.lastModelParams!.microBatchSize, 0);
      expect(engine.lastModelParams!.numberOfThreads, 4);
      expect(engine.lastModelParams!.numberOfThreadsBatch, 4);
    });

    test('releases a partially loaded model after projector failure', () async {
      final engine = _FailingProjectorEngine(Exception('unwind'));
      final service = ChatService(engine: engine);

      await expectLater(
        service.init(
          const ChatSettings(
            modelPath: 'Qwen3-ASR-0.6B-Q8_0.gguf',
            mmprojPath: 'mmproj-Qwen3-ASR-0.6B-Q8_0.gguf',
          ),
        ),
        throwsA(isA<LlamaContextException>()),
      );

      expect(engine.unloadModelCalls, 1);
      expect(engine.initialized, isFalse);
    });

    test('explains Web projector runtime failures', () async {
      if (!kIsWeb) {
        return;
      }
      final engine = _FailingProjectorEngine(Exception('unwind'));
      final service = ChatService(engine: engine);

      await expectLater(
        service.loadMultimodalProjector(
          'https://example.com/mmproj-Qwen3-ASR.gguf',
        ),
        throwsA(
          isA<LlamaContextException>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('WebAssembly memory'),
              contains('Close other tabs'),
              contains('tap Load model again'),
            ),
          ),
        ),
      );
    });
  });
}

class _FailingProjectorEngine extends MockLlamaEngine {
  _FailingProjectorEngine(this.projectorError);

  final Object projectorError;
  int unloadModelCalls = 0;

  @override
  Future<void> loadMultimodalProjector(String mmProjPath) async {
    loadMultimodalProjectorCalls += 1;
    lastLoadedMmprojPath = mmProjPath;
    throw projectorError;
  }

  @override
  Future<void> unloadModel() async {
    unloadModelCalls += 1;
    initialized = false;
  }
}
