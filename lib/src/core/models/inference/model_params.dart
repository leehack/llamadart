import '../../exceptions.dart';
import '../config/compute_device.dart';
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

/// Preferred LiteRT-LM runtime backend for `.litertlm` models.
///
/// Use [ModelParams.device], which every runtime honours and which throws
/// `LlamaUnsupportedException` when the device is unavailable. This selector
/// keeps working until 1.0, so a load can still pick a LiteRT-LM device apart
/// from the llama.cpp one.
@Deprecated('Use ModelParams.device. This will be removed in 1.0.')
enum LiteRtLmBackendPreference {
  /// Let llamadart choose a platform default.
  auto(null),

  /// Run LiteRT-LM on CPU.
  cpu('cpu'),

  /// Run LiteRT-LM on the platform GPU delegate when available.
  gpu('gpu'),

  /// Run LiteRT-LM on Android NPU delegate when available.
  npu('npu');

  /// Native LiteRT-LM backend name, or null for automatic selection.
  final String? nativeName;

  const LiteRtLmBackendPreference(this.nativeName);
}

/// LiteRT-LM activation data type override for native `.litertlm` engines.
///
/// Values mirror upstream LiteRT-LM `ActivationDataType` integer values exposed
/// through `litert_lm_engine_settings_set_activation_data_type`.
enum LiteRtLmActivationDataType {
  /// Use float32 activations.
  float32(0, 'float32'),

  /// Use float16 activations.
  float16(1, 'float16'),

  /// Use int16 activations.
  int16(2, 'int16'),

  /// Use int8 activations.
  int8(3, 'int8');

  /// Native LiteRT-LM C ABI value.
  final int nativeValue;

  /// Stable CLI/docs name.
  final String optionName;

  const LiteRtLmActivationDataType(this.nativeValue, this.optionName);
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
/// final engine = await LlamaEngine.load(
///   LlamaModel(ModelSource.path('path/to/model.gguf')),
///   params: params,
/// );
/// ```
class ModelParams {
  /// Context size (n_ctx) in tokens.
  final int contextSize;

  /// Device to run the model on, for every runtime.
  ///
  /// [ComputeDevice.auto], the default, keeps each runtime's own default,
  /// which [gpuLayers], [preferredBackend] and the deprecated
  /// [liteRtLmBackend] narrow as before.
  ///
  /// An explicit device is honoured or the load throws
  /// `LlamaUnsupportedException`; it never runs elsewhere:
  /// - [ComputeDevice.cpu] loads no GPU layers. On llama.cpp it loads only
  ///   the CPU module, whatever [gpuLayers] and [preferredBackend] say;
  ///   LiteRT-LM still rejects a [gpuLayers] other than 0 or [maxGpuLayers].
  /// - [ComputeDevice.gpu] on llama.cpp needs a GPU module and device for
  ///   [preferredBackend] (Vulkan on Android when it is
  ///   [GpuBackend.auto]), and on the Web an active WebGPU runtime. LiteRT-LM
  ///   needs its GPU backend on this platform, and on the Web a WebGPU
  ///   adapter.
  /// - [ComputeDevice.npu] is LiteRT-LM on Android only.
  ///
  /// Native LiteRT-LM starts its runtime on the first call that needs it, so
  /// a GPU or NPU that fails to start throws `LlamaUnsupportedException`
  /// there. [validate] rejects a device that contradicts [preferredBackend],
  /// [gpuLayers], [mainGpu] or [liteRtLmBackend].
  final ComputeDevice device;

  /// Number of model layers to offload to the GPU (n_gpu_layers).
  final int gpuLayers;

  /// Preferred GPU backend for inference.
  ///
  /// Under [ComputeDevice.auto], on Linux and Windows, an explicit GPU
  /// backend whose module is missing loads the model on CPU with 0 GPU layers
  /// and logs a `LlamaLogLevel.warn` record through the Dart logger. With
  /// [device] set to [ComputeDevice.gpu] the load throws instead.
  final GpuBackend preferredBackend;

