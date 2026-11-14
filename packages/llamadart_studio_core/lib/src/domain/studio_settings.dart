import 'package:llamadart/llamadart.dart';
import 'package:meta/meta.dart';

/// User-facing speculative decoding mode exposed in Studio tuning controls.
enum StudioSpeculativeMode {
  /// Disabled (standard autoregressive decoding).
  off('Off'),

  /// Draftless 3-level n-gram cache (`SpeculativeDecodingStrategy.ngramCache`).
  ngramCache('N-gram Cache'),

  /// Draftless simple n-gram (`SpeculativeDecodingStrategy.ngramSimple`).
  ngramSimple('N-gram Simple'),

  /// Multi-token prediction (`SpeculativeDecodingStrategy.mtp`).
  mtp('MTP');

  const StudioSpeculativeMode(this.label);

  /// Display label.
  final String label;
}

/// UI appearance preference stored in Studio settings.
enum StudioAppearance {
  /// Follow host OS appearance.
  system,

  /// Light Studio theme.
  light,

  /// Dark Studio theme.
  dark,
}

/// High-level hardware tuning presets surfaced in Simple Inspector mode.
enum StudioHardwarePreset {
  /// Compact context & quantized KV cache for lower memory footprint & faster response.
  fast('Fast', '2K ctx · Q8 KV · FlashAttn'),

  /// Auto-tuned GPU layers & context window fitted to free VRAM.
  balanced('Balanced', 'Auto-tuned VRAM & 4K ctx'),

  /// Expanded context window & full F16 KV precision.
  quality('Max Quality', '16K ctx · F16 KV · FlashAttn');

  const StudioHardwarePreset(this.label, this.subtitle);

  /// Short preset chip title.
  final String label;

  /// Concise description shown beneath the preset.
  final String subtitle;
}

/// Immutable runtime, hardware, sampling, and UX settings for Studio.
@immutable
class StudioSettings {
  /// Creates [StudioSettings].
  const StudioSettings({
    this.activeModelId,
    this.modelPath,
    this.mmprojPath,
    this.preferredBackend = GpuBackend.auto,
    this.computeDevice = ComputeDevice.auto,
    this.temperature = 0.7,
    this.topK = 40,
    this.topP = 0.9,
    this.minP = 0.0,
    this.penalty = 1.1,
    this.presencePenalty = 0.0,
    this.contextSize = 4096,
    this.maxTokens = 2048,
    this.gpuLayers = 99,
    this.autoTuneHardware = true,
    this.requestedContextSize = 4096,
    this.numberOfThreads = 0,
    this.numberOfThreadsBatch = 0,
    this.batchSize = 0,
    this.microBatchSize = 0,
    this.maxParallelSequences = 1,
    this.useMmap = true,
    this.useMlock = false,
    this.kvUnified,
    this.ropeFrequencyBase,
    this.ropeFrequencyScale,
    this.cpuMoeLayers = 0,
    this.moeCacheBytes = 0,
    this.flashAttention = FlashAttention.auto,
    this.cacheTypeK = KvCacheType.f16,
    this.cacheTypeV = KvCacheType.f16,
    this.speculativeMode = StudioSpeculativeMode.off,
    this.toolsEnabled = true,
    this.enabledBuiltInTools = const <String>[
      'getWeather',
      'getCurrentTime',
      'evaluateMath',
      'convertUnits',
    ],
    this.customToolDeclarationsJson = '[]',
    this.includeWorkspaceContextInChat = false,
    this.enableMcpInChat = false,
    this.thinkingEnabled = true,
    this.thinkingBudgetTokens = 0,
    this.logLevel = LlamaLogLevel.none,
    this.nativeLogLevel = LlamaLogLevel.warn,
    this.appearance = StudioAppearance.system,
    this.inspectorOpen = true,
    this.inspectorExpertMode = false,
    this.autoLoadLastModel = true,
    this.modelBytesHint,
    this.customModelDirectories = const <String>[],
  });

  /// Identifier of the selected curated/custom model descriptor.
  final String? activeModelId;

