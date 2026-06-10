import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as path;

import '../../core/llama_logger.dart';
import '../../core/models/chat/content_part.dart';
import '../../core/models/config/gpu_backend.dart';
import '../../core/models/config/log_level.dart';
import '../../core/models/inference/generation_params.dart';
import '../../core/models/inference/model_params.dart';
import 'load_param_helpers.dart';
import 'bindings.dart';

const _llamadartWrapperAssetId = 'package:llamadart/llamadart_wrapper';

typedef _GgmlBackendLoadNative = ggml_backend_reg_t Function(Pointer<Char>);
typedef _GgmlBackendLoadDart = ggml_backend_reg_t Function(Pointer<Char>);
typedef _GgmlBackendInitNative = ggml_backend_reg_t Function();
typedef _GgmlBackendInitDart = ggml_backend_reg_t Function();
typedef _GgmlBackendLoadAllNative = Void Function();
typedef _GgmlBackendLoadAllDart = void Function();
typedef _GgmlBackendLoadAllFromPathNative = Void Function(Pointer<Char>);
typedef _GgmlBackendLoadAllFromPathDart = void Function(Pointer<Char>);
typedef _GgmlBackendScoreNative = Int32 Function();
typedef _GgmlBackendScoreDart = int Function();
typedef _GgmlBackendRegisterNative = Void Function(ggml_backend_reg_t);
typedef _GgmlBackendRegisterDart = void Function(ggml_backend_reg_t);
typedef _GgmlBackendRegCountNative = Size Function();
typedef _GgmlBackendRegCountDart = int Function();
typedef _GgmlBackendRegGetNative = ggml_backend_reg_t Function(Size);
typedef _GgmlBackendRegGetDart = ggml_backend_reg_t Function(int);
typedef _GgmlBackendRegNameNative = Pointer<Char> Function(ggml_backend_reg_t);
typedef _GgmlBackendRegNameDart = Pointer<Char> Function(ggml_backend_reg_t);
typedef _GgmlBackendRegByNameNative =
    ggml_backend_reg_t Function(Pointer<Char>);
typedef _GgmlBackendRegByNameDart = ggml_backend_reg_t Function(Pointer<Char>);
typedef _GgmlBackendRegDevCountNative = Size Function(ggml_backend_reg_t);
typedef _GgmlBackendRegDevCountDart = int Function(ggml_backend_reg_t);
typedef _GgmlBackendRegDevGetNative =
    ggml_backend_dev_t Function(ggml_backend_reg_t, Size);
typedef _GgmlBackendRegDevGetDart =
    ggml_backend_dev_t Function(ggml_backend_reg_t, int);
typedef _GgmlBackendDevCountNative = Size Function();
typedef _GgmlBackendDevCountDart = int Function();
typedef _GgmlBackendDevGetNative = ggml_backend_dev_t Function(Size);
typedef _GgmlBackendDevGetDart = ggml_backend_dev_t Function(int);
typedef _GgmlBackendDevNameNative = Pointer<Char> Function(ggml_backend_dev_t);
typedef _GgmlBackendDevNameDart = Pointer<Char> Function(ggml_backend_dev_t);
typedef _GgmlBackendDevBackendRegNative =
    ggml_backend_reg_t Function(ggml_backend_dev_t);
typedef _GgmlBackendDevBackendRegDart =
    ggml_backend_reg_t Function(ggml_backend_dev_t);
typedef _GgmlBackendDevByTypeNative = ggml_backend_dev_t Function(UnsignedInt);
typedef _GgmlBackendDevByTypeDart = ggml_backend_dev_t Function(int);
typedef _GgmlBackendDevTypeNative = UnsignedInt Function(ggml_backend_dev_t);
typedef _GgmlBackendDevTypeDart = int Function(ggml_backend_dev_t);
typedef _GgmlBackendDevGetPropsNative =
    Void Function(ggml_backend_dev_t, Pointer<ggml_backend_dev_props>);
typedef _GgmlBackendDevGetPropsDart =
    void Function(ggml_backend_dev_t, Pointer<ggml_backend_dev_props>);
typedef _GgmlBackendDevMemoryNative =
    Void Function(ggml_backend_dev_t, Pointer<Size>, Pointer<Size>);
typedef _GgmlBackendDevMemoryDart =
    void Function(ggml_backend_dev_t, Pointer<Size>, Pointer<Size>);
typedef _LlamaDartSetLogLevelNative = Void Function(Int32);
typedef _LlamaDartSetLogLevelDart = void Function(int);
typedef _MtmdDefaultMarkerNative = Pointer<Char> Function();
typedef _MtmdDefaultMarkerDart = Pointer<Char> Function();
typedef _MtmdContextParamsDefaultNative = mtmd_context_params Function();
typedef _MtmdContextParamsDefaultDart = mtmd_context_params Function();
typedef _MtmdInitFromFileNative =
    Pointer<mtmd_context> Function(
      Pointer<Char>,
      Pointer<llama_model>,
      mtmd_context_params,
    );
typedef _MtmdInitFromFileDart =
    Pointer<mtmd_context> Function(
      Pointer<Char>,
      Pointer<llama_model>,
      mtmd_context_params,
    );
typedef _MtmdFreeNative = Void Function(Pointer<mtmd_context>);
typedef _MtmdFreeDart = void Function(Pointer<mtmd_context>);
typedef _MtmdInputChunksInitNative = Pointer<mtmd_input_chunks> Function();
typedef _MtmdInputChunksInitDart = Pointer<mtmd_input_chunks> Function();
typedef _MtmdInputChunksFreeNative = Void Function(Pointer<mtmd_input_chunks>);
typedef _MtmdInputChunksFreeDart = void Function(Pointer<mtmd_input_chunks>);
typedef _MtmdHelperBitmapInitFromFileNative =
    Pointer<mtmd_bitmap> Function(Pointer<mtmd_context>, Pointer<Char>);
typedef _MtmdHelperBitmapInitFromFileDart =
    Pointer<mtmd_bitmap> Function(Pointer<mtmd_context>, Pointer<Char>);
typedef _MtmdHelperBitmapInitFromBufNative =
    Pointer<mtmd_bitmap> Function(
      Pointer<mtmd_context>,
      Pointer<UnsignedChar>,
      Size,
    );
typedef _MtmdHelperBitmapInitFromBufDart =
    Pointer<mtmd_bitmap> Function(
      Pointer<mtmd_context>,
      Pointer<UnsignedChar>,
      int,
    );
typedef _MtmdBitmapInitFromAudioNative =
    Pointer<mtmd_bitmap> Function(Size, Pointer<Float>);
typedef _MtmdBitmapInitFromAudioDart =
    Pointer<mtmd_bitmap> Function(int, Pointer<Float>);
typedef _MtmdSupportVisionNative = Bool Function(Pointer<mtmd_context>);
typedef _MtmdSupportVisionDart = bool Function(Pointer<mtmd_context>);
typedef _MtmdSupportAudioNative = Bool Function(Pointer<mtmd_context>);
typedef _MtmdSupportAudioDart = bool Function(Pointer<mtmd_context>);
typedef _MtmdBitmapFreeNative = Void Function(Pointer<mtmd_bitmap>);
typedef _MtmdBitmapFreeDart = void Function(Pointer<mtmd_bitmap>);
typedef _MtmdTokenizeNative =
    Int32 Function(
      Pointer<mtmd_context>,
      Pointer<mtmd_input_chunks>,
      Pointer<mtmd_input_text>,
      Pointer<Pointer<mtmd_bitmap>>,
      Size,
    );
typedef _MtmdTokenizeDart =
    int Function(
      Pointer<mtmd_context>,
      Pointer<mtmd_input_chunks>,
      Pointer<mtmd_input_text>,
      Pointer<Pointer<mtmd_bitmap>>,
      int,
    );
typedef _MtmdHelperEvalChunksNative =
    Int32 Function(
      Pointer<mtmd_context>,
      Pointer<llama_context>,
      Pointer<mtmd_input_chunks>,
      llama_pos,
      llama_seq_id,
      Int32,
      Bool,
      Pointer<llama_pos>,
    );
typedef _MtmdHelperEvalChunksDart =
    int Function(
      Pointer<mtmd_context>,
      Pointer<llama_context>,
      Pointer<mtmd_input_chunks>,
      int,
      int,
      int,
      bool,
      Pointer<llama_pos>,
    );
typedef _MtmdLogSetNative = Void Function(ggml_log_callback, Pointer<Void>);
typedef _MtmdLogSetDart = void Function(ggml_log_callback, Pointer<Void>);
typedef _LlamaDartMtpInitNative =
    Pointer<llama_dart_mtp> Function(
      Pointer<llama_model>,
      Pointer<llama_context>,
      llama_context_params,
      Int32,
      Int32,
      Float,
      Bool,
    );
typedef _LlamaDartMtpInitDart =
    Pointer<llama_dart_mtp> Function(
      Pointer<llama_model>,
      Pointer<llama_context>,
      llama_context_params,
      int,
      int,
      double,
      bool,
    );
typedef _LlamaDartMtpFreeNative = Void Function(Pointer<llama_dart_mtp>);
typedef _LlamaDartMtpFreeDart = void Function(Pointer<llama_dart_mtp>);
typedef _LlamaDartMtpGetDraftContextNative =
    Pointer<llama_context> Function(Pointer<llama_dart_mtp>);
typedef _LlamaDartMtpGetDraftContextDart =
    Pointer<llama_context> Function(Pointer<llama_dart_mtp>);
typedef _LlamaDartMtpBeginNative =
    Bool Function(Pointer<llama_dart_mtp>, llama_seq_id, Pointer<Int32>, Int32);
typedef _LlamaDartMtpBeginDart =
    bool Function(Pointer<llama_dart_mtp>, int, Pointer<Int32>, int);
typedef _LlamaDartMtpProcessBatchNative =
    Bool Function(Pointer<llama_dart_mtp>, llama_batch);
typedef _LlamaDartMtpProcessBatchDart =
    bool Function(Pointer<llama_dart_mtp>, llama_batch);
typedef _LlamaDartMtpDraftNative =
    Int32 Function(
      Pointer<llama_dart_mtp>,
      llama_seq_id,
      llama_pos,
      llama_token,
      Pointer<Int32>,
      Int32,
      Int32,
      Pointer<Int32>,
      Int32,
    );
typedef _LlamaDartMtpDraftDart =
    int Function(
      Pointer<llama_dart_mtp>,
      int,
      int,
      int,
      Pointer<Int32>,
      int,
      int,
      Pointer<Int32>,
      int,
    );
typedef _LlamaDartMtpAcceptNative =
    Void Function(Pointer<llama_dart_mtp>, llama_seq_id, Uint16);
typedef _LlamaDartMtpAcceptDart =
    void Function(Pointer<llama_dart_mtp>, int, int);
typedef _LlamaDartSamplerSampleAndAcceptNNative =
    Int32 Function(
      Pointer<llama_sampler>,
      Pointer<llama_context>,
      Pointer<Int32>,
      Int32,
      Pointer<Int32>,
      Int32,
      Pointer<Int32>,
      Int32,
    );
typedef _LlamaDartSamplerSampleAndAcceptNDart =
    int Function(
      Pointer<llama_sampler>,
      Pointer<llama_context>,
      Pointer<Int32>,
      int,
      Pointer<Int32>,
      int,
      Pointer<Int32>,
      int,
    );

@Native<_LlamaDartMtpInitNative>(
  assetId: _llamadartWrapperAssetId,
  symbol: 'llama_dart_mtp_init',
)
external Pointer<llama_dart_mtp> _llamadartWrapperMtpInit(
  Pointer<llama_model> model,
  Pointer<llama_context> context,
  llama_context_params contextParams,
  int draftTokenMax,
  int draftTokenMin,
  double minProbability,
  bool backendSampling,
);

@Native<_LlamaDartMtpFreeNative>(
  assetId: _llamadartWrapperAssetId,
  symbol: 'llama_dart_mtp_free',
)
external void _llamadartWrapperMtpFree(Pointer<llama_dart_mtp> mtp);

@Native<_LlamaDartMtpGetDraftContextNative>(
  assetId: _llamadartWrapperAssetId,
  symbol: 'llama_dart_mtp_get_draft_context',
)
external Pointer<llama_context> _llamadartWrapperMtpGetDraftContext(
  Pointer<llama_dart_mtp> mtp,
);

@Native<_LlamaDartMtpBeginNative>(
  assetId: _llamadartWrapperAssetId,
  symbol: 'llama_dart_mtp_begin',
)
external bool _llamadartWrapperMtpBegin(
  Pointer<llama_dart_mtp> mtp,
  int seqId,
  Pointer<Int32> prompt,
  int promptCount,
);

@Native<_LlamaDartMtpProcessBatchNative>(
  assetId: _llamadartWrapperAssetId,
  symbol: 'llama_dart_mtp_process_batch',
)
external bool _llamadartWrapperMtpProcessBatch(
  Pointer<llama_dart_mtp> mtp,
  llama_batch batch,
);

@Native<_LlamaDartMtpDraftNative>(
  assetId: _llamadartWrapperAssetId,
  symbol: 'llama_dart_mtp_draft',
)
external int _llamadartWrapperMtpDraft(
  Pointer<llama_dart_mtp> mtp,
  int seqId,
  int nPast,
  int idLast,
  Pointer<Int32> prompt,
  int promptCount,
  int draftTokenMax,
  Pointer<Int32> outTokens,
  int outCapacity,
);

@Native<_LlamaDartMtpAcceptNative>(
  assetId: _llamadartWrapperAssetId,
  symbol: 'llama_dart_mtp_accept',
)
external void _llamadartWrapperMtpAccept(
  Pointer<llama_dart_mtp> mtp,
  int seqId,
  int acceptedCount,
);

@Native<_LlamaDartSamplerSampleAndAcceptNNative>(
  assetId: _llamadartWrapperAssetId,
  symbol: 'llama_dart_sampler_sample_and_accept_n',
)
external int _llamadartWrapperSamplerSampleAndAcceptN(
  Pointer<llama_sampler> sampler,
  Pointer<llama_context> context,
  Pointer<Int32> indexes,
  int indexCount,
  Pointer<Int32> draftTokens,
  int draftCount,
  Pointer<Int32> outTokens,
  int outCapacity,
);

final RegExp _linuxLlamadartProcMapsPattern = RegExp(
  r'/libllamadart\.so(?:\.\d+)?$',
);

class _LlamaCppMtpConfig {
  const _LlamaCppMtpConfig({
    required this.draftTokenMax,
    required this.draftTokenMin,
    required this.minProbability,
  });

  final int draftTokenMax;
  final int draftTokenMin;
  final double minProbability;
}

/// Service responsible for managing Llama.cpp models and contexts.
///
/// This service handles the direct interaction with the native Llama.cpp library,
/// including loading models, creating contexts, managing memory, and running inference.
class LlamaCppService {
  static const bool _androidVulkanAllowKqvOffload = bool.fromEnvironment(
    'LLAMADART_ANDROID_VULKAN_ALLOW_KQV',
    defaultValue: false,
  );
  static const bool _androidVulkanAllowOpOffload = bool.fromEnvironment(
    'LLAMADART_ANDROID_VULKAN_ALLOW_OP_OFFLOAD',
    defaultValue: false,
  );
  static const bool _androidVulkanAllowFlashAttn = bool.fromEnvironment(
    'LLAMADART_ANDROID_VULKAN_ALLOW_FLASH_ATTN',
    defaultValue: false,
  );
  static const bool _androidVulkanAllowMtp = bool.fromEnvironment(
    'LLAMADART_ANDROID_VULKAN_ALLOW_MTP',
    defaultValue: false,
  );

  static const int _maxStartupDiagnostics = 32;
  static const Map<String, int> _androidCpuVariantPriority = <String, int>{
    'android_armv9.2_2': 0,
    'android_armv9.2_1': 1,
    'android_armv9.0_1': 2,
    'android_armv8.6_1': 3,
    'android_armv8.2_2': 4,
    'android_armv8.2_1': 5,
    'android_armv8.0_1': 6,
  };

  int _nextHandle = 1;
  String? _backendModuleDirectory;
  final Set<String> _loadedBackendModules = <String>{};
  final Set<String> _failedBackendModules = <String>{};
  final Map<String, DynamicLibrary> _loadedBackendLibraries =
      <String, DynamicLibrary>{};
  final List<DynamicLibrary> _preloadedCoreLibraries = <DynamicLibrary>[];
  bool _backendLoadAllSymbolUnavailable = false;
  bool _backendLoadAllFromPathSymbolUnavailable = false;
  bool _backendLoadSymbolUnavailable = false;
  bool _backendRegistrySymbolUnavailable = false;
  bool _linuxCorePreloadAttempted = false;
  bool _linuxRuntimeDepsPrepared = false;
  String? _linuxPreparedLibraryDirectory;
  bool _ggmlFallbackLookupAttempted = false;
  String? _ggmlFallbackLookupSearchKey;
  _GgmlBackendLoadDart? _ggmlBackendLoadFallback;
  _GgmlBackendLoadAllDart? _ggmlBackendLoadAllFallback;
  _GgmlBackendLoadAllFromPathDart? _ggmlBackendLoadAllFromPathFallback;
  _GgmlBackendRegisterDart? _ggmlBackendRegisterFallback;
  _GgmlBackendRegCountDart? _ggmlBackendRegCountFallback;
  _GgmlBackendRegGetDart? _ggmlBackendRegGetFallback;
  _GgmlBackendRegNameDart? _ggmlBackendRegNameFallback;
  _GgmlBackendRegByNameDart? _ggmlBackendRegByNameFallback;
  _GgmlBackendRegDevCountDart? _ggmlBackendRegDevCountFallback;
  _GgmlBackendRegDevGetDart? _ggmlBackendRegDevGetFallback;
  _GgmlBackendDevCountDart? _ggmlBackendDevCountFallback;
  _GgmlBackendDevGetDart? _ggmlBackendDevGetFallback;
  _GgmlBackendDevNameDart? _ggmlBackendDevNameFallback;
  _GgmlBackendDevBackendRegDart? _ggmlBackendDevBackendRegFallback;
  _GgmlBackendDevByTypeDart? _ggmlBackendDevByTypeFallback;
  _GgmlBackendDevTypeDart? _ggmlBackendDevTypeFallback;
  _GgmlBackendDevGetPropsDart? _ggmlBackendDevGetPropsFallback;
  _GgmlBackendDevMemoryDart? _ggmlBackendDevMemoryFallback;
  bool _logLevelFallbackLookupAttempted = false;
  String? _logLevelFallbackLookupSearchKey;
  _LlamaDartSetLogLevelDart? _llamaDartSetLogLevelFallback;
  LlamaLogLevel _configuredLogLevel = LlamaLogLevel.warn;
  String _activeBackendName = 'CPU';
  int _activeResolvedGpuLayers = 0;
  bool _mtmdFallbackLookupAttempted = false;
  bool _mtmdPrimarySymbolsUnavailable = false;
  _MtmdApi? _mtmdFallbackApi;
  bool _mtpApiLookupAttempted = false;
  _MtpApi? _mtpApi;
  final List<String> _startupDiagnostics = <String>[];

  // --- Internal State ---
  final Map<int, _LlamaModelWrapper> _models = {};
  final Map<int, _LlamaContextWrapper> _contexts = {};
  final Map<int, int> _contextToModel = {};
  final Map<int, Pointer<llama_sampler>> _samplers = {};
  final Map<int, llama_batch> _batches = {};
  final Map<int, llama_context_params> _contextParams = {};
  final Map<int, Map<String, _LlamaLoraWrapper>> _loraAdapters = {};
  final Map<int, Map<String, double>> _activeLoras = {};
  final Map<int, String> _modelBackendNames = <int, String>{};
  final Map<int, int> _modelResolvedGpuLayers = <int, int>{};

  /// Refcount of in-flight `generate()` calls per context. A set would let the
  /// first completion clear the marker while another decode is still running.
  final Map<int, int> _generatingContexts = <int, int>{};

  // Mapping: modelHandle -> mtmdContextHandle
  final Map<int, int> _modelToMtmd = {};
  final Map<int, Pointer<mtmd_context>> _mtmdContexts = {};
  final Map<int, bool> _modelToMtmdUseGpu = {};

  int _getHandle() => _nextHandle++;

  /// Resolves the effective backend preference for model loading.
  ///
  /// Android keeps Vulkan bundled, but `auto` currently prefers CPU to avoid
  /// initializing optional GPU backends by default on devices with unstable
  /// Vulkan stacks.
  static GpuBackend resolvePreferredBackendForLoad(
    ModelParams modelParams, {
    bool isAndroid = false,
  }) {
    if (isAndroid && modelParams.preferredBackend == GpuBackend.auto) {
      return GpuBackend.cpu;
    }
    return modelParams.preferredBackend;
  }

  /// Resolves the effective GPU layer count for model loading.
  ///
  /// CPU backend preference always forces zero offloaded layers.
  static int resolveGpuLayersForLoad(
    ModelParams modelParams, {
    bool isAndroid = false,
  }) {
    return resolvePreferredBackendForLoad(modelParams, isAndroid: isAndroid) ==
            GpuBackend.cpu
        ? 0
        : modelParams.gpuLayers;
  }

  /// Returns whether context-time GPU offload should be disabled.
  ///
  /// When CPU mode is selected (or model load resolved to zero GPU layers),
  /// context-level offload knobs must also be disabled to prevent runtime
  /// GPU initialization during `llama_init_from_model(...)`.
  static bool shouldDisableContextGpuOffload(
    ModelParams modelParams, {
    int? resolvedGpuLayers,
  }) {
    final effectiveGpuLayers =
        resolvedGpuLayers ?? resolveGpuLayersForLoad(modelParams);
    return modelParams.preferredBackend == GpuBackend.cpu ||
        effectiveGpuLayers <= 0;
  }

  /// Returns whether Android Vulkan should use conservative context settings.
  ///
  /// Some Android Vulkan stacks can abort during decode scheduling when
  /// context-time KQV/op offload and flash-attention auto-selection stay fully
  /// enabled. We keep model layers offloaded but disable the more aggressive
  /// context compute knobs for stability.
  static bool shouldUseConservativeAndroidVulkanContextConfig(
    ModelParams modelParams, {
    int? resolvedGpuLayers,
    bool isAndroid = false,
  }) {
    if (!isAndroid) {
      return false;
    }

    final effectiveGpuLayers =
        resolvedGpuLayers ?? resolveGpuLayersForLoad(modelParams);
    return modelParams.preferredBackend == GpuBackend.vulkan &&
        effectiveGpuLayers > 0;
  }

  /// Returns whether Android should enable the experimental Vulkan fast path
  /// for the given local model file.
  static bool shouldEnableExperimentalAndroidVulkanAcceleration(
    String? modelPath, {
    bool isAndroid = false,
  }) {
    if (!isAndroid || modelPath == null || modelPath.isEmpty) {
      return false;
    }

    final normalized = path.basename(modelPath).toLowerCase();
    return normalized.contains('qwen3.5-0.8b') ||
        normalized.contains('qwen3.5-2b') ||
        normalized.contains('qwen3.5-4b') ||
        normalized.contains('qwen_qwen3.5-0.8b') ||
        normalized.contains('qwen_qwen3.5-2b') ||
        normalized.contains('qwen_qwen3.5-4b');
  }

  /// Returns whether Android Vulkan MTP should be rejected before generation.
  ///
  /// Upstream llama.cpp `draft-mtp` backend sampling currently can abort Android
  /// Vulkan processes with `vk::DeviceLostError`. Keep the public feature usable
  /// on CPU and other backends, but fail fast for this backend combination unless
  /// explicitly enabled for debugging/benchmarking.
  static bool shouldRejectAndroidVulkanMtp(
    String? backendName, {
    int? resolvedGpuLayers,
    bool isAndroid = false,
    bool allowMtp = false,
  }) {
    if (!isAndroid || allowMtp || (resolvedGpuLayers ?? 0) <= 0) {
      return false;
    }
    return (backendName ?? '').toLowerCase().contains('vulkan');
  }

  /// Resolves effective context batch parameters.
  ///
  /// Uses the shared non-FFI helper so native and WebGPU batch semantics stay
  /// in sync.
  static ({int batchSize, int microBatchSize}) resolveContextBatchSizes(
    ModelParams modelParams,
    int contextSize,
  ) {
    return resolveModelContextBatchSizes(modelParams, contextSize);
  }