  /// Preferred LiteRT-LM runtime backend for `.litertlm` models.
  ///
  /// Defaults to [LiteRtLmBackendPreference.auto]. The llama.cpp
  /// [preferredBackend] field is still used for `.gguf` models and as an
  /// automatic LiteRT-LM hint. An unavailable choice throws as it did in
  /// 0.10.0, not `LlamaUnsupportedException`.
  @Deprecated(
    'Use device, which applies to every runtime. This will be removed in '
    '1.0.',
  )
  final LiteRtLmBackendPreference liteRtLmBackend;

  /// Native LiteRT-LM activation data type override.
  ///
  /// `null` keeps the runtime/model default. This option is only applied by the
  /// native LiteRT-LM `.litertlm` backend.
  final LiteRtLmActivationDataType? liteRtLmActivationDataType;

  /// Native LiteRT-LM prefill chunk size for CPU dynamic models.
  ///
  /// `null` keeps the runtime default. Positive values are forwarded to
  /// `litert_lm_engine_settings_set_prefill_chunk_size`.
  final int? liteRtLmPrefillChunkSize;

  /// Native LiteRT-LM file-section loading override.
  ///
  /// `null` keeps the runtime default, which is parallel loading in the pinned
  /// LiteRT-LM runtime. Set `false` to disable it for diagnostics.
  final bool? liteRtLmParallelFileSectionLoading;

  /// Native LiteRT-LM dispatch library directory for Android NPU deployments.
  ///
  /// `null` keeps the runtime default. This path is forwarded to
  /// `litert_lm_engine_settings_set_litert_dispatch_lib_dir`.
  final String? liteRtLmDispatchLibDir;

  /// Native LiteRT-LM runtime cache directory.
  ///
  /// `null` keeps the default: `llamadart_litert_lm` under the system
  /// temporary directory on macOS and Android, and no directory on other
  /// platforms, where the runtime writes its caches next to the model file.
  /// A provided directory is created when missing and forwarded to
  /// `litert_lm_engine_settings_set_cache_dir`.
  final String? liteRtLmCacheDir;

  /// Size cap in bytes for native LiteRT-LM GPU program cache files.
  ///
  /// `null` never deletes anything. Otherwise, before each native engine
  /// create, files directly inside the effective cache directory whose name
  /// ends with `_mldrift_program_cache.bin` and whose size exceeds this value
  /// are deleted. Nothing is deleted when [liteRtLmCacheDir] is `null` on a
  /// platform without a default cache directory.
  final int? liteRtLmMaxProgramCacheBytes;

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
  /// [splitMode] is [ModelSplitMode.none], where a negative value loads the
  /// model on the CPU. Defaults to 0 to preserve llama.cpp's default
  /// behavior.
  final int mainGpu;

  /// Initial LoRA adapters to load along with the model.
  ///
  /// llama.cpp backends apply every adapter at its [LoraAdapterConfig.scale],
  /// in list order, once the model and its context are created, as
  /// `LlamaEngine.setLoraSource` would; `setLoraSource`, `removeLoraSource`
  /// and `clearLoras` can change them afterwards. Each load applies the list
  /// again.
  ///
  /// `LlamaEngine` resolves each [LoraAdapterConfig.source] before the model
  /// loads, as `setLoraSource` does, in list order, with the adapter's own
  /// [LoraAdapterConfig.download]. Without one, an adapter takes only the
  /// non-secret options of the load (the `download` of `LlamaEngine.load`
  /// and `setModel`): cache policy and directory, resume, retries and cancel
  /// token. The load's bearer token,
  /// headers and checksum never reach an adapter's host. Adapter downloads
  /// report no progress; a failed one fails the load before the model loads.
  ///
  /// On WebGPU this needs bridge assets `v0.1.54+` whose runtime LoRA API reports
  /// support. When an adapter cannot be applied the load fails, and a load
  /// through `LlamaEngine` leaves no model loaded. An unsupported adapter,
  /// such as an aLoRA adapter, or older bridge assets throw
  /// `LlamaUnsupportedException` naming the adapter; any other failure throws
  /// `LlamaModelException`, with the adapter and cause in its `details`.
  ///
  /// Native LiteRT-LM supports one default-scale text LoRA adapter at model
  /// load; runtime adapter updates, stacking, custom scales, and LiteRT-LM
  /// web LoRA are unsupported.
  final List<LoraAdapterConfig> loras;

