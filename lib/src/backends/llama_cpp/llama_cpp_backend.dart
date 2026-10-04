import 'dart:async';
import 'dart:isolate';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../backend.dart';
import '../model_params_loras.dart';
import '../../core/engine/engine_observer.dart';
import '../../core/llama_logger.dart';
import '../../core/models/chat/content_part.dart';
import '../../core/models/config/gpu_backend.dart';
import '../../core/models/config/gpu_device_info.dart';
import '../../core/models/inference/next_token_scores.dart';
import '../../core/models/config/log_level.dart';
import '../../core/models/diagnostics/model_file_type.dart';
import '../../core/exceptions.dart';
import '../../core/models/inference/model_params.dart';
import '../../core/models/inference/generation_params.dart';
import '../../core/models/inference/generation_usage.dart';
import 'worker.dart';

/// Worker entry point used by [NativeLlamaBackend].
typedef LlamaWorkerEntrypoint = void Function(SendPort initialSendPort);

/// Native implementation of [LlamaBackend] using isolates and FFI.
class NativeLlamaBackend
    implements
        BackendRuntimeIdentity,
        LlamaBackend,
        BackendAvailability,
        BackendRuntimeDiagnostics,
        BackendModelFileTypeDiagnostics,
        BackendGpuEnumeration,
        BackendPerformanceDiagnostics,
        BackendEmbeddings,
        BackendBatchEmbeddings,
        BackendNextTokenScoring,
        BackendStatePersistence,
        BackendTextToSpeech,
        BackendDecision,
        BackendGenerationCapabilitiesSupport,
        BackendVideoRuntimeSupport,
        BackendGenerationLimitReporting,
        BackendGenerationUsageReporting,
        BackendDartLogLevel {
  Isolate? _isolate;
  SendPort? _sendPort;
  RawReceivePort? _workerLogPort;
  RawReceivePort? _workerLifecyclePort;
  LlamaStateException? _workerFailure;
  final Set<ReceivePort> _responsePorts = <ReceivePort>{};
  Future<void>? _isolateStart;
  Future<void>? _disposeStart;
  int _lifecycleEpoch = 0;
  final LlamaWorkerEntrypoint _workerEntrypoint;
  final Duration _workerStartupTimeout;
  final Allocator _cancelFlagAllocator;
  _NativeCancelFlag? _activeCancelToken;
  void Function()? _activeGenerationCleanup;
  void Function(Object error)? _activeGenerationFailure;
  void Function()? _activeFreeToken;
  _QueuedGeneration? _queuedGeneration;
  bool _textToSpeechActive = false;
  bool _textToSpeechCancelRequested = false;
  bool _textToSpeechRequestSent = false;
  _NativeCancelFlag? _textToSpeechCancelFlag;
  final Expando<BackendGenerationLimit> _generationLimits =
      Expando<BackendGenerationLimit>();
  final Expando<LlamaGenerationUsage> _generationUsages =
      Expando<LlamaGenerationUsage>();

  bool _isReady = false;
  LlamaLogLevel _currentLogLevel = LlamaLogLevel.warn;

  /// Creates a new [NativeLlamaBackend] and initializes its ports.
  ///
  /// [cancelFlagAllocator] allocates and frees the one-byte cancel flag of
  /// each generation and text-to-speech synthesis.
  ///
  /// If a worker spawned by this backend exits unexpectedly, pending work
  /// fails with [LlamaStateException] and existing model/context handles are
  /// invalid. Dispose this backend and create a fresh one before reloading.
  /// This does not recover native allocations owned by an abandoned worker.
  /// An externally supplied [initialSendPort] has no owned isolate to monitor.
  NativeLlamaBackend({
    SendPort? initialSendPort,
    LlamaWorkerEntrypoint workerEntrypoint = llamaWorkerEntry,
    Duration workerStartupTimeout = const Duration(seconds: 30),
    Allocator cancelFlagAllocator = malloc,
  }) : _workerEntrypoint = workerEntrypoint,
       _workerStartupTimeout = workerStartupTimeout,
       _cancelFlagAllocator = cancelFlagAllocator {
    if (initialSendPort != null) {
      _sendPort = initialSendPort;
      _isReady = true;
    }
  }

  @override
  bool get isReady => _isReady;

  void _expectDoneResponse(Object? response, String operation) {
    if (response is DoneResponse) {
      return;
    }
    if (response is ErrorResponse) {
      throw _workerError(response);
    }
    throw Exception('Unknown response during $operation');
  }

  Object _workerError(ErrorResponse response) {
    switch (response.kind) {
      case WorkerErrorKind.model:
        return LlamaModelException(response.message);
      case WorkerErrorKind.context:
        return LlamaContextException(response.message);
      case WorkerErrorKind.inference:
        return LlamaInferenceException(response.message);
      case WorkerErrorKind.unsupported:
        return LlamaUnsupportedException(response.message);
      case WorkerErrorKind.state:
        return LlamaStateException(response.message);
      case WorkerErrorKind.speech:
        return LlamaSpeechException(response.message);
      case WorkerErrorKind.audioFormat:
        return LlamaAudioFormatException(response.message);
      case WorkerErrorKind.textToSpeech:
        return LlamaTextToSpeechException(response.message);
      case WorkerErrorKind.generic:
        const exceptionPrefix = 'Exception: ';
        final message = response.message.startsWith(exceptionPrefix)
            ? response.message.substring(exceptionPrefix.length)
            : response.message;
        return Exception(message);
      case WorkerErrorKind.backendInitialization:
        return LlamaBackendInitializationException(response.message);
      case WorkerErrorKind.argument:
        return LlamaArgumentException(response.message);
      case WorkerErrorKind.range:
        return _WorkerRangeError(response.message);
    }
  }

  void _throwIfWorkerFailed() {
    final failure = _workerFailure;
    if (failure != null) throw failure;
  }

  ReceivePort _openResponsePort() {
    _throwIfWorkerFailed();
    final port = ReceivePort();
    _responsePorts.add(port);
    return port;
  }

  void _closeResponsePort(ReceivePort port) {
    _responsePorts.remove(port);
    port.close();
  }

  void _dispatchRequest(ReceivePort port, WorkerRequest request) {
    try {
      _sendPort!.send(request);
    } catch (_) {
      _closeResponsePort(port);
      rethrow;
    }
  }

  Future<Object?> _receiveResponse(ReceivePort port) async {
    try {
      final response = await port.first;
      if (response is ErrorResponse) throw _workerError(response);
      return response;
    } finally {
      _closeResponsePort(port);
    }
  }

  void _workerExited(RawReceivePort lifecyclePort) {
    if (!identical(_workerLifecyclePort, lifecyclePort)) return;
    lifecyclePort.close();
    _workerLifecyclePort = null;
    _workerLogPort?.close();
    _workerLogPort = null;
    _isolate = null;
    _sendPort = null;
    _isReady = false;
    final failure = _workerFailure = LlamaStateException(
      'The llama.cpp worker exited unexpectedly. Its model and context '
      'handles are no longer usable. Dispose this backend and create a '
      'new backend before loading a model again.',
    );
    // An actual onExit notification proves that this worker has stopped
    // reading shared cancellation flags. Error notifications alone do not.
    _activeGenerationFailure?.call(failure);
    for (final port in _responsePorts.toList()) {
      port.sendPort.send(
        ErrorResponse(failure.message, kind: WorkerErrorKind.state),
      );
    }
    _queuedGeneration?.fail(failure);
  }

  Future<void> _ensureIsolate() async {
    _throwIfWorkerFailed();
    final activeDispose = _disposeStart;
    if (activeDispose != null) {
      await activeDispose;
      _throwIfWorkerFailed();
    }
    final lifecycleEpoch = _lifecycleEpoch;
    final existingStart = _isolateStart;
    if (existingStart != null) {
      await existingStart;
      _throwIfDisposedDuringStartup(lifecycleEpoch);
      _throwIfWorkerFailed();
      _isReady = _sendPort != null;
      return;
    }
    if (_sendPort != null) {
      _isReady = true;
      return;
    }

    final start = _startIsolate();
    _isolateStart = start;
    try {
      await start;
      _throwIfDisposedDuringStartup(lifecycleEpoch);
      _throwIfWorkerFailed();
      _isReady = _sendPort != null;
    } finally {
      if (_isolateStart == start) {
        _isolateStart = null;
      }
    }
  }

  Future<void> _startIsolate() async {
    final completer = Completer<void>();
    final tempPort = ReceivePort();
    final logPort = _openWorkerLogPort();
    final lifecyclePort = RawReceivePort();
    var initialized = false;
    lifecyclePort.keepIsolateAlive = false;
    _workerLifecyclePort = lifecyclePort;
    lifecyclePort.handler = (Object? message) {
      if (!identical(_workerLifecyclePort, lifecyclePort)) return;
      if (!completer.isCompleted) {
        tempPort.sendPort.send(message);
      } else if (message == null && initialized) {
        _workerExited(lifecyclePort);
      }
    };
    SendPort? workerSendPort;
    tempPort.listen((msg) {
      if (msg is SendPort && workerSendPort == null) {
        workerSendPort = msg;
        workerSendPort!.send(
          WorkerHandshake(
            _currentLogLevel,
            tempPort.sendPort,
            dartLogLevel: LlamaLogger.instance.level,
            logPort: logPort.sendPort,
          ),
        );
        return;
      }
      if (completer.isCompleted) {
        return;
      }
      if (msg is DoneResponse && workerSendPort != null) {
        initialized = true;
        _sendPort = workerSendPort;
        completer.complete();
        return;
      }
      if (msg is ErrorResponse && workerSendPort != null) {
        completer.completeError(_workerError(msg));
        return;
      }
      if (msg is List<Object?> && msg.isNotEmpty) {
        final phase = workerSendPort != null
            ? 'during backend initialization'
            : 'before providing its request port';
        completer.completeError(
          LlamaBackendInitializationException(
            'The llama.cpp worker exited $phase: ${msg.first}',
            msg.length > 1 ? msg[1] : null,
          ),
        );
        return;
      }
      final reason = workerSendPort != null
          ? 'before acknowledging the backend initialization handshake'
          : 'before providing its request port';
      completer.completeError(
        LlamaBackendInitializationException(
          msg == null
              ? 'The llama.cpp worker exited $reason.'
              : 'The llama.cpp worker returned an unexpected startup '
                    'response (${msg.runtimeType}) $reason. The worker and '
                    'Dart package may be incompatible.',
        ),
      );
    });
    try {
      _isolate = await Isolate.spawn(
        _workerEntrypoint,
        tempPort.sendPort,
        onError: lifecyclePort.sendPort,
        onExit: lifecyclePort.sendPort,
        errorsAreFatal: true,
      );
      await completer.future.timeout(
        _workerStartupTimeout,
        onTimeout: () {
          throw LlamaBackendInitializationException(
            'Timed out after ${_workerStartupTimeout.inMilliseconds} ms '
            'waiting for the llama.cpp worker to initialize its backend. '
            'The native runtime may be unavailable or unresponsive.',
          );
        },
      );
    } catch (error) {
      _isReady = false;
      _sendPort = null;
      _isolate?.kill(priority: Isolate.immediate);
      _isolate = null;
      _closeWorkerLogPort(logPort);
      lifecyclePort.close();
      if (identical(_workerLifecyclePort, lifecyclePort)) {
        _workerLifecyclePort = null;
      }
      if (error is LlamaBackendInitializationException) {
        rethrow;
      }
      throw LlamaBackendInitializationException(
        'Failed to start the llama.cpp worker isolate: $error',
      );
    } finally {
      tempPort.close();
    }
  }

  RawReceivePort _openWorkerLogPort() {
    final port = RawReceivePort((Object? message) {
      if (message is WorkerLogMessage) {
        message.emit();
      }
    });
    port.keepIsolateAlive = false;
    _workerLogPort = port;
    return port;
  }

  void _closeWorkerLogPort(RawReceivePort port) {
    port.close();
    if (identical(_workerLogPort, port)) {
      _workerLogPort = null;
    }
  }

  void _throwIfDisposedDuringStartup(int lifecycleEpoch) {
    if (lifecycleEpoch != _lifecycleEpoch) {
      throw LlamaBackendInitializationException(
        'The llama.cpp worker was disposed during backend initialization.',
      );
    }
  }

  @override
  void cancelGeneration() {
    _activeCancelToken?.raise();
    _queuedGeneration?.close();
  }

  @override
  Future<void> setLogLevel(LlamaLogLevel level) async {
    _currentLogLevel = level;
    await _sendToRunningWorker(
      (sendPort) => LogLevelRequest(level, sendPort),
      'log-level update',
    );
  }

  @override
  Future<void> setDartLogLevel(LlamaLogLevel level) => _sendToRunningWorker(
    (sendPort) => DartLogLevelRequest(level, sendPort),
    'Dart log-level update',
  );

  Future<void> _sendToRunningWorker(
    WorkerRequest Function(SendPort sendPort) buildRequest,
    String operation,
  ) async {
    _throwIfWorkerFailed();
    final activeDispose = _disposeStart;
    if (activeDispose != null) {
      await activeDispose;
      _throwIfWorkerFailed();
    }
    final lifecycleEpoch = _lifecycleEpoch;
    final startup = _isolateStart;
    if (startup != null) {
      await startup;
      _throwIfDisposedDuringStartup(lifecycleEpoch);
      _throwIfWorkerFailed();
    }
    final sendPort = _sendPort;
    if (sendPort != null) {
      final rp = _openResponsePort();
      try {
        sendPort.send(buildRequest(rp.sendPort));
        _expectDoneResponse(await _receiveResponse(rp), operation);
      } finally {
        _closeResponsePort(rp);
      }
    }
  }

  @override
  Future<int> modelLoad(String path, ModelParams params) async {
    await _ensureIsolate();
    final rp = _openResponsePort();
    _dispatchRequest(rp, ModelLoadRequest(path, params, rp.sendPort));
    final res = await _receiveResponse(rp);
    if (res is HandleResponse) return res.handle;
    if (res is ErrorResponse) throw _workerError(res);
    throw Exception("Unknown response during model load");
  }

  @override
  Future<int> modelLoadFromUrl(
    String url,
    ModelParams params, {
    Function(double progress)? onProgress,
  }) async {
    throw LlamaUnsupportedException(
      'The native llama.cpp backend cannot load a model from a URL: '
      'supportsUrlLoading is false. Download the model first, then call '
      'modelLoad with a local path.',
    );
  }

  @override
  Future<void> modelFree(int modelHandle) async {
    _throwIfWorkerFailed();
    if (_sendPort == null) return;
    final rp = _openResponsePort();
    _dispatchRequest(rp, ModelFreeRequest(modelHandle, rp.sendPort));
    final res = await _receiveResponse(rp);
    _expectDoneResponse(res, 'model free');
  }

  @override
  Future<int> contextCreate(int modelHandle, ModelParams params) async {
    await _ensureIsolate();
    final rp = _openResponsePort();
    _dispatchRequest(
      rp,
      ContextCreateRequest(modelHandle, params, rp.sendPort),
    );
    final res = await _receiveResponse(rp);
    if (res is ErrorResponse) throw _workerError(res);
    if (res is! HandleResponse) {
      throw Exception("Unknown response during context creation");
    }
    final contextHandle = res.handle;
    await applyModelParamsLoras(
      params.loras,
      apply: (lora) => setLoraAdapter(contextHandle, lora.path, lora.scale),
      rollback: () => contextFree(contextHandle),
    );
    return contextHandle;
  }

  @override
  Future<void> contextFree(int contextHandle) async {
    _throwIfWorkerFailed();
    if (_sendPort == null) return;
    final rp = _openResponsePort();
    _dispatchRequest(rp, ContextFreeRequest(contextHandle, rp.sendPort));
    final res = await _receiveResponse(rp);
    _expectDoneResponse(res, 'context free');
  }

  @override
  Future<int> getContextSize(int contextHandle) async {
    _throwIfWorkerFailed();
    if (_sendPort == null) return 0;
    final rp = _openResponsePort();
    _dispatchRequest(rp, GetContextSizeRequest(contextHandle, rp.sendPort));
    final res = await _receiveResponse(rp);
    if (res is GetContextSizeResponse) return res.size;
    return 0;
  }

  @override
  Stream<List<int>> generate(
    int contextHandle,
    String prompt,
    GenerationParams params, {
    List<LlamaContentPart>? parts,
  }) {
    final failure = _workerFailure;
    if (failure != null) return Stream<List<int>>.error(failure);
    final runningToken = _activeCancelToken;
    if (_queuedGeneration != null ||
        (runningToken != null && !runningToken.isRaised)) {
      return Stream<List<int>>.error(
        LlamaStateException(
          'llama.cpp generation is already in progress. Cancel it or wait '
          'for its stream to end before starting another.',
        ),
      );
    }

    late final StreamController<List<int>> controller;
    void Function() cancel = () {};
    controller = StreamController<List<int>>(onCancel: () => cancel());
    final stream = controller.stream;

    void start() {
      cancel = _sendGeneration(
        controller,
        stream,
        contextHandle,
        prompt,
        params,
        parts,
      );
    }

    if (runningToken == null) {
      start();
      return stream;
    }

    late final _QueuedGeneration queued;
    void close() {
      if (_queuedGeneration == queued) {
        _queuedGeneration = null;
      }
      if (!controller.isClosed) {
        unawaited(controller.close());
      }
    }

    queued = _QueuedGeneration(start, close, (error) {
      if (!controller.isClosed) controller.addError(error);
      close();
    });
    cancel = close;
    _queuedGeneration = queued;
    return stream;
  }

  void _startQueuedGeneration() {
    final queued = _queuedGeneration;
    if (queued == null) {
      return;
    }
    _queuedGeneration = null;
    final failure = _workerFailure;
    if (failure != null) {
      queued.fail(failure);
    } else if (_disposeStart != null) {
      queued.close();
    } else {
      queued.start();
    }
  }

  /// Sends a generation to the worker and returns the cancel callback of
  /// [stream].
  void Function() _sendGeneration(
    StreamController<List<int>> controller,
    Stream<List<int>> stream,
    int contextHandle,
    String prompt,
    GenerationParams params,
    List<LlamaContentPart>? parts,
  ) {
    final rp = _openResponsePort();

    final cancelToken = _NativeCancelFlag(_cancelFlagAllocator);
    _activeCancelToken = cancelToken;

    // The cancel token is shared with the worker isolate, which polls it every
    // decode iteration. It must only be freed once the worker has stopped
    // reading it. Cleanup is split in two: detachAndClose() runs eagerly on
    // cancel and only tears down the Dart-side controller, while freeToken()
    // frees the native token and closes the response port. The only safe times
    // to free are when the worker proves it has stopped: a terminal
    // DoneResponse/ErrorResponse (the worker breaks its decode loop on seeing
    // the cancel flag and then emits one), or dispose() freeing it after
    // killing the worker isolate. A timer-based backstop is deliberately
    // avoided: it could fire mid-decode (e.g. during a slow prompt eval) and
    // reintroduce the use-after-free. Worst case (a wedged worker that never
    // responds and is never disposed) leaks a single byte, which is acceptable.
    var tokenFreed = false;
    late final void Function() freeToken;
    freeToken = () {
      if (tokenFreed) {
        return;
      }
      tokenFreed = true;
      _closeResponsePort(rp);
      cancelToken.free();
      if (_activeCancelToken == cancelToken) {
        _activeCancelToken = null;
      }
      if (_activeFreeToken == freeToken) {
        _activeFreeToken = null;
        _activeGenerationFailure = null;
      }
    };
    _activeFreeToken = freeToken;

    var detached = false;
    void detachAndClose() {
      if (detached) {
        return;
      }
      detached = true;
      if (!controller.isClosed) {
        unawaited(controller.close());
      }
      if (_activeGenerationCleanup == detachAndClose) {
        _activeGenerationCleanup = null;
      }
    }

    _activeGenerationCleanup = detachAndClose;
    _activeGenerationFailure = (error) {
      if (!controller.isClosed) controller.addError(error);
      detachAndClose();
      freeToken();
      _activeGenerationFailure = null;
    };

    try {
      _dispatchRequest(
        rp,
        GenerateRequest(
          contextHandle,
          prompt,
          params,
          cancelToken.address,
          rp.sendPort,
          parts: parts,
        ),
      );
    } catch (error, stackTrace) {
      // The worker never received the request, such as for a parameter that
      // cannot cross an isolate, so this generation fails alone and the
      // backend stays usable.
      if (!controller.isClosed) {
        controller.addError(error, stackTrace);
      }
      detachAndClose();
      freeToken();
      _startQueuedGeneration();
      return () {};
    }

    rp.listen((msg) {
      if (msg is TokenResponse) {
        if (!controller.isClosed) {
          controller.add(msg.bytes);
        }
      } else if (msg is DoneResponse) {
        final limit = msg.generationLimit;
        if (limit != null && !detached) {
          _generationLimits[stream] = limit;
        }
        final usage = msg.generationUsage;
        if (usage != null) {
          _generationUsages[stream] = usage;
        }
        detachAndClose();
        freeToken();
        _startQueuedGeneration();
      } else if (msg is ErrorResponse) {
        if (!controller.isClosed) {
          controller.addError(_workerError(msg));
        }
        detachAndClose();
        freeToken();
        _startQueuedGeneration();
      }
    });

    return () {
      // Close the Dart side immediately, but keep the response port open and
      // the native token alive so the worker can observe the cancel flag and
      // emit its terminal response, at which point freeToken() runs.
      cancelToken.raise();
      detachAndClose();
    };
  }

  @override
  BackendGenerationLimit? generationLimitOf(Stream<List<int>> generation) =>
      _generationLimits[generation];

  @override
  LlamaGenerationUsage? generationUsageOf(Stream<List<int>> generation) =>
      _generationUsages[generation];

  @override
  Future<List<int>> tokenize(
    int modelHandle,
    String text, {
    bool addSpecial = true,
  }) async {
    final rp = _openResponsePort();
    _dispatchRequest(
      rp,
      TokenizeRequest(modelHandle, text, addSpecial, rp.sendPort),
    );
    final res = await _receiveResponse(rp);
    if (res is TokenizeResponse) return res.tokens;
    if (res is ErrorResponse) throw _workerError(res);
    throw Exception("Tokenization failed");
  }

  @override
  Future<List<double>> embed(
    int contextHandle,
    String text, {
    bool normalize = true,
  }) async {
    await _ensureIsolate();
    final rp = _openResponsePort();
    _dispatchRequest(
      rp,
      EmbedRequest(contextHandle, text, normalize, rp.sendPort),
    );
    final res = await _receiveResponse(rp);
    if (res is EmbedResponse) return res.embedding;
    if (res is ErrorResponse) throw _workerError(res);
    throw Exception('Embedding failed');
  }

  @override
  Future<LlamaNextTokenScores> scoreNextToken(
    int contextHandle,
    String prompt, {
    required List<int> candidates,
    required int topK,
    required bool reusePromptPrefix,
  }) async {
    await _ensureIsolate();
    final rp = _openResponsePort();
    _dispatchRequest(
      rp,
      ScoreNextTokenRequest(
        contextHandle,
        prompt,
        List<int>.from(candidates),
        topK,
        reusePromptPrefix,
        rp.sendPort,
      ),
    );
    final res = await _receiveResponse(rp);
    if (res is ScoreNextTokenResponse) return res.scores;
    if (res is ErrorResponse) throw _workerError(res);
    throw Exception('Next-token scoring failed');
  }

  @override
  Future<List<List<double>>> embedBatch(
    int contextHandle,
    List<String> texts, {
    bool normalize = true,
  }) async {
    if (texts.isEmpty) {
      return const <List<double>>[];
    }

    await _ensureIsolate();
    final rp = _openResponsePort();
    _dispatchRequest(
      rp,
      EmbedBatchRequest(
        contextHandle,
        List<String>.from(texts),
        normalize,
        rp.sendPort,
      ),
    );
    final res = await _receiveResponse(rp);
    if (res is EmbedBatchResponse) return res.embeddings;
    if (res is ErrorResponse) throw _workerError(res);
    throw Exception('Batch embedding failed');
  }

  @override
  Future<String> detokenize(
    int modelHandle,
    List<int> tokens, {
    bool special = false,
  }) async {
    final rp = _openResponsePort();
    _dispatchRequest(
      rp,
      DetokenizeRequest(modelHandle, tokens, special, rp.sendPort),
    );
    final res = await _receiveResponse(rp);
    if (res is DetokenizeResponse) return res.text;
    if (res is ErrorResponse) throw _workerError(res);
    throw Exception("Detokenization failed");
  }

  @override
  Future<Map<String, String>> modelMetadata(int modelHandle) async {
    final rp = _openResponsePort();
    _dispatchRequest(rp, MetadataRequest(modelHandle, rp.sendPort));
    final res = await _receiveResponse(rp);
    if (res is MetadataResponse) return res.metadata;
    return {};
  }

  @override
  Future<ModelFileType?> getModelFileType(int modelHandle) async {
    final rp = _openResponsePort();
    _dispatchRequest(rp, ModelFileTypeRequest(modelHandle, rp.sendPort));
    final res = await _receiveResponse(rp);
    if (res is ModelFileTypeResponse) return res.modelFileType;
    if (res is ErrorResponse) throw _workerError(res);
    return null;
  }

  @override
  Future<bool> stateSaveFile(
    int contextHandle,
    String path,
    List<int> tokens,
  ) async {
    await _ensureIsolate();
    final rp = _openResponsePort();
    _dispatchRequest(
      rp,
      StateSaveFileRequest(
        contextHandle,
        path,
        List<int>.from(tokens),
        rp.sendPort,
      ),
    );
    final res = await _receiveResponse(rp);
    if (res is StateSaveFileResponse) return res.success;
    if (res is ErrorResponse) throw _workerError(res);
    throw Exception('State save failed');
  }

  @override
  Future<StateLoadResult> stateLoadFile(
    int contextHandle,
    String path,
    int tokenCapacity,
  ) async {
    await _ensureIsolate();
    final rp = _openResponsePort();
    _dispatchRequest(
      rp,
      StateLoadFileRequest(contextHandle, path, tokenCapacity, rp.sendPort),
    );
    final res = await _receiveResponse(rp);
    if (res is StateLoadFileResponse) {
      return StateLoadResult(tokens: res.tokens);
    }
    if (res is ErrorResponse) throw _workerError(res);
    throw Exception('State load failed');
  }

  @override
  Future<void> setLoraAdapter(
    int contextHandle,
    String path,
    double scale,
  ) async {
    await _ensureIsolate();
    final rp = _openResponsePort();
    _dispatchRequest(
      rp,
      LoraRequest(
        contextHandle,
        'set',
        path: path,
        scale: scale,
        sendPort: rp.sendPort,
      ),
    );
    final res = await _receiveResponse(rp);
    _expectDoneResponse(res, 'set LoRA adapter');
  }

  @override
  Future<void> removeLoraAdapter(int contextHandle, String path) async {
    await _ensureIsolate();
    final rp = _openResponsePort();
    _dispatchRequest(
      rp,
      LoraRequest(contextHandle, 'remove', path: path, sendPort: rp.sendPort),
    );
    final res = await _receiveResponse(rp);
    _expectDoneResponse(res, 'remove LoRA adapter');
  }

  @override
  Future<void> clearLoraAdapters(int contextHandle) async {
    await _ensureIsolate();
    final rp = _openResponsePort();
    _dispatchRequest(
      rp,
      LoraRequest(contextHandle, 'clear', sendPort: rp.sendPort),
    );
    final res = await _receiveResponse(rp);
    _expectDoneResponse(res, 'clear LoRA adapters');
  }

  @override
  LlamaRuntime get runtime => LlamaRuntime.llamaCpp;

  @override
  Future<String> getBackendName() async {
    await _ensureIsolate();
    final rp = _openResponsePort();
    _dispatchRequest(rp, BackendInfoRequest(rp.sendPort));
    final res = await _receiveResponse(rp);
    return (res as BackendInfoResponse).name;
  }

  @override
  Future<String> getAvailableBackends() async {
    await _ensureIsolate();
    final rp = _openResponsePort();
    _dispatchRequest(rp, AvailableBackendsRequest(rp.sendPort));
    final res = await _receiveResponse(rp);
    return (res as BackendInfoResponse).name;
  }

  @override
  Future<int?> getResolvedGpuLayers() async {
    await _ensureIsolate();
    final rp = _openResponsePort();
    _dispatchRequest(rp, ResolvedGpuLayersRequest(rp.sendPort));
    final res = await _receiveResponse(rp);
    return (res as ResolvedGpuLayersResponse).layers;
  }

  @override
  Future<BackendPerfContextData?> getPerformanceContext(
    int contextHandle,
  ) async {
    await _ensureIsolate();
    final rp = _openResponsePort();
    _dispatchRequest(rp, PerformanceContextRequest(contextHandle, rp.sendPort));
    final res = await _receiveResponse(rp);
    if (res is PerformanceContextResponse) {
      return BackendPerfContextData(
        loadMs: res.loadMs,
        promptEvalMs: res.promptEvalMs,
        evalMs: res.evalMs,
        sampleMs: res.sampleMs,
        decodeMs: res.decodeMs,
        promptEvalTokens: res.promptEvalTokens,
        evalTokens: res.evalTokens,
        sampleCount: res.sampleCount,
        reusedGraphs: res.reusedGraphs,
        speculativeDraftTokens: res.speculativeDraftTokens,
        speculativeAcceptedDraftTokens: res.speculativeAcceptedDraftTokens,
        speculativeDraftAttempts: res.speculativeDraftAttempts,
        speculativeVerifyTokens: res.speculativeVerifyTokens,
        speculativeReplayTokens: res.speculativeReplayTokens,
        speculativeDraftMs: res.speculativeDraftMs,
        speculativeVerifyMs: res.speculativeVerifyMs,
      );
    }
    if (res is ErrorResponse) {
      throw _workerError(res);
    }
    return null;
  }

  @override
  bool get supportsUrlLoading => false;

  @override
  Future<bool> isGpuSupported() async {
    await _ensureIsolate();
    final rp = _openResponsePort();
    _dispatchRequest(rp, GpuSupportRequest(rp.sendPort));
    final res = await _receiveResponse(rp);
    return (res as GpuSupportResponse).support;
  }

  @override
  Future<void> dispose() async {
    final existingDispose = _disposeStart;
    if (existingDispose != null) {
      await existingDispose;
      return;
    }
    final dispose = _disposeWorker();
    _disposeStart = dispose;
    try {
      await dispose;
    } finally {
      if (_disposeStart == dispose) {
        _disposeStart = null;
      }
    }
  }

  Future<void> _disposeWorker() async {
    // A synthesis claimed after this point sends its flag to the next worker,
    // so this dispose must not free it.
    final textToSpeechCancelFlag = _textToSpeechCancelFlag;
    _lifecycleEpoch += 1;
    _isReady = false;
    final startup = _isolateStart;
    if (startup != null) {
      try {
        await startup;
      } catch (_) {
        // Startup already performed its own failure cleanup.
      }
    }
    // Signal any in-flight generation to stop and close the Dart side, but do
    // not free the shared cancel token yet: the worker may still poll it. The
    // worker awaits the in-flight generation before acking the dispose, so its
    // terminal response normally frees the token first. After killing the
    // worker (below) the token is provably unread, so freeing it there is safe
    // and idempotent (guarded by the freeToken tokenFreed flag).
    cancelGeneration();
    _activeGenerationCleanup?.call();
    cancelTextToSpeech();

    if (_sendPort != null) {
      final rp = _openResponsePort();
      try {
        _dispatchRequest(rp, DisposeRequest(rp.sendPort));
        await _receiveResponse(rp);
        // Normal disposal can also produce onExit before this continuation.
        // Its acknowledgement distinguishes that exit from an abandoned RPC.
        _workerFailure = null;
      } on LlamaStateException {
        if (_workerFailure == null) rethrow;
        // The worker exited without replying. Disposal has no live worker
        // left to await; outstanding operations retain their typed failure.
      } finally {
        _closeResponsePort(rp);
      }
    }
    _isolate?.kill();
    _isolate = null;
    _sendPort = null;
    _isolateStart = null;
    _workerLogPort?.close();
    _workerLogPort = null;
    _workerLifecyclePort?.close();
    _workerLifecyclePort = null;
    // Worker is gone; free the token if a terminal response did not already.
    _activeFreeToken?.call();
    _queuedGeneration?.close();
    textToSpeechCancelFlag?.free();
    _activeCancelToken = null;
    _activeGenerationCleanup = null;
    _activeGenerationFailure = null;
    _activeFreeToken = null;
    _isReady = false;
  }

  @override
  Future<int?> multimodalContextCreate(
    int modelHandle,
    String mmProjPath,
  ) async {
    final rp = _openResponsePort();
    _dispatchRequest(
      rp,
      MultimodalContextCreateRequest(modelHandle, mmProjPath, rp.sendPort),
    );
    final res = await _receiveResponse(rp);
    if (res is HandleResponse) return res.handle;
    if (res is ErrorResponse) throw _workerError(res);
    return null;
  }

  @override
  Future<void> multimodalContextFree(int mmContextHandle) async {
    final rp = _openResponsePort();
    _dispatchRequest(
      rp,
      MultimodalContextFreeRequest(mmContextHandle, rp.sendPort),
    );
    final res = await _receiveResponse(rp);
    _expectDoneResponse(res, 'multimodal context free');
  }

  @override
  Future<bool> supportsAudio(int mmContextHandle) async {
    final rp = _openResponsePort();
    _dispatchRequest(rp, SupportsAudioRequest(mmContextHandle, rp.sendPort));
    final res = await _receiveResponse(rp);
    if (res is ErrorResponse) throw _workerError(res);
    return res as bool;
  }

  @override
  Future<bool?> supportsVideoRuntime(int mmContextHandle) async {
    final rp = _openResponsePort();
    _dispatchRequest(rp, SupportsVideoRequest(mmContextHandle, rp.sendPort));
    final res = await _receiveResponse(rp);
    if (res is ErrorResponse) throw _workerError(res);
    return res as bool;
  }

  @override
  Future<BackendTextToSpeechCapabilities> textToSpeechCapabilities(
    int contextHandle,
    int mmContextHandle,
  ) async {
    await _ensureIsolate();
    final rp = _openResponsePort();
    _dispatchRequest(
      rp,
      TextToSpeechCapabilitiesRequest(
        contextHandle,
        mmContextHandle,
        rp.sendPort,
      ),
    );
    final response = await _receiveResponse(rp);
    if (response is TextToSpeechCapabilitiesResponse) {
      return response.capabilities;
    }
    if (response is ErrorResponse) {
      throw _workerError(response);
    }
    throw LlamaTextToSpeechException(
      'Unexpected native text-to-speech capability response.',
    );
  }

  @override
  Future<BackendTextToSpeechResult> synthesizeTextToSpeech(
    int contextHandle,
    int mmContextHandle,
    BackendTextToSpeechRequest request, {
    void Function(BackendTextToSpeechProgress progress)? onProgress,
  }) async {
    if (_textToSpeechActive) {
      throw LlamaStateException(
        'llama.cpp text-to-speech synthesis is already in progress.',
      );
    }
    // Claimed before the first await so a cancel arriving during isolate
    // startup is recorded rather than dropped.
    _textToSpeechActive = true;
    _textToSpeechCancelRequested = false;
    _textToSpeechRequestSent = false;
    final cancelFlag = _NativeCancelFlag(_cancelFlagAllocator);
    _textToSpeechCancelFlag = cancelFlag;
    late final ReceivePort rp;
    try {
      await _ensureIsolate();
      rp = _openResponsePort();
    } catch (_) {
      _textToSpeechActive = false;
      cancelFlag.free();
      rethrow;
    }
    final completer = Completer<BackendTextToSpeechResult>();
    try {
      _dispatchRequest(
        rp,
        TextToSpeechSynthesizeRequest(
          contextHandle,
          mmContextHandle,
          request,
          cancelFlag.address,
          rp.sendPort,
        ),
      );
    } catch (_) {
      _textToSpeechActive = false;
      cancelFlag.free();
      rethrow;
    }
    _textToSpeechRequestSent = true;
    if (_textToSpeechCancelRequested) {
      _sendPort!.send(TextToSpeechCancelRequest());
    }

    late final StreamSubscription<dynamic> subscription;
    subscription = rp.listen((response) {
      if (response is TextToSpeechProgressResponse) {
        onProgress?.call(response.progress);
        return;
      }
      if (response is TextToSpeechResultResponse) {
        final bytes = response.pcm.materialize().asUint8List();
        final samples = Float32List.view(
          bytes.buffer,
          bytes.offsetInBytes,
          bytes.lengthInBytes ~/ Float32List.bytesPerElement,
        );
        if (!completer.isCompleted) {
          completer.complete(
            BackendTextToSpeechResult(
              samples: samples,
              sampleRateHz: response.sampleRateHz,
              channelCount: response.channelCount,
              framesGenerated: response.framesGenerated,
              truncated: response.truncated,
            ),
          );
        }
        return;
      }
      if (response is ErrorResponse && !completer.isCompleted) {
        completer.completeError(_workerError(response));
      }
    });

    try {
      return await completer.future;
    } finally {
      _textToSpeechActive = false;
      cancelFlag.free();
      await subscription.cancel();
      _closeResponsePort(rp);
    }
  }

  @override
  void cancelTextToSpeech() {
    if (!_textToSpeechActive) {
      return;
    }
    _textToSpeechCancelRequested = true;
    _textToSpeechCancelFlag?.raise();
    if (_textToSpeechRequestSent) {
      _sendPort?.send(TextToSpeechCancelRequest());
    }
  }

  @override
  Future<BackendGenerationCapabilities> generationCapabilities() async {
    return const BackendGenerationCapabilities(
      penalty: true,
      presencePenalty: true,
      minP: true,
      thinkingBudget: true,
      streamBatching: true,
      speculativeDecodingStrategies: <SpeculativeDecodingStrategy>{
        SpeculativeDecodingStrategy.backendDefault,
        SpeculativeDecodingStrategy.mtp,
        SpeculativeDecodingStrategy.ngramSimple,
        SpeculativeDecodingStrategy.draftSimple,
        SpeculativeDecodingStrategy.draftEagle3,
        SpeculativeDecodingStrategy.draftDflash,
        SpeculativeDecodingStrategy.ngramMapK,
        SpeculativeDecodingStrategy.ngramMapK4v,
        SpeculativeDecodingStrategy.ngramMod,
        SpeculativeDecodingStrategy.ngramCache,
        SpeculativeDecodingStrategy.draftDspark,
      },
    );
  }

  @override
  Future<BackendDecisionCapabilities> decisionCapabilities(
    int modelHandle,
  ) async {
    await _ensureIsolate();
    final rp = _openResponsePort();
    _dispatchRequest(rp, DecisionCapabilitiesRequest(modelHandle, rp.sendPort));
    final response = await _receiveResponse(rp);
    if (response is DecisionCapabilitiesResponse) {
      return response.capabilities;
    }
    throw _unexpectedDecisionResponse(response, 'capability probe');
  }

  @override
  Future<BackendDecisionHeadInfo> decisionHeadLoad(
    int modelHandle,
    String headPath, {
    String? configPath,
  }) async {
    await _ensureIsolate();
    final rp = _openResponsePort();
    _dispatchRequest(
      rp,
      DecisionHeadLoadRequest(modelHandle, headPath, configPath, rp.sendPort),
    );
    final response = await _receiveResponse(rp);
    if (response is DecisionHeadLoadResponse) {
      return response.head;
    }
    throw _unexpectedDecisionResponse(response, 'head load');
  }

  @override
  Future<List<BackendDecisionOutput>> decisionRun(
    int headHandle,
    List<BackendDecisionSequence> sequences,
  ) async {
    await _ensureIsolate();
    final rp = _openResponsePort();
    _dispatchRequest(
      rp,
      DecisionRunRequest(
        headHandle,
        List<BackendDecisionSequence>.of(sequences, growable: false),
        rp.sendPort,
      ),
    );
    final response = await _receiveResponse(rp);
    if (response is DecisionRunResponse) {
      return response.outputs;
    }
    throw _unexpectedDecisionResponse(response, 'run');
  }

  @override
  Future<void> decisionHeadFree(int headHandle) async {
    _throwIfWorkerFailed();
    if (_sendPort == null || _disposeStart != null) return;
    final rp = _openResponsePort();
    _dispatchRequest(rp, DecisionHeadFreeRequest(headHandle, rp.sendPort));
    final response = await _receiveResponse(rp);
    _expectDoneResponse(response, 'decision head free');
  }

  Object _unexpectedDecisionResponse(Object? response, String operation) {
    if (response is ErrorResponse) {
      return _workerError(response);
    }
    return LlamaDecisionException(
      'Unexpected llama.cpp worker response (${response.runtimeType}) to a '
      'decision $operation.',
    );
  }

  @override
  Future<bool> supportsVision(int mmContextHandle) async {
    final rp = _openResponsePort();
    _dispatchRequest(rp, SupportsVisionRequest(mmContextHandle, rp.sendPort));
    final res = await _receiveResponse(rp);
    return res as bool;
  }

  @override
  Future<({int total, int free})> getVramInfo() async {
    await _ensureIsolate();
    final rp = _openResponsePort();
    _dispatchRequest(rp, SystemInfoRequest(rp.sendPort));
    final res = await _receiveResponse(rp);
    if (res is SystemInfoResponse) {
      return (total: res.totalVram, free: res.freeVram);
    }
    return (total: 0, free: 0);
  }

  @override
  Future<List<GpuDeviceInfo>> listGpuDevices({
    List<GpuBackend> probeBackends = const [],
  }) async {
    await _ensureIsolate();
    final rp = _openResponsePort();
    _dispatchRequest(rp, ListGpuDevicesRequest(probeBackends, rp.sendPort));
    final res = await _receiveResponse(rp);
    if (res is ListGpuDevicesResponse) {
      return res.devices;
    }
    return const [];
  }

  @override
  Future<String> applyChatTemplate(
    int modelHandle,
    List<Map<String, dynamic>> messages, {
    String? customTemplate,
    bool addAssistant = true,
  }) async {
    await _ensureIsolate();
    final rp = _openResponsePort();
    _dispatchRequest(
      rp,
      ChatTemplateRequest(
        modelHandle,
        messages,
        customTemplate,
        addAssistant,
        rp.sendPort,
      ),
    );
    final res = await _receiveResponse(rp);
    if (res is ChatTemplateResponse) return res.result;
    if (res is ErrorResponse) throw _workerError(res);
    throw Exception("Unknown response during chat template application");
  }
}

