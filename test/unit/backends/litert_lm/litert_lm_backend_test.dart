@TestOn('vm')
library;

import 'dart:io';

import 'package:llamadart/src/backends/backend.dart';
import 'package:llamadart/src/backends/litert_lm/litert_lm_backend.dart';
import 'package:llamadart/src/core/models/config/gpu_backend.dart';
import 'package:llamadart/src/core/models/inference/generation_params.dart';
import 'package:llamadart/src/core/models/inference/model_params.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late File modelFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('llamadart_litert_test_');
    modelFile = File('${tempDir.path}/model.litertlm');
    await modelFile.writeAsString('fake model');
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('implements backend diagnostics contracts', () {
    final backend = LiteRtLmBackend();

    expect(backend, isA<LlamaBackend>());
    expect(backend, isA<BackendAvailability>());
    expect(backend, isA<BackendRuntimeDiagnostics>());
    expect(backend, isA<BackendPerformanceDiagnostics>());
  });

  test('loads local litertlm model and exposes metadata', () async {
    final backend = LiteRtLmBackend();

    final handle = await backend.modelLoad(
      modelFile.path,
      const ModelParams(preferredBackend: GpuBackend.cpu),
    );
    final contextHandle = await backend.contextCreate(
      handle,
      const ModelParams(),
    );

    expect(handle, 1);
    expect(contextHandle, 1);
    expect(backend.isReady, isTrue);
    expect(await backend.getContextSize(contextHandle), 4096);
    expect(await backend.getBackendName(), 'LiteRT-LM cpu');
    expect(await backend.getResolvedGpuLayers(), 0);
    expect(
      await backend.modelMetadata(handle),
      containsPair('general.file_type', 'litertlm'),
    );

    await backend.modelFree(handle);
    expect(backend.isReady, isFalse);
  });

  test('rejects unsupported load and llama.cpp-specific operations', () async {
    final backend = LiteRtLmBackend();
    final wrongFormat = File('${tempDir.path}/model.gguf');
    await wrongFormat.writeAsString('fake model');

    expect(
      () => backend.modelLoad(wrongFormat.path, const ModelParams()),
      throwsArgumentError,
    );
    expect(
      () => backend.modelLoadFromUrl(
        'https://example.test/model.litertlm',
        const ModelParams(),
      ),
      throwsUnsupportedError,
    );

    final handle = await backend.modelLoad(modelFile.path, const ModelParams());
    final contextHandle = await backend.contextCreate(
      handle,
      const ModelParams(),
    );

    expect(() => backend.tokenize(handle, 'hello'), throwsUnsupportedError);
    expect(
      () => backend
          .generate(
            contextHandle,
            'hello',
            const GenerationParams(grammar: 'root ::= "x"'),
          )
          .drain<void>(),
      throwsUnsupportedError,
    );
  });

  test(
    'invalid handles fail before touching native LiteRT-LM runtime',
    () async {
      final backend = LiteRtLmBackend();

      expect(
        () => backend.contextCreate(99, const ModelParams()),
        throwsStateError,
      );
      expect(() => backend.modelMetadata(99), throwsStateError);
      expect(() => backend.getContextSize(99), throwsStateError);
    },
  );
}