  /// Optional Jinja chat template that replaces the model's own template.
  ///
  /// The value is Jinja source; built-in llama.cpp template names such as
  /// `chatml` are not recognized.
  ///
  /// On llama.cpp (native and WebGPU), `LlamaEngine.create` and
  /// `LlamaEngine.chatTemplate` render prompts with it instead of the GGUF
  /// `tokenizer.chat_template` and its `tool_use` variant, as llama.cpp's
  /// `--chat-template-file` does, and detect the tool-call and reasoning
  /// format from it, so output parsing follows the same template. Null or
  /// empty keeps the GGUF template, and `LlamaEngine.getMetadata` still
  /// reports the GGUF template.
  ///
  /// On LiteRT-LM it replaces the built-in template chosen for the bundle,
  /// including an empty string, and drives `LlamaEngine.chatTemplate`, output
  /// parsing, and prompt rendering on LiteRT-LM web and for requests that
  /// cannot use the native Conversation API. Native `LlamaEngine.create`
  /// sends eligible text-only chats through that API, where the template
  /// shapes the prompt only for Qwen3 text bundles.
  ///
  /// A per-call `customTemplate` takes precedence on every runtime.
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
  /// Set to 0 (or negative) to use an automatic value. Native generative
  /// contexts default to the smaller of [contextSize] and
  /// [ModelParams.defaultBatchSize]. Native encoder-only models retain
  /// full-context batching for compatibility. Backends that cannot determine
  /// model architecture before context creation may also retain that policy.
  final int batchSize;

  /// Micro-batch size used by backend schedulers (n_ubatch).
  ///
  /// Mirrors llama.cpp `llama_context_params.n_ubatch` (physical max batch).
  /// See also upstream CLI flag `--ubatch-size`.
  ///
  /// Set to 0 (or negative) to use an automatic value. Native generative
  /// contexts default to the smaller of the resolved [batchSize] and
  /// [ModelParams.defaultMicroBatchSize]. Native encoder-only models retain
  /// the resolved logical batch size for compatibility. Other backends may
  /// preserve the same architecture-agnostic fallback.
  ///
  /// On Android, while this is unset, a llama.cpp context that runs on Vulkan
  /// decodes a text prompt in micro-batches of at most 8 tokens: ggml-vulkan
  /// returns wrong results for one of more than 32 tokens on some GPUs
  /// ([#948](https://github.com/leehack/llamadart/issues/948)). An explicit
  /// value is used as given, so one above 32 can bring the wrong results
  /// back. The cap applies to text-prompt decoding only: it does not cover
  /// prompts with image or audio input, embeddings, decision models,
  /// text-to-speech, or speculative-decoding verification batches during
  /// generation. Those batches can exceed 32 tokens, so speculative decoding
  /// can still produce wrong output on an affected GPU.
  ///
  /// Native encoder-only models and models whose context has no KV cache,
  /// such as BERT and ModernBERT, embed each input in one micro-batch, so a
  /// longer embedding input throws `LlamaInferenceException`. So does an
  /// image with more tokens than the micro-batch when the projector decodes
  /// an image in one pass, as those of Gemma 3 and of Gemma 4 other than E2B
  /// and E4B do.
  final int microBatchSize;

  /// Maximum parallel sequence slots in context memory (n_seq_max).
  ///
  /// Values greater than 1 allow true multi-sequence batching (for example,
  /// embedding batches with independent sequence IDs).
  ///
  /// Set to 1 to preserve single-sequence behavior.
  final int maxParallelSequences;