  /// Resolves whether multimodal projector init should use GPU.
  ///
  /// This follows effective model-load configuration from model loading.
  static bool resolveMtmdUseGpuForLoad(
    ModelParams modelParams,
    int effectiveGpuLayers, {
    String? modelPath,
    bool isAndroid = false,
  }) {
    if (shouldForceCpuProjectorForAndroid(modelPath, isAndroid: isAndroid)) {
      return false;
    }

    return !shouldDisableContextGpuOffload(
      modelParams,
      resolvedGpuLayers: effectiveGpuLayers,
    );
  }

  /// Returns whether Android should keep mtmd projector work on CPU for the
  /// given model file.
  static bool shouldForceCpuProjectorForAndroid(
    String? modelPath, {
    bool isAndroid = false,
  }) {
    if (!isAndroid || modelPath == null || modelPath.isEmpty) {
      return false;
    }

    final normalized = path.basename(modelPath).toLowerCase();
    return normalized.contains('qwen3.5-0.8b') ||
        normalized.contains('qwen_qwen3.5-0.8b');
  }

  // --- Core Methods ---

  /// Sets the log level for the Llama.cpp library.
  void setLogLevel(LlamaLogLevel level) {
    _configuredLogLevel = level;
    _applyConfiguredLogLevel();
  }

  void _applyConfiguredLogLevel() {
    var applied = false;
    try {
      llama_dart_set_log_level(_configuredLogLevel.index);
      applied = true;
    } on ArgumentError {
      // Continue with explicit fallback lookup below.
    }

    // Apply via explicit wrapper lookup as well. On Windows split bundles the
    // primary @DefaultAsset can resolve to a different loaded copy than the
    // runtime backend modules, so applying to both keeps log-level state in
    // sync across module-loading layouts.
    _resolveLogLevelFallbackFunction();
    final fallback = _llamaDartSetLogLevelFallback;
    if (fallback != null) {
      try {
        fallback(_configuredLogLevel.index);
        applied = true;
      } catch (_) {
        // Ignore fallback invocation errors and preserve existing behavior.
      }
    }

    if (!applied) {
      // No applicable symbol found for this runtime layout.
    }

    // mtmd/clip uses its own logger callback chain; mirror llama logger so
    // multimodal projector logs honor the same configured native log level.
    _syncMtmdLogCallbackToLlamaLogger();
  }

  void _syncMtmdLogCallbackToLlamaLogger() {
    final logCallbackPtr = malloc<ggml_log_callback>();
    final userDataPtr = malloc<Pointer<Void>>();

    try {
      try {
        llama_log_get(logCallbackPtr, userDataPtr);
      } on ArgumentError {
        return;
      }

      final callback = logCallbackPtr.value;
      final userData = userDataPtr.value;
      if (callback == nullptr) {
        return;
      }

      var applied = false;
      if (!_mtmdPrimarySymbolsUnavailable) {
        try {
          mtmd_log_set(callback, userData);
          mtmd_helper_log_set(callback, userData);
          applied = true;
        } on ArgumentError {
          _mtmdPrimarySymbolsUnavailable = true;
        }
      }

      if (!applied) {
        final fallback = _resolveMtmdFallbackApi();
        if (fallback != null) {
          fallback.logSet?.call(callback, userData);
          fallback.helperLogSet?.call(callback, userData);
        }
      }
    } finally {
      malloc.free(logCallbackPtr);
      malloc.free(userDataPtr);
    }
  }

  /// Initializes the Llama.cpp backend.
  ///
  /// This must be called before loading any models.
  void initializeBackend() {
    _prepareLinuxRuntimeDependenciesBeforeBinding();
    _preloadLinuxCoreLibrariesForSonameResolution();
    _backendModuleDirectory = resolveBackendModuleDirectory();
    if (_backendModuleDirectory == null && Platform.isLinux) {
      _backendModuleDirectory =
          _linuxPreparedLibraryDirectory ??
          _resolveLinuxPrimaryLibraryDirectory();
    }
    _applyConfiguredLogLevel();
    llama_backend_init();
    _refreshBackendModuleDirectoryAfterPrimaryLoad();
    _applyConfiguredLogLevel();

    if ((Platform.isMacOS || Platform.isIOS) &&
        _backendModuleDirectory == null) {
      return;
    }

    // Startup path should remain CPU-safe so reading backend options does not
    // initialize optional GPU backends.
    if (_backendModuleDirectory != null) {
      _tryLoadBackendModuleIfBundled('cpu');
    } else {
      _tryLoadBackendModule('cpu');
    }

    if (_ggmlBackendRegCount() == 0) {
      // Fallback path: attempt to load CPU backend by filename resolution.
      _tryLoadBackendModule('cpu');
    }
  }

  void _preloadLinuxCoreLibrariesForSonameResolution() {
    if (!Platform.isLinux || _linuxCorePreloadAttempted) {
      return;
    }

    _linuxCorePreloadAttempted = true;

    // Linux split bundles expose versioned SONAMEs (e.g. libllama.so.0).
    // Preloading dependency libraries through native-asset URIs ensures their
    // SONAMEs are already registered before @Native resolves libllamadart.
    final moduleDir = _resolveLinuxPrimaryLibraryDirectory();

    final preloadCandidates = <List<String>>[
      <String>[
        'package:llamadart/ggml-base',
        if (moduleDir != null) path.join(moduleDir, 'libggml-base.so.0'),
        if (moduleDir != null) path.join(moduleDir, 'libggml-base.so'),
      ],
      <String>[
        'package:llamadart/ggml',
        if (moduleDir != null) path.join(moduleDir, 'libggml.so.0'),
        if (moduleDir != null) path.join(moduleDir, 'libggml.so'),
      ],
      <String>[
        'package:llamadart/llama',
        if (moduleDir != null) path.join(moduleDir, 'libllama.so.0'),
        if (moduleDir != null) path.join(moduleDir, 'libllama.so'),
      ],
    ];

    for (final candidates in preloadCandidates) {
      var loaded = false;
      Object? lastError;
      String? lastCandidate;
      for (final candidate in candidates) {
        try {
          _preloadedCoreLibraries.add(DynamicLibrary.open(candidate));
          loaded = true;
          break;
        } catch (error) {
          lastError = error;
          lastCandidate = candidate;
          continue;
        }
      }

      if (!loaded && lastError != null && lastCandidate != null) {
        _recordStartupDiagnostic(
          'Failed to preload Linux core library candidates '
          '`${candidates.join(', ')}`; last error from `$lastCandidate`: '
          '$lastError',
        );
      }
    }
  }

  void _prepareLinuxRuntimeDependenciesBeforeBinding() {
    if (!Platform.isLinux || _linuxRuntimeDepsPrepared) {
      return;
    }
    _linuxRuntimeDepsPrepared = true;

    final targetDir = _resolveLinuxPrimaryLibraryDirectory();
    if (targetDir == null) {
      return;
    }

    final sourceDirectories = _linuxDependencySourceDirectories(targetDir);
    const coreLibraries = <String>[
      'libggml-base.so',
      'libggml.so',
      'libllama.so',
    ];

    for (final libraryFileName in coreLibraries) {
      copyMissingLinuxLibrary(
        targetDirectory: targetDir,
        sourceDirectories: sourceDirectories,
        fileName: libraryFileName,
        onDiagnostic: _recordStartupDiagnostic,
      );
      ensureLinuxSonameAlias(
        directory: targetDir,
        baseFileName: libraryFileName,
        onDiagnostic: _recordStartupDiagnostic,
      );
    }

    const backendModuleLibraries = <String>[
      'libggml-cpu.so',
      'libggml-vulkan.so',
      'libggml-opencl.so',
      'libggml-cuda.so',
      'libggml-blas.so',
      'libggml-hip.so',
    ];

    for (final libraryFileName in backendModuleLibraries) {
      copyMissingLinuxLibrary(
        targetDirectory: targetDir,
        sourceDirectories: sourceDirectories,
        fileName: libraryFileName,
        onDiagnostic: _recordStartupDiagnostic,
      );
      ensureLinuxSonameAlias(
        directory: targetDir,
        baseFileName: libraryFileName,
        onDiagnostic: _recordStartupDiagnostic,
      );
    }

    _linuxPreparedLibraryDirectory = targetDir;
  }

  String? _resolveLinuxPrimaryLibraryDirectory() {
    return resolveLinuxPrimaryLibraryDirectory(
      resolvedExecutablePath: Platform.resolvedExecutable,
      currentDirectoryPath: Directory.current.path,
      environment: Platform.environment,
    );
  }

  void _refreshBackendModuleDirectoryAfterPrimaryLoad() {
    if (_backendModuleDirectory != null) {
      return;
    }

    if (!Platform.isAndroid && !Platform.isLinux) {
      return;
    }

    _backendModuleDirectory = resolveBackendModuleDirectory();
    if (_backendModuleDirectory == null && Platform.isLinux) {
      _backendModuleDirectory =
          _linuxPreparedLibraryDirectory ??
          _resolveLinuxPrimaryLibraryDirectory();
    }
  }

  List<String> _linuxDependencySourceDirectories(String targetDirectory) {
    final dirs = <String>{targetDirectory};
    final bundleNames = _linuxBundleNamesForCurrentAbi();
    if (bundleNames.isEmpty) {
      return dirs.toList(growable: false);
    }

    final cacheRoot = Directory(
      path.join(
        Directory.current.path,
        '.dart_tool',
        'llamadart',
        'native_bundles',
      ),
    );
    if (!cacheRoot.existsSync()) {
      return dirs.toList(growable: false);
    }

    final tagDirectories = cacheRoot.listSync().whereType<Directory>().toList()
      ..sort((a, b) => path.basename(b.path).compareTo(path.basename(a.path)));

    for (final tagDir in tagDirectories) {
      for (final bundleName in bundleNames) {
        final extractedDir = Directory(
          path.join(tagDir.path, bundleName, 'extracted'),
        );
        if (extractedDir.existsSync()) {
          dirs.add(extractedDir.path);
        }
      }
    }

    return dirs.toList(growable: false);
  }

  List<String> _linuxBundleNamesForCurrentAbi() {
    switch (Abi.current()) {
      case Abi.linuxArm64:
        return const <String>['linux-arm64'];
      case Abi.linuxX64:
        return const <String>['linux-x64'];
      default:
        return const <String>[];
    }
  }

  /// Copies a missing Linux runtime dependency into the target directory.
  ///
  /// Returns `true` when the dependency already exists or is copied
  /// successfully. When a copy attempt fails, [onDiagnostic] receives a
  /// best-effort diagnostic message.
  static bool copyMissingLinuxLibrary({
    required String targetDirectory,
    required List<String> sourceDirectories,
    required String fileName,
    void Function(String message)? onDiagnostic,
  }) {
    final targetPath = path.join(targetDirectory, fileName);
    if (File(targetPath).existsSync()) {
      return true;
    }

    for (final sourceDirectory in sourceDirectories) {
      final sourcePath = path.join(sourceDirectory, fileName);
      final sourceFile = File(sourcePath);
      if (!sourceFile.existsSync()) {
        continue;
      }
      try {
        sourceFile.copySync(targetPath);
        return true;
      } catch (error) {
        onDiagnostic?.call(
          'Failed to copy Linux runtime dependency `$fileName` from '
          '`$sourcePath` to `$targetPath`: $error',
        );
        continue;
      }
    }

    return false;
  }

  /// Ensures a Linux SONAME alias file exists for [baseFileName].
  ///
  /// Returns `true` when the alias already exists or is created successfully.
  /// When both symlink creation and fallback copying fail, [onDiagnostic]
  /// receives a best-effort diagnostic message.
  static bool ensureLinuxSonameAlias({
    required String directory,
    required String baseFileName,
    void Function(String message)? onDiagnostic,
  }) {
    final sourcePath = path.join(directory, baseFileName);
    final sourceFile = File(sourcePath);
    if (!sourceFile.existsSync()) {
      return false;
    }

    final aliasPath = '$sourcePath.0';
    final aliasFile = File(aliasPath);
    if (aliasFile.existsSync()) {
      return true;
    }

    Object? linkError;
    try {
      Link(aliasPath).createSync(baseFileName);
      return true;
    } catch (error) {
      linkError = error;
    }

    try {
      sourceFile.copySync(aliasPath);
      return true;
    } catch (copyError) {
      onDiagnostic?.call(
        'Failed to create or copy Linux SONAME alias `$aliasPath` for '
        '`$sourcePath`: link error=$linkError; copy error=$copyError',
      );
      return false;
    }
  }

  bool _tryLoadAllBackendsBestEffort() {
    if (_backendLoadAllSymbolUnavailable) {
      return false;
    }

    try {
      ggml_backend_load_all();
      return true;
    } on ArgumentError {
      _resolveGgmlFallbackFunctions();
      final fallback = _ggmlBackendLoadAllFallback;
      if (fallback != null) {
        fallback();
        return true;
      }

      // Some split bundles don't expose this symbol on the primary FFI asset.
      // Continue with explicit backend-module loading fallback.
      _backendLoadAllSymbolUnavailable = true;
      return false;
    }
  }

  bool _tryLoadAllBackendsFromPathBestEffort(String directoryPath) {
    if (_backendLoadAllFromPathSymbolUnavailable) {
      return false;
    }

    final directoryPathPtr = directoryPath.toNativeUtf8();
    try {
      try {
        ggml_backend_load_all_from_path(directoryPathPtr.cast());
        return true;
      } on ArgumentError {
        _resolveGgmlFallbackFunctions();
        final fallback = _ggmlBackendLoadAllFromPathFallback;
        if (fallback != null) {
          fallback(directoryPathPtr.cast());
          return true;
        }

        _backendLoadAllFromPathSymbolUnavailable = true;
        return false;
      }
    } finally {
      malloc.free(directoryPathPtr);
    }
  }

  /// Resolves the native backend module directory for dynamic backend loading.
  ///
  /// On Android/Linux we inspect `/proc/self/maps` to find the loaded
  /// `libllamadart.so` location, then load backend modules from that directory.
  /// Returns `null` when the path cannot be resolved.
  static String? resolveBackendModuleDirectory() {
    if (Platform.isWindows) {
      return resolveWindowsBackendModuleDirectory(
        resolvedExecutablePath: Platform.resolvedExecutable,
        currentDirectoryPath: Directory.current.path,
        environment: Platform.environment,
      );
    }

    if (!Platform.isAndroid && !Platform.isLinux) {
      return null;
    }

    try {
      final mapsFile = File('/proc/self/maps');
      if (!mapsFile.existsSync()) {
        return null;
      }

      final mapsContent = mapsFile.readAsStringSync();
      return parseBackendModuleDirectoryFromProcMaps(mapsContent);
    } catch (_) {
      return null;
    }
  }

  /// Returns recent best-effort startup diagnostics collected during setup.
  List<String> getStartupDiagnostics() {
    return List<String>.unmodifiable(_startupDiagnostics);
  }

  /// Returns whether a backend score allows a dynamically loaded module.
  ///
  /// Native runtimes expose `ggml_backend_score` to reject unsupported backend
  /// variants on the current system. A `null` score means the optional symbol
  /// is unavailable, so the candidate remains eligible for compatibility.
  static bool isBackendCandidateScoreSupported(int? score) {
    return score == null || score > 0;
  }

  /// Returns the first candidate whose probed score indicates support.
  ///
  /// Candidates with a missing score symbol (`null`) remain eligible so older
  /// backends that do not export `ggml_backend_score` still work.
  static T? selectFirstSupportedBackendCandidate<T>(
    Iterable<T> candidates, {
    required int? Function(T candidate) scoreForCandidate,
  }) {
    for (final candidate in candidates) {
      final score = scoreForCandidate(candidate);
      if (isBackendCandidateScoreSupported(score)) {
        return candidate;
      }
    }

    return null;
  }

  /// Describes why a backend asset candidate was skipped.
  static String describeSkippedBackendAssetCandidate(
    String assetUri,
    int score,
  ) {
    return 'Skipped backend asset `$assetUri` because '
        '`ggml_backend_score` returned $score.';
  }

  /// Describes which backend asset candidate was loaded.
  static String describeLoadedBackendAssetCandidate(
    String assetUri,
    int? score,
  ) {
    if (score == null) {
      return 'Loaded backend asset `$assetUri` without '
          '`ggml_backend_score`.';
    }
    return 'Loaded backend asset `$assetUri` with '
        '`ggml_backend_score`=$score.';
  }

  void _recordStartupDiagnostic(String message) {
    if (message.isEmpty) {
      return;
    }
    if (_startupDiagnostics.length >= _maxStartupDiagnostics) {
      _startupDiagnostics.removeAt(0);
    }
    _startupDiagnostics.add(message);
  }

  /// Resolves Windows backend-module directory for dynamic backend loading.
  ///
  /// Resolution order:
  /// 1. Explicit environment override (`LLAMADART_NATIVE_LIB_DIR` or
  ///    `LLAMADART_BACKEND_MODULE_DIR`)
  /// 2. Directory of resolved executable (if it looks like a native bundle)
  /// 3. Current working directory (if it looks like a native bundle)
  /// 4. Hook cache under `.dart_tool/llamadart/native_bundles`, including
  ///    default, custom GitHub, and local archive cache namespaces.
  /// 5. Directory of resolved executable (best-effort fallback)
  static String? resolveWindowsBackendModuleDirectory({
    required String resolvedExecutablePath,
    required String currentDirectoryPath,
    required Map<String, String> environment,
  }) {
    final overrideCandidates = <String>[
      environment['LLAMADART_NATIVE_LIB_DIR'] ?? '',
      environment['LLAMADART_BACKEND_MODULE_DIR'] ?? '',
    ];
    for (final override in overrideCandidates) {
      if (override.isEmpty) {
        continue;
      }
      if (_containsWindowsNativeModules(override)) {
        return override;
      }
    }

    final executableDir = path.dirname(resolvedExecutablePath);
    if (_containsWindowsNativeModules(executableDir)) {
      return executableDir;
    }

    if (_containsWindowsNativeModules(currentDirectoryPath)) {
      return currentDirectoryPath;
    }

    final dartToolLibDir = _findDartToolLibDirectory(currentDirectoryPath);
    if (dartToolLibDir != null) {
      return dartToolLibDir;
    }

    final preferredBundle = _preferredWindowsBundleName();
    final hookCacheDir = _findHookCacheWindowsBundleDirectory(
      currentDirectoryPath,
      preferredBundleName: preferredBundle,
    );
    if (hookCacheDir != null) {
      return hookCacheDir;
    }

    return executableDir;
  }

  /// Resolves the primary Linux native-library directory.
  ///
  /// Resolution order:
  /// 1. Explicit environment override (`LLAMADART_NATIVE_LIB_DIR` or
  ///    `LLAMADART_BACKEND_MODULE_DIR`)
  /// 2. `.dart_tool/lib`
  /// 3. Executable-adjacent `lib/` directory
  /// 4. Directory of resolved executable
  /// 5. Current working directory `lib/`
  /// 6. Current working directory
  static String? resolveLinuxPrimaryLibraryDirectory({
    required String resolvedExecutablePath,
    required String currentDirectoryPath,
    required Map<String, String> environment,
  }) {
    final overrideCandidates = <String>[
      environment['LLAMADART_NATIVE_LIB_DIR'] ?? '',
      environment['LLAMADART_BACKEND_MODULE_DIR'] ?? '',
    ];
    for (final override in overrideCandidates) {
      if (override.isEmpty) {
        continue;
      }
      if (_containsLinuxPrimaryLibrary(override)) {
        return override;
      }
    }

    final executableDir = path.dirname(resolvedExecutablePath);
    final candidates = <String>[
      path.join(currentDirectoryPath, '.dart_tool', 'lib'),
      path.join(executableDir, 'lib'),
      executableDir,
      path.join(currentDirectoryPath, 'lib'),
      currentDirectoryPath,
    ];

    final seen = <String>{};
    for (final candidate in candidates) {
      final normalized = path.normalize(candidate);
      if (!seen.add(normalized)) {
        continue;
      }
      if (_containsLinuxPrimaryLibrary(normalized)) {
        return normalized;
      }
    }

    return null;
  }

  static String? _preferredWindowsBundleName() {
    switch (Abi.current()) {
      case Abi.windowsX64:
        return 'windows-x64';
      case Abi.windowsArm64:
        return 'windows-arm64';
      default:
        return null;
    }
  }

  static String? _findHookCacheWindowsBundleDirectory(
    String currentDirectoryPath, {
    String? preferredBundleName,
  }) {
    var cursor = Directory(currentDirectoryPath).absolute;
    while (true) {
      final cacheRoot = Directory(
        path.join(cursor.path, '.dart_tool', 'llamadart', 'native_bundles'),
      );
      if (cacheRoot.existsSync()) {
        final found = _selectWindowsBundleDirectoryFromCache(
          cacheRoot.path,
          preferredBundleName: preferredBundleName,
        );
        if (found != null) {
          return found;
        }
      }

      final parent = cursor.parent;
      if (parent.path == cursor.path) {
        break;
      }
      cursor = parent;
    }

    return null;
  }

  static String? _selectWindowsBundleDirectoryFromCache(
    String cacheRootPath, {
    String? preferredBundleName,
  }) {
    final bundleDirs = _windowsBundleDirectoriesFromCache(
      cacheRootPath,
      preferredBundleName: preferredBundleName,
    );

    for (final bundleDir in bundleDirs) {
      final extractedDir = path.join(bundleDir.path, 'extracted');
      if (_containsWindowsNativeModules(extractedDir)) {
        return extractedDir;
      }
      if (_containsWindowsNativeModules(bundleDir.path)) {
        return bundleDir.path;
      }
    }

    return null;
  }

  static List<Directory> _windowsBundleDirectoriesFromCache(
    String cacheRootPath, {
    String? preferredBundleName,
  }) {
    final cacheRoot = Directory(cacheRootPath);
    final tagDirectories = <Directory>[];

    void addDefaultTags(Directory root) {
      for (final child in _listChildDirectories(root)) {
        final name = path.basename(child.path);
        if (name == 'github' || name == 'local') {
          continue;
        }
        tagDirectories.add(child);
      }
    }

    void addGitHubTags(Directory root) {
      final githubRoot = Directory(path.join(root.path, 'github'));
      for (final ownerDir in _listChildDirectories(githubRoot)) {
        for (final repoDir in _listChildDirectories(ownerDir)) {
          tagDirectories.addAll(_listChildDirectories(repoDir));
        }
      }
    }

    void addLocalTags(Directory root) {
      final localRoot = Directory(path.join(root.path, 'local'));
      for (final digestDir in _listChildDirectories(localRoot)) {
        tagDirectories.addAll(_listChildDirectories(digestDir));
      }
    }

    addDefaultTags(cacheRoot);
    addGitHubTags(cacheRoot);
    addLocalTags(cacheRoot);

    tagDirectories.sort(
      (a, b) => path.basename(b.path).compareTo(path.basename(a.path)),
    );

    final candidates = <Directory>[];
    for (final tagDirectory in tagDirectories) {
      if (preferredBundleName != null) {
        final preferred = Directory(
          path.join(tagDirectory.path, preferredBundleName),
        );
        if (preferred.existsSync()) {
          candidates.add(preferred);
        }
      }

      for (final directory in _listChildDirectories(tagDirectory)) {
        if (path.basename(directory.path).startsWith('windows-')) {
          candidates.add(directory);
        }
      }
    }

    final seen = <String>{};
    return candidates
        .where((directory) {
          return seen.add(path.normalize(directory.path));
        })
        .toList(growable: false);
  }

  static List<Directory> _listChildDirectories(Directory directory) {
    try {
      return directory.listSync().whereType<Directory>().toList(
        growable: false,
      );
    } catch (_) {
      return const <Directory>[];
    }
  }

  static bool _containsWindowsNativeModules(String directoryPath) {
    try {
      final directory = Directory(directoryPath);
      if (!directory.existsSync()) {
        return false;
      }

      final fileNames = directory
          .listSync()
          .whereType<File>()
          .map((file) => path.basename(file.path).toLowerCase())
          .toSet();

      final hasLlama = fileNames.any(
        (name) => RegExp(r'^llama(?:-[^.\\/]+)*\.dll$').hasMatch(name),
      );
      final hasGgml = fileNames.any(
        (name) => RegExp(r'^ggml(?:-[^.\\/]+)*\.dll$').hasMatch(name),
      );
      final hasCpuBackend = fileNames.any(
        (name) => RegExp(r'^ggml-cpu(?:-[^.\\/]+)*\.dll$').hasMatch(name),
      );
      return hasLlama && hasGgml && hasCpuBackend;
    } catch (_) {
      return false;
    }
  }

