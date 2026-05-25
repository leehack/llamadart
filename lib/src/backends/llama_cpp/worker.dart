import 'dart:isolate';

import 'llama_cpp_service.dart';
import 'stream_batcher.dart';
import 'worker_messages.dart';

// Re-export messages so native_backend.dart can see them via worker.dart if needed
export 'worker_messages.dart';

/// Entry point for the llama worker isolate.
void llamaWorkerEntry(SendPort initialSendPort) {
  final receivePort = ReceivePort();
  initialSendPort.send(receivePort.sendPort);

  // Service
  final service = LlamaCppService();
  var isInitialized = false;

  receivePort.listen((message) async {
    if (message is DisposeRequest) {
      try {
        service.dispose();
      } catch (e) {
        // Ignore errors during dispose
      }
      message.sendPort.send(null);
      receivePort.close();
      Isolate.exit();
    }

    // Handshake
    if (message is WorkerHandshake) {
      service.setLogLevel(message.initialLogLevel);
      if (!isInitialized) {
        service.initializeBackend();
        isInitialized = true;
      }
      return;
    }

    // Requests
    if (message is WorkerRequest) {
      try {
        switch (message) {
          case ModelLoadRequest():
            final handle = service.loadModel(
              message.modelPath,
              message.modelParams,
            );
            message.sendPort.send(HandleResponse(handle));

          case LogLevelRequest():
            service.setLogLevel(message.logLevel);
            message.sendPort.send(DoneResponse());

          case ModelFreeRequest():
            service.freeModel(message.modelHandle);
            message.sendPort.send(DoneResponse());

          case ContextCreateRequest():
            final handle = service.createContext(
              message.modelHandle,
              message.params,
            );
            message.sendPort.send(HandleResponse(handle));

          case ContextFreeRequest():
            service.freeContext(message.contextHandle);
            message.sendPort.send(DoneResponse());

          case GenerateRequest():
            try {
              final stream = service.generate(
                message.contextHandle,
                message.prompt,
                message.params,
                message.cancelTokenAddress,
                parts: message.parts,
              );

              final batcher = NativeTokenStreamBatcher(
                tokenThreshold: message.params.streamBatchTokenThreshold,
                byteThreshold: message.params.streamBatchByteThreshold,
              );

              await for (final tokens in stream) {
                final readyChunks = batcher.add(tokens);
                for (final chunk in readyChunks) {
                  message.sendPort.send(TokenResponse(chunk));
                }
              }

              final finalChunk = batcher.flush();
              if (finalChunk != null) {
                message.sendPort.send(TokenResponse(finalChunk));
              }

              message.sendPort.send(DoneResponse());
            } catch (e) {
              message.sendPort.send(ErrorResponse(e.toString()));
            }

          case EmbedRequest():
            final embedding = service.embed(
              message.contextHandle,
              message.text,
              normalize: message.normalize,
            );
            message.sendPort.send(EmbedResponse(embedding));

          case EmbedBatchRequest():
            final embeddings = service.embedBatch(
              message.contextHandle,
              message.texts,
              normalize: message.normalize,
            );
            message.sendPort.send(EmbedBatchResponse(embeddings));

          case TokenizeRequest():
            final tokens = service.tokenize(
              message.modelHandle,
              message.text,
              message.addSpecial,
            );
            message.sendPort.send(TokenizeResponse(tokens));

          case DetokenizeRequest():
            final text = service.detokenize(
              message.modelHandle,
              message.tokens,
              message.special,
            );
            message.sendPort.send(DetokenizeResponse(text));

          case MetadataRequest():
            final metadata = service.getMetadata(message.modelHandle);
            message.sendPort.send(MetadataResponse(metadata));

          case LoraRequest():
            service.handleLora(
              message.contextHandle,
              message.path,
              message.scale,
              message.op,
            );
            message.sendPort.send(DoneResponse());

          case BackendInfoRequest():
            final info = service.getActiveBackendName();
            message.sendPort.send(BackendInfoResponse(info));

          case AvailableBackendsRequest():
            final info = service.getAvailableBackendInfo();
            message.sendPort.send(BackendInfoResponse(info.join(", ")));

          case ResolvedGpuLayersRequest():
            final layers = service.getResolvedGpuLayers();
            message.sendPort.send(ResolvedGpuLayersResponse(layers));

          case PerformanceContextRequest():
            final perf = service.getPerformanceContext(message.contextHandle);
            message.sendPort.send(
              PerformanceContextResponse(
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

          case GpuSupportRequest():
            final supports = service.getGpuSupport();
            message.sendPort.send(GpuSupportResponse(supports));

          case MultimodalContextCreateRequest():
            final handle = service.createMultimodalContext(
              message.modelHandle,
              message.mmProjPath,
            );
            message.sendPort.send(HandleResponse(handle));

          case MultimodalContextFreeRequest():
            service.freeMultimodalContext(message.mmContextHandle);
            message.sendPort.send(DoneResponse());

          case GetContextSizeRequest():
            final size = service.getContextSize(message.contextHandle);
            message.sendPort.send(GetContextSizeResponse(size));

          case SupportsVisionRequest():
            final supported = service.supportsVision(message.mmContextHandle);
            message.sendPort.send(supported);

          case SupportsAudioRequest():
            final supported = service.supportsAudio(message.mmContextHandle);
            message.sendPort.send(supported);

          case SystemInfoRequest():
            final info = service.getVramInfo();
            message.sendPort.send(SystemInfoResponse(info.total, info.free));

          case ChatTemplateRequest():
            message.sendPort.send(
              ErrorResponse("Chat template not implemented in service yet"),
            );

          case StateSaveFileRequest():
            final ok = service.stateSaveFile(
              message.contextHandle,
              message.path,
              message.tokens,
            );
            message.sendPort.send(StateSaveFileResponse(ok));

          case StateLoadFileRequest():
            final tokens = service.stateLoadFile(
              message.contextHandle,
              message.path,
              message.tokenCapacity,
            );
            message.sendPort.send(StateLoadFileResponse(tokens));
        }
      } catch (e) {
        message.sendPort.send(ErrorResponse(e.toString()));
      }
    }
  });
}