  /// llama.cpp recurrent-state rollback snapshots per sequence (`n_rs_seq`).
  ///
  /// The default `0` preserves ordinary context memory use. Native llama.cpp
  /// rejects nonzero values for recurrent or hybrid models, including LFM2
  /// and Qwen3.5, with [LlamaUnsupportedException] before context creation:
  /// the native API cannot establish a safe rollback graph-node budget.
  /// Speculative decoding that requires those snapshots is unsupported on
  /// these models until the native runtime can validate the graph capacity.
  /// Nonrecurrent models retain native handling; llama.cpp may clamp the
  /// value to zero for architectures without recurrent rollback.
  /// Other backends, including WebGPU, have their own capability contract.
  final int speculativeRollbackTokenMax;

  /// Whether llama.cpp should memory-map model weights. Default `true`.
  ///
  /// Combined with [useMlock] and mapped to `llama_model_params.load_mode`.
  final bool useMmap;

  /// Whether llama.cpp should lock model weights in memory. Default `false`.
  ///
  /// Combined with [useMmap] and mapped to `llama_model_params.load_mode`.
  final bool useMlock;

  /// Whether llama.cpp should load bundled multi-token prediction tensors.
  ///
  /// Defaults to `false` to avoid the additional memory cost for callers that
  /// do not use MTP speculative decoding. Set this before loading a model when
  /// `SpeculativeDecodingStrategy.mtp` will use MTP tensors embedded in the
  /// target GGUF. Explicit external MTP draft models are loaded as MTP
  /// automatically.
  final bool loadMtp;

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

  /// Web/WebGPU only: prefer the 64-bit (wasm64/mem64) bridge core.
  ///
  /// The default 32-bit core has a 4 GiB linear-memory limit, but large models
  /// need headroom for the KV cache and intermediate buffers. `null` (default)
  /// lets llamadart auto-decide from [modelBytesHint] using the current
  /// wasm32-safe ceiling; `true` forces the mem64 core; `false` forces wasm32.
  /// Ignored on every non-web backend (native llama.cpp uses the host address
  /// space).
  final bool? preferMemory64;

  /// Web/WebGPU only: approximate model size in bytes, used to decide whether
  /// to load the mem64 core up front (instead of waiting for an out-of-memory
  /// failure and retrying). Ignored on non-web backends. `null` when unknown.
  final int? modelBytesHint;

  /// Maximum number of GPU layers to safely offload all layers.
  static const int maxGpuLayers = 999;

  /// Automatic logical batch size for generative contexts.
  ///
  /// This matches llama.cpp's default `n_batch`.
  static const int defaultBatchSize = 2048;

  /// Automatic physical micro-batch size for generative contexts.
  ///
  /// This matches llama.cpp's default `n_ubatch`.
  static const int defaultMicroBatchSize = 512;

  /// Creates configuration for the model. Use [validate] to check for
  /// llama.cpp-incompatible combinations before passing to a load call.
  const ModelParams({
    this.contextSize = 4096,
    this.device = ComputeDevice.auto,
    this.gpuLayers = maxGpuLayers,
    this.preferredBackend = GpuBackend.auto,
    @Deprecated(
      'Use device, which applies to every runtime. This will be removed in '
      '1.0.',
    )
    this.liteRtLmBackend = LiteRtLmBackendPreference.auto,
    this.liteRtLmActivationDataType,
    this.liteRtLmPrefillChunkSize,
    this.liteRtLmParallelFileSectionLoading,
    this.liteRtLmDispatchLibDir,
    this.liteRtLmCacheDir,
    this.liteRtLmMaxProgramCacheBytes,
    this.splitMode = ModelSplitMode.layer,
    this.mainGpu = 0,
    this.loras = const [],
    this.chatTemplate,
    this.numberOfThreads = 0,
    this.numberOfThreadsBatch = 0,
    this.batchSize = 0,
    this.microBatchSize = 0,
    this.maxParallelSequences = 1,
    this.speculativeRollbackTokenMax = 0,
    this.useMmap = true,
    this.useMlock = false,
    this.loadMtp = false,
    this.flashAttention = FlashAttention.auto,
    this.cacheTypeK = KvCacheType.f16,
    this.cacheTypeV = KvCacheType.f16,
    this.kvUnified,
    this.ropeFrequencyBase,
    this.ropeFrequencyScale,
    this.preferMemory64,
    this.modelBytesHint,
  });

