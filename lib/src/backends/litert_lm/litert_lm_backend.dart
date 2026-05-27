import 'dart:async';
import 'dart:isolate';

import '../../core/models/chat/content_part.dart';
import '../../core/models/config/log_level.dart';
import '../../core/models/inference/generation_params.dart';
import '../../core/models/inference/model_params.dart';
import '../backend.dart';
import 'worker.dart';

/// Native LiteRT-LM backend for `.litertlm` models.
///
/// LiteRT-LM native state is owned by a worker isolate so callbacks, native
/// handles, and generation work do not live on the caller isolate.
class LiteRtLmBackend
    implements
        LlamaBackend,
        BackendAvailability,
        BackendRuntimeDiagnostics,
        BackendPerformanceDiagnostics {
  Isolate? _isolate;
  SendPort? _sendPort;
  void Function()? _activeGenerationCleanup;
  final String? _preferredBackend;

  bool _isReady = false;
  bool _disposed = false;
  LlamaLogLevel _currentLogLevel = LlamaLogLevel.warn;

  /// Creates a LiteRT-LM backend.
  LiteRtLmBackend({SendPort? initialSendPort, String? preferredBackend})
    : _preferredBackend = preferredBackend {
    if (initialSendPort != null) {
      _sendPort = initialSendPort;
      _isReady = true;
    }
  }

  @override
  bool get isReady => _isReady;

  @override
  bool get supportsUrlLoading => false;

  @override
  Future<int> modelLoad(String path, ModelParams params) async {
    final response = await _sendRequest(
      (sendPort) => LiteRtLmModelLoadRequest(
        path,
        params,
        sendPort,
        backendOverride: _preferredBackend,
      ),
    );
    final handle = _expect<LiteRtLmHandleResponse>(
      response,
      'model load',
    ).handle;
    _isReady = true;
    return handle;
  }

  @override
  Future<int> modelLoadFromUrl(
    String url,
    ModelParams params, {
    Function(double progress)? onProgress,
  }) {
    throw UnsupportedError('LiteRtLmBackend requires a local .litertlm path.');
  }

  @override
  Future<void> modelFree(int modelHandle) async {
    if (_sendPort == null) {
      return;
    }
    try {
      await _sendRequest(
        (sendPort) => LiteRtLmModelFreeRequest(modelHandle, sendPort),
        timeout: const Duration(seconds: 5),
      );
    } on TimeoutException {
      _killWorker();
    }
    _isReady = false;
  }

  @override
  Future<int> contextCreate(int modelHandle, ModelParams params) async {
    final response = await _sendRequest(
      (sendPort) => LiteRtLmContextCreateRequest(modelHandle, params, sendPort),
    );
    return _expect<LiteRtLmHandleResponse>(response, 'context creation').handle;
  }

  @override
  Future<void> contextFree(int contextHandle) async {
    if (_sendPort == null) {
      return;
    }
    await _sendRequest(
      (sendPort) => LiteRtLmContextFreeRequest(contextHandle, sendPort),
    );
  }

  @override
  Future<int> getContextSize(int contextHandle) async {
    final response = await _sendRequest(
      (sendPort) => LiteRtLmGetContextSizeRequest(contextHandle, sendPort),
    );
    return _expect<LiteRtLmGetContextSizeResponse>(
      response,
      'context size lookup',
    ).size;
  }

  @override
  Stream<List<int>> generate(
    int contextHandle,
    String prompt,
    GenerationParams params, {
    List<LlamaContentPart>? parts,
  }) {
    final responsePort = ReceivePort();
    late final StreamController<List<int>> controller;
    var cleanedUp = false;

    void cleanup() {
      if (cleanedUp) {
        return;
      }
      cleanedUp = true;
      responsePort.close();
      if (!controller.isClosed) {
        unawaited(controller.close());
      }
      if (_activeGenerationCleanup == cleanup) {
        _activeGenerationCleanup = null;
      }
    }

    controller = StreamController<List<int>>(
      onListen: () {
        unawaited(() async {
          try {
            await _ensureIsolate();
            _sendPort!.send(
              LiteRtLmGenerateRequest(
                contextHandle,
                prompt,
                params,
                responsePort.sendPort,
                parts: parts,
              ),
            );
          } catch (error, stackTrace) {
            if (!controller.isClosed) {
              controller.addError(error, stackTrace);
            }
            cleanup();
          }
        }());
      },
      onCancel: () {
        cancelGeneration();
        cleanup();
      },
    );
    _activeGenerationCleanup = cleanup;

    responsePort.listen((message) {
      if (cleanedUp) {
        return;
      }
      if (message is LiteRtLmTokenResponse) {
        controller.add(message.bytes);
      } else if (message is LiteRtLmDoneResponse) {
        cleanup();
      } else if (message is LiteRtLmErrorResponse) {
        controller.addError(_exceptionForErrorResponse(message));
        cleanup();
      }
    });

    return controller.stream;
  }

  @override
  void cancelGeneration() {
    unawaited(_cancelGeneration());
  }

  @override
  Future<List<int>> tokenize(
    int modelHandle,
    String text, {
    bool addSpecial = true,
  }) async {
    final response = await _sendRequest(
      (sendPort) =>
          LiteRtLmTokenizeRequest(modelHandle, text, addSpecial, sendPort),
    );
    return _expect<LiteRtLmTokenizeResponse>(response, 'tokenization').tokens;
  }

  @override
  Future<String> detokenize(
    int modelHandle,
    List<int> tokens, {
    bool special = false,
  }) async {
    final response = await _sendRequest(
      (sendPort) =>
          LiteRtLmDetokenizeRequest(modelHandle, tokens, special, sendPort),
    );
    return _expect<LiteRtLmDetokenizeResponse>(response, 'detokenization').text;
  }

  @override
  Future<Map<String, String>> modelMetadata(int modelHandle) async {
    final response = await _sendRequest(
      (sendPort) => LiteRtLmMetadataRequest(modelHandle, sendPort),
    );
    return _expect<LiteRtLmMetadataResponse>(
      response,
      'metadata lookup',
    ).metadata;
  }

  @override
  Future<void> setLoraAdapter(
    int contextHandle,
    String path,
    double scale,
  ) async {
    await _sendRequest(
      (sendPort) => LiteRtLmLoraRequest(
        contextHandle,
        'set',
        path: path,
        scale: scale,
        sendPort: sendPort,
      ),
    );
  }

  @override
  Future<void> removeLoraAdapter(int contextHandle, String path) async {
    await _sendRequest(
      (sendPort) => LiteRtLmLoraRequest(
        contextHandle,
        'remove',
        path: path,
        sendPort: sendPort,
      ),
    );
  }

  @override
  Future<void> clearLoraAdapters(int contextHandle) async {
    await _sendRequest(
      (sendPort) =>
          LiteRtLmLoraRequest(contextHandle, 'clear', sendPort: sendPort),
    );
  }

  @override
  Future<String> getBackendName() async {
    final response = await _sendRequest(LiteRtLmBackendInfoRequest.new);
    return _expect<LiteRtLmBackendInfoResponse>(
      response,
      'backend info lookup',
    ).name;
  }

  @override
  Future<String> getAvailableBackends() async {
    final response = await _sendRequest(LiteRtLmAvailableBackendsRequest.new);
    return _expect<LiteRtLmBackendInfoResponse>(
      response,
      'available backend lookup',
    ).name;
  }

  @override
  Future<int?> getResolvedGpuLayers() async {
    final response = await _sendRequest(LiteRtLmResolvedGpuLayersRequest.new);
    return _expect<LiteRtLmResolvedGpuLayersResponse>(
      response,
      'resolved GPU layer lookup',
    ).layers;
  }

  @override
  Future<BackendPerfContextData?> getPerformanceContext(
    int contextHandle,
  ) async {
    final response = await _sendRequest(
      (sendPort) => LiteRtLmPerformanceContextRequest(contextHandle, sendPort),
    );
    if (response is LiteRtLmDoneResponse) {
      return null;
    }
    final perf = _expect<LiteRtLmPerformanceContextResponse>(
      response,
      'performance context lookup',
    );
    return BackendPerfContextData(
      loadMs: perf.loadMs,
      promptEvalMs: perf.promptEvalMs,
      evalMs: perf.evalMs,
      sampleMs: perf.sampleMs,
      promptEvalTokens: perf.promptEvalTokens,
      evalTokens: perf.evalTokens,
      sampleCount: perf.sampleCount,
      reusedGraphs: perf.reusedGraphs,
    );
  }

  @override
  Future<bool> isGpuSupported() async {
    final response = await _sendRequest(LiteRtLmGpuSupportRequest.new);
    return _expect<LiteRtLmGpuSupportResponse>(
      response,
      'GPU support lookup',
    ).support;
  }

  @override
  Future<void> setLogLevel(LlamaLogLevel level) async {
    _currentLogLevel = level;
    if (_sendPort == null) {
      return;
    }
    await _sendRequest(
      (sendPort) => LiteRtLmLogLevelRequest(level, sendPort),
      ensureIsolate: false,
    );
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await _cancelGeneration();
    _activeGenerationCleanup?.call();

    final sendPort = _sendPort;
    if (sendPort != null) {
      final responsePort = ReceivePort();
      try {
        sendPort.send(LiteRtLmDisposeRequest(responsePort.sendPort));
        await responsePort.first.timeout(const Duration(seconds: 5));
      } catch (_) {
        // Native LiteRT-LM teardown can stall on some accelerator paths. The
        // isolate is killed below so app shutdown is not held indefinitely.
      } finally {
        responsePort.close();
      }
    }
    _killWorker();
    _isReady = false;
  }

  @override
  Future<int?> multimodalContextCreate(
    int modelHandle,
    String mmProjPath,
  ) async {
    final response = await _sendRequest(
      (sendPort) => LiteRtLmMultimodalContextCreateRequest(
        modelHandle,
        mmProjPath,
        sendPort,
      ),
    );
    return _expect<LiteRtLmHandleResponse>(
      response,
      'multimodal context creation',
    ).handle;
  }

  @override
  Future<void> multimodalContextFree(int mmContextHandle) async {
    await _sendRequest(
      (sendPort) =>
          LiteRtLmMultimodalContextFreeRequest(mmContextHandle, sendPort),
    );
  }

  @override
  Future<bool> supportsVision(int mmContextHandle) async {
    final response = await _sendRequest(
      (sendPort) => LiteRtLmSupportsVisionRequest(mmContextHandle, sendPort),
    );
    return response as bool;
  }

  @override
  Future<bool> supportsAudio(int mmContextHandle) async {
    final response = await _sendRequest(
      (sendPort) => LiteRtLmSupportsAudioRequest(mmContextHandle, sendPort),
    );
    return response as bool;
  }

  @override
  Future<({int total, int free})> getVramInfo() async {
    final response = await _sendRequest(LiteRtLmSystemInfoRequest.new);
    final info = _expect<LiteRtLmSystemInfoResponse>(
      response,
      'system info lookup',
    );
    return (total: info.totalVram, free: info.freeVram);
  }

  @override
  Future<String> applyChatTemplate(
    int modelHandle,
    List<Map<String, dynamic>> messages, {
    String? customTemplate,
    bool addAssistant = true,
  }) async {
    final response = await _sendRequest(
      (sendPort) => LiteRtLmChatTemplateRequest(
        modelHandle,
        messages,
        customTemplate,
        addAssistant,
        sendPort,
      ),
    );
    return _expect<LiteRtLmChatTemplateResponse>(
      response,
      'chat template application',
    ).result;
  }

  Future<void> _ensureIsolate() async {
    if (_disposed) {
      throw StateError('LiteRT-LM backend has been disposed.');
    }
    if (_sendPort != null) {
      return;
    }

    final completer = Completer<void>();
    final tempPort = ReceivePort();
    tempPort.listen((message) {
      if (message is SendPort) {
        _sendPort = message;
        _sendPort!.send(LiteRtLmWorkerHandshake(_currentLogLevel));
        tempPort.close();
        completer.complete();
      }
    });
    _isolate = await Isolate.spawn(liteRtLmWorkerEntry, tempPort.sendPort);
    await completer.future;
  }

  Future<Object?> _sendRequest(
    LiteRtLmWorkerRequest Function(SendPort sendPort) buildRequest, {
    bool ensureIsolate = true,
    Duration? timeout,
  }) async {
    if (ensureIsolate) {
      await _ensureIsolate();
    }
    final sendPort = _sendPort;
    if (sendPort == null) {
      throw StateError('LiteRT-LM worker is not initialized.');
    }

    final responsePort = ReceivePort();
    try {
      sendPort.send(buildRequest(responsePort.sendPort));
      final response = timeout == null
          ? await responsePort.first
          : await responsePort.first.timeout(timeout);
      if (response is LiteRtLmErrorResponse) {
        _throwLiteRtLmError(response);
      }
      return response;
    } finally {
      responsePort.close();
    }
  }

  void _killWorker() {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _sendPort = null;
    _activeGenerationCleanup = null;
  }

  Future<void> _cancelGeneration() async {
    final sendPort = _sendPort;
    if (sendPort == null) {
      return;
    }
    final responsePort = ReceivePort();
    try {
      sendPort.send(LiteRtLmCancelGenerationRequest(responsePort.sendPort));
      await responsePort.first.timeout(const Duration(seconds: 1));
    } catch (_) {
      // Cancellation is best-effort because this method is also used by
      // StreamController.onCancel and dispose paths.
    } finally {
      responsePort.close();
    }
  }

  T _expect<T>(Object? response, String operation) {
    if (response is T) {
      return response;
    }
    throw StateError('Unexpected LiteRT-LM response during $operation.');
  }

  Never _throwLiteRtLmError(LiteRtLmErrorResponse response) {
    throw _exceptionForErrorResponse(response);
  }

  Object _exceptionForErrorResponse(LiteRtLmErrorResponse response) {
    switch (response.kind) {
      case 'unsupported':
        return UnsupportedError(response.message);
      case 'argument':
        return ArgumentError(response.message);
      case 'state':
        return StateError(response.message);
      default:
        return Exception(response.message);
    }
  }
}