  /// Resolved path or remote URL for the primary model file.
  final String? modelPath;

  /// Optional path or remote URL for a GGUF multimodal projector (`mmproj`).
  final String? mmprojPath;

  /// Preferred `llama.cpp` GPU backend.
  final GpuBackend preferredBackend;

  /// Cross-runtime compute device target (`auto`, `cpu`, `gpu`, `npu`).
  final ComputeDevice computeDevice;

  /// Sampling temperature.
  final double temperature;

  /// Top-K sampling cutoff.
  final int topK;

  /// Nucleus (Top-P) sampling probability.
  final double topP;

  /// Min-P relative probability threshold.
  final double minP;

  /// Repetition penalty (`1.0` disables).
  final double penalty;

  /// OpenAI-style additive presence penalty (`0.0` disables).
  final double presencePenalty;

  /// Effective context window (`n_ctx`).
  final int contextSize;

  /// Maximum completion tokens per turn.
  final int maxTokens;

  /// Offloaded GPU layer count (`0` for CPU-only).
  final int gpuLayers;

  /// Whether Studio auto-plans GPU layers and context window from VRAM/RAM.
  final bool autoTuneHardware;

  /// User-requested target context window before memory pressure clamping.
  final int requestedContextSize;

  /// Decode thread count (`0` = runtime auto).
  final int numberOfThreads;

  /// Prompt/batch thread count (`0` = runtime auto).
  final int numberOfThreadsBatch;

  /// Logical batch size (`n_batch`, `0` = runtime default).
  final int batchSize;

  /// Physical micro-batch size (`n_ubatch`, `0` = runtime default).
  final int microBatchSize;

  /// Maximum parallel KV sequences (`n_seq_max`, `1` = single sequence).
  final int maxParallelSequences;

  /// Whether to memory-map GGUF weights (`llama.cpp` `use_mmap`).
  final bool useMmap;

  /// Whether to lock GGUF weights in physical RAM (`llama.cpp` `use_mlock`).
  final bool useMlock;

  /// Optional unified KV cache buffer override (`null` = runtime auto).
  final bool? kvUnified;

  /// Optional RoPE base frequency override (`null` = model metadata).
  final double? ropeFrequencyBase;

  /// Optional RoPE frequency scaling factor (`null` = model metadata).
  final double? ropeFrequencyScale;

  /// Number of MoE FFN layers kept on CPU (`0` = GPU/default, `< 0` = all).
  final int cpuMoeLayers;

  /// Host RAM budget in bytes for cached CPU MoE weights (`0` = unlimited).
  final int moeCacheBytes;

  /// FlashAttention policy (automatically promoted to `enabled` when KV cache
  /// is quantized to `q8_0` or `q4_0`).
  final FlashAttention flashAttention;

  /// Key cache quantization type (`f16`, `q8_0`, `q4_0`).
  final KvCacheType cacheTypeK;

  /// Value cache quantization type (`f16`, `q8_0`, `q4_0`).
  final KvCacheType cacheTypeV;

  /// Self-speculative or MTP decoding strategy.
  final StudioSpeculativeMode speculativeMode;

  /// Whether tool calling is enabled for chat turns.
  final bool toolsEnabled;

  /// Built-in Studio tool names enabled for the session.
  final List<String> enabledBuiltInTools;

  /// Additional OpenAI-compatible JSON array of custom tool declarations.
  final String customToolDeclarationsJson;

  /// Whether casual Chat turns include the Coding Workspace `AGENTS.md` context
  /// (`false` by default so casual prompts stay fast and lean).
  final bool includeWorkspaceContextInChat;

  /// Whether casual Chat turns bridge connected MCP server tools (`false` by
  /// default so MCP schemas remain scoped to Coding unless opted in).
  final bool enableMcpInChat;

  /// Whether chain-of-thought reasoning blocks are enabled.
  final bool thinkingEnabled;

  /// Optional reasoning token cap (`0` = uncapped).
  final int thinkingBudgetTokens;

  /// Dart-side `llamadart` log verbosity.
  final LlamaLogLevel logLevel;