  /// Validates the parameter combination. Throws [LlamaArgumentException]
  /// when a value is out of range or the combination is incompatible with
  /// llama.cpp (a non-F16 KV cache requires flashAttention != disabled), or
  /// when [device] contradicts another field:
  /// - an explicit [device] with a [liteRtLmBackend] other than auto;
  /// - [ComputeDevice.cpu] with a GPU [preferredBackend] (Vulkan, Metal,
  ///   CUDA, OpenCL or HIP);
  /// - [ComputeDevice.gpu] or [ComputeDevice.npu] with a CPU or BLAS
  ///   [preferredBackend], with [gpuLayers] set to 0, or with [splitMode]
  ///   [ModelSplitMode.none] and a negative [mainGpu].
  ///
  /// `LlamaEngine` model loads call it before any download or native call,
  /// so callers don't have to remember it; call it directly to validate a
  /// `ModelParams` up front.
  void validate() {
    _validateDevice();
    if (liteRtLmPrefillChunkSize != null && liteRtLmPrefillChunkSize! <= 0) {
      throw _invalid(
        'liteRtLmPrefillChunkSize',
        liteRtLmPrefillChunkSize,
        'must be positive when provided',
      );
    }
    if (liteRtLmDispatchLibDir != null &&
        liteRtLmDispatchLibDir!.trim().isEmpty) {
      throw _invalid(
        'liteRtLmDispatchLibDir',
        liteRtLmDispatchLibDir,
        'must be non-empty when provided',
      );
    }
    if (liteRtLmCacheDir != null && liteRtLmCacheDir!.trim().isEmpty) {
      throw _invalid(
        'liteRtLmCacheDir',
        liteRtLmCacheDir,
        'must be non-empty when provided',
      );
    }
    if (liteRtLmMaxProgramCacheBytes != null &&
        liteRtLmMaxProgramCacheBytes! < 0) {
      throw _invalid(
        'liteRtLmMaxProgramCacheBytes',
        liteRtLmMaxProgramCacheBytes,
        'must be non-negative when provided',
      );
    }
    if (speculativeRollbackTokenMax < 0) {
      throw _invalid(
        'speculativeRollbackTokenMax',
        speculativeRollbackTokenMax,
        'must be non-negative',
      );
    }
    if ((cacheTypeK != KvCacheType.f16 || cacheTypeV != KvCacheType.f16) &&
        flashAttention == FlashAttention.disabled) {
      throw LlamaArgumentException(
        'Non-F16 KV cache (cacheTypeK=$cacheTypeK, cacheTypeV=$cacheTypeV) '
        'requires flashAttention != disabled. Either set flashAttention to '
        'auto/enabled or use KvCacheType.f16 for both.',
      );
    }
  }

