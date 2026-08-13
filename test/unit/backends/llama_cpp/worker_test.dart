@TestOn('vm')
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:llamadart/src/backends/backend.dart';
import 'package:llamadart/src/core/models/config/log_level.dart';
import 'package:llamadart/src/core/models/chat/content_part.dart';
import 'package:llamadart/src/core/models/inference/generation_params.dart';
import 'package:llamadart/src/core/models/inference/model_params.dart';
import 'package:llamadart/src/backends/llama_cpp/llama_cpp_service.dart';
import 'package:llamadart/src/backends/llama_cpp/worker.dart';
import 'package:llamadart/src/core/exceptions.dart';
import 'package:test/test.dart';

void main() {
  test('llamaWorkerEntry function is available', () {
    expect(llamaWorkerEntry, isA<Function>());
  });

  group('llamaWorkerEntry isolate routing', () {
    test('handles control and info requests', () async {
      final worker = await _spawnWorker();

      try {
        final logResponse = await _sendRequest(
          worker.sendPort,
          (sendPort) => LogLevelRequest(LlamaLogLevel.info, sendPort),
        );
        expect(logResponse, isA<DoneResponse>());

        final backendInfo = await _sendRequest(
          worker.sendPort,
          BackendInfoRequest.new,
        );
        expect(backendInfo, isA<BackendInfoResponse>());

        final available = await _sendRequest(
          worker.sendPort,
          AvailableBackendsRequest.new,
        );
        expect(available, isA<BackendInfoResponse>());

        final resolved = await _sendRequest(
          worker.sendPort,
          ResolvedGpuLayersRequest.new,
        );
        expect(resolved, isA<ResolvedGpuLayersResponse>());

        final gpuSupport = await _sendRequest(
          worker.sendPort,
          GpuSupportRequest.new,
        );
        expect(gpuSupport, isA<GpuSupportResponse>());

        final systemInfo = await _sendRequest(
          worker.sendPort,
          SystemInfoRequest.new,
        );
        expect(systemInfo, isA<SystemInfoResponse>());
      } finally {
        await _disposeWorker(worker);
      }
    });

    test('returns error responses for invalid handles', () async {
      final worker = await _spawnWorker();

      try {
        final contextCreate = await _sendRequest(
          worker.sendPort,
          (sendPort) => ContextCreateRequest(-1, const ModelParams(), sendPort),
        );
        expect(contextCreate, isA<ErrorResponse>());

        final generate = await _sendRequest(
          worker.sendPort,
          (sendPort) => GenerateRequest(
            -1,
            'hello',
            const GenerationParams(),
            0,
            sendPort,
          ),
        );
        expect(generate, isA<ErrorResponse>());

        final embed = await _sendRequest(
          worker.sendPort,
          (sendPort) => EmbedRequest(-1, 'hello', true, sendPort),
        );
        expect(embed, isA<ErrorResponse>());

        final embedBatch = await _sendRequest(
          worker.sendPort,
          (sendPort) =>
              EmbedBatchRequest(-1, const <String>['a'], true, sendPort),
        );
        expect(embedBatch, isA<ErrorResponse>());

        final chatTemplate = await _sendRequest(
          worker.sendPort,
          (sendPort) => ChatTemplateRequest(
            1,
            const <Map<String, dynamic>>[],
            null,
            true,
            sendPort,
          ),
        );
        expect(chatTemplate, isA<ErrorResponse>());
        expect(
          (chatTemplate as ErrorResponse).message,
          contains('Invalid model handle'),
        );
        expect(chatTemplate.message, contains('1'));
        expect(chatTemplate.message, isNot(contains('not implemented')));

        final tokenize = await _sendRequest(
          worker.sendPort,
          (sendPort) => TokenizeRequest(999, 'text', true, sendPort),
        );
        expect(tokenize, isA<TokenizeResponse>());

        final detokenize = await _sendRequest(
          worker.sendPort,
          (sendPort) => DetokenizeRequest(999, const <int>[1], false, sendPort),
        );
        expect(detokenize, isA<DetokenizeResponse>());
      } finally {
        await _disposeWorker(worker);
      }
    });

    test(
      'preserves unsupported generation errors across worker messages',
      () async {
        final worker = await _startWorkerInCurrentIsolate(
          _UnsupportedGenerationLlamaCppService(),
        );

        try {
          final response = await _sendRequest(
            worker.sendPort,
            (sendPort) => GenerateRequest(
              1,
              'hello',
              const GenerationParams(),
              0,
              sendPort,
            ),
          );

          expect(response, isA<ErrorResponse>());
          final error = response as ErrorResponse;
          expect(error.kind, WorkerErrorKind.unsupported);
          expect(error.message, contains('reasoning-budget wrapper'));
        } finally {
          await _disposeWorker(worker);
        }
      },
    );

    test(
      'preserves inference generation errors across worker messages',
      () async {
        final worker = await _startWorkerInCurrentIsolate(
          _InferenceGenerationLlamaCppService(),
        );

        try {
          final response = await _sendRequest(
            worker.sendPort,
            (sendPort) => GenerateRequest(
              1,
              'hello',
              const GenerationParams(),
              0,
              sendPort,
            ),
          );

          expect(response, isA<ErrorResponse>());
          final error = response as ErrorResponse;
          expect(error.kind, WorkerErrorKind.inference);
          expect(error.message, contains('grammar sampler failed'));
          expect(error.message, contains('native grammar stack exhausted'));
          expect(error.message, isNot(contains('LlamaException:')));
        } finally {
          await _disposeWorker(worker);
        }
      },
    );

    test('routes text-to-speech progress, result, and cancellation', () async {
      final service = _BlockingTextToSpeechService();
      final worker = await _startWorkerInCurrentIsolate(service);
      final responsePort = ReceivePort();
      final responses = <Object>[];
      final resultCompleter = Completer<TextToSpeechResultResponse>();
      final subscription = responsePort.listen((response) {
        if (response is Object) {
          responses.add(response);
        }
        if (response is TextToSpeechResultResponse &&
            !resultCompleter.isCompleted) {
          resultCompleter.complete(response);
        }
      });

      try {
        worker.sendPort.send(
          TextToSpeechSynthesizeRequest(
            2,
            3,
            const BackendTextToSpeechRequest(text: 'Hello.'),
            responsePort.sendPort,
          ),
        );
        await service.synthesisStarted.future;
        worker.sendPort.send(TextToSpeechCancelRequest());
        await service.cancelObserved.future;
        service.releaseSynthesis();

        final result = await resultCompleter.future;
        expect(
          responses.whereType<TextToSpeechProgressResponse>(),
          hasLength(1),
        );
        expect(Float32List.view(result.pcm.materialize()).toList(), <double>[
          0.5,
          -0.5,
        ]);
        expect(service.cancelCalls, 1);
      } finally {
        await subscription.cancel();
        responsePort.close();
        await _disposeWorker(worker);
      }
    });

    test('preserves text-to-speech error categories', () async {
      final cases = <(Object, WorkerErrorKind)>[
        (
          LlamaAudioFormatException('Invalid speaker audio', 'wav'),
          WorkerErrorKind.audioFormat,
        ),
        (
          LlamaTextToSpeechException('Synthesis failed', 'native'),
          WorkerErrorKind.textToSpeech,
        ),
        (
          LlamaSpeechException('Speech failed', 'generic'),
          WorkerErrorKind.speech,
        ),
      ];

      for (final (exception, expectedKind) in cases) {
        final worker = await _startWorkerInCurrentIsolate(
          _ThrowingTextToSpeechService(exception),
        );
        try {
          final response = await _sendRequest(
            worker.sendPort,
            (sendPort) => TextToSpeechSynthesizeRequest(
              2,
              3,
              const BackendTextToSpeechRequest(text: 'Hello.'),
              sendPort,
            ),
          );
          expect(response, isA<ErrorResponse>());
          expect((response as ErrorResponse).kind, expectedKind);
          expect(response.message, isNot(contains('LlamaException:')));
        } finally {
          await _disposeWorker(worker);
        }
      }
    });

    test('waits for active generation before freeing native handles', () async {
      final service = _BlockingLlamaCppService();
      final worker = await _startWorkerInCurrentIsolate(service);

      try {
        final generationPort = ReceivePort();
        worker.sendPort.send(
          GenerateRequest(
            1,
            'hold',
            const GenerationParams(),
            0,
            generationPort.sendPort,
          ),
        );
        await service.generateStarted.future;

        final modelFree = _PendingResponse();
        worker.sendPort.send(ModelFreeRequest(11, modelFree.sendPort));
        final contextFree = _PendingResponse();
        worker.sendPort.send(ContextFreeRequest(22, contextFree.sendPort));
        final multimodalFree = _PendingResponse();
        worker.sendPort.send(
          MultimodalContextFreeRequest(33, multimodalFree.sendPort),
        );

        await Future<void>.delayed(Duration.zero);
        expect(service.freeModelCalls, 0);
        expect(service.freeContextCalls, 0);
        expect(service.freeMultimodalContextCalls, 0);
        await modelFree.expectNoResponse();
        await contextFree.expectNoResponse();
        await multimodalFree.expectNoResponse();

        service.releaseGeneration();

        expect(await modelFree.nextResponse, isA<DoneResponse>());
        expect(await contextFree.nextResponse, isA<DoneResponse>());
        expect(await multimodalFree.nextResponse, isA<DoneResponse>());
        expect(service.freeModelCalls, 1);
        expect(service.freeContextCalls, 1);
        expect(service.freeMultimodalContextCalls, 1);

        await _expectDoneResponse(generationPort);
        modelFree.close();
        contextFree.close();
        multimodalFree.close();
      } finally {
        await _disposeWorker(worker);
      }
    });

    test('waits for active generation before disposing service', () async {
      final service = _BlockingLlamaCppService();
      final worker = await _startWorkerInCurrentIsolate(service);

      final generationPort = ReceivePort();
      worker.sendPort.send(
        GenerateRequest(
          1,
          'hold',
          const GenerationParams(),
          0,
          generationPort.sendPort,
        ),
      );
      await service.generateStarted.future;

      final disposeResponse = _PendingResponse();
      worker.sendPort.send(DisposeRequest(disposeResponse.sendPort));

      await Future<void>.delayed(Duration.zero);
      expect(service.disposeCalls, 0);
      await disposeResponse.expectNoResponse();

      service.releaseGeneration();

      expect(await disposeResponse.nextResponse, isNull);
      expect(service.disposeCalls, 1);
      await _expectDoneResponse(generationPort);
      disposeResponse.close();
    });

    test(
      'dispose times out wedged generation without disposing service',
      () async {
        final service = _BlockingLlamaCppService();
        final worker = await _startWorkerInCurrentIsolate(
          service,
          disposeActiveGenerateTimeout: const Duration(milliseconds: 30),
        );

        final generationPort = ReceivePort();
        final disposeResponse = _PendingResponse();
        try {
          worker.sendPort.send(
            GenerateRequest(
              1,
              'hold',
              const GenerationParams(),
              0,
              generationPort.sendPort,
            ),
          );
          await service.generateStarted.future;

          worker.sendPort.send(DisposeRequest(disposeResponse.sendPort));

          await disposeResponse.expectNoResponse();
          expect(await disposeResponse.nextResponse, isNull);
          expect(service.disposeCalls, 0);

          service.releaseGeneration();
          await _expectDoneResponse(generationPort);
        } finally {
          disposeResponse.close();
          generationPort.close();
        }
      },
    );
  });
}

