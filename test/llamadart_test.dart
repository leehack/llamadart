import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';
import 'package:llamadart/llamadart.dart';
import 'test_helper.dart';

void main() async {
  late File modelFile;
  late LlamaService service;

  setUpAll(() async {
    modelFile = await TestHelper.getTestModel();
    service = LlamaService();
  });

  tearDownAll(() async {
    await service.dispose();
  });

  group('LlamaService Basic Tests', () {
    test('Initialization', () async {
      await service.init(modelFile.path);
      expect(service.isReady, isTrue);
    });

    test('Tokenize and Detokenize', () async {
      const text = "Llamas are great animals.";
      final tokens = await service.tokenize(text);
      expect(tokens, isNotEmpty);

      final detokenized = await service.detokenize(tokens);
      // GGUF models often add BOS, so we check if it contains the original text
      expect(detokenized, contains(text));
    });

    test('Metadata retrieval', () async {
      final modelName = await service.getModelMetadata('general.name');
      expect(modelName, isNotNull);
      print('Model Name: $modelName');

      final allMetadata = await service.getAllMetadata();
      expect(allMetadata, isNotEmpty);
      expect(allMetadata.containsKey('general.architecture'), isTrue);
    });

    test('Generation (Streaming)', () async {
      const prompt = "The story of a small llama:";
      final stream = service.generate(
        prompt,
        params: const GenerationParams(maxTokens: 20),
      );

      final buffer = StringBuffer();
      await for (final token in stream) {
        buffer.write(token);
        if (buffer.length > 50) break; // Early exit for speed
      }

      expect(buffer.toString(), isNotEmpty);
    });

    test('Cancel Generation', () async {
      // Re-initialize with CPU to make it slow enough to cancel
      await service.init(
        modelFile.path,
        modelParams: const ModelParams(gpuLayers: 0),
      );

      const prompt =
          "The story of a llama who wanted to see the entire world and traveled to every continent, meeting many new friends along the way and learning about different cultures:";
      // Set a high maxTokens so it doesn't finish naturally too quickly
      final stream = service.generate(
        prompt,
        params: const GenerationParams(maxTokens: 500),
      );

      int tokenCount = 0;
      final completer = Completer<void>();
      final subscription = stream.listen(
        (token) {
          tokenCount++;
          if (tokenCount == 3) {
            service.cancelGeneration();
          }
        },
        onDone: () {
          if (!completer.isCompleted) completer.complete();
        },
        onError: (e) {
          if (!completer.isCompleted) completer.complete();
        },
      );

      await completer.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () => null,
      );
      await subscription.cancel();

      print('Tokens generated before cancellation (CPU): $tokenCount');
      expect(
        tokenCount,
        lessThan(100),
        reason: "Generation did not stop early enough",
      );

      // Re-init with default (GPU) for subsequent tests
      await service.init(modelFile.path);
    });

    test('Context and Backend Info', () async {
      final backend = await service.getBackendName();
      expect(backend, isNotNull);
      print('Backend: $backend');

      final contextSize = await service.getContextSize();
      expect(contextSize, greaterThan(0));
      print('Context Size: $contextSize');

      const text = "Count these tokens.";
      final count = await service.getTokenCount(text);
      expect(count, greaterThan(0));
    });

    test('LoRA non-existent file', () async {
      await expectLater(
        service.setLoraAdapter('non_existent.lora'),
        throwsA(isA<Exception>()),
      );
    });
  });
}