  void _validateDevice() {
    if (device == ComputeDevice.auto) {
      return;
    }
    if (liteRtLmBackend != LiteRtLmBackendPreference.auto) {
      throw LlamaArgumentException(
        'ModelParams.device ${device.name} cannot be combined with the '
        'deprecated liteRtLmBackend ${liteRtLmBackend.name}. Set only device.',
        name: 'liteRtLmBackend',
        invalidValue: liteRtLmBackend.name,
      );
    }
    final cpuBackend =
        preferredBackend == GpuBackend.cpu ||
        preferredBackend == GpuBackend.blas;
    if (device == ComputeDevice.cpu) {
      if (!cpuBackend && preferredBackend != GpuBackend.auto) {
        throw LlamaArgumentException(
          'ModelParams.device cpu cannot be combined with the GPU '
          'preferredBackend ${preferredBackend.name}. Use GpuBackend.auto, '
          'cpu or blas.',
          name: 'preferredBackend',
          invalidValue: preferredBackend.name,
        );
      }
      return;
    }
    if (cpuBackend) {
      throw LlamaArgumentException(
        'ModelParams.device ${device.name} cannot be combined with '
        'preferredBackend ${preferredBackend.name}, which runs on the CPU. '
        'Use GpuBackend.auto or a GPU backend.',
        name: 'preferredBackend',
        invalidValue: preferredBackend.name,
      );
    }
    if (gpuLayers == 0) {
      throw LlamaArgumentException(
        'ModelParams.device ${device.name} cannot be combined with '
        'gpuLayers 0, which runs on the CPU. Leave gpuLayers at '
        'ModelParams.maxGpuLayers or set a positive count.',
        name: 'gpuLayers',
        invalidValue: gpuLayers,
      );
    }
    // llama.cpp reads main_gpu only under split_mode NONE, where a negative
    // value drops every device and loads the whole model on the CPU.
    if (splitMode == ModelSplitMode.none && mainGpu < 0) {
      throw LlamaArgumentException(
        'ModelParams.device ${device.name} cannot be combined with splitMode '
        'none and mainGpu $mainGpu, which llama.cpp runs on the CPU. Set '
        'mainGpu to a GPU index (0 or more).',
        name: 'mainGpu',
        invalidValue: mainGpu,
      );
    }
  }

  static LlamaArgumentException _invalid(
    String name,
    Object? value,
    String requirement,
  ) => LlamaArgumentException(
    'ModelParams.$name $requirement (got $value).',
    name: name,
    invalidValue: value,
  );