  /// Native runtime log verbosity.
  final LlamaLogLevel nativeLogLevel;

  /// Light/dark/system UI theme preference.
  final StudioAppearance appearance;

  /// Whether the right-hand Session Inspector panel is open on desktop.
  final bool inspectorOpen;

  /// Whether Session Inspector Hardware tab reveals expert low-level tuning
  /// parameters (`n_batch`, threads, `mmap`/`mlock`, KV quant, RoPE, MoE).
  final bool inspectorExpertMode;

  /// Whether startup should auto-load the previously active model when safe.
  final bool autoLoadLastModel;

  /// Approximate model byte size used for WebGPU mem64 and native memory fit.
  final int? modelBytesHint;

  /// User-registered extra local folders scanned for `.gguf` and `.litertlm`
  /// models on desktop hosts.
  final List<String> customModelDirectories;

  /// Infers which [StudioHardwarePreset] currently matches these settings, or
  /// `null` when manually customized.
  StudioHardwarePreset? get activeHardwarePreset {
    if (autoTuneHardware &&
        computeDevice == ComputeDevice.auto &&
        cacheTypeK == KvCacheType.f16 &&
        cacheTypeV == KvCacheType.f16) {
      return StudioHardwarePreset.balanced;
    }
    if (!autoTuneHardware &&
        contextSize == 2048 &&
        cacheTypeK == KvCacheType.q8_0 &&
        cacheTypeV == KvCacheType.q8_0) {
      return StudioHardwarePreset.fast;
    }
    if (!autoTuneHardware &&
        contextSize >= 16384 &&
        cacheTypeK == KvCacheType.f16 &&
        cacheTypeV == KvCacheType.f16 &&
        effectiveFlashAttention == FlashAttention.enabled) {
      return StudioHardwarePreset.quality;
    }
    return null;
  }

  /// Applies a curated [StudioHardwarePreset] for Simple Inspector mode.
  StudioSettings applyHardwarePreset(StudioHardwarePreset preset) {
    return switch (preset) {
      StudioHardwarePreset.fast => copyWith(
        autoTuneHardware: false,
        computeDevice: ComputeDevice.auto,
        contextSize: 2048,
        requestedContextSize: 2048,
        gpuLayers: 99,
        cacheTypeK: KvCacheType.q8_0,
        cacheTypeV: KvCacheType.q8_0,
        flashAttention: FlashAttention.enabled,
      ),
      StudioHardwarePreset.balanced => copyWith(
        autoTuneHardware: true,
        computeDevice: ComputeDevice.auto,
        contextSize: 4096,
        requestedContextSize: 4096,
        gpuLayers: 99,
        cacheTypeK: KvCacheType.f16,
        cacheTypeV: KvCacheType.f16,
        flashAttention: FlashAttention.auto,
      ),
      StudioHardwarePreset.quality => copyWith(
        autoTuneHardware: false,
        computeDevice: ComputeDevice.auto,
        contextSize: 16384,
        requestedContextSize: 16384,
        gpuLayers: 99,
        cacheTypeK: KvCacheType.f16,
        cacheTypeV: KvCacheType.f16,
        flashAttention: FlashAttention.enabled,
      ),
    };
  }

  /// Effective FlashAttention setting respecting llama.cpp's quantized KV rule.
  FlashAttention get effectiveFlashAttention {
    final usesQuantizedKv =
        cacheTypeK != KvCacheType.f16 || cacheTypeV != KvCacheType.f16;
    if (usesQuantizedKv && flashAttention == FlashAttention.disabled) {
      return FlashAttention.enabled;
    }
    if (usesQuantizedKv && flashAttention == FlashAttention.auto) {
      return FlashAttention.enabled;
    }
    return flashAttention;
  }

