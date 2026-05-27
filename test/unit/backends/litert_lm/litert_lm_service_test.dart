@TestOn('vm')
library;

import 'dart:io';

import 'package:llamadart/src/backends/litert_lm/litert_lm_service.dart';
import 'package:llamadart/src/core/models/config/gpu_backend.dart';
import 'package:llamadart/src/core/models/inference/generation_params.dart';
import 'package:llamadart/src/core/models/inference/model_params.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late File modelFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'llamadart_litert_service_test_',
    );
    modelFile = File('${tempDir.path}/model.litertlm');
    await modelFile.writeAsString('fake model');
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'loads local litertlm bundles without initializing native runtime',
    () async {
      final service = LiteRtLmService();

      try {
        final modelHandle = await service.loadModel(
          modelFile.path,
          const ModelParams(
            contextSize: 2048,
            preferredBackend: GpuBackend.cpu,
          ),
        );
        final contextHandle = service.createContext(
          modelHandle,
          const ModelParams(contextSize: 1024),
        );

        expect(modelHandle, 1);
        expect(contextHandle, 1);
        expect(service.getContextSize(contextHandle), 1024);
        expect(service.getActiveBackendName(), 'LiteRT-LM cpu');
        expect(service.getResolvedGpuLayers(), 0);
        expect(
          service.getMetadata(modelHandle),
          containsPair('general.file_type', 'litertlm'),
        );
        expect(service.getAvailableBackendInfo(), contains('cpu'));

        service.freeContext(contextHandle);
        service.freeModel(modelHandle);
      } finally {
        service.dispose();
      }
    },
  );

  test('exposes Gemma 4 chat template metadata for Gemma 4 bundles', () async {
    final service = LiteRtLmService();
    final gemmaModelFile = File('${tempDir.path}/gemma-4-E2B-it.litertlm');
    await gemmaModelFile.writeAsString('fake model');

    try {
      final modelHandle = await service.loadModel(
        gemmaModelFile.path,
        const ModelParams(contextSize: 2048),
      );
      final metadata = service.getMetadata(modelHandle);

      expect(metadata, containsPair('general.name', 'gemma-4-E2B-it.litertlm'));
      expect(metadata, containsPair('llm.context_length', '2048'));
      expect(metadata['tokenizer.chat_template'], contains('<|turn>'));
      expect(metadata['tokenizer.chat_template'], contains('<turn|>'));
      expect(metadata, containsPair('tokenizer.ggml.eos_token', '<turn|>'));
    } finally {
      service.dispose();
    }
  });

  test(
    'rejects invalid paths and unsupported llama.cpp-specific features',
    () async {
      final service = LiteRtLmService();
      final wrongFormat = File('${tempDir.path}/model.gguf');
      await wrongFormat.writeAsString('fake model');

      try {
        expect(
          () => service.loadModel(
            '/does/not/exist.litertlm',
            const ModelParams(),
          ),
          throwsArgumentError,
        );
        expect(
          () => service.loadModel(wrongFormat.path, const ModelParams()),
          throwsArgumentError,
        );

        final modelHandle = await service.loadModel(
          modelFile.path,
          const ModelParams(),
        );
        final contextHandle = service.createContext(
          modelHandle,
          const ModelParams(),
        );

        expect(
          () => service.tokenize(modelHandle, 'hello', true),
          throwsUnsupportedError,
        );
        expect(
          () => service.detokenize(modelHandle, const <int>[1], false),
          throwsUnsupportedError,
        );
        await expectLater(
          service.generate(
            contextHandle,
            'hello',
            const GenerationParams(grammar: 'root ::= "x"'),
          ),
          emitsError(isA<UnsupportedError>()),
        );
      } finally {
        service.dispose();
      }
    },
  );

  test('reports platform-level capabilities conservatively', () {
    final service = LiteRtLmService();

    try {
      expect(service.getGpuSupport(), Platform.isMacOS || Platform.isAndroid);
      expect(service.getVramInfo(), (total: 0, free: 0));
      expect(service.supportsVision(1), isFalse);
      expect(service.supportsAudio(1), isFalse);
    } finally {
      service.dispose();
    }
  });
}
