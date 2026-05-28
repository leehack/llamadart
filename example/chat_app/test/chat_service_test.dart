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
  });
}