/// A one-byte cancel flag that the worker isolate reads, including from native
/// code while a text-to-speech step runs.
///
/// The backend frees it after the worker's terminal response for the request
/// that carries it, after the worker that received that request acknowledges
/// a dispose, or when that request was never sent; never on cancel or on a
/// timer.
final class _NativeCancelFlag {
  final Allocator _allocator;
  Pointer<Int8>? _pointer;

  /// Allocates the flag and lowers it.
  _NativeCancelFlag(this._allocator) : _pointer = _allocator<Int8>()..value = 0;

  /// The flag's native address.
  int get address => _pointer!.address;

  /// Whether the flag is raised; false once it is freed.
  bool get isRaised => _pointer?.value == 1;

  /// Raises the flag unless it was freed.
  void raise() => _pointer?.value = 1;

  /// Frees the flag; later calls do nothing.
  void free() {
    final pointer = _pointer;
    if (pointer == null) {
      return;
    }
    _pointer = null;
    _allocator.free(pointer);
  }
}

/// A generation waiting for the worker to stop reading the cancel token of a
/// cancelled run.
final class _QueuedGeneration {
  /// Sends the generation to the worker.
  final void Function() start;

  /// Ends the generation's stream without output.
  final void Function() close;

  /// Fails an unsent generation when its worker exits.
  final void Function(Object error) fail;

  _QueuedGeneration(this.start, this.close, this.fail);
}

/// A [RangeError] raised on the worker isolate, described as it was there.
class _WorkerRangeError extends RangeError {
  _WorkerRangeError(this._description) : super(null);

  final String _description;

  @override
  String toString() => _description;
}
