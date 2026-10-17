import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import '../../core/engine/engine_observer.dart';
import '../../core/exceptions.dart';
import '../../core/models/inference/embedding.dart';
import '../../core/llama_logger.dart';
import '../../core/models/chat/chat_message.dart';
import '../../core/models/chat/content_part.dart';
import '../../core/models/config/log_level.dart';
import '../../core/models/inference/generation_params.dart';
import '../../core/models/inference/model_params.dart';
import '../../core/models/inference/tool_choice.dart';
import '../../core/models/tools/tool_definition.dart';
import '../../core/template/handlers/translate_gemma_handler.dart';
import '../backend.dart';
import 'litert_lm_platform.dart';
import 'litert_lm_embedding.dart';
import 'worker.dart';

/// Native LiteRT-LM backend for `.litertlm` models.
///
/// LiteRT-LM native state is owned by a worker isolate so callbacks, native
/// handles, and generation work do not live on the caller isolate.
class LiteRtLmBackend
    implements
        BackendRuntimeIdentity,
        LlamaBackend,
        BackendAvailability,
        BackendDirectMediaInput,
        BackendGrammarConstraintsSupport,
        BackendRuntimeDiagnostics,
        BackendDeferredEngineCreation,
        BackendPerformanceDiagnostics,
        BackendGenerationCapabilitiesSupport,
        BackendGenerationLimitSupport,
        BackendEmbeddingsSupport,
        BackendBatchEmbeddings,
        BackendMultimodalEmbeddings,
        BackendStatePersistenceSupport,
        BackendNativeChatGeneration,
        BackendDartLogLevel {
  Isolate? _isolate;
  ReceivePort? _workerLifecyclePort;
  RawReceivePort? _workerLogPort;
  SendPort? _sendPort;
  Future<void>? _isolateStart;
  Future<void>? _disposeFuture;
  int _workerGeneration = 0;
  void Function([Object? error])? _activeGenerationCleanup;
  _WorkerGeneration? _runningGeneration;
  _QueuedGeneration? _queuedGeneration;
  final Set<int> _stalePerformanceContexts = {};
  final Map<ReceivePort, Completer<Object?>> _pendingRequests = {};
  final Duration _embeddingTimeout;
  final String? _preferredBackend;
  final void Function(SendPort) _workerEntryPoint;

  bool _isReady = false;
  int _embeddingCancellationSerial = 0;
  bool _embeddingEngine = false;
  int? _embeddingContext;
  bool _disposed = false;
  bool _nativeSettlementUnverified = false;
  LlamaLogLevel _currentLogLevel = LlamaLogLevel.warn;

  /// Creates a LiteRT-LM backend.
  ///
  /// [preferredBackend] (`cpu`, `gpu` or `npu`) is deprecated: set
  /// [ModelParams.device], which also works through the default
  /// `LlamaBackend()` router. A load whose [ModelParams.device] is not auto
  /// throws `LlamaUnsupportedException` when [preferredBackend] is set.
  /// [embeddingTimeout] bounds embedding requests, including worker queue time.
  /// Expiry cancels only that request; other queued calls keep their deadlines.
  /// Explicit cancellation, context/model teardown and disposal cancel all embeds.
  /// [workerEntryPoint] substitutes the worker only for lifecycle tests.
  LiteRtLmBackend({
    SendPort? initialSendPort,
    Duration embeddingTimeout = const Duration(minutes: 10),
    @Deprecated('Use ModelParams.device. This will be removed in 1.0.')
    String? preferredBackend,
    void Function(SendPort)? workerEntryPoint,
  }) : _embeddingTimeout = embeddingTimeout,
       _preferredBackend = preferredBackend,
       _workerEntryPoint = workerEntryPoint ?? liteRtLmWorkerEntry {
    if (initialSendPort != null) {
      _sendPort = initialSendPort;
      _isReady = true;
    }
  }

  @override
  String? get generationLimitUnsupportedReason =>
      'Native LiteRT-LM v0.18.0 does not expose a reliable generation termination reason. '
      'Automatic tool loops require an owner runtime with token-limit reporting; '
      'use ChatSession.create or LlamaEngine.create for manual completion.';

  @override
  bool get isReady => _isReady;

  @override
  bool get supportsUrlLoading => false;

  @override
  bool get defersEngineCreation => true;

  @override
  bool get supportsEmbeddings => _embeddingEngine;

  @override
  bool get supportsStatePersistence => false;

  @override
  bool get supportsGrammarConstraints => false;

  @override
  bool get supportsNativeChatGeneration => true;

  @override
  Future<LlamaEmbeddingCapabilities> getEmbeddingCapabilities(
    int contextHandle,
  ) async {
    if (!_embeddingEngine || contextHandle != _embeddingContext) {
      return const LlamaEmbeddingCapabilities();
    }
    final response = await _sendRequest(
      (port) => LiteRtLmEmbeddingCapabilitiesRequest(contextHandle, port),
    );
    return _expect<LiteRtLmEmbeddingCapabilitiesResponse>(
      response,
      'embedding capabilities',
    ).capabilities;
  }

  @override
  Future<List<double>> embed(
    int contextHandle,
    String text, {
    bool normalize = true,
  }) async =>
      (await embedBatch(contextHandle, [text], normalize: normalize)).single;

  @override
  Future<List<List<double>>> embedBatch(
    int contextHandle,
    List<String> texts, {
    bool normalize = true,
  }) => embedContentBatch(contextHandle, [
    for (final text in texts) LlamaEmbeddingInput([LlamaTextContent(text)]),
  ], normalize: normalize);

  @override
  Future<List<List<double>>> embedContentBatch(
    int contextHandle,
    List<LlamaEmbeddingInput> inputs, {
    bool normalize = true,
  }) async {
    if (inputs.isEmpty) {
      return [];
    }
    if (!_embeddingEngine) {
      throw LlamaUnsupportedException(
        'LiteRT-LM embeddings require liteRtLmEmbeddingEngine: true; a conversation engine is loaded.',
      );
    }
    final cancellationSerial = _embeddingCancellationSerial;
    // Full decoding must not block the caller isolate, even for large media.
    final prepared = await _prepareEmbeddings(inputs);
    if (cancellationSerial != _embeddingCancellationSerial) {
      throw LlamaInferenceException(
        'LiteRT-LM embedding cancelled during media preflight.',
      );
    }
    SendPort? embeddingPort;
    try {
      final response = await _sendRequest((port) {
        // Worker startup can yield after media preflight's cancellation check.
        if (cancellationSerial != _embeddingCancellationSerial) {
          throw LlamaInferenceException(
            'LiteRT-LM embedding cancelled before dispatch.',
          );
        }
        embeddingPort = port;
        return LiteRtLmEmbedRequest(contextHandle, prepared, normalize, port);
      }, timeout: _embeddingTimeout);
      return _expect<LiteRtLmEmbedResponse>(response, 'embedding').vectors;
    } on TimeoutException {
      if (embeddingPort == null) {
        throw LlamaInferenceException(
          'LiteRT-LM embedding worker startup timed out before dispatch.',
        );
      }
      await _cancelGeneration(embeddingPort);
      throw LlamaInferenceException(
        'LiteRT-LM embedding timed out; cancellation requested. Native work settles before reuse.',
      );
    } on StateError catch (error) {
      throw LlamaStateException(
        'LiteRT-LM embedding unavailable: ${error.message}',
      );
    }
  }

  // Keep the isolate closure out of the dispatch scope, which captures this
  // backend's unsendable worker ports for cancellation.
  static Future<List<List<LiteRtLmEmbeddingPart>>> _prepareEmbeddings(
    List<LlamaEmbeddingInput> inputs,
  ) => Isolate.run(() => inputs.map(prepareLiteRtLmEmbedding).toList());

  @override
  Future<int> modelLoad(String path, ModelParams params) async {
    await _cancelActiveGeneration();
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
    _embeddingEngine = params.liteRtLmEmbeddingEngine;
    _embeddingContext = null;
    return handle;
  }

  @override
  Future<int> modelLoadFromUrl(
    String url,
    ModelParams params, {
    void Function(double progress)? onProgress,
  }) {
    throw UnsupportedError('LiteRtLmBackend requires a local .litertlm path.');
  }

  @override
  Future<void> modelFree(int modelHandle) async {
    if (_nativeSettlementUnverified) {
      throw _unsettledWorkerError();
    }
    await _cancelActiveGeneration();
    if (_nativeSettlementUnverified) {
      throw _unsettledWorkerError();
    }
    if (_sendPort == null) {
      _isReady = false;
      return;
    }
    try {
      await _sendRequest(
        (sendPort) => LiteRtLmModelFreeRequest(modelHandle, sendPort),
        timeout: const Duration(seconds: 5),
      );
    } on TimeoutException {
      _nativeSettlementUnverified = true;
      _killWorker();
      throw _unsettledWorkerError();
    }
    _isReady = false;
    _embeddingEngine = false;
    _embeddingContext = null;
  }

  @override
  Future<int> contextCreate(int modelHandle, ModelParams params) async {
    final response = await _sendRequest(
      (sendPort) => LiteRtLmContextCreateRequest(modelHandle, params, sendPort),
    );
    final handle = _expect<LiteRtLmHandleResponse>(
      response,
      'context creation',
    ).handle;
    _embeddingContext = handle;
    return handle;
  }

  @override
  Future<void> contextFree(int contextHandle) async {
    if (_nativeSettlementUnverified) {
      throw _unsettledWorkerError();
    }
    await _cancelActiveGeneration();
    if (_nativeSettlementUnverified) {
      throw _unsettledWorkerError();
    }
    if (_sendPort == null) {
      return;
    }
    try {
      await _sendRequest(
        (sendPort) => LiteRtLmContextFreeRequest(contextHandle, sendPort),
        timeout: const Duration(seconds: 5),
      );
      _embeddingContext = null;
      _stalePerformanceContexts.remove(contextHandle);
    } on TimeoutException {
      _nativeSettlementUnverified = true;
      _killWorker();
      throw _unsettledWorkerError();
    }
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
  }) => _generateOnWorker(
    contextHandle,
    (sendPort) => LiteRtLmGenerateRequest(
      contextHandle,
      prompt,
      params,
      sendPort,
      parts: parts,
    ),
  );

  @override
  Stream<List<int>> generateChat(
    int contextHandle,
    List<LlamaChatMessage> messages,
    GenerationParams params, {
    List<ToolDefinition>? tools,
    ToolChoice toolChoice = ToolChoice.auto,
    bool parallelToolCalls = false,
    bool enableThinking = true,
    Map<String, dynamic>? chatTemplateKwargs,
    @Deprecated("Use chatTemplateKwargs: {'source_lang_code': ...} instead.")
    String? sourceLangCode,
    @Deprecated("Use chatTemplateKwargs: {'target_lang_code': ...} instead.")
    String? targetLangCode,
    DateTime? templateNow,
  }) {
    final nativeTools = tools
        ?.map((tool) => tool.toJson())
        .toList(growable: false);
    return _generateOnWorker(
      contextHandle,
      (sendPort) => LiteRtLmGenerateChatRequest(
        contextHandle,
        messages,
        params,
        sendPort,
        tools: nativeTools,
        toolChoice: toolChoice,
        parallelToolCalls: parallelToolCalls,
        enableThinking: enableThinking,
        chatTemplateKwargs: chatTemplateKwargsWithLanguageCodes(
          chatTemplateKwargs,
          sourceLangCode: sourceLangCode,
          targetLangCode: targetLangCode,
        ),
        templateNow: templateNow,
      ),
    );
  }

  /// Streams the worker generation that [buildRequest] describes.
  ///
  /// A generation listened to while a cancelled one is still running on the
  /// worker waits for that run's terminal response, then starts.
  Stream<List<int>> _generateOnWorker(
    int contextHandle,
    LiteRtLmWorkerRequest Function(SendPort responsePort) buildRequest,
  ) {
    late final StreamController<List<int>> controller;
    _WorkerGeneration? generation;
    _QueuedGeneration? queued;
    var closed = false;
    var admitted = false;
    var requestSent = false;

    void close([Object? error]) {
      if (closed) {
        return;
      }
      closed = true;
      if (admitted && !requestSent) {
        _stalePerformanceContexts.add(contextHandle);
      }
      if (!controller.isClosed) {
        if (error != null) {
          controller.addError(error);
        }
        unawaited(controller.close());
      }
      if (_activeGenerationCleanup == close) {
        _activeGenerationCleanup = null;
      }
    }

    void start() {
      final port = ReceivePort();
      final current = _WorkerGeneration(port);
      generation = current;
      _runningGeneration = current;
      _activeGenerationCleanup = close;
      port.listen((message) {
        if (message is LiteRtLmTokenResponse) {
          if (!closed) {
            controller.add(message.bytes);
          }
        } else if (message is LiteRtLmDoneResponse) {
          close();
          _finishGeneration(current);
        } else if (message is LiteRtLmErrorResponse) {
          close(_exceptionForErrorResponse(message));
          _finishGeneration(current);
        }
      });

      unawaited(() async {
        try {
          await _ensureIsolate();
          // Re-check after the await: a cancel during _ensureIsolate() may
          // have closed this stream or cleared _sendPort. Capture the port and
          // guard in one synchronous step so a cancelled generation never
          // reaches the worker and a closed port is never sent to.
          final sendPort = _sendPort;
          if (closed || current.cancelRequested || sendPort == null) {
            close();
            _finishGeneration(current);
            return;
          }
          sendPort.send(buildRequest(port.sendPort));
          requestSent = true;
          _stalePerformanceContexts.remove(contextHandle);
        } catch (error, stackTrace) {
          if (!closed && !controller.isClosed) {
            controller.addError(error, stackTrace);
          }
          close();
          _finishGeneration(current);
        }
      }());
    }

    controller = StreamController<List<int>>(
      onListen: () {
        final running = _runningGeneration;
        if (_queuedGeneration != null ||
            (running != null && !running.cancelRequested)) {
          close(
            LlamaStateException(
              'LiteRT-LM generation is already in progress. Cancel it or '
              'wait for its stream to end before starting another.',
            ),
          );
          return;
        }
        admitted = true;
        if (running == null) {
          start();
          return;
        }
        final waiting = _QueuedGeneration(start, close);
        queued = waiting;
        _queuedGeneration = waiting;
      },
      onCancel: () {
        final current = generation;
        if (current == null) {
          if (_queuedGeneration == queued) {
            _queuedGeneration = null;
          }
        } else if (identical(_runningGeneration, current) &&
            !current.cancelRequested) {
          // Raises only this run's cancel, so a generation queued behind it
          // still starts once the worker reports that the run stopped.
          current.cancelRequested = true;
          unawaited(_cancelGeneration());
        }
        close();
      },
    );

    return controller.stream;
  }

  /// Releases [generation] after its terminal response, or when it never
  /// reached the worker, and starts the generation queued behind it.
  void _finishGeneration(_WorkerGeneration generation) {
    generation.responsePort.close();
    if (!identical(_runningGeneration, generation)) {
      return;
    }
    _runningGeneration = null;
    final queued = _queuedGeneration;
    if (queued == null) {
      return;
    }
    _queuedGeneration = null;
    queued.start();
  }

  /// Ends the generation waiting for a cancelled run without starting it.
  void _closeQueuedGeneration([Object? error]) {
    final queued = _queuedGeneration;
    _queuedGeneration = null;
    queued?.close(error);
  }

  @override
  void cancelGeneration() {
    _embeddingCancellationSerial++;
    _runningGeneration?.cancelRequested = true;
    _closeQueuedGeneration();
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
  LlamaRuntime get runtime => LlamaRuntime.liteRtLm;

  @override
  Future<String> getBackendName() async {
    final preferredBackend = _preloadPreferredBackend();
    if (preferredBackend != null) {
      return 'LiteRT-LM $preferredBackend';
    }

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
    final preferredBackend = _preloadPreferredBackend();
    if (preferredBackend != null) {
      return preferredBackend == 'cpu' ? 0 : ModelParams.maxGpuLayers;
    }

    final response = await _sendRequest(LiteRtLmResolvedGpuLayersRequest.new);
    return _expect<LiteRtLmResolvedGpuLayersResponse>(
      response,
      'resolved GPU layer lookup',
    ).layers;
  }

  /// Reports the stream batching thresholds the worker applies, none of the
  /// sampling controls, and speculative decoding through the LiteRT-LM
  /// runtime switch, which [SpeculativeDecodingStrategy.backendDefault] and
  /// [SpeculativeDecodingStrategy.mtp] turn on, unless the loaded bundle
  /// declares no speculative decoding drafter. The declaration can
  /// under-report; see `LiteRtLmRuntimeClient.bundleCapabilities`.
  @override
  Future<BackendGenerationCapabilities> generationCapabilities() async {
    final bundle = await _bundleCapabilities();
    return BackendGenerationCapabilities(
      presencePenalty: false,
      minP: false,
      thinkingBudget: false,
      speculativeDecodingStrategies: bundle?.speculativeDecoding == false
          ? const <SpeculativeDecodingStrategy>{}
          : const <SpeculativeDecodingStrategy>{
              SpeculativeDecodingStrategy.backendDefault,
              SpeculativeDecodingStrategy.mtp,
            },
      streamBatching: true,
    );
  }

  @override
  Future<BackendPerfContextData?> getPerformanceContext(
    int contextHandle,
  ) async {
    // An unsent cancellation never resets the service's previous metrics.
    if (_stalePerformanceContexts.contains(contextHandle)) return null;
    final response = await _sendRequest(
      (sendPort) => LiteRtLmPerformanceContextRequest(contextHandle, sendPort),
    );
    if (_stalePerformanceContexts.contains(contextHandle)) return null;
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
  Future<void> setDartLogLevel(LlamaLogLevel level) async {
    if (_sendPort == null) {
      return;
    }
    await _sendRequest(
      (sendPort) => LiteRtLmDartLogLevelRequest(level, sendPort),
      ensureIsolate: false,
    );
  }

  @override
  Future<void> dispose() => _disposeFuture ??= _disposeWorker();

  Future<void> _disposeWorker() async {
    _embeddingCancellationSerial++;
    _disposed = true;
    _runningGeneration?.cancelRequested = true;
    _closeQueuedGeneration();
    await _cancelGeneration();
    _activeGenerationCleanup?.call();

    final sendPort = _sendPort;
    if (sendPort != null) {
      final responsePort = ReceivePort();
      try {
        sendPort.send(LiteRtLmDisposeRequest(responsePort.sendPort));
        final response = await responsePort.first.timeout(
          const Duration(seconds: 5),
        );
        if (response is! LiteRtLmDoneResponse) {
          _nativeSettlementUnverified = true;
        }
      } catch (_) {
        // Native LiteRT-LM teardown can stall on some accelerator paths. The
        // caller ports are closed below; this does not prove native settlement.
        _nativeSettlementUnverified = true;
      } finally {
        responsePort.close();
      }
    }
    _killWorker();
    _isReady = false;
    if (_nativeSettlementUnverified) {
      throw _unsettledWorkerError();
    }
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

  /// Reports the image and audio input that the loaded bundle declares,
  /// which can under-report; see `LiteRtLmRuntimeClient.bundleCapabilities`.
  @override
  Future<({bool vision, bool audio})> directMediaInput() async {
    final bundle = await _bundleCapabilities();
    return (vision: bundle?.vision ?? false, audio: bundle?.audio ?? false);
  }

  Future<({bool vision, bool audio, bool speculativeDecoding})?>
  _bundleCapabilities() async {
    return _expect<LiteRtLmBundleCapabilitiesResponse>(
      await _sendRequest(LiteRtLmBundleCapabilitiesRequest.new),
      'bundle capability lookup',
    ).capabilities;
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
    if (_nativeSettlementUnverified) {
      throw _unsettledWorkerError();
    }
    if (_disposed) {
      throw StateError('LiteRT-LM backend has been disposed.');
    }
    if (_sendPort != null) {
      return;
    }

    final existingStart = _isolateStart;
    if (existingStart != null) {
      await existingStart;
      if (_disposed) {
        throw StateError('LiteRT-LM backend has been disposed.');
      }
      if (_sendPort == null) {
        throw StateError('LiteRT-LM worker startup did not provide a port.');
      }
      return;
    }

    final generation = _workerGeneration;
    final start = _startIsolate(generation);
    _isolateStart = start;
    try {
      await start;
    } finally {
      if (identical(_isolateStart, start)) {
        _isolateStart = null;
      }
    }

    if (_disposed) {
      throw StateError('LiteRT-LM backend has been disposed.');
    }
    if (_sendPort == null) {
      throw StateError('LiteRT-LM worker startup did not provide a port.');
    }
  }

  Future<void> _startIsolate(int generation) async {
    final completer = Completer<void>();
    final tempPort = ReceivePort();
    final lifecyclePort = ReceivePort();
    _workerLifecyclePort = lifecyclePort;
    final logPort = RawReceivePort((Object? message) {
      if (message is WorkerLogMessage) {
        message.emit();
      }
    });
    logPort.keepIsolateAlive = false;
    _workerLogPort = logPort;
    lifecyclePort.listen((_) {
      if (_disposed || generation != _workerGeneration) {
        return;
      }
      _nativeSettlementUnverified = true;
      if (!completer.isCompleted) {
        completer.completeError(_unsettledWorkerError());
      }
      _killWorker();
    });
    late final StreamSubscription<Object?> subscription;
    subscription = tempPort.listen((message) {
      if (message is SendPort) {
        if (_disposed || generation != _workerGeneration) {
          if (!completer.isCompleted) {
            completer.completeError(
              StateError('LiteRT-LM worker startup was cancelled.'),
            );
          }
          unawaited(subscription.cancel());
          tempPort.close();
          return;
        }
        _sendPort = message;
        _sendPort!.send(
          LiteRtLmWorkerHandshake(
            _currentLogLevel,
            dartLogLevel: LlamaLogger.instance.level,
            logPort: logPort.sendPort,
          ),
        );
        tempPort.close();
        unawaited(subscription.cancel());
        if (!completer.isCompleted) {
          completer.complete();
        }
      }
    });
    Isolate? isolate;
    try {
      isolate = await Isolate.spawn(
        _workerEntryPoint,
        tempPort.sendPort,
        onExit: lifecyclePort.sendPort,
        onError: lifecyclePort.sendPort,
      );
      if (_disposed || generation != _workerGeneration) {
        isolate.kill(priority: Isolate.immediate);
        throw StateError('LiteRT-LM worker startup was cancelled.');
      }
      _isolate = isolate;
      await completer.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          throw TimeoutException('Timed out starting LiteRT-LM worker.');
        },
      );
    } catch (_) {
      if (identical(_isolate, isolate)) {
        _isolate = null;
      }
      isolate?.kill(priority: Isolate.immediate);
      await subscription.cancel();
      tempPort.close();
      lifecyclePort.close();
      if (identical(_workerLifecyclePort, lifecyclePort)) {
        _workerLifecyclePort = null;
      }
      logPort.close();
      if (identical(_workerLogPort, logPort)) {
        _workerLogPort = null;
      }
      rethrow;
    }
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
    final completion = Completer<Object?>();
    _pendingRequests[responsePort] = completion;
    responsePort.listen((response) {
      if (!completion.isCompleted) {
        completion.complete(response);
      }
    });
    try {
      sendPort.send(buildRequest(responsePort.sendPort));
      final response = timeout == null
          ? await completion.future
          : await completion.future.timeout(timeout);
      if (response is LiteRtLmErrorResponse) {
        _throwLiteRtLmError(response);
      }
      return response;
    } finally {
      _pendingRequests.remove(responsePort);
      responsePort.close();
    }
  }

  void _killWorker() {
    if (_pendingRequests.isNotEmpty) {
      _nativeSettlementUnverified = true;
    }
    final generationError = _nativeSettlementUnverified
        ? _unsettledWorkerError()
        : null;
    _activeGenerationCleanup?.call(generationError);
    _closeQueuedGeneration(generationError);
    // A killed worker sends no terminal response for the running generation.
    _runningGeneration?.responsePort.close();
    _runningGeneration = null;
    // A killed worker cannot reply. Closing its callers' ports alone would
    // leave their futures pending, while leaving ports open retains the VM.
    // This settles Dart requests only; an in-flight native call may still be
    // running and must not have its resources freed here.
    for (final entry in _pendingRequests.entries) {
      entry.key.close();
      if (!entry.value.isCompleted) {
        entry.value.completeError(_unsettledWorkerError());
      }
    }
    _pendingRequests.clear();
    _stalePerformanceContexts.clear();
    _embeddingEngine = false;
    _embeddingContext = null;
    _workerGeneration += 1;
    _workerLifecyclePort?.close();
    _workerLifecyclePort = null;
    _workerLogPort?.close();
    _workerLogPort = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _sendPort = null;
    _isolateStart = null;
    _activeGenerationCleanup = null;
    _isReady = false;
  }

  LlamaStateException _unsettledWorkerError() => LlamaStateException(
    'LiteRT-LM worker stopped before native cleanup was confirmed. '
    'Native operation settlement is unverified; restart the process before '
    'retrying this runtime.',
  );

  Future<void> _cancelActiveGeneration() async {
    _embeddingCancellationSerial++;
    _closeQueuedGeneration();
    final cleanup = _activeGenerationCleanup;
    if (cleanup == null) {
      if (_embeddingEngine) {
        await _cancelGeneration();
      }
      return;
    }
    _runningGeneration?.cancelRequested = true;
    await _cancelGeneration();
    cleanup();
  }

  Future<void> _cancelGeneration([SendPort? embeddingPort]) async {
    final sendPort = _sendPort;
    if (sendPort == null) {
      return;
    }
    final responsePort = ReceivePort();
    try {
      sendPort.send(
        embeddingPort == null
            ? LiteRtLmCancelGenerationRequest(responsePort.sendPort)
            : LiteRtLmCancelEmbeddingRequest(
                embeddingPort,
                responsePort.sendPort,
              ),
      );
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
      case 'llamaUnsupported':
        return LlamaUnsupportedException(response.message);
      case 'llamaArgument':
        return LlamaArgumentException(response.message);
      case 'llamaModel':
        return LlamaModelException(response.message);
      case 'llamaContext':
        return LlamaContextException(response.message);
      case 'llamaInference':
        return LlamaInferenceException(response.message);
      case 'llamaState':
        return LlamaStateException(response.message);
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

  String? _preloadPreferredBackend() {
    final preferredBackend = _preferredBackend;
    if (_isReady || preferredBackend == null) {
      return null;
    }
    final backend = normalizeLiteRtLmNativeBackendOverride(preferredBackend);
    if (backend == null) {
      return null;
    }
    liteRtLmEnsureNativeBackendSupported(backend);
    final available = liteRtLmAvailableNativeBackendsForCurrentPlatform();
    if (!available.contains(backend)) {
      throw ArgumentError(
        'LiteRtLmBackend backend $backend is not available on '
        '${Platform.operatingSystem}. Available LiteRT-LM backends: '
        '${available.join(', ')}.',
      );
    }
    return backend;
  }
}

/// A generation sent to the worker, tracked until its terminal response even
/// after its stream closes.
final class _WorkerGeneration {
  /// Receives the worker's responses for this generation.
  final ReceivePort responsePort;

  /// Whether this generation was cancelled.
  bool cancelRequested = false;

  _WorkerGeneration(this.responsePort);
}

/// A generation waiting for the worker to finish a cancelled run.
final class _QueuedGeneration {
  /// Sends the generation to the worker.
  final void Function() start;

  /// Ends the generation's stream without output, or with [error].
  final void Function([Object? error]) close;

  _QueuedGeneration(this.start, this.close);
}