  /// Deterministic signature of load-time engine parameters used to detect when
  /// Inspector hardware changes require `Apply & Reload` on a loaded model.
  String engineLoadSignature({required bool isWeb}) {
    final resolvedCtx = contextSize <= 0 ? 4096 : contextSize;
    final cpuForced =
        computeDevice == ComputeDevice.cpu ||
        preferredBackend == GpuBackend.cpu;
    final resolvedLayers = cpuForced ? 0 : (gpuLayers >= 99 ? 99 : gpuLayers);
    final sanitizedMoeCache = (cpuMoeLayers == 0 || moeCacheBytes < 0)
        ? 0
        : moeCacheBytes;
    if (isWeb) {
      return 'web|$resolvedCtx|$resolvedLayers|${preferredBackend.name}|${computeDevice.name}';
    }
    final mtp = speculativeMode == StudioSpeculativeMode.mtp;
    return <Object?>[
      preferredBackend.name,
      computeDevice.name,
      resolvedCtx,
      resolvedLayers,
      numberOfThreads,
      numberOfThreadsBatch,
      batchSize < 0 ? 0 : batchSize,
      microBatchSize < 0 ? 0 : microBatchSize,
      maxParallelSequences < 1 ? 1 : maxParallelSequences,
      useMmap,
      useMlock,
      kvUnified,
      ropeFrequencyBase,
      ropeFrequencyScale,
      cpuMoeLayers,
      sanitizedMoeCache,
      effectiveFlashAttention.name,
      cacheTypeK.name,
      cacheTypeV.name,
      mtp,
    ].join('|');
  }

  /// Returns a copy with sampling parameters restored to Studio defaults.
  StudioSettings resetSamplingDefaults() {
    return copyWith(
      temperature: 0.7,
      topK: 40,
      topP: 0.9,
      minP: 0.0,
      penalty: 1.1,
      presencePenalty: 0.0,
      maxTokens: 2048,
    );
  }

  /// Builds runtime-safe [ModelParams] tailored to [format] and [isWeb].
  ModelParams toModelParams({
    required ModelFormat format,
    required bool isWeb,
  }) {
    final resolvedContext = contextSize <= 0 ? 4096 : contextSize;
    if (format == ModelFormat.liteRtLm) {
      final liteRtCpu =
          computeDevice == ComputeDevice.cpu ||
          preferredBackend == GpuBackend.cpu ||
          gpuLayers == 0;
      return LiteRtLmModelParams(
        contextSize: resolvedContext,
        device: computeDevice,
        gpuLayers: liteRtCpu ? 0 : ModelParams.maxGpuLayers,
        preferredBackend: liteRtCpu ? GpuBackend.cpu : preferredBackend,
        numberOfThreads: isWeb ? 0 : numberOfThreads,
      );
    }

    final cpuForced =
        computeDevice == ComputeDevice.cpu ||
        preferredBackend == GpuBackend.cpu;
    final resolvedLayers = cpuForced
        ? 0
        : (gpuLayers >= 99 ? ModelParams.maxGpuLayers : gpuLayers);
    final sanitizedBatch = batchSize < 0 ? 0 : batchSize;
    final sanitizedMicroBatch = microBatchSize < 0 ? 0 : microBatchSize;
    final sanitizedSeqs = maxParallelSequences < 1 ? 1 : maxParallelSequences;
    final sanitizedMoeCache = (cpuMoeLayers == 0 || moeCacheBytes < 0)
        ? 0
        : moeCacheBytes;

    return LlamaCppModelParams(
      contextSize: resolvedContext,
      device: computeDevice == ComputeDevice.npu
          ? ComputeDevice.auto
          : computeDevice,
      gpuLayers: resolvedLayers,
      preferredBackend: preferredBackend,
      numberOfThreads: isWeb ? 0 : numberOfThreads,
      numberOfThreadsBatch: isWeb ? 0 : numberOfThreadsBatch,
      batchSize: isWeb ? 0 : sanitizedBatch,
      microBatchSize: isWeb ? 0 : sanitizedMicroBatch,
      maxParallelSequences: isWeb ? 1 : sanitizedSeqs,
      useMmap: isWeb ? true : useMmap,
      useMlock: isWeb ? false : useMlock,
      kvUnified: isWeb ? null : kvUnified,
      ropeFrequencyBase: isWeb ? null : ropeFrequencyBase,
      ropeFrequencyScale: isWeb ? null : ropeFrequencyScale,
      cpuMoeLayers: isWeb ? 0 : cpuMoeLayers,
      moeCacheBytes: isWeb ? 0 : sanitizedMoeCache,
      flashAttention: isWeb ? FlashAttention.auto : effectiveFlashAttention,
      cacheTypeK: isWeb ? KvCacheType.f16 : cacheTypeK,
      cacheTypeV: isWeb ? KvCacheType.f16 : cacheTypeV,
      loadMtp: !isWeb && speculativeMode == StudioSpeculativeMode.mtp,
      modelBytesHint: isWeb ? modelBytesHint : null,
    );
  }

