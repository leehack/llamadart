import '../config/flash_attention.dart';
import '../config/gpu_backend.dart';
import '../config/kv_cache_type.dart';
import '../config/lora_config.dart';

/// Strategy for distributing model tensors across GPU devices.
///
/// Mirrors llama.cpp `llama_split_mode`. The default, [layer], preserves
/// upstream behavior.
enum ModelSplitMode {
  /// Use a single GPU selected by [ModelParams.mainGpu].
  none(0),

  /// Split layers and KV cache across GPUs.
  layer(1),

  /// Split layers and KV cache across GPUs, with row-level tensor splitting
  /// where supported by the backend.
  row(2),

  /// Use tensor parallelism where supported by the backend and model.
  tensor(3);

  /// Native llama.cpp enum value.
  final int llamaCppValue;

  const ModelSplitMode(this.llamaCppValue);
}

/// Configuration parameters for loading a Llama model.
///
/// These parameters affect the initial model loading and context allocation.
/// Most of these cannot be changed once the model is loaded.
///
/// Context batching fields in this class mirror llama.cpp semantics:
/// `n_batch` is the logical max decode batch, and `n_ubatch` is the
/// physical micro-batch size.
///
/// Example:
/// ```dart
/// final params = ModelParams(
///   contextSize: 4096,
///   gpuLayers: 33, // Offload 33 layers to GPU
///   splitMode: ModelSplitMode.none,
///   mainGpu: 1, // Use the second GPU device for the full model
/// );
/// await engine.loadModel('path/to/model.gguf', modelParams: params);
/// ```
class ModelParams {
  /// Context size (n_ctx) in tokens.
  final int contextSize;

  /// Number of model layers to offload to the GPU (n_gpu_layers).
  final int gpuLayers;

  /// Preferred GPU backend for inference.
  final GpuBackend preferredBackend;

  /// Model tensor distribution strategy across GPU devices.
  ///
  /// This is passed through to llama.cpp `llama_model_params.split_mode`.
  /// Defaults to [ModelSplitMode.layer] to preserve llama.cpp's default
  /// behavior.
  final ModelSplitMode splitMode;

  /// Primary GPU device index for model loading.
  ///
  /// This is passed through to llama.cpp `llama_model_params.main_gpu`.
  /// Backend-specific device ordering is defined by llama.cpp and the active
  /// backend. Upstream llama.cpp uses this value to select the single GPU when
  /// [splitMode] is [ModelSplitMode.none]. Defaults to 0 to preserve
  /// llama.cpp's default behavior.
  final int mainGpu;

  /// Initial LoRA adapters to load along with the model.
  final List<LoraAdapterConfig> loras;

  /// Optional chat template to override the model's default template.
  final String? chatTemplate;

  /// Number of threads to use for generation (n_threads).
  ///
  /// Set to 0 for automatic detection.
  final int numberOfThreads;

  /// Number of threads to use for batch processing (n_threads_batch).
  ///
  /// Set to 0 for automatic detection.
  final int numberOfThreadsBatch;

  /// Maximum prompt/eval tokens per decode call (n_batch).
  ///
  /// Mirrors llama.cpp `llama_context_params.n_batch` (logical max batch).
  /// See also upstream CLI flag `--batch-size`.
  ///
  /// Set to 0 (or negative) to default to [contextSize].
  final int batchSize;

  /// Micro-batch size used by backend schedulers (n_ubatch).
  ///
  /// Mirrors llama.cpp `llama_context_params.n_ubatch` (physical max batch).
  /// See also upstream CLI flag `--ubatch-size`.
  ///
  /// Set to 0 (or negative) to default to [batchSize].
  final int microBatchSize;

  /// Maximum parallel sequence slots in context memory (n_seq_max).
  ///
  /// Values greater than 1 allow true multi-sequence batching (for example,
  /// embedding batches with independent sequence IDs).
  ///
  /// Set to 1 to preserve single-sequence behavior.
  final int maxParallelSequences;

  /// `llama_model_params.use_mmap`. Default `true`.
  final bool useMmap;

  /// `llama_model_params.use_mlock`. Default `false`.
  final bool useMlock;

  /// `llama_context_params.flash_attn_type`. User-explicit values override
  /// the platform/backend heuristic.
  final FlashAttention flashAttention;

  /// `llama_context_params.type_k`. Non-F16 requires [flashAttention] enabled.
  final KvCacheType cacheTypeK;

  /// `llama_context_params.type_v`. Non-F16 requires [flashAttention] enabled.
  final KvCacheType cacheTypeV;

  /// `llama_context_params.kv_unified`. `null` keeps the current heuristic
  /// (auto-enabled when [maxParallelSequences] > 1).
  final bool? kvUnified;

  /// `llama_context_params.rope_freq_base`. `null` keeps the model's
  /// trained value.
  final double? ropeFrequencyBase;

  /// `llama_context_params.rope_freq_scale`. `null` keeps the model's
  /// trained value.
  final double? ropeFrequencyScale;

  /// Maximum number of GPU layers to safely offload all layers.
  static const int maxGpuLayers = 999;

  /// Creates configuration for the model. Use [validate] to check for
  /// llama.cpp-incompatible combinations before passing to a load call.
  const ModelParams({
    this.contextSize = 4096,
    this.gpuLayers = maxGpuLayers,
    this.preferredBackend = GpuBackend.auto,
    this.splitMode = ModelSplitMode.layer,
    this.mainGpu = 0,
    this.loras = const [],
    this.chatTemplate,
    this.numberOfThreads = 0,
    this.numberOfThreadsBatch = 0,
    this.batchSize = 0,
    this.microBatchSize = 0,
    this.maxParallelSequences = 1,
    this.useMmap = true,
    this.useMlock = false,
    this.flashAttention = FlashAttention.auto,
    this.cacheTypeK = KvCacheType.f16,
    this.cacheTypeV = KvCacheType.f16,
    this.kvUnified,
    this.ropeFrequencyBase,
    this.ropeFrequencyScale,
  });

