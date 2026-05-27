@TestOn('vm')
library;

import 'dart:io';
import 'dart:isolate';

import 'package:llamadart/src/backends/litert_lm/worker.dart';
import 'package:llamadart/llamadart.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late File modelFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'llamadart_litert_worker_test_',
    );
    modelFile = File('${tempDir.path}/model.litertlm');
    await modelFile.writeAsString('fake model');
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('liteRtLmWorkerEntry function is available', () {
    expect(liteRtLmWorkerEntry, isA<Function>());
  });

  group('liteRtLmWorkerEntry isolate routing', () {
    test('handles control and info requests', () async {
      final worker = await _spawnWorker();

      try {
        final logResponse = await _sendRequest(
          worker.sendPort,
          (sendPort) => LiteRtLmLogLevelRequest(LlamaLogLevel.info, sendPort),
        );
        expect(logResponse, isA<LiteRtLmDoneResponse>());

        final backendInfo = await _sendRequest(
          worker.sendPort,
          LiteRtLmBackendInfoRequest.new,
        );
        expect(backendInfo, isA<LiteRtLmBackendInfoResponse>());

        final available = await _sendRequest(
          worker.sendPort,
          LiteRtLmAvailableBackendsRequest.new,
        );
        expect(available, isA<LiteRtLmBackendInfoResponse>());

        final resolved = await _sendRequest(
          worker.sendPort,
          LiteRtLmResolvedGpuLayersRequest.new,
        );
        expect(resolved, isA<LiteRtLmResolvedGpuLayersResponse>());

        final gpuSupport = await _sendRequest(
          worker.sendPort,
          LiteRtLmGpuSupportRequest.new,
        );
        expect(gpuSupport, isA<LiteRtLmGpuSupportResponse>());

        final systemInfo = await _sendRequest(
          worker.sendPort,
          LiteRtLmSystemInfoRequest.new,
        );
        expect(systemInfo, isA<LiteRtLmSystemInfoResponse>());
      } finally {
        await _disposeWorker(worker);
      }
    });

    test('loads model metadata without touching generation runtime', () async {
      final worker = await _spawnWorker();

      try {
        final modelLoad = await _sendRequest(
          worker.sendPort,
          (sendPort) => LiteRtLmModelLoadRequest(
            modelFile.path,
            const ModelParams(preferredBackend: GpuBackend.cpu),
            sendPort,
          ),
        );
        expect(modelLoad, isA<LiteRtLmHandleResponse>());
        final modelHandle = (modelLoad as LiteRtLmHandleResponse).handle;

        final contextCreate = await _sendRequest(
          worker.sendPort,
          (sendPort) => LiteRtLmContextCreateRequest(
            modelHandle,
            const ModelParams(contextSize: 2048),
            sendPort,
          ),
        );
        expect(contextCreate, isA<LiteRtLmHandleResponse>());
        final contextHandle = (contextCreate as LiteRtLmHandleResponse).handle;

        final contextSize = await _sendRequest(
          worker.sendPort,
          (sendPort) => LiteRtLmGetContextSizeRequest(contextHandle, sendPort),
        );
        expect(
          contextSize,
          isA<LiteRtLmGetContextSizeResponse>().having(
            (response) => response.size,
            'size',
            2048,
          ),
        );

        final metadata = await _sendRequest(
          worker.sendPort,
          (sendPort) => LiteRtLmMetadataRequest(modelHandle, sendPort),
        );
        expect(
          metadata,
          isA<LiteRtLmMetadataResponse>().having(
            (response) => response.metadata,
            'metadata',
            containsPair('general.file_type', 'litertlm'),
          ),
        );

        final template = await _sendRequest(
          worker.sendPort,
          (sendPort) => LiteRtLmChatTemplateRequest(
            modelHandle,
            const [
              {'role': 'user', 'content': 'hello'},
            ],
            null,
            true,
            sendPort,
          ),
        );
        expect(
          template,
          isA<LiteRtLmChatTemplateResponse>().having(
            (response) => response.result,
            'result',
            allOf(contains('hello'), contains('assistant')),
          ),
        );

        final clearLora = await _sendRequest(
          worker.sendPort,
          (sendPort) =>
              LiteRtLmLoraRequest(contextHandle, 'clear', sendPort: sendPort),
        );
        expect(
          clearLora,
          isA<LiteRtLmErrorResponse>().having(
            (response) => response.kind,
            'kind',
            'unsupported',
          ),
        );

        final generate = await _sendRequest(
          worker.sendPort,
          (sendPort) => LiteRtLmGenerateRequest(
            contextHandle,
            'hello',
            const GenerationParams(grammar: 'root ::= "x"'),
            sendPort,
          ),
        );
        expect(
          generate,
          isA<LiteRtLmErrorResponse>().having(
            (response) => response.kind,
            'kind',
            'unsupported',
          ),
        );

        final freeModel = await _sendRequest(
          worker.sendPort,
          (sendPort) => LiteRtLmModelFreeRequest(modelHandle, sendPort),
        );
        expect(freeModel, isA<LiteRtLmDoneResponse>());
      } finally {
        await _disposeWorker(worker);
      }
    });

    test('returns typed error responses for invalid handles', () async {
      final worker = await _spawnWorker();

      try {
        final contextCreate = await _sendRequest(
          worker.sendPort,
          (sendPort) =>
              LiteRtLmContextCreateRequest(-1, const ModelParams(), sendPort),
        );
        expect(
          contextCreate,
          isA<LiteRtLmErrorResponse>().having(
            (response) => response.kind,
            'kind',
            'state',
          ),
        );

        final tokenize = await _sendRequest(
          worker.sendPort,
          (sendPort) => LiteRtLmTokenizeRequest(999, 'text', true, sendPort),
        );
        expect(tokenize, isA<LiteRtLmErrorResponse>());

        final detokenize = await _sendRequest(
          worker.sendPort,
          (sendPort) =>
              LiteRtLmDetokenizeRequest(999, const <int>[1], false, sendPort),
        );
        expect(detokenize, isA<LiteRtLmErrorResponse>());
      } finally {
        await _disposeWorker(worker);
      }
    });
  });
}

Future<({Isolate isolate, SendPort sendPort})> _spawnWorker() async {
  final receivePort = ReceivePort();
  final isolate = await Isolate.spawn(
    liteRtLmWorkerEntry,
    receivePort.sendPort,
  );
  final sendPort = await receivePort.first as SendPort;
  sendPort.send(LiteRtLmWorkerHandshake(LlamaLogLevel.warn));
  return (isolate: isolate, sendPort: sendPort);
}

Future<dynamic> _sendRequest(
  SendPort workerSendPort,
  LiteRtLmWorkerRequest Function(SendPort sendPort) buildRequest,
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
  worker.sendPort.send(LiteRtLmDisposeRequest(responsePort.sendPort));
  await responsePort.first;
  responsePort.close();
  worker.isolate.kill(priority: Isolate.immediate);
}