  /// Builds capability-aware [GenerationParams] for [capabilities].
  GenerationParams toGenerationParams({
    required LlamaEngineCapabilities capabilities,
  }) {
    const defaults = GenerationParams();
    final flushEveryToken =
        capabilities.runtime == LlamaRuntime.liteRtLm &&
        capabilities.supportsStreamBatching;
    final appliesPenalty =
        capabilities.supportsPenalty &&
        (capabilities.runtime != LlamaRuntime.liteRtLm || penalty >= 1.0);
    final appliesPresence =
        capabilities.supportsPresencePenalty && presencePenalty != 0.0;

    final SpeculativeDecodingConfig? speculativeConfig =
        switch (speculativeMode) {
          StudioSpeculativeMode.off => null,
          StudioSpeculativeMode.ngramCache =>
            capabilities.runtime == LlamaRuntime.llamaCpp
                ? const SpeculativeDecodingConfig.ngramCache()
                : null,
          StudioSpeculativeMode.ngramSimple =>
            capabilities.runtime == LlamaRuntime.llamaCpp
                ? const SpeculativeDecodingConfig.ngramSimple()
                : null,
          StudioSpeculativeMode.mtp => const SpeculativeDecodingConfig.mtp(),
        };

    final ThinkingBudget? budget =
        thinkingEnabled &&
            thinkingBudgetTokens > 0 &&
            capabilities.supportsThinkingBudget
        ? ThinkingBudget(maxTokens: thinkingBudgetTokens)
        : null;

    return GenerationParams(
      maxTokens: maxTokens,
      temp: temperature,
      topK: topK,
      topP: topP,
      minP: capabilities.supportsMinP ? minP : defaults.minP,
      penalty: appliesPenalty ? penalty : defaults.penalty,
      presencePenalty: appliesPresence
          ? presencePenalty
          : defaults.presencePenalty,
      thinkingBudget: budget,
      streamBatchTokenThreshold: flushEveryToken
          ? 1
          : defaults.streamBatchTokenThreshold,
      speculativeDecoding: speculativeConfig != null,
      speculativeDecodingConfig: speculativeConfig,
    );
  }

