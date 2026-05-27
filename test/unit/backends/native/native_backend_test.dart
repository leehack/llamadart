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
import 'package:llamadart/src/core/models/inference/generation_params.dart';
import 'package:llamadart/src/core/models/inference/model_params.dart';
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

  test(
    'high-level engine rejects tokenization APIs for litertlm bundles',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'llamadart_native_auto_token_litert_',
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
          engine.tokenize('hello'),
          throwsA(isA<LlamaUnsupportedException>()),
        );
        await expectLater(
          engine.detokenize([1, 2, 3]),
          throwsA(isA<LlamaUnsupportedException>()),
        );
        await expectLater(
          engine.getTokenCount('hello'),
          throwsA(isA<LlamaUnsupportedException>()),
        );
      } finally {
        await engine.dispose();
        await tempDir.delete(recursive: true);
      }
    },
  );

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
  final List<LlamaLogLevel> logLevels = <LlamaLogLevel>[];
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
