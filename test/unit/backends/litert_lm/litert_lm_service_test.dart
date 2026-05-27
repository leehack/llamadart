@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:llamadart/src/backends/litert_lm/litert_lm_service.dart';
import 'package:llamadart/src/core/models/config/gpu_backend.dart';
import 'package:llamadart/src/core/models/inference/generation_params.dart';
import 'package:llamadart/src/core/models/inference/model_params.dart';
import 'package:llamadart/src/experimental/litert_lm/litert_lm_benchmark.dart';
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

  test('latches cancellation while LiteRT-LM client initializes', () async {
    final fakeClient = _FakeLiteRtLmBenchmarkClient(blockInitialize: true);
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
    final fakeClient = _FakeLiteRtLmBenchmarkClient();
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
      expect(service.supportsVision(1), isFalse);
      expect(service.supportsAudio(1), isFalse);
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

class _FakeLiteRtLmBenchmarkClient extends LiteRtLmBenchmarkClient {
  _FakeLiteRtLmBenchmarkClient({bool blockInitialize = false})
    : _initializeBlocker = blockInitialize ? Completer<void>() : null;

  final Completer<void> initializeStarted = Completer<void>();
  final Completer<void> generateStarted = Completer<void>();
  final StreamController<String> generated = StreamController<String>();
  final Completer<void>? _initializeBlocker;
  int createConversationCount = 0;
  int generateCount = 0;
  int cancelCount = 0;

  @override
  Future<void> initialize({
    required String modelPath,
    String backend = 'gpu',
    int maxTokens = 4096,
    int outputTokens = 256,
    int? prefillTokens,
    String? cacheDir,
    bool speculativeDecoding = true,
  }) {
    initializeStarted.complete();
    return _initializeBlocker?.future ?? Future<void>.value();
  }

  void completeInitialize() {
    if (_initializeBlocker != null && !_initializeBlocker.isCompleted) {
      _initializeBlocker.complete();
    }
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
    createConversationCount += 1;
  }

  @override
  Stream<String> generate(String prompt) {
    generateCount += 1;
    if (!generateStarted.isCompleted) {
      generateStarted.complete();
    }
    return generated.stream;
  }

  @override
  LiteRtLmBenchmarkMetrics readMetrics({required int wallMilliseconds}) {
    return LiteRtLmBenchmarkMetrics(
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
    cancelCount += 1;
  }

  @override
  void dispose() {
    if (!generated.isClosed) {
      unawaited(generated.close());
    }
  }
}