Future<({Isolate isolate, SendPort sendPort})> _spawnWorker() async {
  final receivePort = ReceivePort();
  final isolate = await Isolate.spawn(llamaWorkerEntry, receivePort.sendPort);
  final sendPort = await receivePort.first as SendPort;
  sendPort.send(WorkerHandshake(LlamaLogLevel.warn));
  return (isolate: isolate, sendPort: sendPort);
}

Future<({Isolate? isolate, SendPort sendPort})> _startWorkerInCurrentIsolate(
  LlamaCppService service, {
  Duration disposeActiveGenerateTimeout = const Duration(seconds: 5),
}) async {
  final receivePort = ReceivePort();
  runLlamaWorkerForTesting(
    receivePort.sendPort,
    service,
    exitOnDispose: false,
    disposeActiveGenerateTimeout: disposeActiveGenerateTimeout,
  );
  final sendPort = await receivePort.first as SendPort;
  receivePort.close();
  sendPort.send(WorkerHandshake(LlamaLogLevel.warn));
  return (isolate: null, sendPort: sendPort);
}

Future<dynamic> _sendRequest(
  SendPort workerSendPort,
  WorkerRequest Function(SendPort sendPort) buildRequest,
) async {
  final responsePort = ReceivePort();
  workerSendPort.send(buildRequest(responsePort.sendPort));
  final response = await responsePort.first;
  responsePort.close();
  return response;
}