  static bool _containsLinuxPrimaryLibrary(String directoryPath) {
    try {
      final directory = Directory(directoryPath);
      if (!directory.existsSync()) {
        return false;
      }

      return File(path.join(directoryPath, 'libllamadart.so')).existsSync() ||
          File(path.join(directoryPath, 'libllamadart.so.0')).existsSync();
    } catch (_) {
      return false;
    }
  }

  static String? _findDartToolLibDirectory(String currentDirectoryPath) {
    var cursor = Directory(currentDirectoryPath).absolute;
    while (true) {
      final dartToolLib = path.join(cursor.path, '.dart_tool', 'lib');
      if (_containsWindowsNativeModules(dartToolLib)) {
        return dartToolLib;
      }

      final parent = cursor.parent;
      if (parent.path == cursor.path) {
        break;
      }
      cursor = parent;
    }

    return null;
  }

  /// Parses `/proc/self/maps` content and returns the module directory.
  ///
  /// This is exposed for testability.
  static String? parseBackendModuleDirectoryFromProcMaps(String mapsContent) {
    for (final rawLine in mapsContent.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty) {
        continue;
      }

      final slashIndex = line.indexOf('/');
      if (slashIndex < 0) {
        continue;
      }

      final mappedPath = line.substring(slashIndex).trim();
      final normalizedPath = mappedPath.endsWith(' (deleted)')
          ? mappedPath.substring(0, mappedPath.length - ' (deleted)'.length)
          : mappedPath;

      if (!_linuxLlamadartProcMapsPattern.hasMatch(normalizedPath)) {
        continue;
      }

      return path.dirname(normalizedPath);
    }

