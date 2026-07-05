@TestOn('vm')
library;

import 'dart:isolate';

import 'package:llamadart/src/core/models/config/log_level.dart';
import 'package:llamadart/src/core/models/inference/generation_params.dart';
import 'package:llamadart/src/core/models/inference/model_params.dart';
import 'package:llamadart/src/backends/llama_cpp/worker.dart';
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
  });
}

Future<({Isolate isolate, SendPort sendPort})> _spawnWorker() async {
  final receivePort = ReceivePort();
  final isolate = await Isolate.spawn(llamaWorkerEntry, receivePort.sendPort);
  final sendPort = await receivePort.first as SendPort;
  sendPort.send(WorkerHandshake(LlamaLogLevel.warn));
  return (isolate: isolate, sendPort: sendPort);
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
  ({Isolate isolate, SendPort sendPort}) worker,
) async {
  final responsePort = ReceivePort();
  worker.sendPort.send(DisposeRequest(responsePort.sendPort));
  await responsePort.first;
  responsePort.close();
  worker.isolate.kill(priority: Isolate.immediate);
}
