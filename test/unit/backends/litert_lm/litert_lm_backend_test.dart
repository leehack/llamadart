@TestOn('vm')
library;

import 'dart:io';
import 'dart:isolate';

import 'package:llamadart/src/backends/backend.dart';
import 'package:llamadart/src/backends/litert_lm/litert_lm_backend.dart';
import 'package:llamadart/src/backends/litert_lm/worker_messages.dart';
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
    expect(backend, isA<BackendEmbeddingsSupport>());
    expect(backend, isA<BackendStatePersistenceSupport>());
    expect((backend as BackendEmbeddingsSupport).supportsEmbeddings, isFalse);
    expect(
      (backend as BackendStatePersistenceSupport).supportsStatePersistence,
      isFalse,
    );
  });

  test('reports platform default diagnostics before model load', () async {
    final backend = LiteRtLmBackend();

    try {
      final expectedBackend = _expectedAutoLiteRtLmBackend();
      expect(await backend.getBackendName(), 'LiteRT-LM $expectedBackend');
      expect(
        await backend.getResolvedGpuLayers(),
        expectedBackend == 'cpu' ? 0 : ModelParams.maxGpuLayers,
      );
    } finally {
      await backend.dispose();
    }
  });

  test(
    'reports direct preferred backend diagnostics before model load',
    () async {
      final backend = LiteRtLmBackend(preferredBackend: 'cpu');

      try {
        expect(await backend.getBackendName(), 'LiteRT-LM cpu');
        expect(await backend.getResolvedGpuLayers(), 0);
      } finally {
        await backend.dispose();
      }
    },
  );

  test('rejects unavailable direct preferred backend diagnostics', () async {
    final backend = LiteRtLmBackend(preferredBackend: 'npu');

    try {
      if (Platform.isAndroid) {
        expect(await backend.getBackendName(), 'LiteRT-LM npu');
        expect(await backend.getResolvedGpuLayers(), ModelParams.maxGpuLayers);
      } else {
        await expectLater(
          backend.getBackendName(),
          throwsA(
            isA<ArgumentError>().having(
              (error) => error.message.toString(),
              'message',
              contains('not available'),
            ),
          ),
        );
      }
    } finally {
      await backend.dispose();
    }
  });

  test('loads local litertlm model and exposes metadata', () async {
    final backend = LiteRtLmBackend();

    try {
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
    } finally {
      await backend.dispose();
    }
  });

  test('rejects unsupported load and llama.cpp-specific operations', () async {
    final backend = LiteRtLmBackend();
    final wrongFormat = File('${tempDir.path}/model.gguf');
    await wrongFormat.writeAsString('fake model');

    try {
      await expectLater(
        backend.modelLoad(wrongFormat.path, const ModelParams()),
        throwsArgumentError,
      );
      expect(
        () => backend.modelLoadFromUrl(
          'https://example.test/model.litertlm',
          const ModelParams(),
        ),
        throwsUnsupportedError,
      );

      final handle = await backend.modelLoad(
        modelFile.path,
        const ModelParams(),
      );
      final contextHandle = await backend.contextCreate(
        handle,
        const ModelParams(),
      );

      expect(
        () => backend.setLoraAdapter(contextHandle, 'adapter.bin', 1.0),
        throwsUnsupportedError,
      );
      expect(
        () => backend.removeLoraAdapter(contextHandle, 'adapter.bin'),
        throwsUnsupportedError,
      );
      expect(
        () => backend.clearLoraAdapters(contextHandle),
        throwsUnsupportedError,
      );
      await expectLater(
        backend.generate(
          contextHandle,
          'hello',
          const GenerationParams(grammar: 'root ::= "x"'),
        ),
        emitsError(isA<UnsupportedError>()),
      );
    } finally {
      await backend.dispose();
    }
  });

  test(
    'invalid handles fail before touching native LiteRT-LM runtime',
    () async {
      final backend = LiteRtLmBackend();

      try {
        expect(
          () => backend.contextCreate(99, const ModelParams()),
          throwsStateError,
        );
        expect(() => backend.modelMetadata(99), throwsStateError);
        expect(() => backend.getContextSize(99), throwsStateError);
      } finally {
        await backend.dispose();
      }
    },
  );

  test('routes tokenization APIs through the LiteRT-LM worker', () async {
    final worker = _FakeLiteRtLmWorker(
      tokenizeResponse: const <int>[2, 10, 11],
      detokenizeResponse: 'hello',
    );
    final backend = LiteRtLmBackend(initialSendPort: worker.sendPort);

    try {
      expect(await backend.tokenize(42, 'hello', addSpecial: false), [
        2,
        10,
        11,
      ]);
      expect(
        await backend.detokenize(42, const [10, 11], special: true),
        'hello',
      );

      final tokenizeRequest = worker.requests
          .whereType<LiteRtLmTokenizeRequest>()
          .single;
      expect(tokenizeRequest.modelHandle, 42);
      expect(tokenizeRequest.text, 'hello');
      expect(tokenizeRequest.addSpecial, isFalse);

      final detokenizeRequest = worker.requests
          .whereType<LiteRtLmDetokenizeRequest>()
          .single;
      expect(detokenizeRequest.modelHandle, 42);
      expect(detokenizeRequest.tokens, [10, 11]);
      expect(detokenizeRequest.special, isTrue);
    } finally {
      await backend.dispose();
      worker.close();
    }
  });

  test(
    'routes chat template application through the LiteRT-LM worker',
    () async {
      final worker = _FakeLiteRtLmWorker(
        tokenizeResponse: const <int>[],
        detokenizeResponse: '',
        chatTemplateResponse: 'templated',
      );
      final backend = LiteRtLmBackend(initialSendPort: worker.sendPort);

      try {
        expect(
          await backend.applyChatTemplate(
            42,
            const [
              {'role': 'user', 'content': 'hello'},
            ],
            customTemplate: 'custom',
            addAssistant: false,
          ),
          'templated',
        );

        final request = worker.requests
            .whereType<LiteRtLmChatTemplateRequest>()
            .single;
        expect(request.modelHandle, 42);
        expect(request.messages.single, containsPair('content', 'hello'));
        expect(request.customTemplate, 'custom');
        expect(request.addAssistant, isFalse);
      } finally {
        await backend.dispose();
        worker.close();
      }
    },
  );
}