    return null;
  }

  /// Loads a model from the specified [modelPath].
  ///
  /// Returns a handle to the loaded model.
  /// Throws an [Exception] if the file does not exist or fails to load.
  int loadModel(String modelPath, ModelParams modelParams) {
    final modelFile = File(modelPath);
    if (!modelFile.existsSync()) {
      throw Exception("File not found: $modelPath");
    }
    final modelFileSize = modelFile.lengthSync();
    if (modelFileSize <= 0) {
      throw Exception("Model file is empty: $modelPath");
    }
    if (!_looksLikeGguf(modelFile)) {
      throw Exception(
        "Model file does not appear to be GGUF: $modelPath. "
        "Please verify the download completed correctly.",
      );
    }

    _applyConfiguredLogLevel();
    final effectiveBackend = resolvePreferredBackendForLoad(
      modelParams,
      isAndroid: Platform.isAndroid,
    );

    _prepareBackendsForModelLoad(effectiveBackend);

    final modelPathPtr = modelPath.toNativeUtf8();
    final mparams = llama_model_default_params();
    var preferredDevices = _createPreferredDeviceList(effectiveBackend);
    var gpuLayers = resolveGpuLayersForLoad(
      modelParams,
      isAndroid: Platform.isAndroid,
    );
    var forcedCpuFallback = false;

    final explicitGpuBackend =
        effectiveBackend != GpuBackend.auto &&
        effectiveBackend != GpuBackend.cpu;
    if (explicitGpuBackend &&
        preferredDevices == null &&
        _shouldForceCpuFallbackForMissingPreferredDevices(effectiveBackend)) {
      // Honor explicit backend intent: if requested GPU backend is unavailable,
      // fall back to CPU instead of letting another GPU backend auto-select.
      preferredDevices = _createPreferredDeviceList(GpuBackend.cpu);
      gpuLayers = 0;
      forcedCpuFallback = true;
    }
    final mtmdUseGpu = resolveMtmdUseGpuForLoad(
      modelParams,
      gpuLayers,
      modelPath: modelPath,
      isAndroid: Platform.isAndroid,
    );

    mparams.n_gpu_layers = gpuLayers;
    mparams.split_modeAsInt = modelParams.splitMode.llamaCppValue;
    mparams.main_gpu = modelParams.mainGpu;
    applyModelParams(mparams, modelParams);
    if (preferredDevices != null) {
      mparams.devices = preferredDevices;
    }

    Pointer<llama_model> modelPtr = nullptr;
    try {
      modelPtr = llama_model_load_from_file(modelPathPtr.cast(), mparams);
    } finally {
      malloc.free(modelPathPtr);
      if (preferredDevices != null) {
        malloc.free(preferredDevices);
      }
    }

    if (modelPtr == nullptr) {
      final diagnostics = _backendDiagnostics();
      throw Exception(
        "Failed to load model (size=$modelFileSize bytes, "
        "diagnostics=$diagnostics)",
      );
    }

    final handle = _getHandle();
    _models[handle] = _LlamaModelWrapper(modelPtr, sourcePath: modelPath);
    _loraAdapters[handle] = {};
    _modelToMtmdUseGpu[handle] = mtmdUseGpu;
    final resolvedBackend = _resolveBackendNameForLoad(
      requestedBackend: modelParams.preferredBackend,
      resolvedGpuLayers: gpuLayers,
      forcedCpuFallback: forcedCpuFallback,
    );
    _modelBackendNames[handle] = resolvedBackend;
    _modelResolvedGpuLayers[handle] = gpuLayers;
    _activeBackendName = resolvedBackend;
    _activeResolvedGpuLayers = gpuLayers;

    return handle;
  }

  String _resolveBackendNameForLoad({
    required GpuBackend requestedBackend,
    required int resolvedGpuLayers,
    required bool forcedCpuFallback,
  }) {
    if (forcedCpuFallback || resolvedGpuLayers <= 0) {
      return _backendDisplayName('cpu');
    }

    final backendInfo = getBackendInfo().join(', ');

    switch (requestedBackend) {
      case GpuBackend.auto:
        return _resolveAutoBackendName(backendInfo) ??
            _backendDisplayName('cpu');
      case GpuBackend.cpu:
        return _backendDisplayName('cpu');
      case GpuBackend.vulkan:
        return _resolveExplicitBackendName(GpuBackend.vulkan, backendInfo);
      case GpuBackend.metal:
        return _resolveExplicitBackendName(GpuBackend.metal, backendInfo);
      case GpuBackend.cuda:
        return _resolveExplicitBackendName(GpuBackend.cuda, backendInfo);
      case GpuBackend.blas:
        return _resolveExplicitBackendName(GpuBackend.blas, backendInfo);
      case GpuBackend.opencl:
        return _resolveExplicitBackendName(GpuBackend.opencl, backendInfo);
      case GpuBackend.hip:
        return _resolveExplicitBackendName(GpuBackend.hip, backendInfo);
    }
  }

  String _resolveExplicitBackendName(GpuBackend backend, String backendInfo) {
    if (_backendInfoContainsBackendMarker(backendInfo, backend)) {
      return _backendDisplayName(backend.name);
    }
    return _backendDisplayName('cpu');
  }

  String? _resolveAutoBackendName(String backendInfo) {
    const preferredOrder = <GpuBackend>[
      GpuBackend.metal,
      GpuBackend.cuda,
      GpuBackend.hip,
      GpuBackend.vulkan,
      GpuBackend.opencl,
      GpuBackend.blas,
    ];

    for (final backend in preferredOrder) {
      if (_backendInfoContainsBackendMarker(backendInfo, backend)) {
        return _backendDisplayName(backend.name);
      }
    }

    return null;
  }

  bool _shouldForceCpuFallbackForMissingPreferredDevices(
    GpuBackend requestedBackend,
  ) {
    final backendModuleDirectory = _backendModuleDirectory;
    if (backendModuleDirectory == null) {
      // Consolidated runtimes (notably Apple) do not expose per-backend
      // dynamic modules. Missing preferred-device pointers here does not
      // reliably mean GPU is unavailable.
      return false;
    }

    return !_isBackendModuleBundled(requestedBackend.name);
  }

  static bool _backendInfoContainsBackendMarker(
    String value,
    GpuBackend backend,
  ) {
    final lower = value.toLowerCase();
    switch (backend) {
      case GpuBackend.metal:
        return lower.contains('metal') || lower.contains('mtl');
      case GpuBackend.vulkan:
        return lower.contains('vulkan');
      case GpuBackend.opencl:
        return lower.contains('opencl');
      case GpuBackend.hip:
        return lower.contains('hip');
      case GpuBackend.cuda:
        return lower.contains('cuda');
      case GpuBackend.blas:
        return lower.contains('blas');
      case GpuBackend.cpu:
        return lower.contains('cpu') || lower.contains('llvm');
      case GpuBackend.auto:
        return false;
    }
  }

  void _prepareBackendsForModelLoad(GpuBackend preferredBackend) {
    // Apple bundles are consolidated into a single native library and do not
    // ship separate ggml backend modules.
    if ((Platform.isMacOS || Platform.isIOS) &&
        _backendModuleDirectory == null) {
      return;
    }
    final backendModuleDirectory = _backendModuleDirectory;

    switch (preferredBackend) {
      case GpuBackend.auto:
        final loadedAll = backendModuleDirectory == null
            ? _tryLoadAllBackendsBestEffort()
            : _tryLoadAllBackendsFromPathBestEffort(backendModuleDirectory);

        if (!loadedAll) {
          // Fallback when load-all symbols are unavailable.
          _tryLoadBackendModuleIfBundled('cpu');
        }

        if (Platform.isAndroid || Platform.isLinux || Platform.isWindows) {
          _tryLoadBackendModuleIfBundled('vulkan');
        }
        if (Platform.isLinux || Platform.isWindows) {
          _tryLoadBackendModuleIfBundled('blas');
          _tryLoadBackendModuleIfBundled('cuda');
        }
        if (Platform.isLinux) {
          _tryLoadBackendModuleIfBundled('hip');
        }
        return;
      case GpuBackend.cpu:
        // Explicit CPU mode must not initialize optional GPU backends.
        _tryLoadBackendModuleIfBundled('cpu');
        return;
      case GpuBackend.vulkan:
        _tryLoadBackendModuleIfBundled('cpu');
        _tryLoadBackendModuleIfBundled('vulkan');
        return;
      case GpuBackend.metal:
        _tryLoadBackendModuleIfBundled('cpu');
        _tryLoadBackendModuleIfBundled('metal');
        return;
      case GpuBackend.cuda:
        _tryLoadBackendModuleIfBundled('cpu');
        _tryLoadBackendModuleIfBundled('cuda');
        return;
      case GpuBackend.blas:
        _tryLoadBackendModuleIfBundled('cpu');
        _tryLoadBackendModuleIfBundled('blas');
        return;
      case GpuBackend.opencl:
        _tryLoadBackendModuleIfBundled('cpu');
        _tryLoadBackendModuleIfBundled('opencl');
        return;
      case GpuBackend.hip:
        _tryLoadBackendModuleIfBundled('cpu');
        _tryLoadBackendModuleIfBundled('hip');
        return;
    }
  }

  void _tryLoadBackendModuleIfBundled(String backend) {
    if (_backendModuleDirectory != null && !_isBackendModuleBundled(backend)) {
      return;
    }
    _tryLoadBackendModule(backend);
  }

  bool _isBackendModuleBundled(String backend) {
    final backendModuleDirectory = _backendModuleDirectory;
    if (backendModuleDirectory == null) {
      return true;
    }

    final fileNameCandidates = _backendLibraryCandidateFileNames(backend);
    if (fileNameCandidates.isEmpty) {
      return false;
    }

    for (final fileName in fileNameCandidates) {
      final fullPath = path.join(backendModuleDirectory, fileName);
      if (File(fullPath).existsSync()) {
        return true;
      }
    }
    return false;
  }

  bool _tryLoadBackendModule(String backend) {
    if (_backendLoadSymbolUnavailable) {
      return false;
    }

    if (_loadedBackendModules.contains(backend)) {
      return true;
    }
    if (_failedBackendModules.contains(backend)) {
      return false;
    }

    final fileNameCandidates = _backendLibraryCandidateFileNames(backend);
    final candidates = <String>{};
    final backendModuleDirectory = _backendModuleDirectory;
    if (backendModuleDirectory != null) {
      for (final fileName in fileNameCandidates) {
        candidates.add(path.join(backendModuleDirectory, fileName));
      }
    } else {
      // No resolved module directory: rely on platform search paths.
      candidates.addAll(fileNameCandidates);
    }

    for (final candidate in candidates) {
      if (path.isAbsolute(candidate) && !File(candidate).existsSync()) {
        continue;
      }

      final libraryPathPtr = candidate.toNativeUtf8();
      try {
        ggml_backend_reg_t reg;
        try {
          reg = ggml_backend_load(libraryPathPtr.cast());
        } on ArgumentError {
          _resolveGgmlFallbackFunctions();
          final fallback = _ggmlBackendLoadFallback;
          if (fallback == null) {
            // Optional dynamic-loader symbol can be missing from the primary
            // FFI asset in split bundles. If ggml fallback is unavailable,
            // stop retrying.
            _backendLoadSymbolUnavailable = true;
            return false;
          }
          reg = fallback(libraryPathPtr.cast());
        }
        if (reg == nullptr) {
          continue;
        }

        // Best-effort compatibility call for runtimes where explicit register is
        // required after dynamic load. We still consider the module load
        // successful even if this symbol is unavailable.
        _registerBackendRegBestEffort(reg);
        _loadedBackendModules.add(backend);
        _failedBackendModules.remove(backend);
        return true;
      } finally {
        malloc.free(libraryPathPtr);
      }
    }

    if (_tryRegisterBackendModuleViaAsset(backend)) {
      return true;
    }

    _failedBackendModules.add(backend);
    return false;
  }

  List<String> _backendAssetUriCandidates(String backend) {
    final candidates = <String>{
      'package:llamadart/$backend',
      'package:llamadart/ggml_$backend',
      'package:llamadart/ggml-$backend',
    };

    if (backend == 'cpu' && Platform.isAndroid) {
      for (final variant in _androidCpuVariantPriority.keys) {
        candidates.add(
          'package:llamadart/ggml-cpu-${variant.replaceAll('.', '_')}',
        );
      }
      candidates.add('package:llamadart/ggml-cpu');
    }

    return candidates.toList(growable: false);
  }

  bool _tryRegisterBackendModuleViaAsset(String backend) {
    final assetCandidates = _backendAssetUriCandidates(backend);
    final recordAssetDiagnostics = backend == 'cpu' && Platform.isAndroid;

    for (final assetUri in assetCandidates) {
      try {
        final library = DynamicLibrary.open(assetUri);
        final score = _lookupBackendAssetScore(library);
        if (!isBackendCandidateScoreSupported(score)) {
          if (recordAssetDiagnostics && score != null) {
            _recordStartupDiagnostic(
              describeSkippedBackendAssetCandidate(assetUri, score),
            );
          }
          continue;
        }

        final init = library
            .lookupFunction<_GgmlBackendInitNative, _GgmlBackendInitDart>(
              'ggml_backend_init',
            );
        final reg = init();
        if (reg == nullptr) {
          if (recordAssetDiagnostics) {
            _recordStartupDiagnostic(
              'Backend asset `$assetUri` returned null from '
              '`ggml_backend_init`.',
            );
          }
          continue;
        }

        // Asset init path mirrors ggml_backend_load() by honoring optional
        // backend score gates before initialization, then explicitly
        // registering the backend because asset loading bypasses the native
        // dynamic-loader helper.
        if (!_registerBackendRegBestEffort(reg)) {
          if (recordAssetDiagnostics) {
            _recordStartupDiagnostic(
              'Backend asset `$assetUri` failed explicit backend '
              'registration.',
            );
          }
          continue;
        }
        _loadedBackendLibraries[backend] = library;
        _loadedBackendModules.add(backend);
        if (recordAssetDiagnostics) {
          _recordStartupDiagnostic(
            describeLoadedBackendAssetCandidate(assetUri, score),
          );
        }
        return true;
      } catch (_) {
        continue;
      }
    }

    return false;
  }

  int? _lookupBackendAssetScore(DynamicLibrary library) {
    try {
      final score = library
          .lookupFunction<_GgmlBackendScoreNative, _GgmlBackendScoreDart>(
            'ggml_backend_score',
          );
      return score();
    } catch (_) {
      return null;
    }
  }

  bool _registerBackendRegBestEffort(ggml_backend_reg_t reg) {
    try {
      ggml_backend_register(reg);
      return true;
    } on ArgumentError {
      _resolveGgmlFallbackFunctions();
      final fallback = _ggmlBackendRegisterFallback;
      if (fallback == null) {
        return false;
      }
      try {
        fallback(reg);
        return true;
      } catch (_) {
        return false;
      }
    }
  }

  void _resolveGgmlFallbackFunctions() {
    final fileNameCandidates = _ggmlLibraryCandidateFileNames();
    final candidates = <String>[..._ggmlAssetUriCandidates()];
    final filesystemCandidates = <String>{};
    final backendModuleDirectory = _backendModuleDirectory;
    if (backendModuleDirectory != null) {
      for (final fileName in fileNameCandidates) {
        filesystemCandidates.add(path.join(backendModuleDirectory, fileName));
      }
    }
    // Keep bare-name fallback last so module-dir resolution wins when present.
    filesystemCandidates.addAll(fileNameCandidates);
    candidates.addAll(filesystemCandidates);

    final searchKey = candidates.map(path.normalize).join('|');
    if (_ggmlFallbackLookupAttempted &&
        _ggmlFallbackLookupSearchKey == searchKey) {
      return;
    }
    _ggmlFallbackLookupAttempted = true;
    _ggmlFallbackLookupSearchKey = searchKey;

    final seen = <String>{};
    for (final candidate in candidates) {
      if (!seen.add(candidate)) {
        continue;
      }

      DynamicLibrary library;
      try {
        library = DynamicLibrary.open(candidate);
      } catch (_) {
        continue;
      }

      if (_ggmlBackendLoadFallback == null) {
        try {
          _ggmlBackendLoadFallback = library
              .lookupFunction<_GgmlBackendLoadNative, _GgmlBackendLoadDart>(
                'ggml_backend_load',
              );
        } catch (_) {
          // Keep searching other candidates.
        }
      }

      if (_ggmlBackendLoadAllFallback == null) {
        try {
          _ggmlBackendLoadAllFallback = library
              .lookupFunction<
                _GgmlBackendLoadAllNative,
                _GgmlBackendLoadAllDart
              >('ggml_backend_load_all');
        } catch (_) {
          // Keep searching other candidates.
        }
      }

      if (_ggmlBackendLoadAllFromPathFallback == null) {
        try {
          _ggmlBackendLoadAllFromPathFallback = library
              .lookupFunction<
                _GgmlBackendLoadAllFromPathNative,
                _GgmlBackendLoadAllFromPathDart
              >('ggml_backend_load_all_from_path');
        } catch (_) {
          // Keep searching other candidates.
        }
      }

      if (_ggmlBackendRegisterFallback == null) {
        try {
          _ggmlBackendRegisterFallback = library
              .lookupFunction<
                _GgmlBackendRegisterNative,
                _GgmlBackendRegisterDart
              >('ggml_backend_register');
        } catch (_) {
          // Keep searching other candidates.
        }
      }

      if (_ggmlBackendRegCountFallback == null) {
        try {
          _ggmlBackendRegCountFallback = library
              .lookupFunction<
                _GgmlBackendRegCountNative,
                _GgmlBackendRegCountDart
              >('ggml_backend_reg_count');
        } catch (_) {
          // Keep searching other candidates.
        }
      }

      if (_ggmlBackendRegGetFallback == null) {
        try {
          _ggmlBackendRegGetFallback = library
              .lookupFunction<_GgmlBackendRegGetNative, _GgmlBackendRegGetDart>(
                'ggml_backend_reg_get',
              );
        } catch (_) {
          // Keep searching other candidates.
        }
      }

      if (_ggmlBackendRegNameFallback == null) {
        try {
          _ggmlBackendRegNameFallback = library
              .lookupFunction<
                _GgmlBackendRegNameNative,
                _GgmlBackendRegNameDart
              >('ggml_backend_reg_name');
        } catch (_) {
          // Keep searching other candidates.
        }
      }

      if (_ggmlBackendRegByNameFallback == null) {
        try {
          _ggmlBackendRegByNameFallback = library
              .lookupFunction<
                _GgmlBackendRegByNameNative,
                _GgmlBackendRegByNameDart
              >('ggml_backend_reg_by_name');
        } catch (_) {
          // Keep searching other candidates.
        }
      }

      if (_ggmlBackendRegDevCountFallback == null) {
        try {
          _ggmlBackendRegDevCountFallback = library
              .lookupFunction<
                _GgmlBackendRegDevCountNative,
                _GgmlBackendRegDevCountDart
              >('ggml_backend_reg_dev_count');
        } catch (_) {
          // Keep searching other candidates.
        }
      }

      if (_ggmlBackendRegDevGetFallback == null) {
        try {
          _ggmlBackendRegDevGetFallback = library
              .lookupFunction<
                _GgmlBackendRegDevGetNative,
                _GgmlBackendRegDevGetDart
              >('ggml_backend_reg_dev_get');
        } catch (_) {
          // Keep searching other candidates.
        }
      }

      if (_ggmlBackendDevCountFallback == null) {
        try {
          _ggmlBackendDevCountFallback = library
              .lookupFunction<
                _GgmlBackendDevCountNative,
                _GgmlBackendDevCountDart
              >('ggml_backend_dev_count');
        } catch (_) {
          // Keep searching other candidates.
        }
      }

      if (_ggmlBackendDevGetFallback == null) {
        try {
          _ggmlBackendDevGetFallback = library
              .lookupFunction<_GgmlBackendDevGetNative, _GgmlBackendDevGetDart>(
                'ggml_backend_dev_get',
              );
        } catch (_) {
          // Keep searching other candidates.
        }
      }

      if (_ggmlBackendDevNameFallback == null) {
        try {
          _ggmlBackendDevNameFallback = library
              .lookupFunction<
                _GgmlBackendDevNameNative,
                _GgmlBackendDevNameDart
              >('ggml_backend_dev_name');
        } catch (_) {
          // Keep searching other candidates.
        }
      }

      if (_ggmlBackendDevBackendRegFallback == null) {
        try {
          _ggmlBackendDevBackendRegFallback = library
              .lookupFunction<
                _GgmlBackendDevBackendRegNative,
                _GgmlBackendDevBackendRegDart
              >('ggml_backend_dev_backend_reg');
        } catch (_) {
          // Keep searching other candidates.
        }
      }

      if (_ggmlBackendDevByTypeFallback == null) {
        try {
          _ggmlBackendDevByTypeFallback = library
              .lookupFunction<
                _GgmlBackendDevByTypeNative,
                _GgmlBackendDevByTypeDart
              >('ggml_backend_dev_by_type');
        } catch (_) {
          // Keep searching other candidates.
        }
      }

      if (_ggmlBackendDevTypeFallback == null) {
        try {
          _ggmlBackendDevTypeFallback = library
              .lookupFunction<
                _GgmlBackendDevTypeNative,
                _GgmlBackendDevTypeDart
              >('ggml_backend_dev_type');
        } catch (_) {
          // Keep searching other candidates.
        }
      }

      if (_ggmlBackendDevGetPropsFallback == null) {
        try {
          _ggmlBackendDevGetPropsFallback = library
              .lookupFunction<
                _GgmlBackendDevGetPropsNative,
                _GgmlBackendDevGetPropsDart
              >('ggml_backend_dev_get_props');
        } catch (_) {
          // Keep searching other candidates.
        }
      }

      if (_ggmlBackendDevMemoryFallback == null) {
        try {
          _ggmlBackendDevMemoryFallback = library
              .lookupFunction<
                _GgmlBackendDevMemoryNative,
                _GgmlBackendDevMemoryDart
              >('ggml_backend_dev_memory');
        } catch (_) {
          // Keep searching other candidates.
        }
      }

      if (_ggmlBackendLoadFallback != null &&
          _ggmlBackendLoadAllFallback != null &&
          _ggmlBackendLoadAllFromPathFallback != null &&
          _ggmlBackendRegisterFallback != null &&
          _ggmlBackendRegCountFallback != null &&
          _ggmlBackendRegGetFallback != null &&
          _ggmlBackendRegNameFallback != null &&
          _ggmlBackendRegByNameFallback != null &&
          _ggmlBackendRegDevCountFallback != null &&
          _ggmlBackendRegDevGetFallback != null &&
          _ggmlBackendDevCountFallback != null &&
          _ggmlBackendDevGetFallback != null &&
          _ggmlBackendDevNameFallback != null &&
          _ggmlBackendDevBackendRegFallback != null &&
          _ggmlBackendDevByTypeFallback != null &&
          _ggmlBackendDevTypeFallback != null &&
          _ggmlBackendDevGetPropsFallback != null &&
          _ggmlBackendDevMemoryFallback != null) {
        return;
      }
    }
  }

  List<String> _ggmlAssetUriCandidates() {
    if (Platform.isWindows) {
      return const <String>[
        'package:llamadart/ggml',
        'package:llamadart/ggml-base',
      ];
    }
    return const <String>['package:llamadart/ggml'];
  }

  void _resolveLogLevelFallbackFunction() {
    final directories = _llamadartFallbackLookupDirectories();
    final searchKey = directories.map(path.normalize).join('|');

    if (_logLevelFallbackLookupAttempted &&
        _llamaDartSetLogLevelFallback != null) {
      return;
    }

    if (_logLevelFallbackLookupAttempted &&
        _llamaDartSetLogLevelFallback == null &&
        _logLevelFallbackLookupSearchKey == searchKey) {
      return;
    }

    _logLevelFallbackLookupAttempted = true;
    _logLevelFallbackLookupSearchKey = searchKey;

    final fileNameCandidates = _llamadartLibraryCandidateFileNames();
    final candidates = <String>[..._llamadartAssetUriCandidates()];
    final pattern = _llamadartLibraryPattern();
    for (final directoryPath in directories) {
      for (final fileName in fileNameCandidates) {
        candidates.add(path.join(directoryPath, fileName));
      }
      for (final fileName in _matchingLibraryNames(directoryPath, pattern)) {
        candidates.add(path.join(directoryPath, fileName));
      }
    }
    // Keep bare-name fallback last so module-dir resolution wins when present.
    candidates.addAll(fileNameCandidates);

    final seen = <String>{};
    for (final candidate in candidates) {
      if (!seen.add(candidate)) {
        continue;
      }
      try {
        final library = DynamicLibrary.open(candidate);
        _llamaDartSetLogLevelFallback = library
            .lookupFunction<
              _LlamaDartSetLogLevelNative,
              _LlamaDartSetLogLevelDart
            >('llama_dart_set_log_level');
        return;
      } catch (_) {
        continue;
      }
    }
  }

  _MtpApi _resolveMtpApi() {
    final cached = _mtpApi;
    if (cached != null) {
      return cached;
    }

    if (_mtpApiLookupAttempted) {
      throw UnsupportedError(_mtpUnavailableMessage());
    }
    _mtpApiLookupAttempted = true;

    if (!Platform.isWindows) {
      try {
        final direct = _MtpApi.direct();
        _mtpApi = direct;
        return direct;
      } catch (_) {}
    }

    if (Platform.isWindows) {
      try {
        final asset = _MtpApi.windowsAsset();
        _mtpApi = asset;
        return asset;
      } catch (_) {}
    }

    for (final candidate in _llamadartWrapperLibraryCandidates()) {
      try {
        final library = DynamicLibrary.open(candidate);
        final api = _MtpApi.tryLoad(library);
        if (api != null) {
          _mtpApi = api;
          return api;
        }
      } catch (_) {
        continue;
      }
    }

    throw UnsupportedError(_mtpUnavailableMessage());
  }

  String _mtpUnavailableMessage() {
    return 'llama.cpp MTP speculative decoding is unavailable in this native '
        'runtime bundle (missing llama_dart_mtp_* wrapper symbols).';
  }

  List<String> _llamadartWrapperLibraryCandidates() {
    final candidates = <String>[..._llamadartAssetUriCandidates()];
    final fileNameCandidates = _llamadartLibraryCandidateFileNames();
    final pattern = _llamadartLibraryPattern();
    for (final directoryPath in _llamadartFallbackLookupDirectories()) {
      for (final fileName in fileNameCandidates) {
        candidates.add(path.join(directoryPath, fileName));
      }
      for (final fileName in _matchingLibraryNames(directoryPath, pattern)) {
        candidates.add(path.join(directoryPath, fileName));
      }
    }
    candidates.addAll(fileNameCandidates);

    final seen = <String>{};
    return [
      for (final candidate in candidates)
        if (seen.add(candidate)) candidate,
    ];
  }

  List<String> _llamadartAssetUriCandidates() {
    // Prefer asset-URI resolution so Windows split bundles can reliably resolve
    // the wrapper helper library without relying on process cwd/search paths.
    if (Platform.isWindows) {
      return const <String>[
        'package:llamadart/llamadart_wrapper',
        'package:llamadart/llamadart',
      ];
    }
    return const <String>['package:llamadart/llamadart'];
  }

  List<String> _llamadartFallbackLookupDirectories() {
    final directories = <String>{};
    final backendModuleDirectory = _backendModuleDirectory;
    if (backendModuleDirectory != null) {
      directories.add(backendModuleDirectory);
    }

    final executableDir = path.dirname(Platform.resolvedExecutable);
    directories.add(executableDir);
    directories.add(Directory.current.path);
    directories.add(path.join(Directory.current.path, '.dart_tool', 'lib'));

    if (Platform.isIOS) {
      directories.add(path.normalize(path.join(executableDir, 'Frameworks')));
    }

    if (Platform.isMacOS) {
      directories.add(
        path.normalize(path.join(executableDir, '..', 'Frameworks')),
      );
      directories.add(path.normalize(path.join(executableDir, 'Frameworks')));
    }

    return directories.toList(growable: false);
  }

  static String _ggmlLibraryFileName() {
    if (Platform.isWindows) {
      return 'ggml.dll';
    }
    if (Platform.isMacOS || Platform.isIOS) {
      return 'libggml.dylib';
    }
    return 'libggml.so';
  }

  static String _llamadartLibraryFileName() {
    if (Platform.isWindows) {
      return 'llamadart.dll';
    }
    if (Platform.isMacOS || Platform.isIOS) {
      return 'libllamadart.dylib';
    }
    return 'libllamadart.so';
  }

  List<String> _backendLibraryCandidateFileNames(String backend) {
    final baseName = _backendLibraryFileName(backend);
    final backendModuleDirectory = _backendModuleDirectory;
    if (backendModuleDirectory == null) {
      if (backend == 'cpu' && Platform.isAndroid) {
        final variants = _androidCpuVariantPriority.keys
            .map((variant) => 'libggml-cpu-$variant.so')
            .toList(growable: false);
        return <String>[...variants, baseName];
      }
      return <String>[baseName];
    }

    final candidates = <String>{};
    final basePath = path.join(backendModuleDirectory, baseName);
    if (File(basePath).existsSync()) {
      candidates.add(baseName);
    }
    final dynamicNames = _matchingLibraryNames(
      backendModuleDirectory,
      _backendLibraryPattern(backend),
    );
    if (backend == 'cpu' && Platform.isAndroid) {
      dynamicNames.sort(_compareAndroidCpuLibraryCandidates);
    }
    candidates.addAll(dynamicNames);
    final resolved = candidates.toList(growable: false);
    if (backend == 'cpu' && Platform.isAndroid) {
      resolved.sort(_compareAndroidCpuLibraryCandidates);
    }
    return resolved;
  }

  static int _compareAndroidCpuLibraryCandidates(String a, String b) {
    final rankA = _androidCpuLibraryCandidateRank(a);
    final rankB = _androidCpuLibraryCandidateRank(b);
    if (rankA != rankB) {
      return rankA.compareTo(rankB);
    }
    return a.compareTo(b);
  }

  static int _androidCpuLibraryCandidateRank(String fileName) {
    final lowered = fileName.toLowerCase();
    if (lowered == 'libggml-cpu.so') {
      return 1000;
    }

    final variantMatch = RegExp(
      r'^libggml-cpu-([^/\\]+)\.so$',
    ).firstMatch(lowered);
    if (variantMatch == null) {
      return 2000;
    }

    final variant = variantMatch.group(1)!;
    return _androidCpuVariantPriority[variant] ?? 900;
  }

  List<String> _ggmlLibraryCandidateFileNames() {
    final baseName = _ggmlLibraryFileName();
    final candidates = <String>{baseName};
    final backendModuleDirectory = _backendModuleDirectory;
    if (backendModuleDirectory == null) {
      return candidates.toList(growable: false);
    }

    final dynamicNames = _matchingLibraryNames(
      backendModuleDirectory,
      _ggmlLibraryPattern(),
    );
    candidates.addAll(dynamicNames);
    return candidates.toList(growable: false);
  }

  List<String> _llamadartLibraryCandidateFileNames() {
    final candidates = _llamadartStaticCandidateFileNames();
    final backendModuleDirectory = _backendModuleDirectory;
    if (backendModuleDirectory == null) {
      return candidates.toList(growable: false);
    }

    final dynamicNames = _matchingLibraryNames(
      backendModuleDirectory,
      _llamadartLibraryPattern(),
    );
    candidates.addAll(dynamicNames);
    return candidates.toList(growable: false);
  }

  Set<String> _llamadartStaticCandidateFileNames() {
    final candidates = <String>{_llamadartLibraryFileName()};
    if (Platform.isWindows) {
      // Hook asset naming can expose wrapper helper as `llamadart_wrapper.dll`.
      candidates.add('llamadart_wrapper.dll');
    }
    return candidates;
  }

  RegExp _backendLibraryPattern(String backend) {
    final escapedBackend = RegExp.escape(backend);
    if (Platform.isWindows) {
      return RegExp('^ggml-$escapedBackend(?:-[^\\\\/]+)*\\.dll\$');
    }
    if (Platform.isMacOS || Platform.isIOS) {
      return RegExp('^libggml-$escapedBackend(?:-[^\\\\/]+)*\\.dylib\$');
    }
    return RegExp('^libggml-$escapedBackend(?:-[^\\\\/]+)*\\.so\$');
  }

  RegExp _ggmlLibraryPattern() {
    if (Platform.isWindows) {
      return RegExp(r'^ggml(?:-[^.\\/]+)*\.dll$');
    }
    if (Platform.isMacOS || Platform.isIOS) {
      return RegExp(r'^libggml(?:-[^.\\/]+)*\.dylib$');
    }
    return RegExp(r'^libggml(?:-[^.\\/]+)*\.so$');
  }

  RegExp _llamadartLibraryPattern() {
    if (Platform.isWindows) {
      return RegExp(r'^llamadart(?:[-_][^.\\/]+)*\.dll$');
    }
    if (Platform.isMacOS || Platform.isIOS) {
      return RegExp(r'^libllamadart(?:[-_][^.\\/]+)*\.dylib$');
    }
    return RegExp(r'^libllamadart(?:[-_][^.\\/]+)*\.so$');
  }

  static List<String> _matchingLibraryNames(
    String directoryPath,
    RegExp regex,
  ) {
    try {
      final names = <String>[];
      for (final entity in Directory(directoryPath).listSync()) {
        if (entity is! File) {
          continue;
        }
        final name = path.basename(entity.path);
        if (regex.hasMatch(name)) {
          names.add(name);
        }
      }
      names.sort();
      return names;
    } catch (_) {
      return const [];
    }
  }

  T _ggmlRegistryFallbackOr<T>(
    T fallback,
    T Function() primaryCall,
    T? Function() fallbackCall,
  ) {
    if (Platform.isWindows) {
      // Windows split bundles can expose ggml registry state through ggml.dll
      // while the generated default asset points at llama.dll. Prefer the
      // explicit ggml runtime lookup when it is available so count/get/name
      // calls all read the same registry.
      _resolveGgmlFallbackFunctions();
      final fallbackValue = fallbackCall();
      if (fallbackValue != null) {
        return fallbackValue;
      }
    }

    try {
      return primaryCall();
    } on ArgumentError {
      _resolveGgmlFallbackFunctions();
      final fallbackValue = fallbackCall();
      if (fallbackValue != null) {
        return fallbackValue;
      }
      _backendRegistrySymbolUnavailable = true;
      return fallback;
    }
  }

  int _ggmlBackendRegCount() {
    return _ggmlRegistryFallbackOr<int>(
      0,
      ggml_backend_reg_count,
      () => _ggmlBackendRegCountFallback?.call(),
    );
  }

  ggml_backend_reg_t _ggmlBackendRegGet(int index) {
    return _ggmlRegistryFallbackOr<ggml_backend_reg_t>(
      nullptr,
      () => ggml_backend_reg_get(index),
      () => _ggmlBackendRegGetFallback?.call(index),
    );
  }

  Pointer<Char> _ggmlBackendRegName(ggml_backend_reg_t reg) {
    return _ggmlRegistryFallbackOr<Pointer<Char>>(
      nullptr,
      () => ggml_backend_reg_name(reg),
      () => _ggmlBackendRegNameFallback?.call(reg),
    );
  }

  ggml_backend_reg_t _ggmlBackendRegByName(Pointer<Char> name) {
    return _ggmlRegistryFallbackOr<ggml_backend_reg_t>(
      nullptr,
      () => ggml_backend_reg_by_name(name),
      () => _ggmlBackendRegByNameFallback?.call(name),
    );
  }

  int _ggmlBackendRegDevCount(ggml_backend_reg_t reg) {
    return _ggmlRegistryFallbackOr<int>(
      0,
      () => ggml_backend_reg_dev_count(reg),
      () => _ggmlBackendRegDevCountFallback?.call(reg),
    );
  }

  ggml_backend_dev_t _ggmlBackendRegDevGet(ggml_backend_reg_t reg, int index) {
    return _ggmlRegistryFallbackOr<ggml_backend_dev_t>(
      nullptr,
      () => ggml_backend_reg_dev_get(reg, index),
      () => _ggmlBackendRegDevGetFallback?.call(reg, index),
    );
  }

  int _ggmlBackendDevCount() {
    return _ggmlRegistryFallbackOr<int>(
      0,
      ggml_backend_dev_count,
      () => _ggmlBackendDevCountFallback?.call(),
    );
  }

  ggml_backend_dev_t _ggmlBackendDevGet(int index) {
    return _ggmlRegistryFallbackOr<ggml_backend_dev_t>(
      nullptr,
      () => ggml_backend_dev_get(index),
      () => _ggmlBackendDevGetFallback?.call(index),
    );
  }

  Pointer<Char> _ggmlBackendDevName(ggml_backend_dev_t dev) {
    return _ggmlRegistryFallbackOr<Pointer<Char>>(
      nullptr,
      () => ggml_backend_dev_name(dev),
      () => _ggmlBackendDevNameFallback?.call(dev),
    );
  }

  ggml_backend_reg_t _ggmlBackendDevBackendReg(ggml_backend_dev_t dev) {
    return _ggmlRegistryFallbackOr<ggml_backend_reg_t>(
      nullptr,
      () => ggml_backend_dev_backend_reg(dev),
      () => _ggmlBackendDevBackendRegFallback?.call(dev),
    );
  }

  ggml_backend_dev_t _ggmlBackendDevByType(ggml_backend_dev_type type) {
    return _ggmlRegistryFallbackOr<ggml_backend_dev_t>(
      nullptr,
      () => ggml_backend_dev_by_type(type),
      () => _ggmlBackendDevByTypeFallback?.call(type.value),
    );
  }

  /// Raw `ggml_backend_dev_type` value (the C enum int) for a device.
  /// Callers compare against `ggml_backend_dev_type.GGML_*.value` so a
  /// newer llama.cpp adding a new enum variant doesn't crash here via
  /// the high-level binding's `fromValue` ArgumentError — unknown
  /// values just don't match any of the GPU-class checks. Returns `-1`
  /// when both the primary `@DefaultAsset` lookup and the ggml-runtime
  /// fallback can't resolve the symbol.
  int _ggmlBackendDevType(ggml_backend_dev_t dev) {
    return _ggmlRegistryFallbackOr<int>(
      -1,
      () => ggml_backend_dev_type$1(dev).value,
      () => _ggmlBackendDevTypeFallback?.call(dev),
    );
  }

  /// Routes `ggml_backend_dev_get_props` through the registry fallback
  /// so the call lands on whichever ggml runtime owns the device state
  /// on Windows split bundles. Returns `false` when the symbol is
  /// unavailable from both the primary asset and the ggml runtime.
  bool _ggmlBackendDevGetProps(
    ggml_backend_dev_t dev,
    Pointer<ggml_backend_dev_props> props,
  ) {
    return _ggmlRegistryFallbackOr<bool>(
      false,
      () {
        ggml_backend_dev_get_props(dev, props);
        return true;
      },
      () {
        final fn = _ggmlBackendDevGetPropsFallback;
        if (fn == null) return null;
        fn(dev, props);
        return true;
      },
    );
  }

  /// Routes `ggml_backend_dev_memory` through the registry fallback.
  /// Same shape as [_ggmlBackendDevGetProps]; returns `false` when the
  /// symbol is unavailable.
  bool _ggmlBackendDevMemory(
    ggml_backend_dev_t dev,
    Pointer<Size> free,
    Pointer<Size> total,
  ) {
    return _ggmlRegistryFallbackOr<bool>(
      false,
      () {
        ggml_backend_dev_memory(dev, free, total);
        return true;
      },
      () {
        final fn = _ggmlBackendDevMemoryFallback;
        if (fn == null) return null;
        fn(dev, free, total);
        return true;
      },
    );
  }

  static String _backendLibraryFileName(String backend) {
    if (Platform.isWindows) {
      return 'ggml-$backend.dll';
    }
    if (Platform.isMacOS || Platform.isIOS) {
      return 'libggml-$backend.dylib';
    }
    return 'libggml-$backend.so';
  }

  static bool _looksLikeGguf(File modelFile) {
    try {
      final header = modelFile.openSync(mode: FileMode.read);
      try {
        final magic = header.readSync(4);
        if (magic.length < 4) {
          return false;
        }
        return magic[0] == 0x47 &&
            magic[1] == 0x47 &&
            magic[2] == 0x55 &&
            magic[3] == 0x46;
      } finally {
        header.closeSync();
      }
    } catch (_) {
      return false;
    }
  }

  String _backendDiagnostics() {
    final regs = <String>[];
    final regCount = _ggmlBackendRegCount();
    for (var i = 0; i < regCount; i++) {
      final reg = _ggmlBackendRegGet(i);
      if (reg == nullptr) {
        continue;
      }
      final regNamePtr = _ggmlBackendRegName(reg);
      if (regNamePtr == nullptr) {
        continue;
      }
      regs.add(regNamePtr.cast<Utf8>().toDartString());
    }

    final devices = getBackendInfo();
    return '{moduleDir=${_backendModuleDirectory ?? "null"}, '
        'loadedModules=${_loadedBackendModules.toList(growable: false)}, '
        'registeredBackends=$regs, devices=$devices, '
        'registryApisUnavailable=$_backendRegistrySymbolUnavailable}';
  }

  Pointer<ggml_backend_dev_t>? _createPreferredDeviceList(GpuBackend backend) {
    final devices = _resolvePreferredDevices(backend);
    if (devices == null || devices.isEmpty) {
      return null;
    }

    final ptr = malloc<ggml_backend_dev_t>(devices.length + 1);
    for (var i = 0; i < devices.length; i++) {
      ptr[i] = devices[i];
    }
    ptr[devices.length] = nullptr;
    return ptr;
  }

  List<ggml_backend_dev_t>? _resolvePreferredDevices(GpuBackend backend) {
    switch (backend) {
      case GpuBackend.auto:
        return null;
      case GpuBackend.cpu:
        final cpuDev = _ggmlBackendDevByType(
          ggml_backend_dev_type.GGML_BACKEND_DEVICE_TYPE_CPU,
        );
        if (cpuDev == nullptr) {
          return null;
        }
        return [cpuDev];
      case GpuBackend.vulkan:
        return _devicesForBackendRegName('Vulkan');
      case GpuBackend.metal:
        return _devicesForBackendRegName('Metal');
      case GpuBackend.cuda:
        return _devicesForBackendRegName('CUDA');
      case GpuBackend.blas:
        return _devicesForBackendRegName('BLAS');
      case GpuBackend.opencl:
        return _devicesForBackendRegName('OpenCL');
      case GpuBackend.hip:
        return _devicesForBackendRegName('HIP');
    }
  }

  List<ggml_backend_dev_t>? _devicesForBackendRegName(String regName) {
    final regNamePtr = regName.toNativeUtf8();
    try {
      final reg = _ggmlBackendRegByName(regNamePtr.cast());
      if (reg == nullptr) {
        return null;
      }

      final count = _ggmlBackendRegDevCount(reg);
      if (count <= 0) {
        return null;
      }

      final devices = <ggml_backend_dev_t>[];
      for (var i = 0; i < count; i++) {
        final dev = _ggmlBackendRegDevGet(reg, i);
        if (dev != nullptr) {
          devices.add(dev);
        }
      }

      if (devices.isEmpty) {
        return null;
      }

      return devices;
    } finally {
      malloc.free(regNamePtr);
    }
  }

  /// Frees the model associated with [modelHandle].
  ///
  /// This also frees all contexts and LoRA adapters associated with the model.
  void freeModel(int modelHandle) {
    final model = _models.remove(modelHandle);
    _modelToMtmdUseGpu.remove(modelHandle);
    if (model != null) {
      final contextsToRemove = _contextToModel.entries
          .where((e) => e.value == modelHandle)
          .map((e) => e.key)
          .toList();
      for (final ctxHandle in contextsToRemove) {
        _freeContext(ctxHandle);
      }
      final adapters = _loraAdapters.remove(modelHandle);
      adapters?.values.forEach((a) => a.dispose());

      // Free associated multimodal context
      final mmHandle = _modelToMtmd.remove(modelHandle);
      if (mmHandle != null) {
        final mmCtx = _mtmdContexts.remove(mmHandle);
        if (mmCtx != null) _mtmdFree(mmCtx);
      }

      model.dispose();
    }

    _modelBackendNames.remove(modelHandle);
    _modelResolvedGpuLayers.remove(modelHandle);
    if (_modelBackendNames.isEmpty) {
      _activeBackendName = _backendDisplayName('cpu');
      _activeResolvedGpuLayers = 0;
    } else {
      _activeBackendName = _modelBackendNames.values.last;
      _activeResolvedGpuLayers = _modelResolvedGpuLayers.values.last;
    }
  }

  /// Creates an inference context for the specified [modelHandle].
  ///
  /// Returns a handle to the created context.
  /// Throws an [Exception] if the model handle is invalid or context creation fails.
  int createContext(int modelHandle, ModelParams params) {
    final model = _models[modelHandle];
    if (model == null) {
      throw Exception("Invalid model handle");
    }

    final ctxParams = llama_context_default_params();
    int nCtx = params.contextSize;
    if (nCtx <= 0) {
      nCtx = llama_model_n_ctx_train(model.pointer);
    }
    final resolvedBatchSizes = resolveContextBatchSizes(params, nCtx);
    final maxSeqLimit = llama_max_parallel_sequences();
    final resolvedMaxParallelSequences = math.max(
      1,
      math.min(params.maxParallelSequences, maxSeqLimit),
    );

    ctxParams.n_ctx = nCtx;
    ctxParams.n_batch = resolvedBatchSizes.batchSize;
    ctxParams.n_ubatch = resolvedBatchSizes.microBatchSize;
    ctxParams.n_seq_max = resolvedMaxParallelSequences;
    ctxParams.n_rs_seq = params.speculativeRollbackTokenMax;
    ctxParams.n_threads = params.numberOfThreads;
    ctxParams.n_threads_batch = params.numberOfThreadsBatch;
    if (resolvedMaxParallelSequences > 1) {
      // Keep per-sequence context at full n_ctx when multiple sequence slots
      // are enabled so regular generation behavior is unchanged.
      ctxParams.kv_unified = true;
    }

    final resolvedModelGpuLayers = _modelResolvedGpuLayers[modelHandle];
    if (shouldDisableContextGpuOffload(
      params,
      resolvedGpuLayers: resolvedModelGpuLayers,
    )) {
      ctxParams.offload_kqv = false;
      ctxParams.op_offload = false;
      ctxParams.flash_attn_typeAsInt =
          llama_flash_attn_type.LLAMA_FLASH_ATTN_TYPE_DISABLED.value;
    } else if (shouldUseConservativeAndroidVulkanContextConfig(
      params,
      resolvedGpuLayers: resolvedModelGpuLayers,
      isAndroid: Platform.isAndroid,
    )) {
      final enableExperimentalAcceleration =
          shouldEnableExperimentalAndroidVulkanAcceleration(
            model.sourcePath,
            isAndroid: Platform.isAndroid,
          );
      final allowKqv =
          _androidVulkanAllowKqvOffload || enableExperimentalAcceleration;
      final allowOp =
          _androidVulkanAllowOpOffload || enableExperimentalAcceleration;
      final allowFlash =
          _androidVulkanAllowFlashAttn || enableExperimentalAcceleration;

      if (!allowKqv) {
        ctxParams.offload_kqv = false;
      }
      if (!allowOp) {
        ctxParams.op_offload = false;
      }
      if (!allowFlash) {
        ctxParams.flash_attn_typeAsInt =
            llama_flash_attn_type.LLAMA_FLASH_ATTN_TYPE_DISABLED.value;
      }
    }

    params.validate();
    final resolvedFlashAttn = applyContextParams(ctxParams, params);
    if (resolvedFlashAttn != params.flashAttention) {
      LlamaLogger.instance.debug(
        'llama_cpp_service: promoting flash_attn=enabled for non-F16 KV '
        '(k=${params.cacheTypeK}, v=${params.cacheTypeV})',
      );
    }

    final ctxPtr = llama_init_from_model(model.pointer, ctxParams);
    if (ctxPtr == nullptr) {
      throw Exception("Failed to create context");
    }

    final handle = _getHandle();
    _contexts[handle] = _LlamaContextWrapper(ctxPtr, model);
    _contextToModel[handle] = modelHandle;
    _activeLoras[handle] = {};
    _contextParams[handle] = ctxParams;
    _samplers[handle] = llama_sampler_chain_init(
      llama_sampler_chain_default_params(),
    );
    _batches[handle] = llama_batch_init(resolvedBatchSizes.batchSize, 0, 1);

    return handle;
  }

  /// Frees the context associated with [contextHandle].
  void freeContext(int contextHandle) {
    _freeContext(contextHandle);
  }

  void _freeContext(int handle) {
    _contextToModel.remove(handle);
    _activeLoras.remove(handle);
    _contextParams.remove(handle);
    final sampler = _samplers.remove(handle);
    if (sampler != null && sampler != nullptr) llama_sampler_free(sampler);
    final batch = _batches.remove(handle);
    if (batch != null) llama_batch_free(batch);
    _contexts.remove(handle)?.dispose();
  }

  _LlamaCppMtpConfig? _resolveLlamaCppMtpConfig(
    GenerationParams params, {
    required bool hasMediaParts,
  }) {
    final speculativeConfig = params.resolvedSpeculativeDecodingConfig;
    if (speculativeConfig == null) {
      return null;
    }

    if (hasMediaParts) {
      throw UnsupportedError(
        'llama.cpp MTP speculative decoding currently supports text-only '
        'generation in llamadart.',
      );
    }
    if (params.grammar != null) {
      throw UnsupportedError(
        'llama.cpp MTP speculative decoding does not yet support grammar '
        'sampling in llamadart.',
      );
    }

    switch (speculativeConfig.strategy) {
      case SpeculativeDecodingStrategy.backendDefault:
      case SpeculativeDecodingStrategy.mtp:
        break;
    }

    final draftTokenMax = speculativeConfig.draftTokenMax ?? 1;
    final draftTokenMin = speculativeConfig.draftTokenMin ?? 0;
    final minProbability = speculativeConfig.minProbability ?? 0.0;

    if (draftTokenMax <= 0) {
      throw RangeError.value(
        draftTokenMax,
        'draftTokenMax',
        'must be greater than zero for llama.cpp MTP',
      );
    }
    if (draftTokenMin < 0 || draftTokenMin > draftTokenMax) {
      throw RangeError.value(
        draftTokenMin,
        'draftTokenMin',
        'must be between zero and draftTokenMax for llama.cpp MTP',
      );
    }
    if (minProbability < 0.0 || minProbability > 1.0) {
      throw RangeError.value(
        minProbability,
        'minProbability',
        'must be between 0.0 and 1.0 for llama.cpp MTP',
      );
    }

    return _LlamaCppMtpConfig(
      draftTokenMax: draftTokenMax,
      draftTokenMin: draftTokenMin,
      minProbability: minProbability,
    );
  }

  /// Generates text based on the given [prompt] and [params].
  ///
  /// Returns a [Stream] of token bytes.
  /// Supports multimodal input via [parts].
  Stream<List<int>> generate(
    int contextHandle,
    String prompt,
    GenerationParams params,
    int cancelTokenAddress, {
    List<LlamaContentPart>? parts,
  }) async* {
    var ctx = _contexts[contextHandle];
    if (ctx == null) throw Exception("Invalid context handle");
    _generatingContexts.update(
      contextHandle,
      (count) => count + 1,
      ifAbsent: () => 1,
    );

    Pointer<Int32> tokensPtr = nullptr;
    Pointer<Uint8> pieceBuf = nullptr;
    Pointer<Utf8> grammarPtr = nullptr;
    Pointer<Utf8> rootPtr = nullptr;
    _LazyGrammarConfig? lazyGrammarConfig;
    Pointer<llama_sampler> sampler = nullptr;
    Pointer<llama_dart_mtp> mtpSession = nullptr;
    _MtpApi? mtpApi;

    try {
      final modelHandle = _contextToModel[contextHandle]!;
      final model = _models[modelHandle]!;
      final modelParams = _contextParams[contextHandle]!;
      final vocab = llama_model_get_vocab(model.pointer);
      final hasMediaParts =
          parts?.any((p) => p is LlamaImageContent || p is LlamaAudioContent) ??
          false;
      final mtpConfig = _resolveLlamaCppMtpConfig(
        params,
        hasMediaParts: hasMediaParts,
      );
      if (mtpConfig != null &&
          shouldRejectAndroidVulkanMtp(
            _modelBackendNames[modelHandle],
            resolvedGpuLayers: _modelResolvedGpuLayers[modelHandle],
            isAndroid: Platform.isAndroid,
            allowMtp: _androidVulkanAllowMtp,
          )) {
        throw UnsupportedError(
          'llama.cpp MTP speculative decoding is disabled for Android Vulkan '
          'because the upstream draft-mtp backend-sampling path can abort with '
          'vk::DeviceLostError. Use the CPU backend, disable MTP, or rebuild '
          'with LLAMADART_ANDROID_VULKAN_ALLOW_MTP=true for debugging.',
        );
      }

      // 1. Reset Context
      ctx = _resetContext(
        contextHandle,
        ctx,
        clearMemory:
            hasMediaParts || mtpConfig != null || !params.reusePromptPrefix,
      );
      ctx.resetLastPerf();
      llama_perf_context_reset(ctx.pointer);
      final existingSampler = _samplers[contextHandle];
      if (existingSampler != null) {
        llama_perf_sampler_reset(existingSampler);
      }

      // 2. Prepare Resources
      final nCtx = llama_n_ctx(ctx.pointer);
      final batch = _batches[contextHandle]!;
      tokensPtr = malloc<Int32>(nCtx);
      pieceBuf = malloc<Uint8>(256);

      if (mtpConfig != null) {
        mtpApi = _resolveMtpApi();
        mtpSession = mtpApi.init(
          model.pointer,
          ctx.pointer,
          modelParams,
          mtpConfig.draftTokenMax,
          mtpConfig.draftTokenMin,
          mtpConfig.minProbability,
          true,
        );
        if (mtpSession == nullptr) {
          throw UnsupportedError(
            'llama.cpp MTP speculative decoding is not available for this '
            'model/context. Use an MTP GGUF model, a native libllamadart build '
            'that includes llama-common, and set '
            'ModelParams.speculativeRollbackTokenMax >= draftTokenMax when the '
            'target architecture needs bounded rollback snapshots.',
          );
        }
        llama_perf_context_reset(ctx.pointer);
      }

      if (params.grammar != null) {
        grammarPtr = params.grammar!.toNativeUtf8();
        rootPtr = params.grammarRoot.toNativeUtf8();
        if (params.grammarLazy && params.grammarTriggers.isNotEmpty) {
          lazyGrammarConfig = _buildLazyGrammarConfig(params);
        }
      }

      // 3. Ingest Prompt (Text or Multimodal)
      final promptEvalStopwatch = Stopwatch()..start();
      final initialTokens = _ingestPrompt(
        contextHandle,
        modelHandle,
        ctx,
        batch,
        vocab,
        prompt,
        parts,
        tokensPtr,
        nCtx,
        modelParams,
        allowTextPromptReuse:
            mtpConfig == null && !hasMediaParts && params.reusePromptPrefix,
        mtpSession: mtpSession,
        mtpApi: mtpApi,
      );
      promptEvalStopwatch.stop();
      ctx.lastPerfPromptEvalMs =
          promptEvalStopwatch.elapsedMicroseconds / 1000.0;
      ctx.lastPerfPromptEvalTokens = initialTokens;

      _ensureLogitsAvailableAfterPromptEval(ctx.pointer);
      if (mtpSession != nullptr &&
          !mtpApi!.begin(mtpSession, 0, tokensPtr, initialTokens)) {
        throw Exception("Failed to initialize llama.cpp MTP prompt state");
      }

      // 4. Initialize and Run Sampler Loop
      sampler = _initializeSampler(
        params,
        vocab,
        grammarPtr,
        rootPtr,
        lazyGrammarConfig,
        initialTokens,
        tokensPtr,
      );

      final preservedTokenIds = _resolvePreservedTokenIds(
        vocab,
        params.preservedTokens,
      );
      final effectiveStopSequences = _effectiveStopSequences(
        params.stopSequences,
        params.preservedTokens,
      );

      if (mtpSession != nullptr && mtpConfig != null) {
        yield* _runMtpInferenceLoop(
          ctx,
          batch,
          vocab,
          sampler,
          params,
          mtpConfig,
          initialTokens,
          nCtx,
          cancelTokenAddress,
          pieceBuf,
          preservedTokenIds,
          effectiveStopSequences,
          mtpSession,
          mtpApi!,
          tokensPtr,
        );
      } else {
        yield* _runInferenceLoop(
          ctx,
          batch,
          vocab,
          sampler,
          params,
          initialTokens,
          nCtx,
          cancelTokenAddress,
          pieceBuf,
          grammarPtr,
          preservedTokenIds,
          effectiveStopSequences,
        );
      }
    } finally {
      if (mtpSession != nullptr) mtpApi?.free(mtpSession);
      if (sampler != nullptr) llama_sampler_free(sampler);
      final remaining = (_generatingContexts[contextHandle] ?? 1) - 1;
      if (remaining <= 0) {
        _generatingContexts.remove(contextHandle);
      } else {
        _generatingContexts[contextHandle] = remaining;
      }
      if (tokensPtr != nullptr) malloc.free(tokensPtr);
      if (pieceBuf != nullptr) malloc.free(pieceBuf);
      if (grammarPtr != nullptr) malloc.free(grammarPtr);
      if (rootPtr != nullptr) malloc.free(rootPtr);
      lazyGrammarConfig?.dispose();
    }
  }

  /// Generates a single embedding vector for [text].
  List<double> embed(int contextHandle, String text, {bool normalize = true}) {
    final ctx = _contexts[contextHandle];
    if (ctx == null) {
      throw Exception('Invalid context handle');
    }

    final modelHandle = _contextToModel[contextHandle];
    if (modelHandle == null) {
      throw Exception('Invalid context handle');
    }

    final model = _models[modelHandle];
    if (model == null) {
      throw Exception('Invalid model handle');
    }

    final contextParams = _contextParams[contextHandle];
    if (contextParams == null) {
      throw Exception('Missing context parameters');
    }

    final hasEncoder = llama_model_has_encoder(model.pointer);
    final hasDecoder = llama_model_has_decoder(model.pointer);
    if (hasEncoder && hasDecoder) {
      throw Exception(
        'Embedding extraction for encoder-decoder models is not supported',
      );
    }
    final useEncoderPath = hasEncoder && !hasDecoder;

    final vocab = llama_model_get_vocab(model.pointer);
    final nSeqCtx = llama_n_ctx_seq(ctx.pointer);
    final tokens = _tokenizeEmbeddingText(vocab, text, nSeqCtx);
    final configuredBatchSize = contextParams.n_batch > 0
        ? contextParams.n_batch
        : tokens.length;
    final batchCapacity = math.max(
      1,
      math.min(configuredBatchSize, tokens.length),
    );
    final batch = llama_batch_init(batchCapacity, 0, 1);
    final embeddingSize = _resolveEmbeddingDimension(model.pointer);

    try {
      llama_synchronize(ctx.pointer);
      _clearContextMemory(ctx.pointer, strict: false);
      ctx.cachedPromptTokens = null;
      llama_set_embeddings(ctx.pointer, true);

      var decodedTokens = 0;
      while (decodedTokens < tokens.length) {
        final remaining = tokens.length - decodedTokens;
        final chunkTokenCount = math.min(batchCapacity, remaining);
        batch.n_tokens = chunkTokenCount;

        for (int i = 0; i < chunkTokenCount; i++) {
          final tokenIndex = decodedTokens + i;
          batch.token[i] = tokens[tokenIndex];
          batch.pos[i] = tokenIndex;
          batch.n_seq_id[i] = 1;
          batch.seq_id[i][0] = 0;
          batch.logits[i] = 1;
        }

        final status = useEncoderPath
            ? llama_encode(ctx.pointer, batch)
            : llama_decode(ctx.pointer, batch);
        if (status != 0) {
          throw Exception('Embedding forward pass failed');
        }

        decodedTokens += chunkTokenCount;
      }

      final poolingType = llama_pooling_type$1(ctx.pointer);
      Pointer<Float> embeddingPtr;
      if (poolingType == llama_pooling_type.LLAMA_POOLING_TYPE_NONE) {
        embeddingPtr = llama_get_embeddings_ith(
          ctx.pointer,
          batch.n_tokens - 1,
        );
        if (embeddingPtr == nullptr) {
          embeddingPtr = llama_get_embeddings(ctx.pointer);
        }
      } else {
        embeddingPtr = llama_get_embeddings_seq(ctx.pointer, 0);
        if (embeddingPtr == nullptr) {
          embeddingPtr = llama_get_embeddings(ctx.pointer);
        }
      }

      if (embeddingPtr == nullptr) {
        throw Exception('Embedding output is unavailable');
      }

      final vector = List<double>.from(
        embeddingPtr.asTypedList(embeddingSize),
        growable: false,
      );

      if (!normalize) {
        return vector;
      }

      return _normalizeEmbeddingVector(vector);
    } finally {
      llama_set_embeddings(ctx.pointer, false);
      llama_batch_free(batch);
    }
  }

  /// Generates embedding vectors for [texts] in input order.
  List<List<double>> embedBatch(
    int contextHandle,
    List<String> texts, {
    bool normalize = true,
  }) {
    if (texts.isEmpty) {
      return const <List<double>>[];
    }

    final ctx = _contexts[contextHandle];
    if (ctx == null) {
      throw Exception('Invalid context handle');
    }

    final modelHandle = _contextToModel[contextHandle];
    if (modelHandle == null) {
      throw Exception('Invalid context handle');
    }

    final model = _models[modelHandle];
    if (model == null) {
      throw Exception('Invalid model handle');
    }

    final contextParams = _contextParams[contextHandle];
    if (contextParams == null) {
      throw Exception('Missing context parameters');
    }

    final hasEncoder = llama_model_has_encoder(model.pointer);
    final hasDecoder = llama_model_has_decoder(model.pointer);
    if (hasEncoder && hasDecoder) {
      throw Exception(
        'Embedding extraction for encoder-decoder models is not supported',
      );
    }
    final useEncoderPath = hasEncoder && !hasDecoder;

    final poolingType = llama_pooling_type$1(ctx.pointer);
    final maxParallelSequences = llama_n_seq_max(ctx.pointer);
    if (poolingType == llama_pooling_type.LLAMA_POOLING_TYPE_NONE ||
        maxParallelSequences <= 1) {
      final fallbackVectors = <List<double>>[];
      for (final text in texts) {
        fallbackVectors.add(embed(contextHandle, text, normalize: normalize));
      }
      return fallbackVectors;
    }

    final vocab = llama_model_get_vocab(model.pointer);
    final nSeqCtx = llama_n_ctx_seq(ctx.pointer);
    final configuredBatchSize = contextParams.n_batch > 0
        ? contextParams.n_batch
        : llama_n_ctx(ctx.pointer);
    final batchCapacity = math.max(1, configuredBatchSize);
    final embeddingSize = _resolveEmbeddingDimension(model.pointer);

    final tokenizedInputs = <List<int>>[];
    for (final text in texts) {
      final tokens = _tokenizeEmbeddingText(vocab, text, nSeqCtx);
      tokenizedInputs.add(tokens);
    }

    final vectors = List<List<double>?>.filled(texts.length, null);

    int index = 0;
    while (index < texts.length) {
      final currentTokenCount = tokenizedInputs[index].length;

      if (currentTokenCount > batchCapacity) {
        vectors[index] = embed(
          contextHandle,
          texts[index],
          normalize: normalize,
        );
        index += 1;
        continue;
      }

      var groupTokenCount = 0;
      final groupStart = index;
      while (index < texts.length &&
          (index - groupStart) < maxParallelSequences) {
        final nextCount = tokenizedInputs[index].length;
        if (nextCount > batchCapacity) {
          break;
        }

        final nextTotal = groupTokenCount + nextCount;
        if (groupTokenCount > 0 && nextTotal > batchCapacity) {
          break;
        }

        groupTokenCount = nextTotal;
        index += 1;
      }

      if (groupStart == index) {
        vectors[index] = embed(
          contextHandle,
          texts[index],
          normalize: normalize,
        );
        index += 1;
        continue;
      }

      final groupSize = index - groupStart;
      final batch = llama_batch_init(groupTokenCount, 0, groupSize);
      try {
        llama_synchronize(ctx.pointer);
        _clearContextMemory(ctx.pointer, strict: false);
        ctx.cachedPromptTokens = null;
        llama_set_embeddings(ctx.pointer, true);

        batch.n_tokens = groupTokenCount;

        var tokenOffset = 0;
        for (int sequence = 0; sequence < groupSize; sequence++) {
          final tokens = tokenizedInputs[groupStart + sequence];
          for (int pos = 0; pos < tokens.length; pos++) {
            batch.token[tokenOffset] = tokens[pos];
            batch.pos[tokenOffset] = pos;
            batch.n_seq_id[tokenOffset] = 1;
            batch.seq_id[tokenOffset][0] = sequence;
            batch.logits[tokenOffset] = 1;
            tokenOffset += 1;
          }
        }

        final status = useEncoderPath
            ? llama_encode(ctx.pointer, batch)
            : llama_decode(ctx.pointer, batch);
        if (status != 0) {
          throw Exception('Batch embedding forward pass failed');
        }

        for (int sequence = 0; sequence < groupSize; sequence++) {
          var embeddingPtr = llama_get_embeddings_seq(ctx.pointer, sequence);
          if (embeddingPtr == nullptr && groupSize == 1) {
            embeddingPtr = llama_get_embeddings(ctx.pointer);
          }
          if (embeddingPtr == nullptr) {
            throw Exception('Batch embedding output is unavailable');
          }

          final vector = List<double>.from(
            embeddingPtr.asTypedList(embeddingSize),
            growable: false,
          );
          vectors[groupStart + sequence] = normalize
              ? _normalizeEmbeddingVector(vector)
              : vector;
        }
      } finally {
        llama_set_embeddings(ctx.pointer, false);
        llama_batch_free(batch);
      }
    }

    return vectors.map((vector) => vector!).toList(growable: false);
  }

  List<int> _tokenizeEmbeddingText(
    Pointer<llama_vocab> vocab,
    String text,
    int maxTokens,
  ) {
    final shouldAddSpecial = !_promptStartsWithBosToken(vocab, text);
    final textPtr = text.toNativeUtf8();

    final requiredTokenCount = -llama_tokenize(
      vocab,
      textPtr.cast(),
      textPtr.length,
      nullptr,
      0,
      shouldAddSpecial,
      true,
    );

    if (requiredTokenCount <= 0 || requiredTokenCount > maxTokens) {
      malloc.free(textPtr);
      throw Exception('Failed to tokenize embedding input');
    }

    final tokensPtr = malloc<Int32>(requiredTokenCount);
    try {
      final actualTokenCount = llama_tokenize(
        vocab,
        textPtr.cast(),
        textPtr.length,
        tokensPtr,
        requiredTokenCount,
        shouldAddSpecial,
        true,
      );
      if (actualTokenCount <= 0 || actualTokenCount > maxTokens) {
        throw Exception('Failed to encode embedding input');
      }

      return List<int>.from(tokensPtr.asTypedList(actualTokenCount));
    } finally {
      malloc.free(tokensPtr);
      malloc.free(textPtr);
    }
  }

  int _resolveEmbeddingDimension(Pointer<llama_model> modelPointer) {
    var embeddingSize = llama_model_n_embd_out(modelPointer);
    if (embeddingSize <= 0) {
      embeddingSize = llama_model_n_embd(modelPointer);
    }
    if (embeddingSize <= 0) {
      throw Exception('Failed to resolve embedding dimension');
    }
    return embeddingSize;
  }

  List<double> _normalizeEmbeddingVector(List<double> vector) {
    var normSquared = 0.0;
    for (final value in vector) {
      normSquared += value * value;
    }

    if (normSquared <= 0.0) {
      return vector;
    }

    final scale = 1.0 / math.sqrt(normSquared);
    final normalized = List<double>.filled(vector.length, 0.0, growable: false);
    for (int i = 0; i < vector.length; i++) {
      normalized[i] = vector[i] * scale;
    }
    return normalized;
  }

  /// Helper: Resets the context state to be ready for new generation.
  _LlamaContextWrapper _resetContext(
    int contextHandle,
    _LlamaContextWrapper ctx, {
    required bool clearMemory,
  }) {
    llama_synchronize(ctx.pointer);

    if (clearMemory) {
      _clearContextMemory(ctx.pointer);
      ctx.cachedPromptTokens = null;
    }

    _contexts[contextHandle] = ctx;
    return ctx;
  }

  void _clearContextMemory(
    Pointer<llama_context> contextPointer, {
    bool strict = true,
  }) {
    final memory = llama_get_memory(contextPointer);
    if (memory == nullptr) {
      if (strict) {
        throw Exception("Failed to reset context memory");
      }
      return;
    }

    llama_memory_clear(memory, true);
  }

  /// Helper: Ingests the prompt (text or multimodal) and returns initial token count.
  int _ingestPrompt(
    int contextHandle,
    int modelHandle,
    _LlamaContextWrapper ctx,
    llama_batch batch,
    Pointer<llama_vocab> vocab,
    String prompt,
    List<LlamaContentPart>? parts,
    Pointer<Int32> tokensPtr,
    int nCtx,
    llama_context_params modelParams, {
    required bool allowTextPromptReuse,
    required Pointer<llama_dart_mtp> mtpSession,
    required _MtpApi? mtpApi,
  }) {
    final mediaParts =
        parts
            ?.where((p) => p is LlamaImageContent || p is LlamaAudioContent)
            .toList() ??
        [];
    final mmHandle = _modelToMtmd[modelHandle];
    final mmCtx = mmHandle != null ? _mtmdContexts[mmHandle] : null;

    if (mediaParts.isNotEmpty && mmCtx != null) {
      return _ingestMultimodalPrompt(
        mmCtx,
        ctx,
        vocab,
        prompt,
        mediaParts,
        modelParams,
      );
    } else {
      return _ingestTextPrompt(
        batch,
        vocab,
        prompt,
        tokensPtr,
        nCtx,
        ctx,
        maxBatchTokens: modelParams.n_batch,
        allowPromptReuse: allowTextPromptReuse,
        mtpSession: mtpSession,
        mtpApi: mtpApi,
      );
    }
  }

  int _ingestMultimodalPrompt(
    Pointer<mtmd_context> mmCtx,
    _LlamaContextWrapper ctx,
    Pointer<llama_vocab> vocab,
    String prompt,
    List<LlamaContentPart> mediaParts,
    llama_context_params modelParams,
  ) {
    int initialTokens = 0;
    final bitmaps = malloc<Pointer<mtmd_bitmap>>(mediaParts.length);
    final chunks = _mtmdInputChunksInit();
    Pointer<mtmd_input_text> inputText = nullptr;
    Pointer<Utf8> promptPtr = nullptr;

    try {
      for (int i = 0; i < mediaParts.length; i++) {
        final p = mediaParts[i];
        bitmaps[i] = nullptr;
        if (p is LlamaImageContent) {
          if (p.path != null) {
            final pathPtr = p.path!.toNativeUtf8();
            bitmaps[i] = _mtmdHelperBitmapInitFromFile(mmCtx, pathPtr.cast());
            malloc.free(pathPtr);
          } else if (p.bytes != null) {
            final dataPtr = malloc<Uint8>(p.bytes!.length);
            dataPtr.asTypedList(p.bytes!.length).setAll(0, p.bytes!);
            bitmaps[i] = _mtmdHelperBitmapInitFromBuf(
              mmCtx,
              dataPtr.cast(),
              p.bytes!.length,
            );
            malloc.free(dataPtr);
          }
        } else if (p is LlamaAudioContent) {
          if (p.path != null) {
            final pathPtr = p.path!.toNativeUtf8();
            bitmaps[i] = _mtmdHelperBitmapInitFromFile(mmCtx, pathPtr.cast());
            malloc.free(pathPtr);
          } else if (p.bytes != null) {
            final dataPtr = malloc<Uint8>(p.bytes!.length);
            dataPtr.asTypedList(p.bytes!.length).setAll(0, p.bytes!);
            bitmaps[i] = _mtmdHelperBitmapInitFromBuf(
              mmCtx,
              dataPtr.cast(),
              p.bytes!.length,
            );
            malloc.free(dataPtr);
          } else if (p.samples != null) {
            final dataPtr = malloc<Float>(p.samples!.length);
            dataPtr.asTypedList(p.samples!.length).setAll(0, p.samples!);
            bitmaps[i] = _mtmdBitmapInitFromAudio(
              p.samples!.length,
              dataPtr.cast(),
            );
            malloc.free(dataPtr);
          }
        }

        if (bitmaps[i] == nullptr) {
          throw Exception("Failed to load media part $i");
        }
      }

      inputText = malloc<mtmd_input_text>();
      final normalizedPrompt = _normalizeMtmdPromptMarkers(
        prompt,
        mediaParts.length,
      );
      promptPtr = normalizedPrompt.toNativeUtf8();
      inputText.ref.text = promptPtr.cast();

      final bos = llama_vocab_bos(vocab);
      final eos = llama_vocab_eos(vocab);
      final shouldAddSpecial =
          (bos != eos && bos != -1) &&
          !_promptStartsWithBosToken(vocab, normalizedPrompt);
      inputText.ref.add_special = shouldAddSpecial;
      inputText.ref.parse_special = true;

      final res = _mtmdTokenize(
        mmCtx,
        chunks,
        inputText,
        bitmaps.cast(),
        mediaParts.length,
      );

      if (res == 0) {
        final newPast = malloc<llama_pos>();
        try {
          final evalResult = _mtmdHelperEvalChunks(
            mmCtx,
            ctx.pointer,
            chunks,
            0,
            0,
            modelParams.n_batch,
            true,
            newPast,
          );
          if (evalResult == 0) {
            initialTokens = newPast.value;
          } else {
            throw Exception(
              'Multimodal prompt evaluation failed: $evalResult. '
              'The active context window may be too small for this image and conversation history.',
            );
          }
        } finally {
          malloc.free(newPast);
        }
      } else {
        throw Exception("mtmd_tokenize failed: $res");
      }
    } finally {
      // Free in finally so a tokenize/eval failure above does not leak the
      // prompt buffer or the input-text struct.
      if (promptPtr != nullptr) malloc.free(promptPtr);
      if (inputText != nullptr) malloc.free(inputText);
      for (int i = 0; i < mediaParts.length; i++) {
        if (bitmaps[i] != nullptr) _mtmdBitmapFree(bitmaps[i]);
      }
      malloc.free(bitmaps);
      _mtmdInputChunksFree(chunks);
    }
    ctx.cachedPromptTokens = null;
    return initialTokens;
  }

  void _ensureLogitsAvailableAfterPromptEval(Pointer<llama_context> ctx) {
    if (llama_get_logits(ctx) != nullptr) {
      return;
    }

    throw Exception(
      'Prompt evaluation produced no logits for sampling. '
      'The active context window may be too small for this prompt or multimodal decode failed.',
    );
  }

  String _normalizeMtmdPromptMarkers(String prompt, int mediaPartCount) {
    final markerPtr = _mtmdDefaultMarker();
    final marker = markerPtr == nullptr
        ? '<__media__>'
        : markerPtr.cast<Utf8>().toDartString();

    var normalized = prompt;
    const directPlaceholders = [
      '<image>',
      '[IMG]',
      '<|image|>',
      '<|audio|>',
      '<|video|>',
      '<img>',
      '<|img|>',
      '<image_soft_token>',
      '<audio_soft_token>',
      '<video_soft_token>',
    ];

    for (final placeholder in directPlaceholders) {
      normalized = normalized.replaceAll(placeholder, marker);
    }

    // Some VLM templates index image placeholders (e.g. <|image_1|>).
    normalized = normalized.replaceAll(RegExp(r'<\|image_\d+\|>'), marker);

    if (mediaPartCount <= 0) {
      return normalized;
    }

    final markerCount = _countOccurrences(normalized, marker);
    if (markerCount < mediaPartCount) {
      final missing = mediaPartCount - markerCount;
      final markerBlock = List.filled(missing, marker).join(' ');

      if (normalized.contains('User:')) {
        normalized = normalized.replaceFirst('User:', 'User: $markerBlock ');
      } else if (normalized.contains('user:')) {
        normalized = normalized.replaceFirst('user:', 'user: $markerBlock ');
      } else {
        normalized = '$markerBlock\n$normalized';
      }
    }

    return normalized;
  }

  int _countOccurrences(String text, String pattern) {
    if (pattern.isEmpty) {
      return 0;
    }

    int count = 0;
    int start = 0;
    while (true) {
      final index = text.indexOf(pattern, start);
      if (index == -1) {
        break;
      }
      count++;
      start = index + pattern.length;
    }
    return count;
  }

  bool _promptStartsWithBosToken(Pointer<llama_vocab> vocab, String prompt) {
    final bos = llama_vocab_bos(vocab);
    if (bos < 0) {
      return false;
    }

    final bosPtr = llama_token_get_text(vocab, bos);
    if (bosPtr == nullptr) {
      return false;
    }

    final bosToken = bosPtr.cast<Utf8>().toDartString();
    if (bosToken.isEmpty) {
      return false;
    }

    return prompt.trimLeft().startsWith(bosToken);
  }

  int _ingestTextPrompt(
    llama_batch batch,
    Pointer<llama_vocab> vocab,
    String prompt,
    Pointer<Int32> tokensPtr,
    int nCtx,
    _LlamaContextWrapper ctx, {
    required int maxBatchTokens,
    required bool allowPromptReuse,
    required Pointer<llama_dart_mtp> mtpSession,
    required _MtpApi? mtpApi,
  }) {
    final promptPtr = prompt.toNativeUtf8();
    final shouldAddSpecial = !_promptStartsWithBosToken(vocab, prompt);
    final nTokens = llama_tokenize(
      vocab,
      promptPtr.cast(),
      promptPtr.length,
      tokensPtr,
      nCtx,
      shouldAddSpecial,
      true,
    );
    malloc.free(promptPtr);

    if (nTokens < 0 || nTokens > nCtx) {
      throw Exception("Tokenization failed or prompt too long");
    }

    if (!allowPromptReuse || nTokens == 0) {
      return _decodeAndCacheFullPrompt(
        batch,
        tokensPtr,
        ctx,
        nTokens,
        maxBatchTokens: maxBatchTokens,
        outputAllLogits: mtpSession != nullptr,
        mtpSession: mtpSession,
        mtpApi: mtpApi,
      );
    }

    final cachedTokens = ctx.cachedPromptTokens;
    if (cachedTokens == null || cachedTokens.isEmpty) {
      return _decodeAndCacheFullPrompt(
        batch,
        tokensPtr,
        ctx,
        nTokens,
        maxBatchTokens: maxBatchTokens,
        outputAllLogits: mtpSession != nullptr,
        mtpSession: mtpSession,
        mtpApi: mtpApi,
      );
    }

    final reusedPrefix = _sharedPrefixLength(cachedTokens, tokensPtr, nTokens);

    // Loaded KV holds no live logits; re-decode only the final token. Gated
    // on kvFromStateLoad so the in-process reuse path stays bit-exact against
    // a cleared baseline (parity property).
    final exactStateLoadMatch =
        ctx.kvFromStateLoad &&
        reusedPrefix == nTokens &&
        cachedTokens.length == nTokens;

    if (reusedPrefix <= 0 ||
        (reusedPrefix >= nTokens && !exactStateLoadMatch)) {
      final canReuseCachedCopy =
          reusedPrefix == nTokens && cachedTokens.length == nTokens;
      return _decodeAndCacheFullPrompt(
        batch,
        tokensPtr,
        ctx,
        nTokens,
        maxBatchTokens: maxBatchTokens,
        existingCachedTokens: canReuseCachedCopy ? cachedTokens : null,
        outputAllLogits: mtpSession != nullptr,
        mtpSession: mtpSession,
        mtpApi: mtpApi,
      );
    }

    final memory = llama_get_memory(ctx.pointer);
    if (memory == nullptr) {
      return _decodeAndCacheFullPrompt(
        batch,
        tokensPtr,
        ctx,
        nTokens,
        maxBatchTokens: maxBatchTokens,
        outputAllLogits: mtpSession != nullptr,
        mtpSession: mtpSession,
        mtpApi: mtpApi,
      );
    }

    final decodeStart = exactStateLoadMatch ? nTokens - 1 : reusedPrefix;

    final maxSeqPos = llama_memory_seq_pos_max(memory, 0);
    final removeTo = maxSeqPos >= decodeStart ? maxSeqPos + 1 : decodeStart;
    final removedTail = llama_memory_seq_rm(memory, 0, decodeStart, removeTo);
    if (!removedTail) {
      return _decodeAndCacheFullPrompt(
        batch,
        tokensPtr,
        ctx,
        nTokens,
        maxBatchTokens: maxBatchTokens,
        outputAllLogits: mtpSession != nullptr,
        mtpSession: mtpSession,
      );
    }

    final suffixTokenCount = nTokens - decodeStart;
    _decodePromptSegment(
      batch,
      tokensPtr,
      ctx,
      startTokenIndex: decodeStart,
      tokenCount: suffixTokenCount,
      maxBatchTokens: maxBatchTokens,
      outputAllLogits: mtpSession != nullptr,
      mtpSession: mtpSession,
      mtpApi: mtpApi,
    );

    ctx.cachedPromptTokens = exactStateLoadMatch
        ? cachedTokens
        : _copyPromptTokens(tokensPtr, nTokens);
    ctx.kvFromStateLoad = false;

    return nTokens;
  }

  int _decodeAndCacheFullPrompt(
    llama_batch batch,
    Pointer<Int32> tokensPtr,
    _LlamaContextWrapper ctx,
    int nTokens, {
    required int maxBatchTokens,
    List<int>? existingCachedTokens,
    bool outputAllLogits = false,
    Pointer<llama_dart_mtp>? mtpSession,
    _MtpApi? mtpApi,
  }) {
    _clearContextMemory(ctx.pointer);
    _decodePromptSegment(
      batch,
      tokensPtr,
      ctx,
      startTokenIndex: 0,
      tokenCount: nTokens,
      maxBatchTokens: maxBatchTokens,
      outputAllLogits: outputAllLogits,
      mtpSession: mtpSession,
      mtpApi: mtpApi,
    );
    ctx.cachedPromptTokens =
        existingCachedTokens ?? _copyPromptTokens(tokensPtr, nTokens);
    ctx.kvFromStateLoad = false;
    return nTokens;
  }

  List<int> _copyPromptTokens(Pointer<Int32> tokensPtr, int tokenCount) {
    if (tokenCount <= 0) {
      return const <int>[];
    }
    return List<int>.from(tokensPtr.asTypedList(tokenCount), growable: false);
  }

  void _decodePromptSegment(
    llama_batch batch,
    Pointer<Int32> tokensPtr,
    _LlamaContextWrapper ctx, {
    required int startTokenIndex,
    required int tokenCount,
    required int maxBatchTokens,
    bool outputAllLogits = false,
    Pointer<llama_dart_mtp>? mtpSession,
    _MtpApi? mtpApi,
  }) {
    if (tokenCount <= 0) {
      return;
    }

    final effectiveBatchTokens = maxBatchTokens > 0
        ? maxBatchTokens
        : tokenCount;
    var decoded = 0;

    while (decoded < tokenCount) {
      final remaining = tokenCount - decoded;
      final chunkTokenCount = remaining > effectiveBatchTokens
          ? effectiveBatchTokens
          : remaining;
      batch.n_tokens = chunkTokenCount;

      for (int i = 0; i < chunkTokenCount; i++) {
        final tokenIndex = startTokenIndex + decoded + i;
        batch.token[i] = tokensPtr[tokenIndex];
        batch.pos[i] = tokenIndex;
        batch.n_seq_id[i] = 1;
        batch.seq_id[i][0] = 0;
        final isLastTokenInPrompt = decoded + i == tokenCount - 1;
        batch.logits[i] = outputAllLogits || isLastTokenInPrompt ? 1 : 0;
      }

      if (llama_decode(ctx.pointer, batch) != 0) {
        throw Exception("Initial decode failed");
      }
      if (mtpSession != null &&
          mtpSession != nullptr &&
          !mtpApi!.processBatch(mtpSession, batch)) {
        throw Exception("MTP prompt decode processing failed");
      }

      decoded += chunkTokenCount;
    }
  }

  int _sharedPrefixLength(
    List<int> cachedTokens,
    Pointer<Int32> newTokens,
    int newTokenCount,
  ) {
    final maxLength = cachedTokens.length < newTokenCount
        ? cachedTokens.length
        : newTokenCount;
    int i = 0;
    while (i < maxLength && cachedTokens[i] == newTokens[i]) {
      i++;
    }
    return i;
  }

  /// Helper: Initializes the sampler chain.
  Pointer<llama_sampler> _initializeSampler(
    GenerationParams params,
    Pointer<llama_vocab> vocab,
    Pointer<Utf8> grammarPtr,
    Pointer<Utf8> rootPtr,
    _LazyGrammarConfig? lazyGrammarConfig,
    int initialTokens,
    Pointer<Int32> tokensPtr,
  ) {
    final sampler = llama_sampler_chain_init(
      llama_sampler_chain_default_params(),
    );

    llama_sampler_chain_add(
      sampler,
      llama_sampler_init_penalties(64, params.penalty, 0.0, 0.0),
    );

    if (grammarPtr != nullptr) {
      if (params.grammarLazy && lazyGrammarConfig != null) {
        llama_sampler_chain_add(
          sampler,
          llama_sampler_init_grammar_lazy_patterns(
            vocab,
            grammarPtr.cast(),
            rootPtr.cast(),
            lazyGrammarConfig.triggerPatterns,
            lazyGrammarConfig.numTriggerPatterns,
            lazyGrammarConfig.triggerTokens,
            lazyGrammarConfig.numTriggerTokens,
          ),
        );
      } else {
        llama_sampler_chain_add(
          sampler,
          llama_sampler_init_grammar(vocab, grammarPtr.cast(), rootPtr.cast()),
        );
      }
    }

    llama_sampler_chain_add(sampler, llama_sampler_init_top_k(params.topK));
    llama_sampler_chain_add(sampler, llama_sampler_init_top_p(params.topP, 1));
    if (params.minP > 0) {
      llama_sampler_chain_add(
        sampler,
        llama_sampler_init_min_p(params.minP, 1),
      );
    }
    llama_sampler_chain_add(sampler, llama_sampler_init_temp(params.temp));

    if (params.temp <= 0) {
      llama_sampler_chain_add(sampler, llama_sampler_init_greedy());
    } else {
      final seed = params.seed ?? DateTime.now().millisecondsSinceEpoch;
      llama_sampler_chain_add(sampler, llama_sampler_init_dist(seed));
    }

    if (grammarPtr == nullptr && tokensPtr != nullptr && initialTokens > 0) {
      for (int i = 0; i < initialTokens; i++) {
        llama_sampler_accept(sampler, tokensPtr[i]);
      }
    }

    return sampler;
  }

  /// Helper: Runs the main inference loop and yields tokens.
  Stream<List<int>> _runInferenceLoop(
    _LlamaContextWrapper ctx,
    llama_batch batch,
    Pointer<llama_vocab> vocab,
    Pointer<llama_sampler> sampler,
    GenerationParams params,
    int startPos,
    int nCtx,
    int cancelTokenAddress,
    Pointer<Uint8> pieceBuf,
    Pointer<Utf8> grammarPtr,
    Set<int> preservedTokenIds,
    List<String> stopSequences,
  ) async* {
    final cancelToken = Pointer<Int8>.fromAddress(cancelTokenAddress);
    int currentPos = startPos;
    final accumulatedBytes = <int>[];
    final evalStopwatch = Stopwatch()..start();
    var sampleMicros = 0;
    var evalMicros = 0;
    var generatedTokens = 0;

    for (int i = 0; i < params.maxTokens; i++) {
      if (cancelToken.value == 1) break;
      if (currentPos >= nCtx) break;

      final sampleTick = Stopwatch()..start();
      final selectedToken = llama_sampler_sample(sampler, ctx.pointer, -1);
      sampleTick.stop();
      sampleMicros += sampleTick.elapsedMicroseconds;
      if (llama_vocab_is_eog(vocab, selectedToken)) break;

      final pieceTick = Stopwatch()..start();
      final n = llama_token_to_piece(
        vocab,
        selectedToken,
        pieceBuf.cast(),
        256,
        0,
        preservedTokenIds.contains(selectedToken),
      );
      pieceTick.stop();
      sampleMicros += pieceTick.elapsedMicroseconds;

      if (n > 0) {
        final bytes = pieceBuf.asTypedList(n).toList();
        yield bytes;
        generatedTokens++;

        if (stopSequences.isNotEmpty) {
          accumulatedBytes.addAll(bytes);
          if (accumulatedBytes.length > 64) {
            accumulatedBytes.removeRange(0, accumulatedBytes.length - 64);
          }
          final text = utf8.decode(accumulatedBytes, allowMalformed: true);
          if (stopSequences.any((s) => text.endsWith(s))) break;
        }
      }

      batch.n_tokens = 1;
      batch.token[0] = selectedToken;
      batch.pos[0] = currentPos++;
      batch.n_seq_id[0] = 1;
      batch.seq_id[0][0] = 0;
      batch.logits[0] = 1;

      final evalTick = Stopwatch()..start();
      final decodeStatus = llama_decode(ctx.pointer, batch);
      evalTick.stop();
      evalMicros += evalTick.elapsedMicroseconds;
      if (decodeStatus != 0) break;
    }

    evalStopwatch.stop();
    ctx.lastPerfEvalMs = evalMicros / 1000.0;
    ctx.lastPerfSampleMs = sampleMicros / 1000.0;
    ctx.lastPerfEvalTokens = generatedTokens;
    ctx.lastPerfSampleCount = generatedTokens;
  }

  Stream<List<int>> _runMtpInferenceLoop(
    _LlamaContextWrapper ctx,
    llama_batch batch,
    Pointer<llama_vocab> vocab,
    Pointer<llama_sampler> sampler,
    GenerationParams params,
    _LlamaCppMtpConfig mtpConfig,
    int startPos,
    int nCtx,
    int cancelTokenAddress,
    Pointer<Uint8> pieceBuf,
    Set<int> preservedTokenIds,
    List<String> stopSequences,
    Pointer<llama_dart_mtp> mtpSession,
    _MtpApi mtpApi,
    Pointer<Int32> tokensPtr,
  ) async* {
    final cancelToken = Pointer<Int8>.fromAddress(cancelTokenAddress);
    final draftCapacity = mtpConfig.draftTokenMax;
    final draftPtr = malloc<Int32>(draftCapacity);
    final idxPtr = malloc<Int32>(draftCapacity + 1);
    final acceptedPtr = malloc<Int32>(draftCapacity + 1);

    int currentPos = startPos;
    int? pendingSampledToken;
    final accumulatedBytes = <int>[];
    final evalStopwatch = Stopwatch()..start();
    var sampleMicros = 0;
    var evalMicros = 0;
    var generatedTokens = 0;
    var shouldStop = false;

    try {
      while (!shouldStop && generatedTokens < params.maxTokens) {
        if (cancelToken.value == 1) break;
        if (currentPos >= nCtx) break;

        int selectedToken;
        if (pendingSampledToken != null) {
          selectedToken = pendingSampledToken;
          pendingSampledToken = null;
        } else {
          final sampleTick = Stopwatch()..start();
          selectedToken = llama_sampler_sample(sampler, ctx.pointer, -1);
          sampleTick.stop();
          sampleMicros += sampleTick.elapsedMicroseconds;
          if (llama_vocab_is_eog(vocab, selectedToken)) break;

          final pieceTick = Stopwatch()..start();
          final n = llama_token_to_piece(
            vocab,
            selectedToken,
            pieceBuf.cast(),
            256,
            0,
            preservedTokenIds.contains(selectedToken),
          );
          pieceTick.stop();
          sampleMicros += pieceTick.elapsedMicroseconds;
          generatedTokens++;

          if (n > 0) {
            final bytes = pieceBuf.asTypedList(n).toList();
            yield bytes;
            if (stopSequences.isNotEmpty) {
              accumulatedBytes.addAll(bytes);
              if (accumulatedBytes.length > 64) {
                accumulatedBytes.removeRange(0, accumulatedBytes.length - 64);
              }
              final text = utf8.decode(accumulatedBytes, allowMalformed: true);
              if (stopSequences.any((s) => text.endsWith(s))) {
                shouldStop = true;
              }
            }
          }

          if (shouldStop || generatedTokens >= params.maxTokens) {
            break;
          }
        }

        final remainingToGenerate = params.maxTokens - generatedTokens;
        final batchCapacity = math.max(1, llama_n_batch(ctx.pointer));
        final rollbackCapacity = llama_n_rs_seq(ctx.pointer);
        final contextDraftCapacity = rollbackCapacity > 0
            ? math.min(nCtx - currentPos - 2, rollbackCapacity)
            : nCtx - currentPos - 2;
        final draftLimit = math.min(
          mtpConfig.draftTokenMax,
          math.min(
            math.min(remainingToGenerate - 1, contextDraftCapacity),
            batchCapacity - 1,
          ),
        );

        var draftCount = 0;
        if (draftLimit > 0) {
          final draftTick = Stopwatch()..start();
          draftCount = mtpApi.draft(
            mtpSession,
            0,
            currentPos,
            selectedToken,
            tokensPtr,
            currentPos,
            draftLimit,
            draftPtr,
            draftCapacity,
          );
          draftTick.stop();
          sampleMicros += draftTick.elapsedMicroseconds;
          if (draftCount < 0) {
            throw Exception("llama.cpp MTP draft failed");
          }
        }

        if (draftCount <= 0) {
          batch.n_tokens = 1;
          batch.token[0] = selectedToken;
          batch.pos[0] = currentPos;
          batch.n_seq_id[0] = 1;
          batch.seq_id[0][0] = 0;
          batch.logits[0] = 1;

          final evalTick = Stopwatch()..start();
          final decodeStatus = llama_decode(ctx.pointer, batch);
          if (decodeStatus == 0 && !mtpApi.processBatch(mtpSession, batch)) {
            throw Exception("MTP decode processing failed");
          }
          evalTick.stop();
          evalMicros += evalTick.elapsedMicroseconds;
          if (decodeStatus != 0) break;

          tokensPtr[currentPos] = selectedToken;
          currentPos++;
          continue;
        }

        final draftContext = mtpApi.getDraftContext(mtpSession);
        final draftMemory = draftContext == nullptr
            ? nullptr
            : llama_get_memory(draftContext);
        if (draftMemory == nullptr ||
            !llama_memory_seq_rm(draftMemory, 0, currentPos, -1)) {
          throw UnsupportedError(
            'llama.cpp MTP draft rollback failed for this context.',
          );
        }

        final batchTokens = draftCount + 1;
        batch.n_tokens = batchTokens;
        batch.token[0] = selectedToken;
        batch.pos[0] = currentPos;
        batch.n_seq_id[0] = 1;
        batch.seq_id[0][0] = 0;
        batch.logits[0] = 1;
        for (int i = 0; i < draftCount; i++) {
          final batchIndex = i + 1;
          batch.token[batchIndex] = draftPtr[i];
          batch.pos[batchIndex] = currentPos + batchIndex;
          batch.n_seq_id[batchIndex] = 1;
          batch.seq_id[batchIndex][0] = 0;
          batch.logits[batchIndex] = 1;
        }

        final evalTick = Stopwatch()..start();
        final decodeStatus = llama_decode(ctx.pointer, batch);
        if (decodeStatus == 0 && !mtpApi.processBatch(mtpSession, batch)) {
          throw Exception("MTP decode processing failed");
        }
        evalTick.stop();
        evalMicros += evalTick.elapsedMicroseconds;
        if (decodeStatus != 0) break;

        for (int i = 0; i < batchTokens; i++) {
          idxPtr[i] = i;
        }

        final verifyTick = Stopwatch()..start();
        final acceptedCount = mtpApi.sampleAndAcceptN(
          sampler,
          ctx.pointer,
          idxPtr,
          batchTokens,
          draftPtr,
          draftCount,
          acceptedPtr,
          batchTokens,
        );
        verifyTick.stop();
        sampleMicros += verifyTick.elapsedMicroseconds;
        if (acceptedCount <= 0) {
          throw Exception("llama.cpp MTP draft verification failed");
        }

        final acceptedDraftCount = acceptedCount - 1;
        mtpApi.accept(mtpSession, 0, acceptedDraftCount);

        final keepUntil = currentPos + 1 + acceptedDraftCount;
        final targetMemory = llama_get_memory(ctx.pointer);
        if (targetMemory == nullptr ||
            !llama_memory_seq_rm(targetMemory, 0, keepUntil, -1) ||
            !llama_memory_seq_rm(draftMemory, 0, keepUntil, -1)) {
          throw UnsupportedError(
            'llama.cpp MTP target rollback failed for this context.',
          );
        }

        tokensPtr[currentPos] = selectedToken;
        for (int i = 0; i < acceptedDraftCount; i++) {
          tokensPtr[currentPos + 1 + i] = acceptedPtr[i];
        }
        currentPos = keepUntil;

        for (int i = 0; i < acceptedCount; i++) {
          final token = acceptedPtr[i];
          if (llama_vocab_is_eog(vocab, token)) {
            shouldStop = true;
            break;
          }

          final pieceTick = Stopwatch()..start();
          final n = llama_token_to_piece(
            vocab,
            token,
            pieceBuf.cast(),
            256,
            0,
            preservedTokenIds.contains(token),
          );
          pieceTick.stop();
          sampleMicros += pieceTick.elapsedMicroseconds;
          generatedTokens++;

          if (n > 0) {
            final bytes = pieceBuf.asTypedList(n).toList();
            yield bytes;
            if (stopSequences.isNotEmpty) {
              accumulatedBytes.addAll(bytes);
              if (accumulatedBytes.length > 64) {
                accumulatedBytes.removeRange(0, accumulatedBytes.length - 64);
              }
              final text = utf8.decode(accumulatedBytes, allowMalformed: true);
              if (stopSequences.any((s) => text.endsWith(s))) {
                shouldStop = true;
              }
            }
          }

          if (shouldStop || generatedTokens >= params.maxTokens) {
            break;
          }
        }

        if (!shouldStop && generatedTokens < params.maxTokens) {
          pendingSampledToken = acceptedPtr[acceptedCount - 1];
        }
      }
    } finally {
      malloc.free(draftPtr);
      malloc.free(idxPtr);
      malloc.free(acceptedPtr);
      evalStopwatch.stop();
      ctx.lastPerfEvalMs = evalMicros / 1000.0;
      ctx.lastPerfSampleMs = sampleMicros / 1000.0;
      ctx.lastPerfEvalTokens = generatedTokens;
      ctx.lastPerfSampleCount = generatedTokens;
    }
  }

  _LazyGrammarConfig? _buildLazyGrammarConfig(GenerationParams params) {
    final triggerPatterns = <String>[];
    final triggerTokens = <int>[];

    for (final trigger in params.grammarTriggers) {
      switch (trigger.type) {
        case 0:
          triggerPatterns.add(_regexEscape(trigger.value));
          break;
        case 1:
          final token = trigger.token ?? int.tryParse(trigger.value);
          if (token != null) {
            triggerTokens.add(token);
          }
          break;
        case 2:
          triggerPatterns.add(trigger.value);
          break;
        case 3:
          final pattern = trigger.value;
          final anchored = pattern.isEmpty
              ? r'^$'
              : "${pattern.startsWith('^') ? '' : '^'}$pattern${pattern.endsWith(r'$') ? '' : r'$'}";
          triggerPatterns.add(anchored);
          break;
      }
    }

    if (triggerPatterns.isEmpty && triggerTokens.isEmpty) {
      return null;
    }

    final allocatedPatternPtrs = triggerPatterns
        .map((pattern) => pattern.toNativeUtf8())
        .toList(growable: false);

    final triggerPatternsPtr = allocatedPatternPtrs.isEmpty
        ? nullptr
        : malloc<Pointer<Char>>(allocatedPatternPtrs.length);

    if (triggerPatternsPtr != nullptr) {
      for (var i = 0; i < allocatedPatternPtrs.length; i++) {
        triggerPatternsPtr[i] = allocatedPatternPtrs[i].cast();
      }
    }

    final triggerTokensPtr = triggerTokens.isEmpty
        ? nullptr
        : malloc<llama_token>(triggerTokens.length);

    if (triggerTokensPtr != nullptr) {
      for (var i = 0; i < triggerTokens.length; i++) {
        triggerTokensPtr[i] = triggerTokens[i];
      }
    }

    return _LazyGrammarConfig(
      triggerPatterns: triggerPatternsPtr,
      numTriggerPatterns: allocatedPatternPtrs.length,
      triggerTokens: triggerTokensPtr,
      numTriggerTokens: triggerTokens.length,
      allocatedPatternPointers: allocatedPatternPtrs,
    );
  }

  Set<int> _resolvePreservedTokenIds(
    Pointer<llama_vocab> vocab,
    List<String> preservedTokens,
  ) {
    if (preservedTokens.isEmpty) {
      return const <int>{};
    }

    final ids = <int>{};
    for (final tokenText in preservedTokens) {
      if (tokenText.isEmpty) {
        continue;
      }

      final textPtr = tokenText.toNativeUtf8();
      try {
        final required = -llama_tokenize(
          vocab,
          textPtr.cast(),
          textPtr.length,
          nullptr,
          0,
          false,
          true,
        );

        if (required <= 0) {
          continue;
        }

        final tokenIds = malloc<Int32>(required);
        try {
          final actual = llama_tokenize(
            vocab,
            textPtr.cast(),
            textPtr.length,
            tokenIds,
            required,
            false,
            true,
          );

          if (actual > 0) {
            for (int i = 0; i < actual; i++) {
              ids.add(tokenIds[i]);
            }
          }
        } finally {
          malloc.free(tokenIds);
        }
      } finally {
        malloc.free(textPtr);
      }
    }

    return ids;
  }

  List<String> _effectiveStopSequences(
    List<String> stopSequences,
    List<String> preservedTokens,
  ) {
    if (stopSequences.isEmpty || preservedTokens.isEmpty) {
      return stopSequences;
    }

    final preservedSet = preservedTokens.toSet();
    return stopSequences
        .where((sequence) => !preservedSet.contains(sequence))
        .toList(growable: false);
  }

  String _regexEscape(String input) {
    final escaped = StringBuffer();
    const regexMeta = r'\^$.*+?()[]{}|';
    for (var i = 0; i < input.length; i++) {
      final char = input[i];
      if (regexMeta.contains(char)) {
        escaped.write('\\');
      }
      escaped.write(char);
    }
    return escaped.toString();
  }

  /// Tokenizes the given [text].
  List<int> tokenize(int modelHandle, String text, bool addSpecial) {
    final model = _models[modelHandle];
    if (model == null) return [];
    final vocab = llama_model_get_vocab(model.pointer);
    final textPtr = text.toNativeUtf8();
    final shouldAddSpecial =
        addSpecial && !_promptStartsWithBosToken(vocab, text);
    final n = -llama_tokenize(
      vocab,
      textPtr.cast(),
      textPtr.length,
      nullptr,
      0,
      shouldAddSpecial,
      true,
    );
    final tokensPtr = malloc<Int32>(n);
    final actual = llama_tokenize(
      vocab,
      textPtr.cast(),
      textPtr.length,
      tokensPtr,
      n,
      shouldAddSpecial,
      true,
    );
    final result = List.generate(actual, (i) => tokensPtr[i]);
    malloc.free(textPtr);
    malloc.free(tokensPtr);
    return result;
  }

  /// Detokenizes the given [tokens].
  String detokenize(int modelHandle, List<int> tokens, bool special) {
    final model = _models[modelHandle];
    if (model == null) return "";
    final vocab = llama_model_get_vocab(model.pointer);
    final buffer = malloc<Int8>(256);
    final bytes = <int>[];
    for (final t in tokens) {
      final n = llama_token_to_piece(vocab, t, buffer.cast(), 256, 0, special);
      if (n > 0) bytes.addAll(buffer.asTypedList(n));
    }
    malloc.free(buffer);
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// Persists the KV-cache state of [contextHandle] to [path] together
  /// with the producing token sequence so a later [stateLoadFile] can
  /// resume inference without paying the prompt-eval cost again.
  ///
  /// Wraps `llama_state_save_file`. Returns true on success.
  bool stateSaveFile(int contextHandle, String path, List<int> tokens) {
    final ctx = _contexts[contextHandle];
    if (ctx == null) {
      throw StateError('Unknown context handle: $contextHandle');
    }
    if (_generatingContexts.containsKey(contextHandle)) {
      throw StateError(
        'Cannot save state while generation is active on context $contextHandle',
      );
    }
    llama_synchronize(ctx.pointer);
    final pathPtr = path.toNativeUtf8();
    final tokensPtr = tokens.isEmpty ? nullptr : malloc<Int32>(tokens.length);
    try {
      for (int i = 0; i < tokens.length; i++) {
        tokensPtr[i] = tokens[i];
      }
      return llama_state_save_file(
        ctx.pointer,
        pathPtr.cast(),
        tokensPtr,
        tokens.length,
      );
    } finally {
      malloc.free(pathPtr);
      if (tokensPtr != nullptr) malloc.free(tokensPtr);
    }
  }

  /// Restores a previously saved KV-cache state into [contextHandle].
  /// [tokenCapacity] caps the number of tokens read back.
  ///
  /// Wraps `llama_state_load_file`. Throws on failure (corrupt file,
  /// schema mismatch, etc.).
  List<int> stateLoadFile(int contextHandle, String path, int tokenCapacity) {
    final ctx = _contexts[contextHandle];
    if (ctx == null) {
      throw StateError('Unknown context handle: $contextHandle');
    }
    if (_generatingContexts.containsKey(contextHandle)) {
      throw StateError(
        'Cannot load state while generation is active on context $contextHandle',
      );
    }
    if (tokenCapacity <= 0) {
      throw ArgumentError.value(
        tokenCapacity,
        'tokenCapacity',
        'must be positive',
      );
    }
    final contextCapacity = llama_n_ctx(ctx.pointer);
    if (tokenCapacity > contextCapacity) {
      throw ArgumentError.value(
        tokenCapacity,
        'tokenCapacity',
        'must not exceed context size ($contextCapacity)',
      );
    }
    llama_synchronize(ctx.pointer);
    final pathPtr = path.toNativeUtf8();
    final tokensPtr = malloc<Int32>(tokenCapacity);
    final countPtr = malloc<Size>();
    try {
      countPtr.value = 0;
      final ok = llama_state_load_file(
        ctx.pointer,
        pathPtr.cast(),
        tokensPtr,
        tokenCapacity,
        countPtr,
      );
      if (!ok) {
        throw StateError(
          'llama_state_load_file failed for "$path" '
          '(corrupt file, version mismatch, or capacity too small)',
        );
      }
      final actual = countPtr.value;
      if (actual > tokenCapacity) {
        throw StateError(
          'llama_state_load_file returned actual=$actual '
          'exceeding capacity=$tokenCapacity',
        );
      }
      final loaded = List<int>.generate(actual, (i) => tokensPtr[i]);
      ctx.cachedPromptTokens = loaded;
      ctx.kvFromStateLoad = true;
      return loaded;
    } finally {
      malloc.free(pathPtr);
      malloc.free(tokensPtr);
      malloc.free(countPtr);
    }
  }

  /// Returns metadata for the specified [modelHandle].
  Map<String, String> getMetadata(int modelHandle) {
    final model = _models[modelHandle];
    if (model == null) return {};
    final metadata = <String, String>{};
    final keyBuf = malloc<Int8>(1024);
    final valBuf = malloc<Int8>(1024 * 64);
    final n = llama_model_meta_count(model.pointer);
    for (int i = 0; i < n; i++) {
      llama_model_meta_key_by_index(model.pointer, i, keyBuf.cast(), 1024);
      llama_model_meta_val_str_by_index(
        model.pointer,
        i,
        valBuf.cast(),
        1024 * 64,
      );
      metadata[keyBuf.cast<Utf8>().toDartString()] = valBuf
          .cast<Utf8>()
          .toDartString();
    }
    malloc.free(keyBuf);
    malloc.free(valBuf);
    return metadata;
  }

  /// Handles LoRA adapter operations.
  void handleLora(int contextHandle, String? path, double? scale, String op) {
    final ctx = _contexts[contextHandle];
    final modelHandle = _contextToModel[contextHandle];
    if (ctx == null || modelHandle == null) return;

    final modelAdapters = _loraAdapters[modelHandle];
    final activeLoras = _activeLoras[contextHandle];
    if (modelAdapters == null || activeLoras == null) return;

    try {
      if (op == 'set') {
        if (path == null) {
          throw Exception('LoRA path is required for set operation');
        }
        if (scale == null) {
          throw Exception('LoRA scale is required for set operation');
        }

        var adapter = modelAdapters[path];
        if (adapter == null) {
          final pathPtr = path.toNativeUtf8();
          final adapterPtr = llama_adapter_lora_init(
            _models[modelHandle]!.pointer,
            pathPtr.cast(),
          );
          malloc.free(pathPtr);
          if (adapterPtr == nullptr) {
            throw Exception("Failed to load LoRA at $path");
          }
          adapter = _LlamaLoraWrapper(adapterPtr);
          modelAdapters[path] = adapter;
        }
        activeLoras[path] = scale;
        _applyActiveLoras(ctx.pointer, modelAdapters, activeLoras);
        ctx.cachedPromptTokens = null;
      } else if (op == 'remove') {
        if (path == null) {
          throw Exception('LoRA path is required for remove operation');
        }
        activeLoras.remove(path);
        _applyActiveLoras(ctx.pointer, modelAdapters, activeLoras);
        ctx.cachedPromptTokens = null;
      } else if (op == 'clear') {
        activeLoras.clear();
        _applyActiveLoras(ctx.pointer, modelAdapters, activeLoras);
        ctx.cachedPromptTokens = null;
      } else {
        throw Exception('Unknown LoRA operation: $op');
      }
    } catch (e) {
      rethrow;
    }
  }

  void _applyActiveLoras(
    Pointer<llama_context> context,
    Map<String, _LlamaLoraWrapper> loadedAdapters,
    Map<String, double> activeLoras,
  ) {
    if (activeLoras.isEmpty) {
      final result = llama_set_adapters_lora(context, nullptr, 0, nullptr);
      if (result != 0) {
        throw Exception('Failed to clear LoRA adapters (code: $result)');
      }
      return;
    }

    final activeEntries = activeLoras.entries.toList(growable: false);
    final adapterPointers = malloc<Pointer<llama_adapter_lora>>(
      activeEntries.length,
    );
    final scalesPointer = malloc<Float>(activeEntries.length);

    try {
      for (var i = 0; i < activeEntries.length; i++) {
        final entry = activeEntries[i];
        final adapter = loadedAdapters[entry.key];
        if (adapter == null) {
          throw Exception(
            'LoRA adapter not loaded for active path: ${entry.key}',
          );
        }
        adapterPointers[i] = adapter.pointer;
        scalesPointer[i] = entry.value;
      }

      final result = llama_set_adapters_lora(
        context,
        adapterPointers,
        activeEntries.length,
        scalesPointer,
      );
      if (result != 0) {
        throw Exception('Failed to apply LoRA adapters (code: $result)');
      }
    } finally {
      malloc.free(adapterPointers);
      malloc.free(scalesPointer);
    }
  }

  /// Returns the currently active backend name.
  String getActiveBackendName() {
    return _activeBackendName;
  }

  /// Returns resolved GPU layers for the active model load.
  int? getResolvedGpuLayers() {
    if (_models.isEmpty) {
      return null;
    }
    return _activeResolvedGpuLayers;
  }

  /// Returns backend names available for selection.
  ///
  /// This path avoids optional GPU backend initialization and is intended for
  /// settings/selector UIs.
  List<String> getAvailableBackendInfo() {
    final available = <String>{};
    final backendModuleDirectory = _backendModuleDirectory;

    if (backendModuleDirectory != null) {
      const backendCandidates = <String>[
        'cpu',
        'vulkan',
        'opencl',
        'metal',
        'cuda',
        'hip',
        'blas',
      ];

      for (final backend in backendCandidates) {
        if (_isBackendModuleBundled(backend)) {
          available.add(_backendDisplayName(backend));
        }
      }
    }

    if (available.isEmpty) {
      available.addAll(getBackendInfo());
    }

    if (available.isEmpty) {
      available.add(_backendDisplayName('cpu'));
    }

    final ordered = available.toList(growable: false)
      ..sort((a, b) {
        final aOrder = _backendDisplaySortKey(a);
        final bOrder = _backendDisplaySortKey(b);
        if (aOrder != bOrder) {
          return aOrder.compareTo(bOrder);
        }
        return a.compareTo(b);
      });
    return ordered;
  }

  static int _backendDisplaySortKey(String backendName) {
    switch (backendName.toUpperCase()) {
      case 'CPU':
        return 0;
      case 'METAL':
        return 1;
      case 'VULKAN':
        return 2;
      case 'OPENCL':
        return 3;
      case 'HIP':
        return 4;
      case 'CUDA':
        return 5;
      case 'BLAS':
        return 6;
      default:
        return 99;
    }
  }

  /// Returns information about currently initialized backend devices.
  List<String> getBackendInfo() {
    final count = _ggmlBackendDevCount();
    final devices = <String>{};
    for (var i = 0; i < count; i++) {
      final dev = _ggmlBackendDevGet(i);
      if (dev == nullptr) continue;

      final devNamePtr = _ggmlBackendDevName(dev);
      if (devNamePtr == nullptr) continue;
      final devName = devNamePtr.cast<Utf8>().toDartString();

      String label = devName;
      final reg = _ggmlBackendDevBackendReg(dev);
      if (reg != nullptr) {
        final regNamePtr = _ggmlBackendRegName(reg);
        if (regNamePtr != nullptr) {
          final regName = regNamePtr.cast<Utf8>().toDartString();
          if (regName.toLowerCase() == devName.toLowerCase()) {
            label = regName;
          } else {
            label = '$regName ($devName)';
          }
        }
      }

      devices.add(label);
    }
    if (devices.isNotEmpty) {
      return devices.toList(growable: false);
    }

    // Fallback when device-enumeration symbols are unavailable: surface loaded
    // backend modules so UI can still present selectable backends.
    final moduleBackends =
        _loadedBackendModules
            .map(_backendDisplayName)
            .where((name) => name.isNotEmpty)
            .toSet()
            .toList(growable: false)
          ..sort();
    return moduleBackends;
  }

  static String _backendDisplayName(String backend) {
    switch (backend.toLowerCase()) {
      case 'cpu':
        return 'CPU';
      case 'vulkan':
        return 'Vulkan';
      case 'opencl':
        return 'OpenCL';
      case 'metal':
        return 'Metal';
      case 'cuda':
        return 'CUDA';
      case 'hip':
        return 'HIP';
      case 'blas':
        return 'BLAS';
      default:
        return backend;
    }
  }

  /// Returns whether GPU offloading is supported.
  bool getGpuSupport() {
    return llama_supports_gpu_offload();
  }

  /// Disposes of all resources managed by the service.
  void dispose() {
    for (final c in _contexts.values) {
      c.dispose();
    }
    _contexts.clear();
    for (final m in _models.values) {
      m.dispose();
    }
    _models.clear();
    _modelBackendNames.clear();
    _modelResolvedGpuLayers.clear();
    _activeBackendName = _backendDisplayName('cpu');
    _activeResolvedGpuLayers = 0;
    for (final m in _mtmdContexts.values) {
      _mtmdFree(m);
    }
    _mtmdContexts.clear();
    _modelToMtmd.clear();
    _modelToMtmdUseGpu.clear();
    // llama_backend_free(); // DISABLED: Prevents race conditions with other isolates
  }

  /// Creates a multimodal context (projector) for the model.
  int createMultimodalContext(int modelHandle, String mmProjPath) {
    final model = _models[modelHandle];
    if (model == null) {
      throw Exception("Invalid model handle");
    }
    _applyConfiguredLogLevel();

    final mmProjPathPtr = mmProjPath.toNativeUtf8();
    Pointer<mtmd_context> mmCtx = nullptr;
    try {
      final ctxParams = _mtmdContextParamsDefault();
      ctxParams.use_gpu = _modelToMtmdUseGpu[modelHandle] ?? true;
      mmCtx = _mtmdInitFromFile(mmProjPathPtr.cast(), model.pointer, ctxParams);
    } finally {
      malloc.free(mmProjPathPtr);
    }

    if (mmCtx == nullptr) {
      throw Exception("Failed to load multimodal projector");
    }

    final handle = _getHandle();
    _mtmdContexts[handle] = mmCtx;
    _modelToMtmd[modelHandle] = handle;
    return handle;
  }

  /// Frees the multimodal context (projector).
  void freeMultimodalContext(int mmContextHandle) {
    final mmCtx = _mtmdContexts.remove(mmContextHandle);
    if (mmCtx != null) {
      _mtmdFree(mmCtx);
      _modelToMtmd.removeWhere((k, v) => v == mmContextHandle);
    }
  }

  Pointer<Char> _mtmdDefaultMarker() {
    if (!_mtmdPrimarySymbolsUnavailable) {
      try {
        return mtmd_default_marker();
      } on ArgumentError {
        _mtmdPrimarySymbolsUnavailable = true;
      }
    }
    final fallback = _resolveMtmdFallbackApi();
    return fallback?.defaultMarker() ?? nullptr;
  }

  mtmd_context_params _mtmdContextParamsDefault() {
    if (!_mtmdPrimarySymbolsUnavailable) {
      try {
        return mtmd_context_params_default();
      } on ArgumentError {
        _mtmdPrimarySymbolsUnavailable = true;
      }
    }
    final fallback = _resolveMtmdFallbackApi();
    if (fallback == null) {
      throw Exception(_mtmdUnavailableMessage('mtmd_context_params_default'));
    }
    return fallback.contextParamsDefault();
  }

  Pointer<mtmd_context> _mtmdInitFromFile(
    Pointer<Char> mmProjPath,
    Pointer<llama_model> model,
    mtmd_context_params ctxParams,
  ) {
    if (!_mtmdPrimarySymbolsUnavailable) {
      try {
        return mtmd_init_from_file(mmProjPath, model, ctxParams);
      } on ArgumentError {
        _mtmdPrimarySymbolsUnavailable = true;
      }
    }
    final fallback = _resolveMtmdFallbackApi();
    if (fallback == null) {
      throw Exception(_mtmdUnavailableMessage('mtmd_init_from_file'));
    }
    return fallback.initFromFile(mmProjPath, model, ctxParams);
  }

  void _mtmdFree(Pointer<mtmd_context> ctx) {
    if (!_mtmdPrimarySymbolsUnavailable) {
      try {
        mtmd_free(ctx);
        return;
      } on ArgumentError {
        _mtmdPrimarySymbolsUnavailable = true;
      }
    }
    final fallback = _resolveMtmdFallbackApi();
    if (fallback == null) {
      return;
    }
    fallback.free(ctx);
  }

  Pointer<mtmd_input_chunks> _mtmdInputChunksInit() {
    if (!_mtmdPrimarySymbolsUnavailable) {
      try {
        return mtmd_input_chunks_init();
      } on ArgumentError {
        _mtmdPrimarySymbolsUnavailable = true;
      }
    }
    final fallback = _resolveMtmdFallbackApi();
    if (fallback == null) {
      throw Exception(_mtmdUnavailableMessage('mtmd_input_chunks_init'));
    }
    return fallback.inputChunksInit();
  }

  void _mtmdInputChunksFree(Pointer<mtmd_input_chunks> chunks) {
    if (!_mtmdPrimarySymbolsUnavailable) {
      try {
        mtmd_input_chunks_free(chunks);
        return;
      } on ArgumentError {
        _mtmdPrimarySymbolsUnavailable = true;
      }
    }
    final fallback = _resolveMtmdFallbackApi();
    if (fallback == null) {
      return;
    }
    fallback.inputChunksFree(chunks);
  }

  Pointer<mtmd_bitmap> _mtmdHelperBitmapInitFromFile(
    Pointer<mtmd_context> ctx,
    Pointer<Char> pathPtr,
  ) {
    if (!_mtmdPrimarySymbolsUnavailable) {
      try {
        return mtmd_helper_bitmap_init_from_file(ctx, pathPtr, false).bitmap;
      } on ArgumentError {
        _mtmdPrimarySymbolsUnavailable = true;
      }
    }
    final fallback = _resolveMtmdFallbackApi();
    if (fallback == null) {
      throw Exception(
        _mtmdUnavailableMessage('mtmd_helper_bitmap_init_from_file'),
      );
    }
    return fallback.helperBitmapInitFromFile(ctx, pathPtr);
  }

  Pointer<mtmd_bitmap> _mtmdHelperBitmapInitFromBuf(
    Pointer<mtmd_context> ctx,
    Pointer<UnsignedChar> data,
    int size,
  ) {
    if (!_mtmdPrimarySymbolsUnavailable) {
      try {
        return mtmd_helper_bitmap_init_from_buf(ctx, data, size, false).bitmap;
      } on ArgumentError {
        _mtmdPrimarySymbolsUnavailable = true;
      }
    }
    final fallback = _resolveMtmdFallbackApi();
    if (fallback == null) {
      throw Exception(
        _mtmdUnavailableMessage('mtmd_helper_bitmap_init_from_buf'),
      );
    }
    return fallback.helperBitmapInitFromBuf(ctx, data, size);
  }

  Pointer<mtmd_bitmap> _mtmdBitmapInitFromAudio(int n, Pointer<Float> samples) {
    if (!_mtmdPrimarySymbolsUnavailable) {
      try {
        return mtmd_bitmap_init_from_audio(n, samples);
      } on ArgumentError {
        _mtmdPrimarySymbolsUnavailable = true;
      }
    }
    final fallback = _resolveMtmdFallbackApi();
    if (fallback == null) {
      throw Exception(_mtmdUnavailableMessage('mtmd_bitmap_init_from_audio'));
    }
    return fallback.bitmapInitFromAudio(n, samples);
  }

  void _mtmdBitmapFree(Pointer<mtmd_bitmap> bitmap) {
    if (!_mtmdPrimarySymbolsUnavailable) {
      try {
        mtmd_bitmap_free(bitmap);
        return;
      } on ArgumentError {
        _mtmdPrimarySymbolsUnavailable = true;
      }
    }
    final fallback = _resolveMtmdFallbackApi();
    if (fallback == null) {
      return;
    }
    fallback.bitmapFree(bitmap);
  }

  int _mtmdTokenize(
    Pointer<mtmd_context> ctx,
    Pointer<mtmd_input_chunks> output,
    Pointer<mtmd_input_text> text,
    Pointer<Pointer<mtmd_bitmap>> bitmaps,
    int nBitmaps,
  ) {
    if (!_mtmdPrimarySymbolsUnavailable) {
      try {
        return mtmd_tokenize(ctx, output, text, bitmaps, nBitmaps);
      } on ArgumentError {
        _mtmdPrimarySymbolsUnavailable = true;
      }
    }
    final fallback = _resolveMtmdFallbackApi();
    if (fallback == null) {
      throw Exception(_mtmdUnavailableMessage('mtmd_tokenize'));
    }
    return fallback.tokenize(ctx, output, text, bitmaps, nBitmaps);
  }

  int _mtmdHelperEvalChunks(
    Pointer<mtmd_context> ctx,
    Pointer<llama_context> lctx,
    Pointer<mtmd_input_chunks> chunks,
    int nPast,
    int seqId,
    int nBatch,
    bool logitsLast,
    Pointer<llama_pos> newNPast,
  ) {
    if (!_mtmdPrimarySymbolsUnavailable) {
      try {
        return mtmd_helper_eval_chunks(
          ctx,
          lctx,
          chunks,
          nPast,
          seqId,
          nBatch,
          logitsLast,
          newNPast,
        );
      } on ArgumentError {
        _mtmdPrimarySymbolsUnavailable = true;
      }
    }
    final fallback = _resolveMtmdFallbackApi();
    if (fallback == null) {
      throw Exception(_mtmdUnavailableMessage('mtmd_helper_eval_chunks'));
    }
    return fallback.helperEvalChunks(
      ctx,
      lctx,
      chunks,
      nPast,
      seqId,
      nBatch,
      logitsLast,
      newNPast,
    );
  }

  _MtmdApi? _resolveMtmdFallbackApi() {
    if (_mtmdFallbackLookupAttempted) {
      return _mtmdFallbackApi;
    }
    _mtmdFallbackLookupAttempted = true;

    final fileNameCandidates = _mtmdLibraryCandidateFileNames();
    final candidates = <String>{...fileNameCandidates};
    final backendModuleDirectory = _backendModuleDirectory;
    if (backendModuleDirectory != null) {
      for (final fileName in fileNameCandidates) {
        candidates.add(path.join(backendModuleDirectory, fileName));
      }
    }

    DynamicLibrary? library;
    for (final candidate in candidates) {
      try {
        library = DynamicLibrary.open(candidate);
        break;
      } catch (_) {
        continue;
      }
    }
    if (library == null) {
      return null;
    }

    _mtmdFallbackApi = _MtmdApi.tryLoad(library);
    return _mtmdFallbackApi;
  }

  List<String> _mtmdLibraryCandidateFileNames() {
    final baseName = _mtmdLibraryFileName();
    final candidates = <String>{baseName};
    final backendModuleDirectory = _backendModuleDirectory;
    if (backendModuleDirectory == null) {
      return candidates.toList(growable: false);
    }

    final dynamicNames = _matchingLibraryNames(
      backendModuleDirectory,
      _mtmdLibraryPattern(),
    );
    candidates.addAll(dynamicNames);
    return candidates.toList(growable: false);
  }

  static String _mtmdLibraryFileName() {
    if (Platform.isWindows) {
      return 'mtmd.dll';
    }
    if (Platform.isMacOS || Platform.isIOS) {
      return 'libmtmd.dylib';
    }
    return 'libmtmd.so';
  }

  RegExp _mtmdLibraryPattern() {
    if (Platform.isWindows) {
      return RegExp(r'^mtmd(?:-[^.\\/]+)*\.dll$');
    }
    if (Platform.isMacOS || Platform.isIOS) {
      return RegExp(r'^libmtmd(?:-[^.\\/]+)*\.dylib$');
    }
    return RegExp(r'^libmtmd(?:-[^.\\/]+)*\.so$');
  }

  String _mtmdUnavailableMessage(String symbol) {
    return 'Multimodal support is unavailable in this native runtime bundle '
        '(missing `$symbol` in both primary and mtmd libraries).';
  }

  // --- Helper Getters ---

  /// Returns total and free VRAM (in bytes) of the first GPU-class ggml
  /// backend device. Backend-agnostic — works for Vulkan, CUDA, HIP,
  /// Metal, whichever the active backend(s) expose at runtime.
  ///
  /// Reads memory via `ggml_backend_dev_get_props` (the struct-filling
  /// API) first. The older `ggml_backend_dev_memory` is unreliable on
  /// the Vulkan backend in current llama.cpp — it can return all-zeros
  /// even when the GPU is fully free — so we use it only as a
  /// second-chance fallback per device, for backends that haven't moved
  /// their memory reporting to props yet.
  ///
  /// All ggml backend-device FFI calls are routed through registry
  /// fallback wrappers ([_ggmlBackendDevCount], [_ggmlBackendDevType],
  /// [_ggmlBackendDevGetProps], [_ggmlBackendDevMemory]) so the call
  /// lands on whichever runtime asset owns the device state on
  /// Windows split bundles. Returns `(0, 0)` only when no GPU-class
  /// device is reachable through either symbol path AND every
  /// reachable GPU device declines to report memory.
  ({int total, int free}) getVramInfo() {
    final count = _ggmlBackendDevCount();
    for (var i = 0; i < count; i++) {
      final dev = _ggmlBackendDevGet(i);
      if (dev == nullptr) continue;
      // Compare via raw int so a future llama.cpp adding a new
      // `ggml_backend_dev_type` variant doesn't crash here via the
      // high-level binding's `fromValue` ArgumentError — unknown
      // values just don't match any GPU-class check and we move on.
      final type = _ggmlBackendDevType(dev);
      if (type != ggml_backend_dev_type.GGML_BACKEND_DEVICE_TYPE_GPU.value &&
          type != ggml_backend_dev_type.GGML_BACKEND_DEVICE_TYPE_IGPU.value &&
          type != ggml_backend_dev_type.GGML_BACKEND_DEVICE_TYPE_ACCEL.value) {
        continue;
      }
      final propsPtr = calloc<ggml_backend_dev_props>();
      try {
        if (_ggmlBackendDevGetProps(dev, propsPtr)) {
          final props = propsPtr.ref;
          if (props.memory_total > 0) {
            return (total: props.memory_total, free: props.memory_free);
          }
        }
        // get_props unavailable or reported zero on this device —
        // fall back to the older dev_memory entry point.
        final freePtr = calloc<Size>();
        final totalPtr = calloc<Size>();
        try {
          if (_ggmlBackendDevMemory(dev, freePtr, totalPtr) &&
              totalPtr.value > 0) {
            return (total: totalPtr.value, free: freePtr.value);
          }
        } finally {
          calloc.free(freePtr);
          calloc.free(totalPtr);
        }
      } finally {
        calloc.free(propsPtr);
      }
    }
    return (total: 0, free: 0);
  }

  /// Returns the context size for the given [contextHandle].
  int getContextSize(int contextHandle) {
    final ctx = _contexts[contextHandle];
    if (ctx == null) return 0;
    return llama_n_ctx(ctx.pointer);
  }

  /// Returns native llama.cpp perf timings for [contextHandle].
  ({
    double loadMs,
    double promptEvalMs,
    double evalMs,
    double sampleMs,
    int promptEvalTokens,
    int evalTokens,
    int sampleCount,
    int reusedGraphs,
  })
  getPerformanceContext(int contextHandle) {
    final ctx = _contexts[contextHandle];
    if (ctx == null) {
      throw Exception("Invalid context handle");
    }

    final perf = llama_perf_context(ctx.pointer);
    final sampler = _samplers[contextHandle];
    final samplerPerf = sampler != null ? llama_perf_sampler(sampler) : null;

    final promptEvalMs = ctx.lastPerfPromptEvalMs > 0
        ? ctx.lastPerfPromptEvalMs
        : perf.t_p_eval_ms;
    final evalMs = ctx.lastPerfEvalMs > 0 ? ctx.lastPerfEvalMs : perf.t_eval_ms;
    final sampleMs = ctx.lastPerfSampleMs > 0
        ? ctx.lastPerfSampleMs
        : (samplerPerf?.t_sample_ms ?? 0);
    final promptEvalTokens = perf.n_p_eval > 0
        ? perf.n_p_eval
        : ctx.lastPerfPromptEvalTokens;
    final evalTokens = ctx.lastPerfEvalTokens > 0
        ? ctx.lastPerfEvalTokens
        : perf.n_eval;
    final sampleCount = ctx.lastPerfSampleCount > 0
        ? ctx.lastPerfSampleCount
        : (samplerPerf?.n_sample ?? 0);

    return (
      loadMs: perf.t_load_ms,
      promptEvalMs: promptEvalMs,
      evalMs: evalMs,
      sampleMs: sampleMs,
      promptEvalTokens: promptEvalTokens,
      evalTokens: evalTokens,
      sampleCount: sampleCount,
      reusedGraphs: perf.n_reused,
    );
  }

  /// Checks if a multimodal context exists.
  bool hasMultimodalContext(int mmContextHandle) {
    return _mtmdContexts.containsKey(mmContextHandle);
  }

  /// Returns whether the active multimodal projector supports vision input.
  bool supportsVision(int mmContextHandle) {
    final mmCtx = _mtmdContexts[mmContextHandle];
    if (mmCtx == null) {
      return false;
    }

    if (!_mtmdPrimarySymbolsUnavailable) {
      try {
        return mtmd_support_vision(mmCtx);
      } on ArgumentError {
        _mtmdPrimarySymbolsUnavailable = true;
      }
    }

    final fallback = _resolveMtmdFallbackApi();
    return fallback?.supportsVision(mmCtx) ?? false;
  }

  /// Returns whether the active multimodal projector supports audio input.
  bool supportsAudio(int mmContextHandle) {
    final mmCtx = _mtmdContexts[mmContextHandle];
    if (mmCtx == null) {
      return false;
    }

    if (!_mtmdPrimarySymbolsUnavailable) {
      try {
        return mtmd_support_audio(mmCtx);
      } on ArgumentError {
        _mtmdPrimarySymbolsUnavailable = true;
      }
    }

    final fallback = _resolveMtmdFallbackApi();
    return fallback?.supportsAudio(mmCtx) ?? false;
  }
}

