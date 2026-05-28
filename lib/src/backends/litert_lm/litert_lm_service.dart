import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/models/chat/content_part.dart';
import '../../core/models/chat/chat_message.dart';
import '../../core/models/chat/chat_role.dart';
import '../../core/models/config/flash_attention.dart';
import '../../core/models/config/gpu_backend.dart';
import '../../core/models/config/kv_cache_type.dart';
import '../../core/models/config/log_level.dart';
import '../../core/models/inference/generation_params.dart';
import '../../core/models/inference/model_params.dart';
import '../../core/template/chat_template_engine.dart';
import '../backend.dart';
import 'litert_lm_platform.dart';
import 'litert_lm_runtime.dart';

/// Worker-owned service for the LiteRT-LM backend.
///
/// This keeps all LiteRT-LM FFI state inside the backend worker isolate. The
/// public backend only sends requests and receives stream chunks, mirroring the
/// llama.cpp backend architecture.
class LiteRtLmService {
  static const String _gemma4ChatTemplate =
      '{% for message in messages %}'
      '<|turn>{% if message["role"] == "assistant" %}model\n'
      '{% else %}{{ message["role"] }}\n{% endif %}'
      '{{ message["content"] }}<turn|>\n'
      '{% endfor %}'
      '{% if add_generation_prompt %}<|turn>model\n'
      '{% if enable_thinking %}<|channel>thought\n{% endif %}'
      '{% endif %}';

  /// Creates a LiteRT-LM service.
  LiteRtLmService({LiteRtLmRuntimeClient Function()? clientFactory})
    : _clientFactory = clientFactory ?? LiteRtLmRuntimeClient.new;

  final LiteRtLmRuntimeClient Function() _clientFactory;
  LiteRtLmRuntimeClient? _client;
  ModelParams? _modelParams;
  String? _modelPath;
  String? _activeBackend;
  int? _activeOutputTokens;
  int _nextModelHandle = 1;
  int _nextContextHandle = 1;
  int? _modelHandle;
  int? _contextHandle;
  LiteRtLmRuntimeMetrics? _lastMetrics;
  LlamaLogLevel _logLevel = LlamaLogLevel.warn;
  bool _modelLoaded = false;
  bool _contextCreated = false;
  bool _cancelRequested = false;

  /// Updates the current backend log level.
  void setLogLevel(LlamaLogLevel level) {
    _logLevel = level;
    _client?.setMinLogLevel(_liteRtLmMinLogLevel(level));
  }

  /// Loads a local `.litertlm` model bundle.
  Future<int> loadModel(
    String path,
    ModelParams params, {
    String? backendOverride,
  }) async {
    final file = File(path);
    if (!await file.exists()) {
      throw ArgumentError('LiteRT-LM model does not exist: $path');
    }
    if (!path.toLowerCase().endsWith('.litertlm')) {
      throw ArgumentError(
        'LiteRtLmBackend expects a .litertlm model bundle; got $path',
      );
    }
    _validateModelParams(params);
    final resolvedBackend = _resolveBackendName(
      params,
      backendOverride: backendOverride,
    );

    _client?.dispose();
    _client = null;
    _modelPath = path;
    _modelParams = params;
    _activeBackend = resolvedBackend;
    _activeOutputTokens = null;
    _modelHandle = _nextModelHandle++;
    _contextHandle = null;
    _lastMetrics = null;
    _cancelRequested = false;
    _modelLoaded = true;
    _contextCreated = false;
    return _modelHandle!;
  }

  /// Frees the loaded model and any active LiteRT-LM client.
  void freeModel(int modelHandle) {
    _checkModelHandle(modelHandle);
    _client?.dispose();
    _client = null;
    _modelPath = null;
    _modelParams = null;
    _activeBackend = null;
    _activeOutputTokens = null;
    _modelHandle = null;
    _contextHandle = null;
    _lastMetrics = null;
    _cancelRequested = false;
    _modelLoaded = false;
    _contextCreated = false;
  }