String _expectedAutoLiteRtLmBackend() {
  if (Platform.isAndroid || Platform.isMacOS) {
    return 'gpu';
  }
  return 'cpu';
}

class _FakeLiteRtLmWorker {
  _FakeLiteRtLmWorker({
    required this.tokenizeResponse,
    required this.detokenizeResponse,
    this.chatTemplateResponse = '',
  }) {
    _receivePort.listen(_handleMessage);
  }

  final List<int> tokenizeResponse;
  final String detokenizeResponse;
  final String chatTemplateResponse;
  final ReceivePort _receivePort = ReceivePort();
  final List<Object?> requests = <Object?>[];

  SendPort get sendPort => _receivePort.sendPort;

  void close() {
    _receivePort.close();
  }

  void _handleMessage(Object? message) {
    requests.add(message);
    switch (message) {
      case LiteRtLmTokenizeRequest():
        message.sendPort.send(LiteRtLmTokenizeResponse(tokenizeResponse));
      case LiteRtLmDetokenizeRequest():
        message.sendPort.send(LiteRtLmDetokenizeResponse(detokenizeResponse));
      case LiteRtLmChatTemplateRequest():
        message.sendPort.send(
          LiteRtLmChatTemplateResponse(chatTemplateResponse),
        );
      case LiteRtLmCancelGenerationRequest():
        message.sendPort.send(LiteRtLmDoneResponse());
      case LiteRtLmDisposeRequest():
        message.sendPort.send(LiteRtLmDoneResponse());
      default:
        if (message is LiteRtLmWorkerRequest) {
          message.sendPort.send(
            LiteRtLmErrorResponse(
              'Unexpected fake worker request: ${message.runtimeType}',
              kind: 'state',
            ),
          );
        }
    }
  }
}
