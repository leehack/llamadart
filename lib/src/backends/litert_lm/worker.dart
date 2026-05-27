import 'dart:async';
import 'dart:isolate';

import '../native_token_stream_batcher.dart';
import 'litert_lm_service.dart';
import 'worker_messages.dart';

export 'worker_messages.dart';

/// Entry point for the LiteRT-LM worker isolate.
void liteRtLmWorkerEntry(SendPort initialSendPort) {
  final receivePort = ReceivePort();
  initialSendPort.send(receivePort.sendPort);

  final service = LiteRtLmService();
  Future<void>? activeGeneration;

  receivePort.listen((message) async {
    if (message is LiteRtLmDisposeRequest) {
      service.cancelGeneration();
      try {
        await activeGeneration?.timeout(const Duration(seconds: 5));
      } on TimeoutException {
        // Teardown continues below; the isolate is exited after the response.
      } catch (_) {
        // Generation errors are reported to the original generation listener.
      }
      try {
        service.dispose();
      } catch (_) {
        // Ignore errors during dispose.
      }
      message.sendPort.send(LiteRtLmDoneResponse());
      receivePort.close();
      Isolate.exit();
    }

    if (message is LiteRtLmWorkerHandshake) {
      service.setLogLevel(message.initialLogLevel);
      return;
    }

    if (message is! LiteRtLmWorkerRequest) {
      return;
    }

    if (message is LiteRtLmCancelGenerationRequest) {
      service.cancelGeneration();
      message.sendPort.send(LiteRtLmDoneResponse());
      return;
    }

    final currentGeneration = activeGeneration;
    if (currentGeneration != null) {
      if (message is LiteRtLmGenerateRequest) {
        message.sendPort.send(
          LiteRtLmErrorResponse(
            'LiteRT-LM generation is already in progress.',
            kind: 'state',
          ),
        );
        return;
      }
      await currentGeneration;
    }

    try {
      switch (message) {
        case LiteRtLmModelLoadRequest():
          final handle = await service.loadModel(
            message.modelPath,
            message.modelParams,
            backendOverride: message.backendOverride,
          );
          message.sendPort.send(LiteRtLmHandleResponse(handle));

        case LiteRtLmModelFreeRequest():
          service.freeModel(message.modelHandle);
          message.sendPort.send(LiteRtLmDoneResponse());

        case LiteRtLmContextCreateRequest():
          final handle = service.createContext(
            message.modelHandle,
            message.params,
          );
          message.sendPort.send(LiteRtLmHandleResponse(handle));

        case LiteRtLmContextFreeRequest():
          service.freeContext(message.contextHandle);
          message.sendPort.send(LiteRtLmDoneResponse());

        case LiteRtLmGenerateRequest():
          final generationCompleter = Completer<void>();
          activeGeneration = generationCompleter.future;
          try {
            final stream = service.generate(
              message.contextHandle,
              message.prompt,
              message.params,
              parts: message.parts,
            );
            final batcher = NativeTokenStreamBatcher(
              tokenThreshold: message.params.streamBatchTokenThreshold,
              byteThreshold: message.params.streamBatchByteThreshold,
            );

            await for (final tokens in stream) {
              final readyChunks = batcher.add(tokens);
              for (final chunk in readyChunks) {
                message.sendPort.send(LiteRtLmTokenResponse(chunk));
              }
            }

            final finalChunk = batcher.flush();
            if (finalChunk != null) {
              message.sendPort.send(LiteRtLmTokenResponse(finalChunk));
            }

            message.sendPort.send(LiteRtLmDoneResponse());
          } catch (error) {
            message.sendPort.send(LiteRtLmErrorResponse.from(error));
          } finally {
            generationCompleter.complete();
            if (identical(activeGeneration, generationCompleter.future)) {
              activeGeneration = null;
            }
          }

        case LiteRtLmTokenizeRequest():
          final tokens = service.tokenize(
            message.modelHandle,
            message.text,
            message.addSpecial,
          );
          message.sendPort.send(LiteRtLmTokenizeResponse(tokens));

        case LiteRtLmDetokenizeRequest():
          final text = service.detokenize(
            message.modelHandle,
            message.tokens,
            message.special,
          );
          message.sendPort.send(LiteRtLmDetokenizeResponse(text));

        case LiteRtLmMetadataRequest():
          final metadata = service.getMetadata(message.modelHandle);
          message.sendPort.send(LiteRtLmMetadataResponse(metadata));

        case LiteRtLmLoraRequest():
          service.handleLora(
            message.contextHandle,
            message.path,
            message.scale,
            message.op,
          );
          message.sendPort.send(LiteRtLmDoneResponse());

        case LiteRtLmBackendInfoRequest():
          final info = service.getActiveBackendName();
          message.sendPort.send(LiteRtLmBackendInfoResponse(info));

        case LiteRtLmAvailableBackendsRequest():
          final info = service.getAvailableBackendInfo();
          message.sendPort.send(LiteRtLmBackendInfoResponse(info.join(', ')));

        case LiteRtLmResolvedGpuLayersRequest():
          final layers = service.getResolvedGpuLayers();
          message.sendPort.send(LiteRtLmResolvedGpuLayersResponse(layers));

        case LiteRtLmPerformanceContextRequest():
          final perf = service.getPerformanceContext(message.contextHandle);
          if (perf == null) {
            message.sendPort.send(LiteRtLmDoneResponse());
          } else {
            message.sendPort.send(
              LiteRtLmPerformanceContextResponse(
                loadMs: perf.loadMs,
                promptEvalMs: perf.promptEvalMs,
                evalMs: perf.evalMs,
                sampleMs: perf.sampleMs,
                promptEvalTokens: perf.promptEvalTokens,
                evalTokens: perf.evalTokens,
                sampleCount: perf.sampleCount,
                reusedGraphs: perf.reusedGraphs,
              ),
            );
          }

        case LiteRtLmGpuSupportRequest():
          final supports = service.getGpuSupport();
          message.sendPort.send(LiteRtLmGpuSupportResponse(supports));

        case LiteRtLmLogLevelRequest():
          service.setLogLevel(message.logLevel);
          message.sendPort.send(LiteRtLmDoneResponse());

        case LiteRtLmGetContextSizeRequest():
          final size = service.getContextSize(message.contextHandle);
          message.sendPort.send(LiteRtLmGetContextSizeResponse(size));

        case LiteRtLmMultimodalContextCreateRequest():
          final handle = service.createMultimodalContext(
            message.modelHandle,
            message.mmProjPath,
          );
          message.sendPort.send(LiteRtLmHandleResponse(handle));

        case LiteRtLmMultimodalContextFreeRequest():
          service.freeMultimodalContext(message.mmContextHandle);
          message.sendPort.send(LiteRtLmDoneResponse());

        case LiteRtLmSupportsVisionRequest():
          final supported = service.supportsVision(message.mmContextHandle);
          message.sendPort.send(supported);

        case LiteRtLmSupportsAudioRequest():
          final supported = service.supportsAudio(message.mmContextHandle);
          message.sendPort.send(supported);

        case LiteRtLmSystemInfoRequest():
          final info = service.getVramInfo();
          message.sendPort.send(
            LiteRtLmSystemInfoResponse(info.total, info.free),
          );

        case LiteRtLmChatTemplateRequest():
          final result = service.applyChatTemplate(
            message.modelHandle,
            message.messages,
            customTemplate: message.customTemplate,
            addAssistant: message.addAssistant,
          );
          message.sendPort.send(LiteRtLmChatTemplateResponse(result));
      }
    } catch (error) {
      message.sendPort.send(LiteRtLmErrorResponse.from(error));
    }
  });
}