  /// Returns a copy with selectively updated fields.
  StudioSettings copyWith({
    String? activeModelId,
    bool clearActiveModelId = false,
    String? modelPath,
    bool clearModelPath = false,
    String? mmprojPath,
    bool clearMmprojPath = false,
    GpuBackend? preferredBackend,
    ComputeDevice? computeDevice,
    double? temperature,
    int? topK,
    double? topP,
    double? minP,
    double? penalty,
    double? presencePenalty,
    int? contextSize,
    int? maxTokens,
    int? gpuLayers,
    bool? autoTuneHardware,
    int? requestedContextSize,
    int? numberOfThreads,
    int? numberOfThreadsBatch,
    int? batchSize,
    int? microBatchSize,
    int? maxParallelSequences,
    bool? useMmap,
    bool? useMlock,
    bool? kvUnified,
    bool clearKvUnified = false,
    double? ropeFrequencyBase,
    bool clearRopeFrequencyBase = false,
    double? ropeFrequencyScale,
    bool clearRopeFrequencyScale = false,
    int? cpuMoeLayers,
    int? moeCacheBytes,
    FlashAttention? flashAttention,
    KvCacheType? cacheTypeK,
    KvCacheType? cacheTypeV,
    StudioSpeculativeMode? speculativeMode,
    bool? toolsEnabled,
    List<String>? enabledBuiltInTools,
    String? customToolDeclarationsJson,
    bool? includeWorkspaceContextInChat,
    bool? enableMcpInChat,
    bool? thinkingEnabled,
    int? thinkingBudgetTokens,
    LlamaLogLevel? logLevel,
    LlamaLogLevel? nativeLogLevel,
    StudioAppearance? appearance,
    bool? inspectorOpen,
    bool? inspectorExpertMode,
    bool? autoLoadLastModel,
    int? modelBytesHint,
    bool clearModelBytesHint = false,
    List<String>? customModelDirectories,
  }) {
    return StudioSettings(
      activeModelId: clearActiveModelId
          ? null
          : (activeModelId ?? this.activeModelId),
      modelPath: clearModelPath ? null : (modelPath ?? this.modelPath),
      mmprojPath: clearMmprojPath ? null : (mmprojPath ?? this.mmprojPath),
      preferredBackend: preferredBackend ?? this.preferredBackend,
      computeDevice: computeDevice ?? this.computeDevice,
      temperature: temperature ?? this.temperature,
      topK: topK ?? this.topK,
      topP: topP ?? this.topP,
      minP: minP ?? this.minP,
      penalty: penalty ?? this.penalty,
      presencePenalty: presencePenalty ?? this.presencePenalty,
      contextSize: contextSize ?? this.contextSize,
      maxTokens: maxTokens ?? this.maxTokens,
      gpuLayers: gpuLayers ?? this.gpuLayers,
      autoTuneHardware: autoTuneHardware ?? this.autoTuneHardware,
      requestedContextSize: requestedContextSize ?? this.requestedContextSize,
      numberOfThreads: numberOfThreads ?? this.numberOfThreads,
      numberOfThreadsBatch: numberOfThreadsBatch ?? this.numberOfThreadsBatch,
      batchSize: batchSize ?? this.batchSize,
      microBatchSize: microBatchSize ?? this.microBatchSize,
      maxParallelSequences: maxParallelSequences ?? this.maxParallelSequences,
      useMmap: useMmap ?? this.useMmap,
      useMlock: useMlock ?? this.useMlock,
      kvUnified: clearKvUnified ? null : (kvUnified ?? this.kvUnified),
      ropeFrequencyBase: clearRopeFrequencyBase
          ? null
          : (ropeFrequencyBase ?? this.ropeFrequencyBase),
      ropeFrequencyScale: clearRopeFrequencyScale
          ? null
          : (ropeFrequencyScale ?? this.ropeFrequencyScale),
      cpuMoeLayers: cpuMoeLayers ?? this.cpuMoeLayers,
      moeCacheBytes: moeCacheBytes ?? this.moeCacheBytes,
      flashAttention: flashAttention ?? this.flashAttention,
      cacheTypeK: cacheTypeK ?? this.cacheTypeK,
      cacheTypeV: cacheTypeV ?? this.cacheTypeV,
      speculativeMode: speculativeMode ?? this.speculativeMode,
      toolsEnabled: toolsEnabled ?? this.toolsEnabled,
      enabledBuiltInTools: enabledBuiltInTools ?? this.enabledBuiltInTools,
      customToolDeclarationsJson:
          customToolDeclarationsJson ?? this.customToolDeclarationsJson,
      includeWorkspaceContextInChat:
          includeWorkspaceContextInChat ?? this.includeWorkspaceContextInChat,
      enableMcpInChat: enableMcpInChat ?? this.enableMcpInChat,
      thinkingEnabled: thinkingEnabled ?? this.thinkingEnabled,
      thinkingBudgetTokens: thinkingBudgetTokens ?? this.thinkingBudgetTokens,
      logLevel: logLevel ?? this.logLevel,
      nativeLogLevel: nativeLogLevel ?? this.nativeLogLevel,
      appearance: appearance ?? this.appearance,
      inspectorOpen: inspectorOpen ?? this.inspectorOpen,
      inspectorExpertMode: inspectorExpertMode ?? this.inspectorExpertMode,
      autoLoadLastModel: autoLoadLastModel ?? this.autoLoadLastModel,
      modelBytesHint: clearModelBytesHint
          ? null
          : (modelBytesHint ?? this.modelBytesHint),
      customModelDirectories:
          customModelDirectories ?? this.customModelDirectories,
    );
  }