class _LazyGrammarConfig {
  final Pointer<Pointer<Char>> triggerPatterns;
  final int numTriggerPatterns;
  final Pointer<llama_token> triggerTokens;
  final int numTriggerTokens;
  final List<Pointer<Utf8>> allocatedPatternPointers;

  const _LazyGrammarConfig({
    required this.triggerPatterns,
    required this.numTriggerPatterns,
    required this.triggerTokens,
    required this.numTriggerTokens,
    required this.allocatedPatternPointers,
  });

  void dispose() {
    for (final pointer in allocatedPatternPointers) {
      malloc.free(pointer);
    }

    if (triggerPatterns != nullptr) {
      malloc.free(triggerPatterns);
    }
    if (triggerTokens != nullptr) {
      malloc.free(triggerTokens);
    }
  }
}

class _MtpApi {
  final _LlamaDartMtpInitDart init;
  final _LlamaDartMtpFreeDart free;
  final _LlamaDartMtpGetDraftContextDart getDraftContext;
  final _LlamaDartMtpBeginDart begin;
  final _LlamaDartMtpProcessBatchDart processBatch;
  final _LlamaDartMtpDraftDart draft;
  final _LlamaDartMtpAcceptDart accept;
  final _LlamaDartSamplerSampleAndAcceptNDart sampleAndAcceptN;