Future<void> _disposeWorker(
  ({Isolate? isolate, SendPort sendPort}) worker,
) async {
  final responsePort = ReceivePort();
  worker.sendPort.send(DisposeRequest(responsePort.sendPort));
  await responsePort.first;
  responsePort.close();
  worker.isolate?.kill(priority: Isolate.immediate);
}

Future<void> _expectDoneResponse(ReceivePort responsePort) async {
  final response = await responsePort.first;
  expect(response, isA<DoneResponse>());
  responsePort.close();
}

class _PendingResponse {
  final ReceivePort _port = ReceivePort();
  final Completer<Object?> _nextResponse = Completer<Object?>();
  late final StreamSubscription<Object?> _subscription;

  _PendingResponse() {
    _subscription = _port.listen((response) {
      if (!_nextResponse.isCompleted) {
        _nextResponse.complete(response);
      }
    });
  }

  SendPort get sendPort => _port.sendPort;

  Future<Object?> get nextResponse => _nextResponse.future;

  Future<void> expectNoResponse() async {
    await expectLater(
      _nextResponse.future.timeout(const Duration(milliseconds: 20)),
      throwsA(isA<TimeoutException>()),
    );
  }

  void close() {
    _subscription.cancel();
    _port.close();
  }
}

class _BlockingLlamaCppService extends LlamaCppService {
  final Completer<void> generateStarted = Completer<void>();
  final Completer<void> _releaseGeneration = Completer<void>();
  int freeModelCalls = 0;
  int freeContextCalls = 0;
  int freeMultimodalContextCalls = 0;
  int disposeCalls = 0;