  /// Serializes settings to JSON.
  Map<String, Object?> toJson() {
    return <String, Object?>{
      if (activeModelId != null) 'activeModelId': activeModelId,
      if (modelPath != null) 'modelPath': modelPath,
      if (mmprojPath != null) 'mmprojPath': mmprojPath,
      'preferredBackend': preferredBackend.name,
      'computeDevice': computeDevice.name,
      'temperature': temperature,
      'topK': topK,
      'topP': topP,
      'minP': minP,
      'penalty': penalty,
      'presencePenalty': presencePenalty,
      'contextSize': contextSize,
      'maxTokens': maxTokens,
      'gpuLayers': gpuLayers,
      'autoTuneHardware': autoTuneHardware,
      'requestedContextSize': requestedContextSize,
      'numberOfThreads': numberOfThreads,
      'numberOfThreadsBatch': numberOfThreadsBatch,
      'batchSize': batchSize,
      'microBatchSize': microBatchSize,
      'maxParallelSequences': maxParallelSequences,
      'useMmap': useMmap,
      'useMlock': useMlock,
      if (kvUnified != null) 'kvUnified': kvUnified,
      if (ropeFrequencyBase != null) 'ropeFrequencyBase': ropeFrequencyBase,
      if (ropeFrequencyScale != null) 'ropeFrequencyScale': ropeFrequencyScale,
      'cpuMoeLayers': cpuMoeLayers,
      'moeCacheBytes': moeCacheBytes,
      'flashAttention': flashAttention.name,
      'cacheTypeK': cacheTypeK.name,
      'cacheTypeV': cacheTypeV.name,
      'speculativeMode': speculativeMode.name,
      'toolsEnabled': toolsEnabled,
      'enabledBuiltInTools': enabledBuiltInTools,
      'customToolDeclarationsJson': customToolDeclarationsJson,
      'includeWorkspaceContextInChat': includeWorkspaceContextInChat,
      'enableMcpInChat': enableMcpInChat,
      'thinkingEnabled': thinkingEnabled,
      'thinkingBudgetTokens': thinkingBudgetTokens,
      'logLevel': logLevel.name,
      'nativeLogLevel': nativeLogLevel.name,
      'appearance': appearance.name,
      'inspectorOpen': inspectorOpen,
      'inspectorExpertMode': inspectorExpertMode,
      'autoLoadLastModel': autoLoadLastModel,
      if (modelBytesHint != null) 'modelBytesHint': modelBytesHint,
      if (customModelDirectories.isNotEmpty)
        'customModelDirectories': customModelDirectories,
    };
  }