  /// Creates a copy of this [ModelParams] with updated fields.
  ///
  /// Nullable fields ([chatTemplate], [kvUnified], [ropeFrequencyBase],
  /// [ropeFrequencyScale]) use a sentinel pattern so callers can
  /// **explicitly clear them back to null** by passing the corresponding
  /// `clear*: true` flag. Without the sentinel, `null` would be
  /// indistinguishable from "argument omitted, keep current value".
  ModelParams copyWith({
    int? contextSize,
    ComputeDevice? device,
    int? gpuLayers,
    GpuBackend? preferredBackend,
    @Deprecated(
      'Use device, which applies to every runtime. This will be removed in '
      '1.0.',
    )
    LiteRtLmBackendPreference? liteRtLmBackend,
    LiteRtLmActivationDataType? liteRtLmActivationDataType,
    bool clearLiteRtLmActivationDataType = false,
    int? liteRtLmPrefillChunkSize,
    bool clearLiteRtLmPrefillChunkSize = false,
    bool? liteRtLmParallelFileSectionLoading,
    bool clearLiteRtLmParallelFileSectionLoading = false,
    String? liteRtLmDispatchLibDir,
    bool clearLiteRtLmDispatchLibDir = false,
    String? liteRtLmCacheDir,
    bool clearLiteRtLmCacheDir = false,
    int? liteRtLmMaxProgramCacheBytes,
    bool clearLiteRtLmMaxProgramCacheBytes = false,
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
    int? speculativeRollbackTokenMax,
    bool? useMmap,
    bool? useMlock,
    bool? loadMtp,
    FlashAttention? flashAttention,
    KvCacheType? cacheTypeK,
    KvCacheType? cacheTypeV,
    bool? kvUnified,
    bool clearKvUnified = false,
    double? ropeFrequencyBase,
    bool clearRopeFrequencyBase = false,
    double? ropeFrequencyScale,
    bool clearRopeFrequencyScale = false,
    bool? preferMemory64,
    bool clearPreferMemory64 = false,
    int? modelBytesHint,
    bool clearModelBytesHint = false,
  }) {
    return ModelParams(
      contextSize: contextSize ?? this.contextSize,
      device: device ?? this.device,
      gpuLayers: gpuLayers ?? this.gpuLayers,
      preferredBackend: preferredBackend ?? this.preferredBackend,
      liteRtLmBackend: liteRtLmBackend ?? this.liteRtLmBackend,
      liteRtLmActivationDataType: clearLiteRtLmActivationDataType
          ? null
          : (liteRtLmActivationDataType ?? this.liteRtLmActivationDataType),
      liteRtLmPrefillChunkSize: clearLiteRtLmPrefillChunkSize
          ? null
          : (liteRtLmPrefillChunkSize ?? this.liteRtLmPrefillChunkSize),
      liteRtLmParallelFileSectionLoading:
          clearLiteRtLmParallelFileSectionLoading
          ? null
          : (liteRtLmParallelFileSectionLoading ??
                this.liteRtLmParallelFileSectionLoading),
      liteRtLmDispatchLibDir: clearLiteRtLmDispatchLibDir
          ? null
          : (liteRtLmDispatchLibDir ?? this.liteRtLmDispatchLibDir),
      liteRtLmCacheDir: clearLiteRtLmCacheDir
          ? null
          : (liteRtLmCacheDir ?? this.liteRtLmCacheDir),
      liteRtLmMaxProgramCacheBytes: clearLiteRtLmMaxProgramCacheBytes
          ? null
          : (liteRtLmMaxProgramCacheBytes ?? this.liteRtLmMaxProgramCacheBytes),
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
      speculativeRollbackTokenMax:
          speculativeRollbackTokenMax ?? this.speculativeRollbackTokenMax,
      useMmap: useMmap ?? this.useMmap,
      useMlock: useMlock ?? this.useMlock,
      loadMtp: loadMtp ?? this.loadMtp,
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
      preferMemory64: clearPreferMemory64
          ? null
          : (preferMemory64 ?? this.preferMemory64),
      modelBytesHint: clearModelBytesHint
          ? null
          : (modelBytesHint ?? this.modelBytesHint),
    );
  }
}

/// Resolves llama.cpp-compatible context batch parameters.
///
/// When [ModelParams.batchSize] and [ModelParams.microBatchSize] are unset,
/// generative contexts use llama.cpp's standard defaults:
///
/// - `n_batch = min(n_ctx, 2048)`
/// - `n_ubatch = min(n_batch, 512)`
///
/// Set [useFullContextDefaults] for a detected encoder-only model that needs
/// the legacy `n_batch = n_ctx`, `n_ubatch = n_batch` cascade. Explicit
/// positive values always take precedence over either default policy.
///
/// Values are clamped to safe bounds so `n_ubatch <= n_batch <= n_ctx`.
({int batchSize, int microBatchSize}) resolveModelContextBatchSizes(
  ModelParams modelParams,
  int contextSize, {
  bool useFullContextDefaults = false,
}) {
  final effectiveContextSize = contextSize > 0 ? contextSize : 1;
  final automaticBatchSize = useFullContextDefaults
      ? effectiveContextSize
      : ModelParams.defaultBatchSize;

  final configuredBatchSize = modelParams.batchSize > 0
      ? modelParams.batchSize
      : automaticBatchSize;
  final cappedBatchSize = configuredBatchSize > effectiveContextSize
      ? effectiveContextSize
      : configuredBatchSize;
  final batchSize = cappedBatchSize > 0 ? cappedBatchSize : 1;
  final automaticMicroBatchSize = useFullContextDefaults
      ? batchSize
      : ModelParams.defaultMicroBatchSize;

  final configuredMicroBatchSize = modelParams.microBatchSize > 0
      ? modelParams.microBatchSize
      : automaticMicroBatchSize;
  final cappedMicroBatchSize = configuredMicroBatchSize > batchSize
      ? batchSize
      : configuredMicroBatchSize;
  final microBatchSize = cappedMicroBatchSize > 0 ? cappedMicroBatchSize : 1;

  return (batchSize: batchSize, microBatchSize: microBatchSize);
}