  const _MtpApi({
    required this.init,
    required this.free,
    required this.getDraftContext,
    required this.begin,
    required this.processBatch,
    required this.draft,
    required this.accept,
    required this.sampleAndAcceptN,
  });

  factory _MtpApi.direct() {
    final api = _MtpApi(
      init: llama_dart_mtp_init,
      free: llama_dart_mtp_free,
      getDraftContext: llama_dart_mtp_get_draft_context,
      begin: llama_dart_mtp_begin,
      processBatch: llama_dart_mtp_process_batch,
      draft: llama_dart_mtp_draft,
      accept: llama_dart_mtp_accept,
      sampleAndAcceptN: llama_dart_sampler_sample_and_accept_n,
    );
    api.probe();
    return api;
  }

  factory _MtpApi.windowsAsset() {
    _llamadartWrapperMtpFree(nullptr.cast<llama_dart_mtp>());
    return _MtpApi(
      init: _llamadartWrapperMtpInit,
      free: _llamadartWrapperMtpFree,
      getDraftContext: _llamadartWrapperMtpGetDraftContext,
      begin: _llamadartWrapperMtpBegin,
      processBatch: _llamadartWrapperMtpProcessBatch,
      draft: _llamadartWrapperMtpDraft,
      accept: _llamadartWrapperMtpAccept,
      sampleAndAcceptN: _llamadartWrapperSamplerSampleAndAcceptN,
    );
  }