  /// Restores [StudioSettings] from JSON with safe enum fallbacks.
  factory StudioSettings.fromJson(Map<String, Object?> json) {
    T enumByName<T extends Enum>(List<T> values, Object? raw, T fallback) {
      if (raw is! String) {
        return fallback;
      }
      for (final value in values) {
        if (value.name == raw) {
          return value;
        }
      }
      return fallback;
    }

    final rawTools = json['enabledBuiltInTools'];
    final enabledTools = rawTools is List
        ? rawTools.whereType<String>().toList(growable: false)
        : const <String>[
            'getWeather',
            'getCurrentTime',
            'evaluateMath',
            'convertUnits',
          ];

    final rawDirs = json['customModelDirectories'];
    final customDirs = rawDirs is List
        ? rawDirs.whereType<String>().toList(growable: false)
        : const <String>[];

    return StudioSettings(
      activeModelId: json['activeModelId'] as String?,
      modelPath: json['modelPath'] as String?,
      mmprojPath: json['mmprojPath'] as String?,
      preferredBackend: enumByName(
        GpuBackend.values,
        json['preferredBackend'],
        GpuBackend.auto,
      ),
      computeDevice: enumByName(
        ComputeDevice.values,
        json['computeDevice'],
        ComputeDevice.auto,
      ),
      temperature: (json['temperature'] as num?)?.toDouble() ?? 0.7,
      topK: (json['topK'] as num?)?.toInt() ?? 40,
      topP: (json['topP'] as num?)?.toDouble() ?? 0.9,
      minP: (json['minP'] as num?)?.toDouble() ?? 0.0,
      penalty: (json['penalty'] as num?)?.toDouble() ?? 1.1,
      presencePenalty: (json['presencePenalty'] as num?)?.toDouble() ?? 0.0,
      contextSize: (json['contextSize'] as num?)?.toInt() ?? 4096,
      maxTokens: (json['maxTokens'] as num?)?.toInt() ?? 2048,
      gpuLayers: (json['gpuLayers'] as num?)?.toInt() ?? 99,
      autoTuneHardware: (json['autoTuneHardware'] as bool?) ?? true,
      requestedContextSize:
          (json['requestedContextSize'] as num?)?.toInt() ?? 4096,
      numberOfThreads: (json['numberOfThreads'] as num?)?.toInt() ?? 0,
      numberOfThreadsBatch:
          (json['numberOfThreadsBatch'] as num?)?.toInt() ?? 0,
      batchSize: (json['batchSize'] as num?)?.toInt() ?? 0,
      microBatchSize: (json['microBatchSize'] as num?)?.toInt() ?? 0,
      maxParallelSequences:
          (json['maxParallelSequences'] as num?)?.toInt() ?? 1,
      useMmap: (json['useMmap'] as bool?) ?? true,
      useMlock: (json['useMlock'] as bool?) ?? false,
      kvUnified: json['kvUnified'] as bool?,
      ropeFrequencyBase: (json['ropeFrequencyBase'] as num?)?.toDouble(),
      ropeFrequencyScale: (json['ropeFrequencyScale'] as num?)?.toDouble(),
      cpuMoeLayers: (json['cpuMoeLayers'] as num?)?.toInt() ?? 0,
      moeCacheBytes: (json['moeCacheBytes'] as num?)?.toInt() ?? 0,
      flashAttention: enumByName(
        FlashAttention.values,
        json['flashAttention'],
        FlashAttention.auto,
      ),
      cacheTypeK: enumByName(
        KvCacheType.values,
        json['cacheTypeK'],
        KvCacheType.f16,
      ),
      cacheTypeV: enumByName(
        KvCacheType.values,
        json['cacheTypeV'],
        KvCacheType.f16,
      ),
      speculativeMode: enumByName(
        StudioSpeculativeMode.values,
        json['speculativeMode'],
        StudioSpeculativeMode.off,
      ),
      toolsEnabled: (json['toolsEnabled'] as bool?) ?? true,
      enabledBuiltInTools: enabledTools,
      customToolDeclarationsJson:
          (json['customToolDeclarationsJson'] as String?) ?? '[]',
      includeWorkspaceContextInChat:
          (json['includeWorkspaceContextInChat'] as bool?) ?? false,
      enableMcpInChat: (json['enableMcpInChat'] as bool?) ?? false,
      thinkingEnabled: (json['thinkingEnabled'] as bool?) ?? true,
      thinkingBudgetTokens:
          (json['thinkingBudgetTokens'] as num?)?.toInt() ?? 0,
      logLevel: enumByName(
        LlamaLogLevel.values,
        json['logLevel'],
        LlamaLogLevel.none,
      ),
      nativeLogLevel: enumByName(
        LlamaLogLevel.values,
        json['nativeLogLevel'],
        LlamaLogLevel.warn,
      ),
      appearance: enumByName(
        StudioAppearance.values,
        json['appearance'],
        StudioAppearance.system,
      ),
      inspectorOpen: (json['inspectorOpen'] as bool?) ?? true,
      inspectorExpertMode: (json['inspectorExpertMode'] as bool?) ?? false,
      autoLoadLastModel: (json['autoLoadLastModel'] as bool?) ?? true,
      modelBytesHint: (json['modelBytesHint'] as num?)?.toInt(),
      customModelDirectories: customDirs,
    );
  }
}
