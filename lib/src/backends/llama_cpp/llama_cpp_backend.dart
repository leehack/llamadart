import 'dart:async';
import 'dart:isolate';
import 'dart:ffi';
import 'package:ffi/ffi.dart';
import '../backend.dart';
import '../../core/models/chat/content_part.dart';
import '../../core/models/config/log_level.dart';
import '../../core/models/inference/model_params.dart';
import '../../core/models/inference/generation_params.dart';
import 'worker.dart';

/// Creates a [NativeLlamaBackend].
LlamaBackend createBackend() => NativeLlamaBackend();

/// Native implementation of [LlamaBackend] using isolates and FFI.
class NativeLlamaBackend
    implements
        LlamaBackend,
        BackendAvailability,
        BackendRuntimeDiagnostics,
        BackendPerformanceDiagnostics,
        BackendEmbeddings,
        BackendBatchEmbeddings,
        BackendStatePersistence {
  Isolate? _isolate;
  SendPort? _sendPort;
  final ReceivePort _responsesPort = ReceivePort();
  Pointer<Int8>? _activeCancelToken;
  void Function()? _activeGenerationCleanup;

  bool _isReady = false;
  LlamaLogLevel _currentLogLevel = LlamaLogLevel.warn;

  /// Creates a new [NativeLlamaBackend] and initializes its ports.
  NativeLlamaBackend({SendPort? initialSendPort}) {
    _responsesPort.listen(_handleResponse);
    if (initialSendPort != null) {
      _sendPort = initialSendPort;
      _isReady = true;
    }
  }

  @override
  bool get isReady => _isReady;

  void _handleResponse(dynamic message) {
    if (message is SendPort) {
      _sendPort = message;
      // Complete handshake
      _sendPort!.send(WorkerHandshake(_currentLogLevel));
      // Sync log level
      _sendPort!.send(
        LogLevelRequest(_currentLogLevel, ReceivePort().sendPort),
      );
    }
  }

  Future<void> _ensureIsolate() async {
    if (_sendPort != null) {
      _isReady = true;
      return;
    }

    final completer = Completer<void>();
    final tempPort = ReceivePort();
    tempPort.listen((msg) {
      if (msg is SendPort) {
        _sendPort = msg;
        _sendPort!.send(WorkerHandshake(_currentLogLevel));
        final logRp = ReceivePort();
        _sendPort!.send(LogLevelRequest(_currentLogLevel, logRp.sendPort));
        logRp.first.then((_) {
          logRp.close();
        });
        tempPort.close();
        completer.complete();
      }
    });
    _isolate = await Isolate.spawn(llamaWorkerEntry, tempPort.sendPort);
    await completer.future;
    _isReady = true;
  }

  @override
  void cancelGeneration() {
    _activeCancelToken?.value = 1;
  }

  @override
  Future<void> setLogLevel(LlamaLogLevel level) async {
    _currentLogLevel = level;
    if (_sendPort != null) {
      final rp = ReceivePort();
      _sendPort!.send(LogLevelRequest(level, rp.sendPort));
      await rp.first;
      rp.close();
    }
  }

  @override
  Future<int> modelLoad(String path, ModelParams params) async {
    await _ensureIsolate();
    final rp = ReceivePort();
    _sendPort!.send(ModelLoadRequest(path, params, rp.sendPort));
    final res = await rp.first;
    rp.close();
    if (res is HandleResponse) return res.handle;
    if (res is ErrorResponse) throw Exception(res.message);
    throw Exception("Unknown response during model load");
  }

  @override
  Future<int> modelLoadFromUrl(
    String url,
    ModelParams params, {
    Function(double progress)? onProgress,
  }) async {
    throw UnimplementedError("Use modelLoad with a local path for now");
  }

  @override
  Future<void> modelFree(int modelHandle) async {
    if (_sendPort == null) return;
    final rp = ReceivePort();
    _sendPort!.send(ModelFreeRequest(modelHandle, rp.sendPort));
    await rp.first;
    rp.close();
  }

  @override
  Future<int> contextCreate(int modelHandle, ModelParams params) async {
    await _ensureIsolate();
    final rp = ReceivePort();
    _sendPort!.send(ContextCreateRequest(modelHandle, params, rp.sendPort));
    final res = await rp.first;
    rp.close();
    if (res is HandleResponse) return res.handle;
    if (res is ErrorResponse) throw Exception(res.message);
    throw Exception("Unknown response during context creation");
  }

  @override
  Future<void> contextFree(int contextHandle) async {
    if (_sendPort == null) return;
    final rp = ReceivePort();
    _sendPort!.send(ContextFreeRequest(contextHandle, rp.sendPort));
    await rp.first;
    rp.close();
  }

  @override
  Future<int> getContextSize(int contextHandle) async {
    if (_sendPort == null) return 0;
    final rp = ReceivePort();
    _sendPort!.send(GetContextSizeRequest(contextHandle, rp.sendPort));
    final res = await rp.first;
    rp.close();
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
    late final StreamController<List<int>> controller;
    final rp = ReceivePort();

    final cancelToken = malloc<Int8>(1);
    cancelToken.value = 0;
    _activeCancelToken = cancelToken;

    var cleanedUp = false;
    void cleanup() {
      if (cleanedUp) {
        return;
      }
      cleanedUp = true;

      rp.close();
      if (!controller.isClosed) {
        unawaited(controller.close());
      }
      malloc.free(cancelToken);
      if (_activeCancelToken == cancelToken) {
        _activeCancelToken = null;
      }
      if (_activeGenerationCleanup == cleanup) {
        _activeGenerationCleanup = null;
      }
    }

    controller = StreamController<List<int>>(
      onCancel: () {
        cancelGeneration();
        cleanup();
      },
    );
    _activeGenerationCleanup = cleanup;

    _sendPort!.send(
      GenerateRequest(
        contextHandle,
        prompt,
        params,
        cancelToken.address,
        rp.sendPort,
        parts: parts,
      ),
    );

    rp.listen((msg) {
      if (msg is TokenResponse) {
        controller.add(msg.bytes);
      } else if (msg is DoneResponse) {
        cleanup();
      } else if (msg is ErrorResponse) {
        controller.addError(Exception(msg.message));
        cleanup();
      }
    });

    return controller.stream;
  }

  @override
  Future<List<int>> tokenize(
    int modelHandle,
    String text, {
    bool addSpecial = true,
  }) async {
    final rp = ReceivePort();
    _sendPort!.send(
      TokenizeRequest(modelHandle, text, addSpecial, rp.sendPort),
    );
    final res = await rp.first;
    rp.close();
    if (res is TokenizeResponse) return res.tokens;
    throw Exception("Tokenization failed");
  }

  @override
  Future<List<double>> embed(
    int contextHandle,
    String text, {
    bool normalize = true,
  }) async {
    await _ensureIsolate();
    final rp = ReceivePort();
    _sendPort!.send(EmbedRequest(contextHandle, text, normalize, rp.sendPort));
    final res = await rp.first;
    rp.close();
    if (res is EmbedResponse) return res.embedding;
    if (res is ErrorResponse) throw Exception(res.message);
    throw Exception('Embedding failed');
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
    final rp = ReceivePort();
    _sendPort!.send(
      EmbedBatchRequest(
        contextHandle,
        List<String>.from(texts),
        normalize,
        rp.sendPort,
      ),
    );
    final res = await rp.first;
    rp.close();
    if (res is EmbedBatchResponse) return res.embeddings;
    if (res is ErrorResponse) throw Exception(res.message);
    throw Exception('Batch embedding failed');
  }

  @override
  Future<String> detokenize(
    int modelHandle,
    List<int> tokens, {
    bool special = false,
  }) async {
    final rp = ReceivePort();
    _sendPort!.send(
      DetokenizeRequest(modelHandle, tokens, special, rp.sendPort),
    );
    final res = await rp.first;
    rp.close();
    if (res is DetokenizeResponse) return res.text;
    throw Exception("Detokenization failed");
  }

  @override
  Future<Map<String, String>> modelMetadata(int modelHandle) async {
    final rp = ReceivePort();
    _sendPort!.send(MetadataRequest(modelHandle, rp.sendPort));
    final res = await rp.first;
    rp.close();
    if (res is MetadataResponse) return res.metadata;
    return {};
  }

  @override
  Future<bool> stateSaveFile(
    int contextHandle,
    String path,
    List<int> tokens,
  ) async {
    await _ensureIsolate();
    final rp = ReceivePort();
    _sendPort!.send(
      StateSaveFileRequest(
        contextHandle,
        path,
        List<int>.from(tokens),
        rp.sendPort,
      ),
    );
    final res = await rp.first;
    rp.close();
    if (res is StateSaveFileResponse) return res.success;
    if (res is ErrorResponse) throw Exception(res.message);
    throw Exception('State save failed');
  }

  @override
  Future<StateLoadResult> stateLoadFile(
    int contextHandle,
    String path,
    int tokenCapacity,
  ) async {
    await _ensureIsolate();
    final rp = ReceivePort();
    _sendPort!.send(
      StateLoadFileRequest(contextHandle, path, tokenCapacity, rp.sendPort),
    );
    final res = await rp.first;
    rp.close();
    if (res is StateLoadFileResponse) {
      return StateLoadResult(tokens: res.tokens);
    }
    if (res is ErrorResponse) throw Exception(res.message);
    throw Exception('State load failed');
  }

  @override
  Future<void> setLoraAdapter(
    int contextHandle,
    String path,
    double scale,
  ) async {
    final rp = ReceivePort();
    _sendPort!.send(
      LoraRequest(
        contextHandle,
        'set',
        path: path,
        scale: scale,
        sendPort: rp.sendPort,
      ),
    );
    final res = await rp.first;
    rp.close();
    if (res is ErrorResponse) throw Exception(res.message);
  }

  @override
  Future<void> removeLoraAdapter(int contextHandle, String path) async {
    final rp = ReceivePort();
    _sendPort!.send(
      LoraRequest(contextHandle, 'remove', path: path, sendPort: rp.sendPort),
    );
    final res = await rp.first;
    rp.close();
    if (res is ErrorResponse) throw Exception(res.message);
  }

  @override
  Future<void> clearLoraAdapters(int contextHandle) async {
    final rp = ReceivePort();
    _sendPort!.send(LoraRequest(contextHandle, 'clear', sendPort: rp.sendPort));
    final res = await rp.first;
    rp.close();
    if (res is ErrorResponse) throw Exception(res.message);
  }

  @override
  Future<String> getBackendName() async {
    await _ensureIsolate();
    final rp = ReceivePort();
    _sendPort!.send(BackendInfoRequest(rp.sendPort));
    final res = await rp.first;
    rp.close();
    return (res as BackendInfoResponse).name;
  }

  @override
  Future<String> getAvailableBackends() async {
    await _ensureIsolate();
    final rp = ReceivePort();
    _sendPort!.send(AvailableBackendsRequest(rp.sendPort));
    final res = await rp.first;
    rp.close();
    return (res as BackendInfoResponse).name;
  }

  @override
  Future<int?> getResolvedGpuLayers() async {
    await _ensureIsolate();
    final rp = ReceivePort();
    _sendPort!.send(ResolvedGpuLayersRequest(rp.sendPort));
    final res = await rp.first;
    rp.close();
    return (res as ResolvedGpuLayersResponse).layers;
  }

  @override
  Future<BackendPerfContextData?> getPerformanceContext(
    int contextHandle,
  ) async {
    await _ensureIsolate();
    final rp = ReceivePort();
    _sendPort!.send(PerformanceContextRequest(contextHandle, rp.sendPort));
    final res = await rp.first;
    rp.close();
    if (res is PerformanceContextResponse) {
      return BackendPerfContextData(
        loadMs: res.loadMs,
        promptEvalMs: res.promptEvalMs,
        evalMs: res.evalMs,
        sampleMs: res.sampleMs,
        promptEvalTokens: res.promptEvalTokens,
        evalTokens: res.evalTokens,
        sampleCount: res.sampleCount,
        reusedGraphs: res.reusedGraphs,
      );
    }
    if (res is ErrorResponse) {
      throw Exception(res.message);
    }
    return null;
  }

  @override
  bool get supportsUrlLoading => false;

  @override
  Future<bool> isGpuSupported() async {
    await _ensureIsolate();
    final rp = ReceivePort();
    _sendPort!.send(GpuSupportRequest(rp.sendPort));
    final res = await rp.first;
    rp.close();
    return (res as GpuSupportResponse).support;
  }

  @override
  Future<void> dispose() async {
    _activeCancelToken?.value = 1;
    _activeGenerationCleanup?.call();

    if (_sendPort != null) {
      final rp = ReceivePort();
      _sendPort!.send(DisposeRequest(rp.sendPort));
      await rp.first;
      rp.close();
    }
    _isolate?.kill();
    _responsesPort.close();
    _activeCancelToken = null;
    _activeGenerationCleanup = null;
    _isReady = false;
  }

  @override
  Future<int?> multimodalContextCreate(
    int modelHandle,
    String mmProjPath,
  ) async {
    final rp = ReceivePort();
    _sendPort!.send(
      MultimodalContextCreateRequest(modelHandle, mmProjPath, rp.sendPort),
    );
    final res = await rp.first;
    rp.close();
    if (res is HandleResponse) return res.handle;
    if (res is ErrorResponse) throw Exception(res.message);
    return null;
  }

  @override
  Future<void> multimodalContextFree(int mmContextHandle) async {
    final rp = ReceivePort();
    _sendPort!.send(MultimodalContextFreeRequest(mmContextHandle, rp.sendPort));
    await rp.first;
    rp.close();
  }

  @override
  Future<bool> supportsAudio(int mmContextHandle) async {
    final rp = ReceivePort();
    _sendPort!.send(SupportsAudioRequest(mmContextHandle, rp.sendPort));
    final res = await rp.first;
    rp.close();
    return res as bool;
  }

  @override
  Future<bool> supportsVision(int mmContextHandle) async {
    final rp = ReceivePort();
    _sendPort!.send(SupportsVisionRequest(mmContextHandle, rp.sendPort));
    final res = await rp.first;
    rp.close();
    return res as bool;
  }

  @override
  Future<({int total, int free})> getVramInfo() async {
    await _ensureIsolate();
    final rp = ReceivePort();
    _sendPort!.send(SystemInfoRequest(rp.sendPort));
    final res = await rp.first;
    rp.close();
    if (res is SystemInfoResponse) {
      return (total: res.totalVram, free: res.freeVram);
    }
    return (total: 0, free: 0);
  }

  @override
  Future<String> applyChatTemplate(
    int modelHandle,
    List<Map<String, dynamic>> messages, {
    String? customTemplate,
    bool addAssistant = true,
  }) async {
    await _ensureIsolate();
    final rp = ReceivePort();
    _sendPort!.send(
      ChatTemplateRequest(
        modelHandle,
        messages,
        customTemplate,
        addAssistant,
        rp.sendPort,
      ),
    );
    final res = await rp.first;
    rp.close();
    if (res is ChatTemplateResponse) return res.result;
    if (res is ErrorResponse) throw Exception(res.message);
    throw Exception("Unknown response during chat template application");
  }
}