  /// Validates the parameter combination. Throws [ArgumentError] when the
  /// combination is incompatible with llama.cpp (currently: non-F16 KV
  /// cache requires flashAttention != disabled). Called automatically by
  /// `LlamaCppService.loadModel` before the native call so callers don't
  /// have to remember it; exposed publicly so callers who construct
  /// `ModelParams` defensively can validate up-front.
  void validate() {
    if ((cacheTypeK != KvCacheType.f16 || cacheTypeV != KvCacheType.f16) &&
        flashAttention == FlashAttention.disabled) {
      throw ArgumentError(
        'Non-F16 KV cache (cacheTypeK=$cacheTypeK, cacheTypeV=$cacheTypeV) '
        'requires flashAttention != disabled. Either set flashAttention to '
        'auto/enabled or use KvCacheType.f16 for both.',
      );
    }
  }

  /// Creates a copy of this [ModelParams] with updated fields.
  ///
  /// Nullable fields ([chatTemplate], [kvUnified], [ropeFrequencyBase],
  /// [ropeFrequencyScale]) use a sentinel pattern so callers can
  /// **explicitly clear them back to null** by passing the corresponding
  /// `clear*: true` flag. Without the sentinel, `null` would be
  /// indistinguishable from "argument omitted, keep current value".
  ModelParams copyWith({
    int? contextSize,
    int? gpuLayers,
    GpuBackend? preferredBackend,
    ModelSplitMode? splitMode,
    int? mainGpu,
    List<LoraAdapterConfig>? loras,
    String? chatTemplate,
    bool clearChatTemplate = false,
    int? numberOfThreads,
    int? numberOfThreadsBatch,
    int? batchSize,
    int? microBatchSize,
    int? maxParallelSequences,
    bool? useMmap,
    bool? useMlock,
    FlashAttention? flashAttention,
    KvCacheType? cacheTypeK,
    KvCacheType? cacheTypeV,
    bool? kvUnified,
    bool clearKvUnified = false,
    double? ropeFrequencyBase,
    bool clearRopeFrequencyBase = false,
    double? ropeFrequencyScale,
    bool clearRopeFrequencyScale = false,
  }) {
    return ModelParams(
      contextSize: contextSize ?? this.contextSize,
      gpuLayers: gpuLayers ?? this.gpuLayers,
      preferredBackend: preferredBackend ?? this.preferredBackend,
      splitMode: splitMode ?? this.splitMode,
      mainGpu: mainGpu ?? this.mainGpu,
      loras: loras ?? this.loras,
      chatTemplate: clearChatTemplate
          ? null
          : (chatTemplate ?? this.chatTemplate),
      numberOfThreads: numberOfThreads ?? this.numberOfThreads,
      numberOfThreadsBatch: numberOfThreadsBatch ?? this.numberOfThreadsBatch,
      batchSize: batchSize ?? this.batchSize,
      microBatchSize: microBatchSize ?? this.microBatchSize,
      maxParallelSequences: maxParallelSequences ?? this.maxParallelSequences,
      useMmap: useMmap ?? this.useMmap,
      useMlock: useMlock ?? this.useMlock,
      flashAttention: flashAttention ?? this.flashAttention,
      cacheTypeK: cacheTypeK ?? this.cacheTypeK,
      cacheTypeV: cacheTypeV ?? this.cacheTypeV,
      kvUnified: clearKvUnified ? null : (kvUnified ?? this.kvUnified),
      ropeFrequencyBase: clearRopeFrequencyBase
          ? null
          : (ropeFrequencyBase ?? this.ropeFrequencyBase),
      ropeFrequencyScale: clearRopeFrequencyScale
          ? null
          : (ropeFrequencyScale ?? this.ropeFrequencyScale),
    );
  }
}

/// Resolves llama.cpp-compatible context batch parameters.
///
/// Preserves native defaults when [ModelParams.batchSize] and
/// [ModelParams.microBatchSize] are unset:
///
/// - `n_batch = n_ctx`
/// - `n_ubatch = n_batch`
///
/// Values are clamped to safe bounds so `n_ubatch <= n_batch <= n_ctx`.
({int batchSize, int microBatchSize}) resolveModelContextBatchSizes(
  ModelParams modelParams,
  int contextSize,
) {
  final effectiveContextSize = contextSize > 0 ? contextSize : 1;

  final configuredBatchSize = modelParams.batchSize > 0
      ? modelParams.batchSize
      : effectiveContextSize;
  final cappedBatchSize = configuredBatchSize > effectiveContextSize
      ? effectiveContextSize
      : configuredBatchSize;
  final batchSize = cappedBatchSize > 0 ? cappedBatchSize : 1;

  final configuredMicroBatchSize = modelParams.microBatchSize > 0
      ? modelParams.microBatchSize
      : batchSize;
  final cappedMicroBatchSize = configuredMicroBatchSize > batchSize
      ? batchSize
      : configuredMicroBatchSize;
  final microBatchSize = cappedMicroBatchSize > 0 ? cappedMicroBatchSize : 1;

  return (batchSize: batchSize, microBatchSize: microBatchSize);
}