  /// Creates the single LiteRT-LM context used by this backend.
  int createContext(int modelHandle, ModelParams params) {
    _checkModelHandle(modelHandle);
    _validateModelParams(params);
    _validateContextBackendParams(params);
    _disposeContextRuntimeState();
    _modelParams = params;
    _contextHandle = _nextContextHandle++;
    _contextCreated = true;
    return _contextHandle!;
  }

  /// Frees the active LiteRT-LM context.
  void freeContext(int contextHandle) {
    _checkContextHandle(contextHandle);
    _disposeContextRuntimeState();
    _contextHandle = null;
    _contextCreated = false;
  }

  /// Returns the configured context size.
  int getContextSize(int contextHandle) {
    _checkContextHandle(contextHandle);
    return _modelParams?.contextSize ?? 0;
  }

  /// Generates UTF-8 token byte chunks for [prompt].
  Stream<List<int>> generate(
    int contextHandle,
    String prompt,
    GenerationParams params, {
    List<LlamaContentPart>? parts,
  }) async* {
    _checkContextHandle(contextHandle);
    if (_hasMediaParts(parts)) {
      throw UnsupportedError('LiteRtLmBackend does not support media parts.');
    }
    _validateGenerationParams(params);

    _cancelRequested = false;
    if (params.maxTokens <= 0) {
      _lastMetrics = null;
      return;
    }

    final client = await _ensureClientForGeneration(params);
    if (_cancelRequested) {
      return;
    }
    final backend =
        _activeBackend ?? _backendNameFor(_modelParams ?? const ModelParams());
    client.createConversation(
      temperature: params.temp,
      topK: params.topK,
      topP: params.topP,
      seed: params.seed ?? _defaultSamplerSeed(),
      npuBackend: backend == 'npu',
    );
    if (_cancelRequested) {
      client.cancel();
      return;
    }

    final stopSequences = params.stopSequences
        .where((sequence) => sequence.isNotEmpty)
        .toList(growable: false);
    final sw = Stopwatch()..start();
    try {
      final stream = _applyStopSequences(
        client.generate(prompt),
        stopSequences,
        onStop: cancelGeneration,
      );
      await for (final chunk in stream) {
        if (_cancelRequested) {
          break;
        }
        yield chunk;
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

  /// Cancels the active LiteRT-LM conversation if one is running.
  void cancelGeneration() {
    _cancelRequested = true;
    _client?.cancel();
  }

  /// Tokenizes text with the loaded LiteRT-LM model tokenizer.
  Future<List<int>> tokenize(
    int modelHandle,
    String text,
    bool addSpecial,
  ) async {
    _checkModelHandle(modelHandle);
    final client = await _ensureClientForRuntime();
    return client.tokenize(text, addSpecial: addSpecial);
  }

  /// Detokenizes token IDs with the loaded LiteRT-LM model tokenizer.
  Future<String> detokenize(
    int modelHandle,
    List<int> tokens,
    bool special,
  ) async {
    _checkModelHandle(modelHandle);
    if (special) {
      throw UnsupportedError(
        'LiteRtLmBackend does not support detokenizing special tokens.',
      );
    }
    final client = await _ensureClientForRuntime();
    return client.detokenize(tokens);
  }

  /// Returns the metadata known from the LiteRT-LM bundle path.
  Map<String, String> getMetadata(int modelHandle) {
    _checkModelHandle(modelHandle);
    final modelPath = _modelPath;
    final modelName = modelPath == null
        ? null
        : File(modelPath).uri.pathSegments.last;
    final metadata = <String, String>{
      'general.architecture': 'litert-lm',
      'general.file_type': 'litertlm',
    };
    if (modelName != null) {
      metadata['general.name'] = modelName;
    }
    if (_modelParams case final params?) {
      metadata['llm.context_length'] = params.contextSize.toString();
    }
    if (modelName != null && _isGemma4ModelName(modelName)) {
      metadata.addAll(const <String, String>{
        'tokenizer.chat_template': _gemma4ChatTemplate,
        'tokenizer.ggml.bos_token': '<bos>',
        'tokenizer.ggml.eos_token': '<turn|>',
      });
    }
    if (_modelParams?.chatTemplate case final customTemplate?) {
      metadata['tokenizer.chat_template'] = customTemplate;
    }
    return metadata;
  }

  bool _isGemma4ModelName(String modelName) {
    final normalized = modelName.toLowerCase().replaceAll('_', '-');
    return normalized.contains('gemma-4') || normalized.contains('gemma4');
  }

  /// Handles LiteRT-LM LoRA operations.
  void handleLora(int contextHandle, String? path, double? scale, String op) {
    _checkContextHandle(contextHandle);
    throw UnsupportedError('LiteRtLmBackend does not support LoRA adapters.');
  }

  /// Returns the active backend name.
  String getActiveBackendName() {
    final backend =
        _activeBackend ?? liteRtLmDefaultNativeBackendForCurrentPlatform();
    return 'LiteRT-LM $backend';
  }

  /// Returns the backend choices available on this platform.
  List<String> getAvailableBackendInfo() {
    return liteRtLmAvailableNativeBackendsForCurrentPlatform();
  }

  /// Returns the resolved GPU layer count analogue for LiteRT-LM.
  int? getResolvedGpuLayers() {
    final backend =
        _activeBackend ?? liteRtLmDefaultNativeBackendForCurrentPlatform();
    return backend == liteRtLmCpuBackend ? 0 : ModelParams.maxGpuLayers;
  }

  /// Returns the most recent LiteRT-LM performance metrics.
  BackendPerfContextData? getPerformanceContext(int contextHandle) {
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

  /// Returns whether this runtime can use a GPU LiteRT-LM backend.
  bool getGpuSupport() {
    return liteRtLmNativeGpuSupportedOnCurrentPlatform();
  }

  /// Creates a multimodal context.
  int createMultimodalContext(int modelHandle, String mmProjPath) {
    _checkModelHandle(modelHandle);
    throw UnsupportedError(
      'LiteRtLmBackend does not support multimodal input.',
    );
  }

  /// Frees a multimodal context.
  void freeMultimodalContext(int mmContextHandle) {
    throw UnsupportedError(
      'LiteRtLmBackend does not support multimodal input.',
    );
  }

  /// Returns whether vision is supported for a multimodal context.
  bool supportsVision(int mmContextHandle) {
    throw UnsupportedError(
      'LiteRtLmBackend does not support multimodal input.',
    );
  }

  /// Returns whether audio is supported for a multimodal context.
  bool supportsAudio(int mmContextHandle) {
    throw UnsupportedError(
      'LiteRtLmBackend does not support multimodal input.',
    );
  }

  /// Returns VRAM information when the backend can expose it.
  ({int total, int free}) getVramInfo() => (total: 0, free: 0);

  /// Applies a native chat template.
  String applyChatTemplate(
    int modelHandle,
    List<Map<String, dynamic>> messages, {
    String? customTemplate,
    bool addAssistant = true,
  }) {
    _checkModelHandle(modelHandle);
    final metadata = getMetadata(modelHandle);
    final result = ChatTemplateEngine.render(
      templateSource: metadata['tokenizer.chat_template'],
      messages: messages.map(_messageFromTemplateMap).toList(growable: false),
      metadata: metadata,
      addAssistant: addAssistant,
      customTemplate: customTemplate,
    );
    return result.prompt;
  }

  /// Releases all service-owned native resources.
  void dispose() {
    _disposeContextRuntimeState();
    _modelPath = null;
    _modelParams = null;
    _activeBackend = null;
    _modelHandle = null;
    _contextHandle = null;
    _modelLoaded = false;
    _contextCreated = false;
  }

  void _disposeContextRuntimeState() {
    _client?.dispose();
    _client = null;
    _activeOutputTokens = null;
    _lastMetrics = null;
    _cancelRequested = false;
  }

  Future<LiteRtLmRuntimeClient> _ensureClientForGeneration(
    GenerationParams params,
  ) {
    return _ensureClientForRuntime(outputTokens: params.maxTokens);
  }

  Future<LiteRtLmRuntimeClient> _ensureClientForRuntime({
    int? outputTokens,
  }) async {
    final modelPath = _modelPath;
    final modelParams = _modelParams;
    if (modelPath == null || modelParams == null) {
      throw StateError('No LiteRT-LM model is loaded.');
    }

    final resolvedOutputTokens =
        outputTokens ?? _activeOutputTokens ?? GenerationParams().maxTokens;
    final backend = _activeBackend ?? _backendNameFor(modelParams);
    final existing = _client;
    if (existing != null &&
        (outputTokens == null || _activeOutputTokens == resolvedOutputTokens) &&
        _activeBackend == backend) {
      return existing;
    }

    existing?.dispose();
    _client = null;
    _activeOutputTokens = null;
    final client = _clientFactory();
    try {
      await client.initialize(
        modelPath: modelPath,
        backend: backend,
        maxTokens: modelParams.contextSize,
        outputTokens: resolvedOutputTokens,
        cacheDir: _defaultCacheDir(),
        speculativeDecoding: false,
        minLogLevel: _liteRtLmMinLogLevel(_logLevel),
      );
    } catch (_) {
      try {
        client.dispose();
      } catch (_) {
        // Preserve the initialization error reported by the runtime.
      }
      rethrow;
    }
    _client = client;
    _activeOutputTokens = resolvedOutputTokens;
    _activeBackend = backend;
    return client;
  }

  Stream<List<int>> _applyStopSequences(
    Stream<String> source,
    List<String> stopSequences, {
    required void Function() onStop,
  }) async* {
    if (stopSequences.isEmpty) {
      await for (final chunk in source) {
        if (chunk.isNotEmpty) {
          yield utf8.encode(chunk);
        }
      }
      return;
    }

    final keepChars =
        stopSequences
            .map((sequence) => sequence.length)
            .reduce((a, b) => a > b ? a : b) -
        1;
    var pending = '';
    var stopped = false;

    await for (final chunk in source) {
      pending += chunk;
      final stopIndex = _firstStopIndex(pending, stopSequences);
      if (stopIndex >= 0) {
        final allowed = pending.substring(0, stopIndex);
        if (allowed.isNotEmpty) {
          yield utf8.encode(allowed);
        }
        stopped = true;
        onStop();
        break;
      }

      final emitLength = pending.length - keepChars;
      if (emitLength > 0) {
        final allowed = pending.substring(0, emitLength);
        pending = pending.substring(emitLength);
        if (allowed.isNotEmpty) {
          yield utf8.encode(allowed);
        }
      }
    }

    if (!stopped && pending.isNotEmpty) {
      yield utf8.encode(pending);
    }
  }

  bool _hasMediaParts(List<LlamaContentPart>? parts) {
    if (parts == null) {
      return false;
    }
    return parts.any(
      (part) => part is LlamaImageContent || part is LlamaAudioContent,
    );
  }

  int _firstStopIndex(String text, List<String> stopSequences) {
    var stopIndex = -1;
    for (final stop in stopSequences) {
      final index = text.indexOf(stop);
      if (index >= 0 && (stopIndex < 0 || index < stopIndex)) {
        stopIndex = index;
      }
    }
    return stopIndex;
  }

  String _resolveBackendName(ModelParams params, {String? backendOverride}) {
    final backend =
        normalizeLiteRtLmNativeBackendOverride(backendOverride) ??
        _backendNameFor(params);
    final available = getAvailableBackendInfo();
    if (!available.contains(backend)) {
      throw ArgumentError(
        'LiteRtLmBackend backend $backend is not available on '
        '${Platform.operatingSystem}. Available LiteRT-LM backends: '
        '${available.join(', ')}.',
      );
    }
    return backend;
  }

  String _backendNameFor(ModelParams params) {
    final explicit = params.liteRtLmBackend.nativeName;
    if (explicit != null) {
      return explicit;
    }
    if (params.gpuLayers <= 0) {
      return liteRtLmCpuBackend;
    }
    return _backendNameForGpuPreference(params.preferredBackend);
  }

  void _validateModelParams(ModelParams params) {
    params.validate();

    final unsupported = <String>[];
    if (params.contextSize <= 0) {
      unsupported.add('contextSize=${params.contextSize}');
    }
    if (params.gpuLayers > 0 && params.gpuLayers != ModelParams.maxGpuLayers) {
      unsupported.add('gpuLayers=${params.gpuLayers}');
    }
    if (params.splitMode != ModelSplitMode.layer) {
      unsupported.add('splitMode');
    }
    if (params.mainGpu != 0) {
      unsupported.add('mainGpu');
    }
    if (params.loras.isNotEmpty) {
      unsupported.add('loras');
    }
    if (params.numberOfThreads != 0) {
      unsupported.add('numberOfThreads');
    }
    if (params.numberOfThreadsBatch != 0) {
      unsupported.add('numberOfThreadsBatch');
    }
    if (params.batchSize > 0) {
      unsupported.add('batchSize');
    }
    if (params.microBatchSize > 0) {
      unsupported.add('microBatchSize');
    }
    if (params.maxParallelSequences != 1) {
      unsupported.add('maxParallelSequences');
    }
    if (!params.useMmap) {
      unsupported.add('useMmap=false');
    }
    if (params.useMlock) {
      unsupported.add('useMlock');
    }
    if (params.flashAttention != FlashAttention.auto) {
      unsupported.add('flashAttention');
    }
    if (params.cacheTypeK != KvCacheType.f16) {
      unsupported.add('cacheTypeK');
    }
    if (params.cacheTypeV != KvCacheType.f16) {
      unsupported.add('cacheTypeV');
    }
    if (params.kvUnified != null) {
      unsupported.add('kvUnified');
    }
    if (params.ropeFrequencyBase != null) {
      unsupported.add('ropeFrequencyBase');
    }
    if (params.ropeFrequencyScale != null) {
      unsupported.add('ropeFrequencyScale');
    }

    if (unsupported.isEmpty) {
      return;
    }
    throw ArgumentError(
      'LiteRtLmBackend does not support llama.cpp-specific ModelParams: '
      '${unsupported.join(', ')}. Supported LiteRT-LM load options are '
      'contextSize, chatTemplate, preferredBackend, all-or-CPU gpuLayers '
      'hints, and liteRtLmBackend for explicit CPU/GPU/NPU selection.',
    );
  }

  void _validateContextBackendParams(ModelParams params) {
    final requestedBackend = _explicitContextBackendName(params);
    if (requestedBackend == null) {
      return;
    }

    final available = getAvailableBackendInfo();
    if (!available.contains(requestedBackend)) {
      throw ArgumentError(
        'LiteRtLmBackend backend $requestedBackend is not available on '
        '${Platform.operatingSystem}. Available LiteRT-LM backends: '
        '${available.join(', ')}.',
      );
    }

    final activeBackend =
        _activeBackend ?? liteRtLmDefaultNativeBackendForCurrentPlatform();
    if (requestedBackend == activeBackend) {
      return;
    }

    throw ArgumentError(
      'LiteRtLmBackend contextCreate cannot change the loaded backend from '
      '$activeBackend to $requestedBackend. Select the LiteRT-LM backend in '
      'modelLoad ModelParams.',
    );
  }

  String? _explicitContextBackendName(ModelParams params) {
    final explicit = params.liteRtLmBackend.nativeName;
    if (explicit != null) {
      return explicit;
    }
    if (params.gpuLayers <= 0) {
      return liteRtLmCpuBackend;
    }
    if (params.preferredBackend != GpuBackend.auto) {
      return _backendNameForGpuPreference(params.preferredBackend);
    }
    return null;
  }

  void _validateGenerationParams(GenerationParams params) {
    const defaults = GenerationParams();
    final unsupported = <String>[];
    if (params.minP != defaults.minP) {
      unsupported.add('minP');
    }
    if (params.penalty != defaults.penalty) {
      unsupported.add('penalty');
    }
    if (params.grammar != null) {
      unsupported.add('grammar');
    }
    if (params.grammarLazy) {
      unsupported.add('grammarLazy');
    }
    if (params.grammarTriggers.isNotEmpty) {
      unsupported.add('grammarTriggers');
    }
    if (params.preservedTokens.isNotEmpty) {
      unsupported.add('preservedTokens');
    }
    if (params.grammarRoot != defaults.grammarRoot) {
      unsupported.add('grammarRoot');
    }

    if (unsupported.isEmpty) {
      return;
    }
    throw UnsupportedError(
      'LiteRtLmBackend does not support llama.cpp-specific GenerationParams: '
      '${unsupported.join(', ')}. Supported LiteRT-LM generation options are '
      'maxTokens, temp, topK, topP, seed, stopSequences, and native stream '
      'batching thresholds.',
    );
  }

  int _defaultSamplerSeed() {
    return DateTime.now().microsecondsSinceEpoch & 0x7fffffff;
  }

  String _backendNameForGpuPreference(GpuBackend backend) {
    switch (backend) {
      case GpuBackend.cpu:
      case GpuBackend.blas:
        return liteRtLmCpuBackend;
      case GpuBackend.auto:
        return liteRtLmDefaultNativeBackendForCurrentPlatform();
      case GpuBackend.vulkan:
      case GpuBackend.metal:
      case GpuBackend.cuda:
      case GpuBackend.opencl:
      case GpuBackend.hip:
        return liteRtLmGpuBackend;
    }
  }

  LlamaChatMessage _messageFromTemplateMap(Map<String, dynamic> message) {
    final roleName = message['role']?.toString() ?? LlamaChatRole.user.name;
    final role = LlamaChatRole.values.byName(roleName);
    return LlamaChatMessage.fromText(
      role: role,
      text: _contentTextFromTemplateMap(message['content']),
    );
  }

  String _contentTextFromTemplateMap(Object? content) {
    if (content == null) {
      return '';
    }
    if (content is String) {
      return content;
    }
    if (content is Map) {
      if (_isUnsupportedTemplateContentPart(content)) {
        throw UnsupportedError(
          'LiteRtLmBackend does not support multimodal chat-template content.',
        );
      }
      if (content['type']?.toString() == 'text' && content['text'] != null) {
        return content['text'].toString();
      }
      return content.toString();
    }
    if (content is Iterable) {
      final buffer = StringBuffer();
      for (final part in content) {
        if (part is Map) {
          if (_isUnsupportedTemplateContentPart(part)) {
            throw UnsupportedError(
              'LiteRtLmBackend does not support multimodal chat-template '
              'content.',
            );
          }
          final type = part['type']?.toString();
          if (type == 'text' && part['text'] != null) {
            buffer.write(part['text']);
            continue;
          }
        }
        buffer.write(part);
      }
      return buffer.toString();
    }
    return content.toString();
  }

  bool _isUnsupportedTemplateContentPart(Map<dynamic, dynamic> part) {
    final type = part['type']?.toString().toLowerCase();
    if (type == 'image' ||
        type == 'image_url' ||
        type == 'input_image' ||
        type == 'audio' ||
        type == 'input_audio' ||
        type == 'video' ||
        type == 'input_video') {
      return true;
    }
    return part.containsKey('image') ||
        part.containsKey('image_url') ||
        part.containsKey('input_audio') ||
        part.containsKey('audio') ||
        part.containsKey('video');
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

  int _liteRtLmMinLogLevel(LlamaLogLevel level) {
    switch (level) {
      case LlamaLogLevel.none:
        return 1000;
      case LlamaLogLevel.debug:
        return 1;
      case LlamaLogLevel.info:
        return 2;
      case LlamaLogLevel.warn:
        return 3;
      case LlamaLogLevel.error:
        return 4;
    }
  }

  void _checkModelHandle(int handle) {
    if (handle != _modelHandle || !_modelLoaded) {
      throw StateError('Invalid LiteRT-LM model handle: $handle');
    }
  }

  void _checkContextHandle(int handle) {
    if (handle != _contextHandle || !_modelLoaded || !_contextCreated) {
      throw StateError('Invalid LiteRT-LM context handle: $handle');
    }
  }
}