  void probe() {
    final nullMtp = nullptr.cast<llama_dart_mtp>();
    final nullModel = nullptr.cast<llama_model>();
    final nullContext = nullptr.cast<llama_context>();
    final nullSampler = nullptr.cast<llama_sampler>();
    final nullTokenArray = nullptr.cast<Int32>();
    final ctxParams = llama_context_default_params();
    final batch = llama_batch_init(1, 0, 1);
    try {
      init(nullModel, nullContext, ctxParams, 1, 0, 0.0, true);
      free(nullMtp);
      getDraftContext(nullMtp);
      begin(nullMtp, 0, nullTokenArray, 0);
      processBatch(nullMtp, batch);
      draft(nullMtp, 0, 0, 0, nullTokenArray, 0, 1, nullTokenArray, 0);
      accept(nullMtp, 0, 0);
      sampleAndAcceptN(
        nullSampler,
        nullContext,
        nullTokenArray,
        0,
        nullTokenArray,
        0,
        nullTokenArray,
        0,
      );
    } finally {
      llama_batch_free(batch);
    }
  }

  static _MtpApi? tryLoad(DynamicLibrary library) {
    try {
      return _MtpApi(
        init: library
            .lookupFunction<_LlamaDartMtpInitNative, _LlamaDartMtpInitDart>(
              'llama_dart_mtp_init',
            ),
        free: library
            .lookupFunction<_LlamaDartMtpFreeNative, _LlamaDartMtpFreeDart>(
              'llama_dart_mtp_free',
            ),
        getDraftContext: library
            .lookupFunction<
              _LlamaDartMtpGetDraftContextNative,
              _LlamaDartMtpGetDraftContextDart
            >('llama_dart_mtp_get_draft_context'),
        begin: library
            .lookupFunction<_LlamaDartMtpBeginNative, _LlamaDartMtpBeginDart>(
              'llama_dart_mtp_begin',
            ),
        processBatch: library
            .lookupFunction<
              _LlamaDartMtpProcessBatchNative,
              _LlamaDartMtpProcessBatchDart
            >('llama_dart_mtp_process_batch'),
        draft: library
            .lookupFunction<_LlamaDartMtpDraftNative, _LlamaDartMtpDraftDart>(
              'llama_dart_mtp_draft',
            ),
        accept: library
            .lookupFunction<_LlamaDartMtpAcceptNative, _LlamaDartMtpAcceptDart>(
              'llama_dart_mtp_accept',
            ),
        sampleAndAcceptN: library
            .lookupFunction<
              _LlamaDartSamplerSampleAndAcceptNNative,
              _LlamaDartSamplerSampleAndAcceptNDart
            >('llama_dart_sampler_sample_and_accept_n'),
      );
    } catch (_) {
      return null;
    }
  }
}

