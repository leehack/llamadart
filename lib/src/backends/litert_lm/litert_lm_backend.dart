import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/models/chat/content_part.dart';
import '../../core/models/config/gpu_backend.dart';
import '../../core/models/config/log_level.dart';
import '../../core/models/inference/generation_params.dart';
import '../../core/models/inference/model_params.dart';
import '../../experimental/litert_lm/litert_lm_benchmark.dart';
import '../backend.dart';

/// Experimental LiteRT-LM backend for `.litertlm` models.
///
/// This backend intentionally implements the narrow inference path needed for
/// early LiteRT-LM validation. Unsupported llama.cpp-specific features throw
/// [UnsupportedError] instead of pretending to work.
class LiteRtLmBackend
    implements
        LlamaBackend,
        BackendAvailability,
        BackendRuntimeDiagnostics,
        BackendPerformanceDiagnostics {
  static const int _modelHandle = 1;
  static const int _contextHandle = 1;

  LiteRtLmBenchmarkClient? _client;
  ModelParams? _modelParams;
  String? _modelPath;
  String? _activeBackend;
  int? _activeOutputTokens;
  LiteRtLmBenchmarkMetrics? _lastMetrics;
  bool _isReady = false;

  @override
  bool get isReady => _isReady;

  @override
  bool get supportsUrlLoading => false;

  @override
  Future<int> modelLoad(String path, ModelParams params) async {
    final file = File(path);
    if (!await file.exists()) {
      throw ArgumentError('LiteRT-LM model does not exist: $path');
    }
    if (!path.endsWith('.litertlm')) {
      throw ArgumentError(
        'LiteRtLmBackend expects a .litertlm model bundle; got $path',
      );
    }
    _modelPath = path;
    _modelParams = params;
    _activeBackend = _backendNameFor(params.preferredBackend);
    _lastMetrics = null;
    _isReady = true;
    return _modelHandle;
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
    _checkModelHandle(modelHandle);
    _client?.dispose();
    _client = null;
    _modelPath = null;
    _modelParams = null;
    _activeBackend = null;
    _activeOutputTokens = null;
    _lastMetrics = null;
    _isReady = false;
  }

  @override
  Future<int> contextCreate(int modelHandle, ModelParams params) async {
    _checkModelHandle(modelHandle);
    _modelParams = params;
    return _contextHandle;
  }

  @override
  Future<void> contextFree(int contextHandle) async {
    _checkContextHandle(contextHandle);
  }

  @override
  Future<int> getContextSize(int contextHandle) async {
    _checkContextHandle(contextHandle);
    return _modelParams?.contextSize ?? 0;
  }

  @override
  Stream<List<int>> generate(
    int contextHandle,
    String prompt,
    GenerationParams params, {
    List<LlamaContentPart>? parts,
  }) async* {
    _checkContextHandle(contextHandle);
    if (parts != null && parts.isNotEmpty) {
      throw UnsupportedError('LiteRtLmBackend does not support media parts.');
    }
    if (params.grammar != null) {
      throw UnsupportedError('LiteRtLmBackend does not support grammars yet.');
    }

    final client = await _ensureClient(params);
    client.createConversation(
      temperature: params.temp,
      topK: params.topK,
      topP: params.topP,
      seed: params.seed ?? 1,
    );

    final stopSequences = params.stopSequences.where((s) => s.isNotEmpty);
    final emitted = StringBuffer();
    final sw = Stopwatch()..start();
    try {
      await for (final chunk in client.generate(prompt)) {
        var next = chunk;
        final combined = emitted.toString() + next;
        var stopIndex = -1;
        for (final stop in stopSequences) {
          final index = combined.indexOf(stop);
          if (index >= 0 && (stopIndex < 0 || index < stopIndex)) {
            stopIndex = index;
          }
        }
        if (stopIndex >= 0) {
          final allowed = stopIndex - emitted.length;
          if (allowed > 0) {
            next = next.substring(0, allowed);
            emitted.write(next);
            yield utf8.encode(next);
          }
          cancelGeneration();
          break;
        }

        emitted.write(next);
        if (next.isNotEmpty) {
          yield utf8.encode(next);
        }
      }
    } finally {
      sw.stop();
      try {
        _lastMetrics = client.readMetrics(
          wallMilliseconds: sw.elapsedMilliseconds,
        );
      } catch (_) {
        _lastMetrics = null;
      }
    }
  }

  @override
  void cancelGeneration() {
    _client?.cancel();
  }

  @override
  Future<List<int>> tokenize(
    int modelHandle,
    String text, {
    bool addSpecial = true,
  }) {
    _checkModelHandle(modelHandle);
    throw UnsupportedError('LiteRtLmBackend does not expose tokenization yet.');
  }

  @override
  Future<String> detokenize(
    int modelHandle,
    List<int> tokens, {
    bool special = false,
  }) {
    _checkModelHandle(modelHandle);
    throw UnsupportedError(
      'LiteRtLmBackend does not expose detokenization yet.',
    );
  }

  @override
  Future<Map<String, String>> modelMetadata(int modelHandle) async {
    _checkModelHandle(modelHandle);
    return <String, String>{
      'general.architecture': 'litert-lm',
      'general.file_type': 'litertlm',
      if (_modelPath != null)
        'general.name': File(_modelPath!).uri.pathSegments.last,
    };
  }

  @override
  Future<void> setLoraAdapter(int contextHandle, String path, double scale) {
    _checkContextHandle(contextHandle);
    throw UnsupportedError('LiteRtLmBackend does not support LoRA adapters.');
  }

  @override
  Future<void> removeLoraAdapter(int contextHandle, String path) {
    _checkContextHandle(contextHandle);
    throw UnsupportedError('LiteRtLmBackend does not support LoRA adapters.');
  }

  @override
  Future<void> clearLoraAdapters(int contextHandle) async {
    _checkContextHandle(contextHandle);
  }

  @override
  Future<String> getBackendName() async {
    final backend = _activeBackend ?? 'gpu';
    return 'LiteRT-LM $backend';
  }

  @override
  Future<String> getAvailableBackends() async {
    return Platform.isMacOS || Platform.isAndroid ? 'cpu,gpu' : 'cpu';
  }

  @override
  Future<int?> getResolvedGpuLayers() async {
    return _activeBackend == 'cpu' ? 0 : ModelParams.maxGpuLayers;
  }

  @override
  Future<BackendPerfContextData?> getPerformanceContext(
    int contextHandle,
  ) async {
    _checkContextHandle(contextHandle);
    final metrics = _lastMetrics;
    if (metrics == null) {
      return null;
    }
    final promptEvalMs = _millisecondsFromTps(
      metrics.inputTokens,
      metrics.prefillTokensPerSecond,
    );
    final evalMs = _millisecondsFromTps(
      metrics.outputTokens,
      metrics.decodeTokensPerSecond,
    );
    return BackendPerfContextData(
      loadMs: (metrics.initSeconds ?? 0) * 1000.0,
      promptEvalMs: promptEvalMs,
      evalMs: evalMs,
      sampleMs: 0,
      promptEvalTokens: metrics.inputTokens,
      evalTokens: metrics.outputTokens,
      sampleCount: metrics.outputTokens,
      reusedGraphs: 0,
    );
  }

  @override
  Future<bool> isGpuSupported() async {
    return Platform.isMacOS || Platform.isAndroid;
  }

  @override
  Future<void> setLogLevel(LlamaLogLevel level) async {}

  @override
  Future<void> dispose() async {
    _client?.dispose();
    _client = null;
    _modelPath = null;
    _modelParams = null;
    _activeBackend = null;
    _activeOutputTokens = null;
    _lastMetrics = null;
    _isReady = false;
  }

  @override
  Future<int?> multimodalContextCreate(int modelHandle, String mmProjPath) {
    _checkModelHandle(modelHandle);
    throw UnsupportedError(
      'LiteRtLmBackend does not support multimodal input.',
    );
  }

  @override
  Future<void> multimodalContextFree(int mmContextHandle) async {}

  @override
  Future<bool> supportsVision(int mmContextHandle) async => false;

  @override
  Future<bool> supportsAudio(int mmContextHandle) async => false;

  @override
  Future<({int total, int free})> getVramInfo() async {
    return (total: 0, free: 0);
  }

  @override
  Future<String> applyChatTemplate(
    int modelHandle,
    List<Map<String, dynamic>> messages, {
    String? customTemplate,
    bool addAssistant = true,
  }) {
    _checkModelHandle(modelHandle);
    throw UnsupportedError(
      'LiteRtLmBackend uses Dart-side chat templates for now.',
    );
  }

  Future<LiteRtLmBenchmarkClient> _ensureClient(GenerationParams params) async {
    final modelPath = _modelPath;
    final modelParams = _modelParams;
    if (modelPath == null || modelParams == null) {
      throw StateError('No LiteRT-LM model is loaded.');
    }

    final outputTokens = params.maxTokens <= 0 ? 4096 : params.maxTokens;
    final backend =
        _activeBackend ?? _backendNameFor(modelParams.preferredBackend);
    final existing = _client;
    if (existing != null &&
        _activeOutputTokens == outputTokens &&
        _activeBackend == backend) {
      return existing;
    }

    existing?.dispose();
    final client = LiteRtLmBenchmarkClient();
    await client.initialize(
      modelPath: modelPath,
      backend: backend,
      maxTokens: modelParams.contextSize,
      outputTokens: outputTokens,
      cacheDir: _defaultCacheDir(),
      speculativeDecoding: false,
    );
    _client = client;
    _activeOutputTokens = outputTokens;
    _activeBackend = backend;
    return client;
  }

  String _backendNameFor(GpuBackend backend) {
    switch (backend) {
      case GpuBackend.cpu:
      case GpuBackend.blas:
        return 'cpu';
      case GpuBackend.auto:
      case GpuBackend.vulkan:
      case GpuBackend.metal:
      case GpuBackend.cuda:
      case GpuBackend.opencl:
      case GpuBackend.hip:
        return 'gpu';
    }
  }

  String? _defaultCacheDir() {
    if (!Platform.isMacOS && !Platform.isAndroid) {
      return null;
    }
    final dir = Directory('${Directory.systemTemp.path}/llamadart_litert_lm');
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir.path;
  }

  double _millisecondsFromTps(int tokens, double? tps) {
    if (tokens <= 0 || tps == null || tps <= 0) {
      return 0;
    }
    return tokens / tps * 1000.0;
  }

  void _checkModelHandle(int handle) {
    if (handle != _modelHandle || !_isReady) {
      throw StateError('Invalid LiteRT-LM model handle: $handle');
    }
  }

  void _checkContextHandle(int handle) {
    if (handle != _contextHandle || !_isReady) {
      throw StateError('Invalid LiteRT-LM context handle: $handle');
    }
  }
}
