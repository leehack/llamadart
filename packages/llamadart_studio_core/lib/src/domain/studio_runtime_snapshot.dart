import 'package:llamadart/llamadart.dart';
import 'package:meta/meta.dart';

import 'studio_model_descriptor.dart';
import 'studio_settings.dart';

/// Lifecycle phase of the primary chat/inference runtime.
enum StudioEnginePhase {
  /// No model loaded.
  unloaded,

  /// Resolving, downloading, or allocating native/WebGPU model weights.
  loading,

  /// Model ready for inference.
  ready,

  /// Unloading or switching models.
  unloading,

  /// Last load failed with an actionable error.
  error,
}

/// Immutable snapshot of the active inference engine, hardware devices,
/// capabilities, and most recent performance telemetry.
@immutable
class StudioRuntimeSnapshot {
  /// Creates a [StudioRuntimeSnapshot].
  const StudioRuntimeSnapshot({
    this.phase = StudioEnginePhase.unloaded,
    this.activeDescriptor,
    this.activeModelLabel,
    this.backendName = 'None',
    this.availableBackends = '',
    this.capabilities,
    this.resolvedContextSize,
    this.resolvedGpuLayers,
    this.loadedEngineSignature,
    this.vramTotalBytes = 0,
    this.vramFreeBytes = 0,
    this.gpuDevices = const <GpuDeviceInfo>[],
    this.metadata = const <String, String>{},
    this.perfContext,
    this.loadProgressFraction,
    this.statusMessage,
    this.errorMessage,
  });

  /// Current lifecycle phase.
  final StudioEnginePhase phase;

  /// Curated or custom model descriptor currently active or loading.
  final StudioModelDescriptor? activeDescriptor;

  /// Display name of the loaded or loading model.
  final String? activeModelLabel;

  /// Active backend label reported by `llamadart` (e.g. `Metal`, `Vulkan`, `WebGPU`).
  final String backendName;

  /// Comma-separated backends compiled into the runtime.
  final String availableBackends;

  /// Runtime capability flags reported by `LlamaEngine.capabilities`.
  final LlamaEngineCapabilities? capabilities;

  /// Effective allocated context window (`n_ctx`).
  final int? resolvedContextSize;

  /// Effective offloaded GPU layer count.
  final int? resolvedGpuLayers;

  /// Signature of load-time engine settings active when the model was loaded.
  final String? loadedEngineSignature;

  /// Reported total VRAM/unified memory in bytes (`0` when unavailable).
  final int vramTotalBytes;

  /// Reported free VRAM/unified memory in bytes (`0` when unavailable).
  final int vramFreeBytes;

  /// Enumerated compute/GPU devices reported by the backend.
  final List<GpuDeviceInfo> gpuDevices;

  /// Selected GGUF/LiteRT metadata key-value pairs.
  final Map<String, String> metadata;

  /// Most recent native `llama_perf_context` telemetry snapshot.
  final BackendPerfContextData? perfContext;

  /// Optional download/load progress in `0.0 .. 1.0`.
  final double? loadProgressFraction;

  /// Transient human-readable status message during load/auto-tune.
  final String? statusMessage;

  /// Actionable error message when [phase] is [StudioEnginePhase.error].
  final String? errorMessage;

  /// Convenience getter for ready state.
  bool get isReady => phase == StudioEnginePhase.ready;

  /// Convenience getter for loading state.
  bool get isLoading =>
      phase == StudioEnginePhase.loading ||
      phase == StudioEnginePhase.unloading;

  /// Whether image attachments are supported right now.
  bool get supportsVision => capabilities?.supportsVision ?? false;

  /// Whether audio attachments are supported right now.
  bool get supportsAudio => capabilities?.supportsAudio ?? false;

  /// Whether tool calling is supported right now.
  bool get supportsToolCalling => capabilities?.supportsToolCalling ?? false;

  /// Whether structured JSON grammar is supported right now.
  bool get supportsStructuredOutput =>
      capabilities?.supportsStructuredOutput ?? false;

  /// Whether [currentSettings] differ in load-time engine parameters from the
  /// currently loaded model and require `Apply & Reload` to take effect.
  bool hasUnappliedEngineChanges(
    StudioSettings currentSettings, {
    required bool isWeb,
  }) {
    if (!isReady || loadedEngineSignature == null) {
      return false;
    }
    return loadedEngineSignature !=
        currentSettings.engineLoadSignature(isWeb: isWeb);
  }

  /// Returns an updated copy of this snapshot.
  StudioRuntimeSnapshot copyWith({
    StudioEnginePhase? phase,
    StudioModelDescriptor? activeDescriptor,
    bool clearActiveDescriptor = false,
    String? activeModelLabel,
    bool clearActiveModelLabel = false,
    String? backendName,
    String? availableBackends,
    LlamaEngineCapabilities? capabilities,
    bool clearCapabilities = false,
    int? resolvedContextSize,
    bool clearResolvedContextSize = false,
    int? resolvedGpuLayers,
    bool clearResolvedGpuLayers = false,
    String? loadedEngineSignature,
    bool clearLoadedEngineSignature = false,
    int? vramTotalBytes,
    int? vramFreeBytes,
    List<GpuDeviceInfo>? gpuDevices,
    Map<String, String>? metadata,
    BackendPerfContextData? perfContext,
    bool clearPerfContext = false,
    double? loadProgressFraction,
    bool clearLoadProgress = false,
    String? statusMessage,
    bool clearStatusMessage = false,
    String? errorMessage,
    bool clearErrorMessage = false,
  }) {
    return StudioRuntimeSnapshot(
      phase: phase ?? this.phase,
      activeDescriptor: clearActiveDescriptor
          ? null
          : (activeDescriptor ?? this.activeDescriptor),
      activeModelLabel: clearActiveModelLabel
          ? null
          : (activeModelLabel ?? this.activeModelLabel),
      backendName: backendName ?? this.backendName,
      availableBackends: availableBackends ?? this.availableBackends,
      capabilities: clearCapabilities
          ? null
          : (capabilities ?? this.capabilities),
      resolvedContextSize: clearResolvedContextSize
          ? null
          : (resolvedContextSize ?? this.resolvedContextSize),
      resolvedGpuLayers: clearResolvedGpuLayers
          ? null
          : (resolvedGpuLayers ?? this.resolvedGpuLayers),
      loadedEngineSignature: clearLoadedEngineSignature
          ? null
          : (loadedEngineSignature ?? this.loadedEngineSignature),
      vramTotalBytes: vramTotalBytes ?? this.vramTotalBytes,
      vramFreeBytes: vramFreeBytes ?? this.vramFreeBytes,
      gpuDevices: gpuDevices ?? this.gpuDevices,
      metadata: metadata ?? this.metadata,
      perfContext: clearPerfContext ? null : (perfContext ?? this.perfContext),
      loadProgressFraction: clearLoadProgress
          ? null
          : (loadProgressFraction ?? this.loadProgressFraction),
      statusMessage: clearStatusMessage
          ? null
          : (statusMessage ?? this.statusMessage),
      errorMessage: clearErrorMessage
          ? null
          : (errorMessage ?? this.errorMessage),
    );
  }
}