class _MtmdApi {
  final _MtmdDefaultMarkerDart defaultMarker;
  final _MtmdContextParamsDefaultDart contextParamsDefault;
  final _MtmdInitFromFileDart initFromFile;
  final _MtmdFreeDart free;
  final _MtmdInputChunksInitDart inputChunksInit;
  final _MtmdInputChunksFreeDart inputChunksFree;
  final _MtmdHelperBitmapInitFromFileDart helperBitmapInitFromFile;
  final _MtmdHelperBitmapInitFromBufDart helperBitmapInitFromBuf;
  final _MtmdBitmapInitFromAudioDart bitmapInitFromAudio;
  final _MtmdSupportVisionDart supportsVision;
  final _MtmdSupportAudioDart supportsAudio;
  final _MtmdBitmapFreeDart bitmapFree;
  final _MtmdTokenizeDart tokenize;
  final _MtmdHelperEvalChunksDart helperEvalChunks;
  final _MtmdLogSetDart? logSet;
  final _MtmdLogSetDart? helperLogSet;

  const _MtmdApi({
    required this.defaultMarker,
    required this.contextParamsDefault,
    required this.initFromFile,
    required this.free,
    required this.inputChunksInit,
    required this.inputChunksFree,
    required this.helperBitmapInitFromFile,
    required this.helperBitmapInitFromBuf,
    required this.bitmapInitFromAudio,
    required this.supportsVision,
    required this.supportsAudio,
    required this.bitmapFree,
    required this.tokenize,
    required this.helperEvalChunks,
    required this.logSet,
    required this.helperLogSet,
  });

  static _MtmdApi? tryLoad(DynamicLibrary library) {
    try {
      _MtmdLogSetDart? logSet;
      _MtmdLogSetDart? helperLogSet;
      try {
        logSet = library.lookupFunction<_MtmdLogSetNative, _MtmdLogSetDart>(
          'mtmd_log_set',
        );
      } catch (_) {}
      try {
        helperLogSet = library
            .lookupFunction<_MtmdLogSetNative, _MtmdLogSetDart>(
              'mtmd_helper_log_set',
            );
      } catch (_) {}

      return _MtmdApi(
        defaultMarker: library
            .lookupFunction<_MtmdDefaultMarkerNative, _MtmdDefaultMarkerDart>(
              'mtmd_default_marker',
            ),
        contextParamsDefault: library
            .lookupFunction<
              _MtmdContextParamsDefaultNative,
              _MtmdContextParamsDefaultDart
            >('mtmd_context_params_default'),
        initFromFile: library
            .lookupFunction<_MtmdInitFromFileNative, _MtmdInitFromFileDart>(
              'mtmd_init_from_file',
            ),
        free: library.lookupFunction<_MtmdFreeNative, _MtmdFreeDart>(
          'mtmd_free',
        ),
        inputChunksInit: library
            .lookupFunction<
              _MtmdInputChunksInitNative,
              _MtmdInputChunksInitDart
            >('mtmd_input_chunks_init'),
        inputChunksFree: library
            .lookupFunction<
              _MtmdInputChunksFreeNative,
              _MtmdInputChunksFreeDart
            >('mtmd_input_chunks_free'),
        helperBitmapInitFromFile: library
            .lookupFunction<
              _MtmdHelperBitmapInitFromFileNative,
              _MtmdHelperBitmapInitFromFileDart
            >('mtmd_helper_bitmap_init_from_file'),
        helperBitmapInitFromBuf: library
            .lookupFunction<
              _MtmdHelperBitmapInitFromBufNative,
              _MtmdHelperBitmapInitFromBufDart
            >('mtmd_helper_bitmap_init_from_buf'),
        bitmapInitFromAudio: library
            .lookupFunction<
              _MtmdBitmapInitFromAudioNative,
              _MtmdBitmapInitFromAudioDart
            >('mtmd_bitmap_init_from_audio'),
        supportsVision: library
            .lookupFunction<_MtmdSupportVisionNative, _MtmdSupportVisionDart>(
              'mtmd_support_vision',
            ),
        supportsAudio: library
            .lookupFunction<_MtmdSupportAudioNative, _MtmdSupportAudioDart>(
              'mtmd_support_audio',
            ),
        bitmapFree: library
            .lookupFunction<_MtmdBitmapFreeNative, _MtmdBitmapFreeDart>(
              'mtmd_bitmap_free',
            ),
        tokenize: library
            .lookupFunction<_MtmdTokenizeNative, _MtmdTokenizeDart>(
              'mtmd_tokenize',
            ),
        helperEvalChunks: library
            .lookupFunction<
              _MtmdHelperEvalChunksNative,
              _MtmdHelperEvalChunksDart
            >('mtmd_helper_eval_chunks'),
        logSet: logSet,
        helperLogSet: helperLogSet,
      );
    } catch (_) {
      return null;
    }
  }
}

// --- Native Wrappers ---

class _LlamaLoraWrapper {
  final Pointer<llama_adapter_lora> pointer;
  _LlamaLoraWrapper(this.pointer);
  void dispose() {
    llama_adapter_lora_free(pointer);
  }
}

class _LlamaModelWrapper {
  final Pointer<llama_model> pointer;
  final String? sourcePath;
  _LlamaModelWrapper(this.pointer, {this.sourcePath});
  void dispose() {
    llama_model_free(pointer);
  }
}

class _LlamaContextWrapper {
  final Pointer<llama_context> pointer;
  final _LlamaModelWrapper? _modelKeepAlive;
  List<int>? cachedPromptTokens;

  /// Set by stateLoadFile, cleared by any decode. Gates the exact-prompt
  /// single-token resume path; without the gate, the in-process reuse path
  /// would diverge from the cleared+full-decode baseline (parity property).
  bool kvFromStateLoad = false;

  double lastPerfPromptEvalMs = 0;
  double lastPerfEvalMs = 0;
  double lastPerfSampleMs = 0;
  int lastPerfPromptEvalTokens = 0;
  int lastPerfEvalTokens = 0;
  int lastPerfSampleCount = 0;
  _LlamaContextWrapper(this.pointer, this._modelKeepAlive);
  void resetLastPerf() {
    lastPerfPromptEvalMs = 0;
    lastPerfEvalMs = 0;
    lastPerfSampleMs = 0;
    lastPerfPromptEvalTokens = 0;
    lastPerfEvalTokens = 0;
    lastPerfSampleCount = 0;
  }

  void dispose() {
    // ignore: unused_local_variable
    final _ = _modelKeepAlive;
    cachedPromptTokens = null;
    kvFromStateLoad = false;
    llama_free(pointer);
  }
}
