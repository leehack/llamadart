@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:llamadart/src/backends/litert_lm/litert_lm_service.dart';
import 'package:llamadart/src/backends/litert_lm/litert_lm_runtime.dart';
import 'package:llamadart/src/core/models/chat/content_part.dart';
import 'package:llamadart/src/core/models/config/flash_attention.dart';
import 'package:llamadart/src/core/models/config/gpu_backend.dart';
import 'package:llamadart/src/core/models/config/kv_cache_type.dart';
import 'package:llamadart/src/core/models/config/log_level.dart';
import 'package:llamadart/src/core/models/config/lora_config.dart';
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

        final uppercaseModelFile = File('${tempDir.path}/MODEL.LITERTLM');
        await uppercaseModelFile.writeAsString('fake model');
        final uppercaseModelHandle = await service.loadModel(
          uppercaseModelFile.path,
          const ModelParams(preferredBackend: GpuBackend.cpu),
        );
        expect(uppercaseModelHandle, isNot(modelHandle));
        expect(
          service.getMetadata(uppercaseModelHandle),
          containsPair('general.name', 'MODEL.LITERTLM'),
        );
        service.freeModel(uppercaseModelHandle);
      } finally {
        service.dispose();
      }
    },
  );

  test('invalidates stale model and context handles after reload', () async {
    final service = LiteRtLmService();
    final secondModelFile = File('${tempDir.path}/second.litertlm');
    await secondModelFile.writeAsString('fake model');

    try {
      final firstModelHandle = await service.loadModel(
        modelFile.path,
        const ModelParams(preferredBackend: GpuBackend.cpu),
      );
      final firstContextHandle = service.createContext(
        firstModelHandle,
        const ModelParams(preferredBackend: GpuBackend.cpu),
      );

      final secondModelHandle = await service.loadModel(
        secondModelFile.path,
        const ModelParams(preferredBackend: GpuBackend.cpu),
      );
      final secondContextHandle = service.createContext(
        secondModelHandle,
        const ModelParams(preferredBackend: GpuBackend.cpu),
      );

      expect(secondModelHandle, isNot(firstModelHandle));
      expect(secondContextHandle, isNot(firstContextHandle));
      expect(() => service.getMetadata(firstModelHandle), throwsStateError);
      expect(
        () => service.getContextSize(firstContextHandle),
        throwsStateError,
      );
      expect(() => service.freeContext(firstContextHandle), throwsStateError);
      expect(() => service.freeModel(firstModelHandle), throwsStateError);
      expect(
        service.getMetadata(secondModelHandle),
        containsPair('general.name', 'second.litertlm'),
      );
      expect(service.getContextSize(secondContextHandle), 4096);
    } finally {
      service.dispose();
    }
  });

  test('exposes Gemma 4 chat template metadata for Gemma 4 bundles', () async {
    final service = LiteRtLmService();
    final gemmaModelFile = File('${tempDir.path}/gemma-4-E2B-it.litertlm');
    await gemmaModelFile.writeAsString('fake model');

    try {
      final modelHandle = await service.loadModel(
        gemmaModelFile.path,
        const ModelParams(
          contextSize: 2048,
          chatTemplate: 'custom {{ message }}',
        ),
      );
      final metadata = service.getMetadata(modelHandle);

      expect(metadata, containsPair('general.name', 'gemma-4-E2B-it.litertlm'));
      expect(metadata, containsPair('llm.context_length', '2048'));
      expect(
        metadata,
        containsPair('tokenizer.chat_template', 'custom {{ message }}'),
      );
      expect(metadata, containsPair('tokenizer.ggml.bos_token', '<bos>'));
      expect(metadata, containsPair('tokenizer.ggml.eos_token', '<turn|>'));
    } finally {
      service.dispose();
    }
  });

  test('exposes the built-in Gemma 4 template when no override is set', () async {
    final service = LiteRtLmService();
    final gemmaModelFile = File('${tempDir.path}/gemma-4-E2B-it.litertlm');
    await gemmaModelFile.writeAsString('fake model');

    try {
      final modelHandle = await service.loadModel(
        gemmaModelFile.path,
        const ModelParams(contextSize: 2048),
      );
      final template = service.getMetadata(
        modelHandle,
      )['tokenizer.chat_template'];

      // The full canonical template renders tool declarations and the thinking
      // channel — unlike the previous stub, which omitted both.
      expect(template, isNotNull);
      expect(template, contains('format_function_declaration'));
      expect(template, contains('<|tool>'));
      expect(template, contains('<|think|>'));
      // The native runtime adds the start token, so the template must not emit
      // its own BOS (which would double it).
      expect(template, isNot(contains('bos_token')));
    } finally {
      service.dispose();
    }
  });

  test('applies chat templates through the Dart template engine', () async {
    final service = LiteRtLmService();
    final gemmaModelFile = File('${tempDir.path}/gemma-4-E2B-it.litertlm');
    await gemmaModelFile.writeAsString('fake model');

    try {
      final modelHandle = await service.loadModel(
        gemmaModelFile.path,
        const ModelParams(contextSize: 2048),
      );

      final rendered = service.applyChatTemplate(modelHandle, const [
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'hello'},
          ],
        },
      ]);

      expect(rendered, contains('<|turn>user\nhello<turn|>'));
      // Thinking is enabled by default: the canonical template emits a
      // `<|think|>` system block and leaves the model turn open.
      expect(rendered, contains('<|turn>system\n<|think|>\n<turn|>'));
      expect(rendered, endsWith('<|turn>model\n'));

      final custom = service.applyChatTemplate(
        modelHandle,
        const [
          {'role': 'user', 'content': 'hello'},
        ],
        customTemplate:
            '{{ messages[0]["role"] }}:{{ messages[0]["content"] }}'
            '{% if add_generation_prompt %}:assistant{% endif %}',
      );
      expect(custom, 'user:hello:assistant');

      expect(
        () => service.applyChatTemplate(modelHandle, const [
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': 'describe this'},
              {
                'type': 'image_url',
                'image_url': {'url': 'file:///tmp/image.png'},
              },
            ],
          },
        ]),
        throwsUnsupportedError,
      );

      final mappedContent = service.applyChatTemplate(modelHandle, const [
        {
          'role': 'user',
          'content': {'type': 'text', 'text': 'mapped'},
        },
        {
          'role': 'user',
          'content': {'type': 'custom', 'value': 7},
        },
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'part'},
            ' tail',
            {'type': 'custom', 'value': 1},
          ],
        },
        {'role': 'user', 'content': 42},
      ]);

      expect(mappedContent, contains('<|turn>user\nmapped<turn|>'));
      expect(
        mappedContent,
        contains('<|turn>user\n{type: custom, value: 7}<turn|>'),
      );
      expect(
        mappedContent,
        contains('<|turn>user\npart tail{type: custom, value: 1}<turn|>'),
      );
      expect(mappedContent, contains('<|turn>user\n42<turn|>'));

      expect(
        () => service.applyChatTemplate(modelHandle, const [
          {
            'role': 'user',
            'content': {'type': 'input_audio', 'data': '...'},
          },
        ]),
        throwsUnsupportedError,
      );
    } finally {
      service.dispose();
    }
  });

  test('resolves LiteRT-LM backend preference from model params', () async {
    final service = LiteRtLmService();

    try {
      var modelHandle = await service.loadModel(
        modelFile.path,
        const ModelParams(),
      );
      expect(
        service.getActiveBackendName(),
        'LiteRT-LM ${_expectedAutoLiteRtLmBackend()}',
      );
      service.freeModel(modelHandle);

      modelHandle = await service.loadModel(
        modelFile.path,
        const ModelParams(preferredBackend: GpuBackend.blas),
      );
      expect(service.getActiveBackendName(), 'LiteRT-LM cpu');
      service.freeModel(modelHandle);

      final gpuLikeBackends = <GpuBackend>[
        GpuBackend.vulkan,
        GpuBackend.metal,
        GpuBackend.cuda,
        GpuBackend.opencl,
        GpuBackend.hip,
      ];
      for (final preferredBackend in gpuLikeBackends) {
        if (service.getAvailableBackendInfo().contains('gpu')) {
          modelHandle = await service.loadModel(
            modelFile.path,
            ModelParams(preferredBackend: preferredBackend),
          );
          expect(service.getActiveBackendName(), 'LiteRT-LM gpu');
          service.freeModel(modelHandle);
        } else {
          expect(
            () => service.loadModel(
              modelFile.path,
              ModelParams(preferredBackend: preferredBackend),
            ),
            throwsArgumentError,
          );
        }
      }

      modelHandle = await service.loadModel(
        modelFile.path,
        const ModelParams(gpuLayers: 0),
      );
      expect(service.getActiveBackendName(), 'LiteRT-LM cpu');
      expect(service.getResolvedGpuLayers(), 0);
      service.freeModel(modelHandle);

      modelHandle = await service.loadModel(
        modelFile.path,
        const ModelParams(),
        backendOverride: ' CPU ',
      );
      expect(service.getActiveBackendName(), 'LiteRT-LM cpu');
      expect(service.getResolvedGpuLayers(), 0);
      service.freeModel(modelHandle);

      modelHandle = await service.loadModel(
        modelFile.path,
        const ModelParams(
          preferredBackend: GpuBackend.metal,
          liteRtLmBackend: LiteRtLmBackendPreference.cpu,
        ),
      );
      expect(service.getActiveBackendName(), 'LiteRT-LM cpu');
      service.freeModel(modelHandle);

      if (service.getAvailableBackendInfo().contains('gpu')) {
        modelHandle = await service.loadModel(
          modelFile.path,
          const ModelParams(liteRtLmBackend: LiteRtLmBackendPreference.gpu),
        );
        expect(service.getActiveBackendName(), 'LiteRT-LM gpu');
        service.freeModel(modelHandle);
      } else {
        expect(
          () => service.loadModel(
            modelFile.path,
            const ModelParams(liteRtLmBackend: LiteRtLmBackendPreference.gpu),
          ),
          throwsArgumentError,
        );
      }

      if (Platform.isAndroid) {
        modelHandle = await service.loadModel(
          modelFile.path,
          const ModelParams(liteRtLmBackend: LiteRtLmBackendPreference.npu),
        );
        expect(service.getActiveBackendName(), 'LiteRT-LM npu');
      } else {
        expect(
          () => service.loadModel(
            modelFile.path,
            const ModelParams(liteRtLmBackend: LiteRtLmBackendPreference.npu),
          ),
          throwsArgumentError,
        );
      }
    } finally {
      service.dispose();
    }
  });

  test('rejects explicit backend changes during context creation', () async {
    final service = LiteRtLmService();

    try {
      final modelHandle = await service.loadModel(
        modelFile.path,
        const ModelParams(gpuLayers: 0),
      );
      final contextHandle = service.createContext(
        modelHandle,
        const ModelParams(gpuLayers: 0),
      );

      expect(service.getActiveBackendName(), 'LiteRT-LM cpu');
      expect(service.getContextSize(contextHandle), 4096);
      service.freeContext(contextHandle);

      if (service.getAvailableBackendInfo().contains('gpu')) {
        expect(
          () => service.createContext(
            modelHandle,
            const ModelParams(liteRtLmBackend: LiteRtLmBackendPreference.gpu),
          ),
          throwsA(
            isA<ArgumentError>().having(
              (error) => error.message.toString(),
              'message',
              allOf(contains('cannot change'), contains('cpu to gpu')),
            ),
          ),
        );
      }

      expect(
        () => service.createContext(
          modelHandle,
          const ModelParams(liteRtLmBackend: LiteRtLmBackendPreference.npu),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message.toString(),
            'message',
            Platform.isAndroid
                ? allOf(contains('cannot change'), contains('cpu to npu'))
                : contains('not available'),
          ),
        ),
      );
    } finally {
      service.dispose();
    }
  });

  test('rejects unsupported LiteRT-LM load-time model params', () async {
    final service = LiteRtLmService();

    try {
      await expectLater(
        () =>
            service.loadModel(modelFile.path, const ModelParams(gpuLayers: 12)),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message.toString(),
            'message',
            contains('gpuLayers=12'),
          ),
        ),
      );

      await expectLater(
        () => service.loadModel(
          modelFile.path,
          const ModelParams(contextSize: 0),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message.toString(),
            'message',
            contains('contextSize=0'),
          ),
        ),
      );

      await expectLater(
        () => service.loadModel(
          modelFile.path,
          const ModelParams(
            gpuLayers: 12,
            liteRtLmBackend: LiteRtLmBackendPreference.gpu,
          ),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message.toString(),
            'message',
            contains('gpuLayers=12'),
          ),
        ),
      );

      await expectLater(
        () => service.loadModel(
          modelFile.path,
          const ModelParams(batchSize: 128, useMlock: true),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message.toString(),
            'message',
            allOf(contains('batchSize'), contains('useMlock')),
          ),
        ),
      );

      await expectLater(
        () => service.loadModel(
          modelFile.path,
          const ModelParams(
            splitMode: ModelSplitMode.none,
            mainGpu: 1,
            loras: [LoraAdapterConfig(path: 'adapter.bin')],
            numberOfThreads: 2,
            numberOfThreadsBatch: 3,
            microBatchSize: 64,
            maxParallelSequences: 2,
            useMmap: false,
            flashAttention: FlashAttention.enabled,
            cacheTypeK: KvCacheType.q8_0,
            cacheTypeV: KvCacheType.q4_0,
            kvUnified: true,
            ropeFrequencyBase: 10000,
            ropeFrequencyScale: 1.0,
          ),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message.toString(),
            'message',
            predicate<String>(
              (message) => const <String>[
                'splitMode',
                'mainGpu',
                'loras',
                'numberOfThreads',
                'numberOfThreadsBatch',
                'microBatchSize',
                'maxParallelSequences',
                'useMmap=false',
                'flashAttention',
                'cacheTypeK',
                'cacheTypeV',
                'kvUnified',
                'ropeFrequencyBase',
                'ropeFrequencyScale',
              ].every(message.contains),
              'contains every unsupported ModelParams field',
            ),
          ),
        ),
      );

      expect(
        () => service.loadModel(
          modelFile.path,
          const ModelParams(),
          backendOverride: 'directml',
        ),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message.toString(),
            'message',
            allOf(contains('must be cpu, gpu, or npu'), contains('directml')),
          ),
        ),
      );

      expect(
        service.getActiveBackendName(),
        'LiteRT-LM ${_expectedAutoLiteRtLmBackend()}',
      );
    } finally {
      service.dispose();
    }
  });

  test('reports platform default backend diagnostics before load', () {
    final service = LiteRtLmService();

    try {
      final expectedBackend = _expectedAutoLiteRtLmBackend();
      expect(service.getActiveBackendName(), 'LiteRT-LM $expectedBackend');
      expect(
        service.getResolvedGpuLayers(),
        expectedBackend == 'cpu' ? 0 : ModelParams.maxGpuLayers,
      );
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
          () => service.handleLora(contextHandle, 'adapter.bin', 1.0, 'set'),
          throwsUnsupportedError,
        );
        expect(
          () =>
              service.handleLora(contextHandle, 'adapter.bin', null, 'remove'),
          throwsUnsupportedError,
        );
        expect(
          () => service.handleLora(contextHandle, null, null, 'clear'),
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

  test('rejects media parts before native runtime initialization', () async {
    final fakeClient = _FakeLiteRtLmRuntimeClient();
    final service = LiteRtLmService(clientFactory: () => fakeClient);

    try {
      final modelHandle = await service.loadModel(
        modelFile.path,
        const ModelParams(preferredBackend: GpuBackend.cpu),
      );
      final contextHandle = service.createContext(
        modelHandle,
        const ModelParams(preferredBackend: GpuBackend.cpu),
      );

      await expectLater(
        service.generate(
          contextHandle,
          'describe',
          const GenerationParams(),
          parts: const [LlamaImageContent(path: '/tmp/image.png')],
        ),
        emitsError(
          isA<UnsupportedError>().having(
            (error) => error.message.toString(),
            'message',
            contains('media parts'),
          ),
        ),
      );

      expect(fakeClient.initializeStarted.isCompleted, isFalse);
      expect(fakeClient.createConversationCount, 0);
      expect(fakeClient.generateCount, 0);
    } finally {
      service.dispose();
    }
  });

  test(
    'allows text parts already represented in the rendered prompt',
    () async {
      final fakeClient = _FakeLiteRtLmRuntimeClient();
      final service = LiteRtLmService(clientFactory: () => fakeClient);

      try {
        final modelHandle = await service.loadModel(
          modelFile.path,
          const ModelParams(preferredBackend: GpuBackend.cpu),
        );
        final contextHandle = service.createContext(
          modelHandle,
          const ModelParams(preferredBackend: GpuBackend.cpu),
        );

        final chunksFuture = service
            .generate(
              contextHandle,
              'hello',
              const GenerationParams(),
              parts: const [LlamaTextContent('hello')],
            )
            .toList();

        await fakeClient.generateStarted.future;
        fakeClient.generated.add('ok');
        await fakeClient.generated.close();

        expect(await chunksFuture, [utf8.encode('ok')]);
        expect(fakeClient.createConversationCount, 1);
        expect(fakeClient.generateCount, 1);
      } finally {
        service.dispose();
      }
    },
  );

  test('passes LiteRT-LM tokenization APIs to the client', () async {
    final fakeClient = _FakeLiteRtLmRuntimeClient()
      ..tokenizeResult = const <int>[2, 10, 11]
      ..detokenizeResult = 'hello';
    final service = LiteRtLmService(clientFactory: () => fakeClient);

    try {
      final modelHandle = await service.loadModel(
        modelFile.path,
        const ModelParams(contextSize: 3072, preferredBackend: GpuBackend.cpu),
      );

      expect(await service.tokenize(modelHandle, 'hello', true), [2, 10, 11]);
      expect(
        await service.detokenize(modelHandle, const [10, 11], false),
        'hello',
      );
      expect(
        () => service.detokenize(modelHandle, const [10, 11], true),
        throwsUnsupportedError,
      );
      expect(fakeClient.lastModelPath, modelFile.path);
      expect(fakeClient.lastBackend, 'cpu');
      expect(fakeClient.lastMaxTokens, 3072);
      expect(fakeClient.lastMinLogLevel, 3);
      expect(fakeClient.lastTokenizeText, 'hello');
      expect(fakeClient.lastTokenizeAddSpecial, isTrue);
      expect(fakeClient.lastDetokenizeTokens, [10, 11]);
    } finally {
      service.dispose();
    }
  });

  test('recovers after replacement client initialization fails', () async {
    final firstClient = _FakeLiteRtLmRuntimeClient()
      ..tokenizeResult = const <int>[1];
    final failingClient = _FakeLiteRtLmRuntimeClient(
      initializeError: StateError('planned initialization failure'),
    );
    final retryClient = _FakeLiteRtLmRuntimeClient()
      ..tokenizeResult = const <int>[3];
    final clients = [firstClient, failingClient, retryClient];
    var nextClient = 0;
    final service = LiteRtLmService(clientFactory: () => clients[nextClient++]);

    try {
      final modelHandle = await service.loadModel(
        modelFile.path,
        const ModelParams(contextSize: 3072, preferredBackend: GpuBackend.cpu),
      );
      final contextHandle = service.createContext(
        modelHandle,
        const ModelParams(contextSize: 3072, preferredBackend: GpuBackend.cpu),
      );

      expect(await service.tokenize(modelHandle, 'first', true), [1]);

      await expectLater(
        service
            .generate(
              contextHandle,
              'hello',
              const GenerationParams(maxTokens: 7),
            )
            .drain<void>(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('planned initialization failure'),
          ),
        ),
      );

      expect(firstClient.disposeCount, 1);
      expect(failingClient.disposeCount, 1);
      expect(await service.tokenize(modelHandle, 'retry', true), [3]);
      expect(retryClient.lastTokenizeText, 'retry');
      expect(nextClient, 3);
    } finally {
      service.dispose();
    }
  });

  test('maps log levels to LiteRT-LM native log levels', () async {
    final fakeClient = _FakeLiteRtLmRuntimeClient()
      ..tokenizeResult = const <int>[1];
    final service = LiteRtLmService(clientFactory: () => fakeClient);

    try {
      service.setLogLevel(LlamaLogLevel.debug);
      final modelHandle = await service.loadModel(
        modelFile.path,
        const ModelParams(preferredBackend: GpuBackend.cpu),
      );

      await service.tokenize(modelHandle, 'hello', false);
      expect(fakeClient.lastMinLogLevel, 1);

      service.setLogLevel(LlamaLogLevel.error);
      expect(fakeClient.lastSetMinLogLevel, 4);

      service.setLogLevel(LlamaLogLevel.none);
      expect(fakeClient.lastSetMinLogLevel, 1000);
    } finally {
      service.dispose();
    }
  });

  test('passes supported LiteRT-LM generation options to the client', () async {
    final fakeClient = _FakeLiteRtLmRuntimeClient();
    final service = LiteRtLmService(clientFactory: () => fakeClient);

    try {
      final modelHandle = await service.loadModel(
        modelFile.path,
        const ModelParams(contextSize: 3072, preferredBackend: GpuBackend.cpu),
      );
      final contextHandle = service.createContext(
        modelHandle,
        const ModelParams(contextSize: 3072, preferredBackend: GpuBackend.cpu),
      );

      final chunks = <List<int>>[];
      final subscription = service
          .generate(
            contextHandle,
            'hello',
            const GenerationParams(
              maxTokens: 7,
              temp: 0.3,
              topK: 5,
              topP: 0.4,
              seed: 123,
              stopSequences: ['STOP'],
            ),
          )
          .listen(chunks.add);

      await fakeClient.generateStarted.future;
      fakeClient.generated.add('alpha STOP hidden');
      await fakeClient.generated.close();
      await subscription.asFuture<void>();

      expect(fakeClient.lastModelPath, modelFile.path);
      expect(fakeClient.lastBackend, 'cpu');
      expect(fakeClient.lastMaxTokens, 3072);
      expect(fakeClient.lastOutputTokens, 7);
      expect(fakeClient.lastTemperature, 0.3);
      expect(fakeClient.lastTopK, 5);
      expect(fakeClient.lastTopP, 0.4);
      expect(fakeClient.lastSeed, 123);
      expect(fakeClient.lastNpuBackend, isFalse);
      expect(utf8.decode(chunks.expand((chunk) => chunk).toList()), 'alpha ');
      expect(fakeClient.cancelCount, 1);
    } finally {
      service.dispose();
    }
  });

  test('buffers stop-sequence tails when no stop is found', () async {
    final fakeClient = _FakeLiteRtLmRuntimeClient();
    final service = LiteRtLmService(clientFactory: () => fakeClient);

    try {
      final modelHandle = await service.loadModel(
        modelFile.path,
        const ModelParams(contextSize: 3072, preferredBackend: GpuBackend.cpu),
      );
      final contextHandle = service.createContext(
        modelHandle,
        const ModelParams(contextSize: 3072, preferredBackend: GpuBackend.cpu),
      );

      final chunks = <List<int>>[];
      final subscription = service
          .generate(
            contextHandle,
            'hello',
            const GenerationParams(stopSequences: ['XYZ']),
          )
          .listen(chunks.add);

      await fakeClient.generateStarted.future;
      fakeClient.generated
        ..add('ab')
        ..add('cd')
        ..add('ef');
      unawaited(fakeClient.generated.close());
      await subscription.asFuture<void>();

      expect(utf8.decode(chunks.expand((chunk) => chunk).toList()), 'abcdef');
      expect(fakeClient.cancelCount, 0);
    } finally {
      service.dispose();
    }
  });

  test('skips empty chunks when no stop sequences are configured', () async {
    final fakeClient = _FakeLiteRtLmRuntimeClient();
    final service = LiteRtLmService(clientFactory: () => fakeClient);

    try {
      final modelHandle = await service.loadModel(
        modelFile.path,
        const ModelParams(contextSize: 3072, preferredBackend: GpuBackend.cpu),
      );
      final contextHandle = service.createContext(
        modelHandle,
        const ModelParams(contextSize: 3072, preferredBackend: GpuBackend.cpu),
      );

      final chunks = <List<int>>[];
      final subscription = service
          .generate(contextHandle, 'hello', const GenerationParams())
          .listen(chunks.add);

      await fakeClient.generateStarted.future;
      fakeClient.generated
        ..add('')
        ..add('visible');
      unawaited(fakeClient.generated.close());
      await subscription.asFuture<void>();

      expect(chunks, hasLength(1));
      expect(utf8.decode(chunks.single), 'visible');
    } finally {
      service.dispose();
    }
  });

  test('stores LiteRT-LM runtime metrics as performance context', () async {
    final fakeClient = _FakeLiteRtLmRuntimeClient()
      ..metrics = const LiteRtLmRuntimeMetrics(
        inputTokens: 8,
        outputTokens: 5,
        timeToFirstTokenSeconds: 0.05,
        initSeconds: 0.25,
        prefillTokensPerSecond: 40,
        decodeTokensPerSecond: 25,
        wallMilliseconds: 123,
      );
    final service = LiteRtLmService(clientFactory: () => fakeClient);

    try {
      final modelHandle = await service.loadModel(
        modelFile.path,
        const ModelParams(contextSize: 3072, preferredBackend: GpuBackend.cpu),
      );
      final contextHandle = service.createContext(
        modelHandle,
        const ModelParams(contextSize: 3072, preferredBackend: GpuBackend.cpu),
      );

      final subscription = service
          .generate(contextHandle, 'hello', const GenerationParams())
          .listen((_) {});

      await fakeClient.generateStarted.future;
      fakeClient.generated.add('done');
      unawaited(fakeClient.generated.close());
      await subscription.asFuture<void>();

      final perf = service.getPerformanceContext(contextHandle);
      expect(perf, isNotNull);
      expect(perf!.loadMs, 250);
      expect(perf.promptEvalMs, 200);
      expect(perf.evalMs, 200);
      expect(perf.promptEvalTokens, 8);
      expect(perf.evalTokens, 5);
      expect(perf.sampleCount, 5);
    } finally {
      service.dispose();
    }
  });

  test('clears performance context when runtime metrics fail', () async {
    final fakeClient = _FakeLiteRtLmRuntimeClient()
      ..metricsError = StateError('metrics unavailable');
    final service = LiteRtLmService(clientFactory: () => fakeClient);

    try {
      final modelHandle = await service.loadModel(
        modelFile.path,
        const ModelParams(contextSize: 3072, preferredBackend: GpuBackend.cpu),
      );
      final contextHandle = service.createContext(
        modelHandle,
        const ModelParams(contextSize: 3072, preferredBackend: GpuBackend.cpu),
      );

      final subscription = service
          .generate(contextHandle, 'hello', const GenerationParams())
          .listen((_) {});

      await fakeClient.generateStarted.future;
      fakeClient.generated.add('done');
      unawaited(fakeClient.generated.close());
      await subscription.asFuture<void>();

      expect(service.getPerformanceContext(contextHandle), isNull);
    } finally {
      service.dispose();
    }
  });

  test(
    'cancels when cancellation is requested after conversation setup',
    () async {
      final fakeClient = _FakeLiteRtLmRuntimeClient();
      final service = LiteRtLmService(clientFactory: () => fakeClient);
      fakeClient.onCreateConversation = service.cancelGeneration;

      try {
        final modelHandle = await service.loadModel(
          modelFile.path,
          const ModelParams(
            contextSize: 3072,
            preferredBackend: GpuBackend.cpu,
          ),
        );
        final contextHandle = service.createContext(
          modelHandle,
          const ModelParams(
            contextSize: 3072,
            preferredBackend: GpuBackend.cpu,
          ),
        );

        final chunks = await service
            .generate(contextHandle, 'hello', const GenerationParams())
            .toList();

        expect(chunks, isEmpty);
        expect(fakeClient.createConversationCount, 1);
        expect(fakeClient.generateCount, 0);
        expect(fakeClient.cancelCount, 2);
      } finally {
        service.dispose();
      }
    },
  );

  test('maxTokens less than one is a no-op and clears metrics', () async {
    final fakeClient = _FakeLiteRtLmRuntimeClient();
    final service = LiteRtLmService(clientFactory: () => fakeClient);

    try {
      final modelHandle = await service.loadModel(
        modelFile.path,
        const ModelParams(contextSize: 3072, preferredBackend: GpuBackend.cpu),
      );
      final contextHandle = service.createContext(
        modelHandle,
        const ModelParams(contextSize: 3072, preferredBackend: GpuBackend.cpu),
      );

      final firstSubscription = service
          .generate(
            contextHandle,
            'hello',
            const GenerationParams(maxTokens: 2, stopSequences: ['STOP']),
          )
          .listen((_) {});

      await fakeClient.generateStarted.future;
      fakeClient.generated.add('alpha STOP hidden');
      await fakeClient.generated.close();
      await firstSubscription.asFuture<void>();

      expect(service.getPerformanceContext(contextHandle), isNotNull);
      expect(fakeClient.lastOutputTokens, 2);
      expect(fakeClient.createConversationCount, 1);
      expect(fakeClient.generateCount, 1);

      final zeroChunks = await service
          .generate(
            contextHandle,
            'should not run',
            const GenerationParams(maxTokens: 0),
          )
          .toList();
      final negativeChunks = await service
          .generate(
            contextHandle,
            'should not run either',
            const GenerationParams(maxTokens: -1),
          )
          .toList();

      expect(zeroChunks, isEmpty);
      expect(negativeChunks, isEmpty);
      expect(service.getPerformanceContext(contextHandle), isNull);
      expect(fakeClient.lastOutputTokens, 2);
      expect(fakeClient.createConversationCount, 1);
      expect(fakeClient.generateCount, 1);
    } finally {
      service.dispose();
    }
  });

  test(
    'freeContext disposes runtime client and clears context metrics',
    () async {
      final firstClient = _FakeLiteRtLmRuntimeClient();
      final secondClient = _FakeLiteRtLmRuntimeClient()
        ..tokenizeResult = const <int>[42];
      final clients = <_FakeLiteRtLmRuntimeClient>[firstClient, secondClient];
      var nextClient = 0;
      final service = LiteRtLmService(
        clientFactory: () => clients[nextClient++],
      );

      try {
        final modelHandle = await service.loadModel(
          modelFile.path,
          const ModelParams(
            contextSize: 3072,
            preferredBackend: GpuBackend.cpu,
          ),
        );
        final contextHandle = service.createContext(
          modelHandle,
          const ModelParams(
            contextSize: 3072,
            preferredBackend: GpuBackend.cpu,
          ),
        );

        final subscription = service
            .generate(
              contextHandle,
              'hello',
              const GenerationParams(stopSequences: ['STOP']),
            )
            .listen((_) {});
        await firstClient.generateStarted.future;
        firstClient.generated.add('done STOP hidden');
        await subscription.asFuture<void>();

        expect(service.getPerformanceContext(contextHandle), isNotNull);

        service.freeContext(contextHandle);
        expect(firstClient.disposeCount, 1);

        final nextContextHandle = service.createContext(
          modelHandle,
          const ModelParams(
            contextSize: 3072,
            preferredBackend: GpuBackend.cpu,
          ),
        );
        expect(nextContextHandle, isNot(contextHandle));
        expect(service.getPerformanceContext(nextContextHandle), isNull);
        expect(await service.tokenize(modelHandle, 'after-free', true), [42]);
        expect(secondClient.lastTokenizeText, 'after-free');
        expect(nextClient, 2);
      } finally {
        service.dispose();
      }
    },
  );

  test(
    'createContext disposes pre-context runtime client and applies params',
    () async {
      final firstClient = _FakeLiteRtLmRuntimeClient()
        ..tokenizeResult = const <int>[1];
      final secondClient = _FakeLiteRtLmRuntimeClient()
        ..tokenizeResult = const <int>[2];
      final clients = <_FakeLiteRtLmRuntimeClient>[firstClient, secondClient];
      var nextClient = 0;
      final service = LiteRtLmService(
        clientFactory: () => clients[nextClient++],
      );

      try {
        final modelHandle = await service.loadModel(
          modelFile.path,
          const ModelParams(
            contextSize: 2048,
            preferredBackend: GpuBackend.cpu,
          ),
        );

        expect(await service.tokenize(modelHandle, 'before-context', true), [
          1,
        ]);
        expect(firstClient.lastMaxTokens, 2048);

        final contextHandle = service.createContext(
          modelHandle,
          const ModelParams(
            contextSize: 4096,
            preferredBackend: GpuBackend.cpu,
          ),
        );

        expect(firstClient.disposeCount, 1);
        expect(service.getContextSize(contextHandle), 4096);
        expect(await service.tokenize(modelHandle, 'after-context', true), [2]);
        expect(secondClient.lastTokenizeText, 'after-context');
        expect(secondClient.lastMaxTokens, 4096);
        expect(nextClient, 2);
      } finally {
        service.dispose();
      }
    },
  );

  test(
    'recreating context disposes previous runtime client and metrics',
    () async {
      final firstClient = _FakeLiteRtLmRuntimeClient();
      final secondClient = _FakeLiteRtLmRuntimeClient()
        ..tokenizeResult = const <int>[7];
      final clients = <_FakeLiteRtLmRuntimeClient>[firstClient, secondClient];
      var nextClient = 0;
      final service = LiteRtLmService(
        clientFactory: () => clients[nextClient++],
      );

      try {
        final modelHandle = await service.loadModel(
          modelFile.path,
          const ModelParams(
            contextSize: 3072,
            preferredBackend: GpuBackend.cpu,
          ),
        );
        final firstContextHandle = service.createContext(
          modelHandle,
          const ModelParams(
            contextSize: 3072,
            preferredBackend: GpuBackend.cpu,
          ),
        );

        final subscription = service
            .generate(
              firstContextHandle,
              'hello',
              const GenerationParams(stopSequences: ['STOP']),
            )
            .listen((_) {});
        await firstClient.generateStarted.future;
        firstClient.generated.add('done STOP hidden');
        await subscription.asFuture<void>();

        expect(service.getPerformanceContext(firstContextHandle), isNotNull);

        final secondContextHandle = service.createContext(
          modelHandle,
          const ModelParams(
            contextSize: 3072,
            preferredBackend: GpuBackend.cpu,
          ),
        );

        expect(secondContextHandle, isNot(firstContextHandle));
        expect(firstClient.disposeCount, 1);
        expect(
          () => service.getPerformanceContext(firstContextHandle),
          throwsStateError,
        );
        expect(service.getPerformanceContext(secondContextHandle), isNull);
        expect(await service.tokenize(modelHandle, 'after-recreate', true), [
          7,
        ]);
        expect(secondClient.lastTokenizeText, 'after-recreate');
        expect(nextClient, 2);
      } finally {
        service.dispose();
      }
    },
  );

  test('rejects unsupported LiteRT-LM generation params', () async {
    final service = LiteRtLmService();

    try {
      final modelHandle = await service.loadModel(
        modelFile.path,
        const ModelParams(),
      );
      final contextHandle = service.createContext(
        modelHandle,
        const ModelParams(),
      );

      await expectLater(
        service.generate(
          contextHandle,
          'hello',
          const GenerationParams(minP: 0.1),
        ),
        emitsError(
          isA<UnsupportedError>().having(
            (error) => error.message.toString(),
            'message',
            contains('minP'),
          ),
        ),
      );

      await expectLater(
        service.generate(
          contextHandle,
          'hello',
          const GenerationParams(
            penalty: 1.0,
            grammarLazy: true,
            grammarTriggers: [
              GenerationGrammarTrigger(type: 0, value: '<tool_call>'),
            ],
            preservedTokens: ['<tool_call>'],
            grammarRoot: 'tool_call',
          ),
        ),
        emitsError(
          isA<UnsupportedError>().having(
            (error) => error.message.toString(),
            'message',
            allOf(
              contains('penalty'),
              contains('grammarLazy'),
              contains('grammarTriggers'),
              contains('preservedTokens'),
              contains('grammarRoot'),
            ),
          ),
        ),
      );
    } finally {
      service.dispose();
    }
  });

  test('latches cancellation while LiteRT-LM client initializes', () async {
    final fakeClient = _FakeLiteRtLmRuntimeClient(blockInitialize: true);
    final service = LiteRtLmService(clientFactory: () => fakeClient);

    try {
      final modelHandle = await service.loadModel(
        modelFile.path,
        const ModelParams(),
      );
      final contextHandle = service.createContext(
        modelHandle,
        const ModelParams(),
      );

      final chunks = <List<int>>[];
      final subscription = service
          .generate(contextHandle, 'hello', const GenerationParams())
          .listen(chunks.add);

      await fakeClient.initializeStarted.future;
      service.cancelGeneration();
      fakeClient.completeInitialize();
      await subscription.asFuture<void>();

      expect(chunks, isEmpty);
      expect(fakeClient.createConversationCount, 0);
      expect(fakeClient.generateCount, 0);
    } finally {
      service.dispose();
    }
  });

  test('suppresses late blocking response after cancellation', () async {
    final fakeClient = _FakeLiteRtLmRuntimeClient();
    final service = LiteRtLmService(clientFactory: () => fakeClient);

    try {
      final modelHandle = await service.loadModel(
        modelFile.path,
        const ModelParams(),
      );
      final contextHandle = service.createContext(
        modelHandle,
        const ModelParams(),
      );

      final chunks = <List<int>>[];
      final subscription = service
          .generate(contextHandle, 'hello', const GenerationParams())
          .listen(chunks.add);

      await fakeClient.generateStarted.future;
      service.cancelGeneration();
      fakeClient.generated.add('late response');
      await fakeClient.generated.close();
      await subscription.asFuture<void>();

      expect(chunks, isEmpty);
      expect(fakeClient.createConversationCount, 1);
      expect(fakeClient.cancelCount, 1);
    } finally {
      service.dispose();
    }
  });

  test('reports platform-level capabilities conservatively', () {
    final service = LiteRtLmService();

    try {
      expect(service.getGpuSupport(), Platform.isMacOS || Platform.isAndroid);
      expect(service.getVramInfo(), (total: 0, free: 0));
      expect(() => service.freeMultimodalContext(1), throwsUnsupportedError);
      expect(() => service.supportsVision(1), throwsUnsupportedError);
      expect(() => service.supportsAudio(1), throwsUnsupportedError);
    } finally {
      service.dispose();
    }
  });
}

String _expectedAutoLiteRtLmBackend() {
  if (Platform.isAndroid || Platform.isMacOS) {
    return 'gpu';
  }
  return 'cpu';
}

class _FakeLiteRtLmRuntimeClient extends LiteRtLmRuntimeClient {
  _FakeLiteRtLmRuntimeClient({
    bool blockInitialize = false,
    this.initializeError,
  }) : _initializeBlocker = blockInitialize ? Completer<void>() : null;

  final Completer<void> initializeStarted = Completer<void>();
  final Completer<void> generateStarted = Completer<void>();
  final StreamController<String> generated = StreamController<String>();
  final Completer<void>? _initializeBlocker;
  final Object? initializeError;
  String? lastModelPath;
  String? lastBackend;
  int? lastMaxTokens;
  int? lastOutputTokens;
  String? lastCacheDir;
  bool? lastSpeculativeDecoding;
  int? lastMinLogLevel;
  int? lastSetMinLogLevel;
  double? lastTemperature;
  int? lastTopK;
  double? lastTopP;
  int? lastSeed;
  bool? lastNpuBackend;
  String? lastTokenizeText;
  bool? lastTokenizeAddSpecial;
  List<int>? lastDetokenizeTokens;
  List<int> tokenizeResult = const <int>[];
  String detokenizeResult = '';
  LiteRtLmRuntimeMetrics? metrics;
  Object? metricsError;
  void Function()? onCreateConversation;
  int createConversationCount = 0;
  int generateCount = 0;
  int cancelCount = 0;
  int disposeCount = 0;

  @override
  Future<void> initialize({
    required String modelPath,
    String backend = 'gpu',
    int maxTokens = 4096,
    int outputTokens = 256,
    int? prefillTokens,
    String? cacheDir,
    bool speculativeDecoding = true,
    int minLogLevel = 3,
  }) {
    lastModelPath = modelPath;
    lastBackend = backend;
    lastMaxTokens = maxTokens;
    lastOutputTokens = outputTokens;
    lastCacheDir = cacheDir;
    lastSpeculativeDecoding = speculativeDecoding;
    lastMinLogLevel = minLogLevel;
    if (!initializeStarted.isCompleted) {
      initializeStarted.complete();
    }
    final error = initializeError;
    if (error != null) {
      throw error;
    }
    return _initializeBlocker?.future ?? Future<void>.value();
  }

  void completeInitialize() {
    if (_initializeBlocker != null && !_initializeBlocker.isCompleted) {
      _initializeBlocker.complete();
    }
  }

  @override
  void setMinLogLevel(int level) {
    _checkNotDisposed();
    lastSetMinLogLevel = level;
  }

  @override
  void createConversation({
    String? systemMessage,
    double temperature = 0.8,
    int topK = 40,
    double topP = 0.95,
    int seed = 1,
    bool npuBackend = false,
  }) {
    _checkNotDisposed();
    lastTemperature = temperature;
    lastTopK = topK;
    lastTopP = topP;
    lastSeed = seed;
    lastNpuBackend = npuBackend;
    createConversationCount += 1;
    onCreateConversation?.call();
  }

  @override
  List<int> tokenize(String text, {bool addSpecial = true}) {
    _checkNotDisposed();
    lastTokenizeText = text;
    lastTokenizeAddSpecial = addSpecial;
    return tokenizeResult;
  }

  @override
  String detokenize(List<int> tokens) {
    _checkNotDisposed();
    lastDetokenizeTokens = List<int>.from(tokens);
    return detokenizeResult;
  }

  @override
  Stream<String> generate(String prompt) {
    _checkNotDisposed();
    generateCount += 1;
    if (!generateStarted.isCompleted) {
      generateStarted.complete();
    }
    return generated.stream;
  }

  @override
  LiteRtLmRuntimeMetrics readMetrics({required int wallMilliseconds}) {
    _checkNotDisposed();
    final error = metricsError;
    if (error != null) {
      throw error;
    }
    final currentMetrics = metrics;
    if (currentMetrics != null) {
      return LiteRtLmRuntimeMetrics(
        inputTokens: currentMetrics.inputTokens,
        outputTokens: currentMetrics.outputTokens,
        timeToFirstTokenSeconds: currentMetrics.timeToFirstTokenSeconds,
        initSeconds: currentMetrics.initSeconds,
        prefillTokensPerSecond: currentMetrics.prefillTokensPerSecond,
        decodeTokensPerSecond: currentMetrics.decodeTokensPerSecond,
        wallMilliseconds: wallMilliseconds,
      );
    }
    return LiteRtLmRuntimeMetrics(
      inputTokens: 0,
      outputTokens: 0,
      timeToFirstTokenSeconds: null,
      initSeconds: null,
      prefillTokensPerSecond: null,
      decodeTokensPerSecond: null,
      wallMilliseconds: wallMilliseconds,
    );
  }

  @override
  void cancel() {
    _checkNotDisposed();
    cancelCount += 1;
  }

  @override
  void dispose() {
    disposeCount += 1;
    if (!generated.isClosed) {
      unawaited(generated.close());
    }
  }

  void _checkNotDisposed() {
    if (disposeCount > 0) {
      throw StateError('Fake LiteRT-LM client has been disposed.');
    }
  }
}