  void releaseGeneration() {
    if (!_releaseGeneration.isCompleted) {
      _releaseGeneration.complete();
    }
  }

  @override
  void initializeBackend() {}

  @override
  void setLogLevel(LlamaLogLevel level) {}

  @override
  Stream<List<int>> generate(
    int contextHandle,
    String prompt,
    GenerationParams params,
    int cancelTokenAddress, {
    List<LlamaContentPart>? parts,
  }) async* {
    if (!generateStarted.isCompleted) {
      generateStarted.complete();
    }
    await _releaseGeneration.future;
  }

  @override
  void freeModel(int modelHandle) {
    freeModelCalls += 1;
  }

  @override
  void freeContext(int contextHandle) {
    freeContextCalls += 1;
  }

  @override
  void freeMultimodalContext(int mmContextHandle) {
    freeMultimodalContextCalls += 1;
  }

  @override
  void dispose() {
    disposeCalls += 1;
  }
}

class _UnsupportedGenerationLlamaCppService extends LlamaCppService {
  @override
  void initializeBackend() {}

  @override
  void setLogLevel(LlamaLogLevel level) {}

  @override
  Stream<List<int>> generate(
    int contextHandle,
    String prompt,
    GenerationParams params,
    int cancelTokenAddress, {
    List<LlamaContentPart>? parts,
  }) async* {
    throw LlamaUnsupportedException(
      'missing reasoning-budget wrapper in this test runtime',
    );
  }

  @override
  void dispose() {}
}

class _BlockingTextToSpeechService extends LlamaCppService {
  final Completer<void> synthesisStarted = Completer<void>();
  final Completer<void> cancelObserved = Completer<void>();
  final Completer<void> _releaseSynthesis = Completer<void>();
  int cancelCalls = 0;

  void releaseSynthesis() {
    if (!_releaseSynthesis.isCompleted) {
      _releaseSynthesis.complete();
    }
  }

  @override
  void initializeBackend() {}

  @override
  void setLogLevel(LlamaLogLevel level) {}

  @override
  Future<BackendTextToSpeechResult> synthesizeTextToSpeech(
    int contextHandle,
    int mmContextHandle,
    BackendTextToSpeechRequest request, {
    void Function(BackendTextToSpeechProgress progress)? onProgress,
  }) async {
    if (!synthesisStarted.isCompleted) {
      synthesisStarted.complete();
    }
    await _releaseSynthesis.future;
    onProgress?.call(
      const BackendTextToSpeechProgress(
        phase: BackendTextToSpeechPhase.generating,
        promptTokensRemaining: 0,
        framesGenerated: 2,
        truncated: false,
      ),
    );
    return BackendTextToSpeechResult(
      samples: Float32List.fromList(<double>[0.5, -0.5]),
      sampleRateHz: 24000,
      channelCount: 1,
      framesGenerated: 2,
      truncated: false,
    );
  }

  @override
  void cancelTextToSpeech() {
    cancelCalls += 1;
    if (!cancelObserved.isCompleted) {
      cancelObserved.complete();
    }
  }

  @override
  void dispose() {}
}

class _ThrowingTextToSpeechService extends LlamaCppService {
  _ThrowingTextToSpeechService(this.exception);

  final Object exception;

  @override
  void initializeBackend() {}

  @override
  void setLogLevel(LlamaLogLevel level) {}

  @override
  Future<BackendTextToSpeechResult> synthesizeTextToSpeech(
    int contextHandle,
    int mmContextHandle,
    BackendTextToSpeechRequest request, {
    void Function(BackendTextToSpeechProgress progress)? onProgress,
  }) async {
    throw exception;
  }

  @override
  void dispose() {}
}

class _InferenceGenerationLlamaCppService extends LlamaCppService {
  @override
  void initializeBackend() {}

  @override
  void setLogLevel(LlamaLogLevel level) {}

  @override
  Stream<List<int>> generate(
    int contextHandle,
    String prompt,
    GenerationParams params,
    int cancelTokenAddress, {
    List<LlamaContentPart>? parts,
  }) async* {
    throw LlamaInferenceException(
      'grammar sampler failed in this test runtime',
      'native grammar stack exhausted',
    );
  }

  @override
  void dispose() {}
}
