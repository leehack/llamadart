import 'package:llamadart/llamadart.dart';

class ChatSettings {
  final String? modelPath;
  final String? mmprojPath;
  final GpuBackend preferredBackend;
  final double temperature;
  final int topK;
  final double topP;
  final double minP;
  final double penalty;
  final int contextSize;
  final int maxTokens;
  final int gpuLayers;

  /// Whether native Auto should recompute GPU layers and context headroom on
  /// every model load. Resolved values remain visible in [gpuLayers] and
  /// [contextSize], while this flag preserves the user's Auto intent across
  /// app restarts.
  final bool autoTuneModelParams;

  /// Context requested by the user or model preset while Auto tuning is
  /// active. [contextSize] can hold a lower resolved value under memory
  /// pressure without losing the target for a later model load.
  final int? autoTuneRequestedContextSize;

  final int numberOfThreads;
  final int numberOfThreadsBatch;

  /// Dart-side logger verbosity (llamadart logger).
  final LlamaLogLevel logLevel;

  /// Native llama.cpp backend logger verbosity.
  final LlamaLogLevel nativeLogLevel;
  final bool toolsEnabled;
  final String toolDeclarations;
  final bool thinkingEnabled;
  final int thinkingBudgetTokens;
  final bool singleTurnMode;

  /// Capabilities declared by the selected model profile for the active
  /// platform. Runtime projector probes can add to these capabilities.
  final bool modelSupportsVision;
  final bool modelSupportsAudio;

  /// Whether media is consumed directly by the model backend instead of an
  /// external multimodal projector.
  final bool directMediaInput;

  /// Approximate selected-model size in bytes. Native Auto uses it for memory
  /// planning; Web forwards it to `ModelParams.modelBytesHint` so WebGPU can
  /// select the mem64 core before loading large models. `null`/`0` when unknown.
  final int? modelBytesHint;

  const ChatSettings({
    this.modelPath,
    this.mmprojPath,
    this.preferredBackend = GpuBackend.auto,
    this.temperature = 0.7,
    this.topK = 40,
    this.topP = 0.9,
    this.minP = 0.0,
    this.penalty = 1.1,
    this.contextSize = 4096,
    this.maxTokens = 4096,
    this.gpuLayers = 32,
    this.autoTuneModelParams = false,
    this.autoTuneRequestedContextSize,
    this.numberOfThreads = 0,
    this.numberOfThreadsBatch = 0,
    this.logLevel = LlamaLogLevel.none,
    this.nativeLogLevel = LlamaLogLevel.warn,
    this.toolsEnabled = false,
    this.toolDeclarations = '[]',
    this.thinkingEnabled = true,
    this.thinkingBudgetTokens = 0,
    this.singleTurnMode = false,
    this.modelSupportsVision = false,
    this.modelSupportsAudio = false,
    this.directMediaInput = false,
    this.modelBytesHint,
  });

  ChatSettings copyWith({
    String? modelPath,
    String? mmprojPath,
    GpuBackend? preferredBackend,
    double? temperature,
    int? topK,
    double? topP,
    double? minP,
    double? penalty,
    int? contextSize,
    int? maxTokens,
    int? gpuLayers,
    bool? autoTuneModelParams,
    int? autoTuneRequestedContextSize,
    int? numberOfThreads,
    int? numberOfThreadsBatch,
    LlamaLogLevel? logLevel,
    LlamaLogLevel? nativeLogLevel,
    bool? toolsEnabled,
    String? toolDeclarations,
    bool? thinkingEnabled,
    int? thinkingBudgetTokens,
    bool? singleTurnMode,
    bool? modelSupportsVision,
    bool? modelSupportsAudio,
    bool? directMediaInput,
    int? modelBytesHint,
  }) {
    return ChatSettings(
      modelPath: modelPath ?? this.modelPath,
      mmprojPath: mmprojPath ?? this.mmprojPath,
      preferredBackend: preferredBackend ?? this.preferredBackend,
      temperature: temperature ?? this.temperature,
      topK: topK ?? this.topK,
      topP: topP ?? this.topP,
      minP: minP ?? this.minP,
      penalty: penalty ?? this.penalty,
      contextSize: contextSize ?? this.contextSize,
      maxTokens: maxTokens ?? this.maxTokens,
      gpuLayers: gpuLayers ?? this.gpuLayers,
      autoTuneModelParams: autoTuneModelParams ?? this.autoTuneModelParams,
      autoTuneRequestedContextSize:
          autoTuneRequestedContextSize ?? this.autoTuneRequestedContextSize,
      numberOfThreads: numberOfThreads ?? this.numberOfThreads,
      numberOfThreadsBatch: numberOfThreadsBatch ?? this.numberOfThreadsBatch,
      logLevel: logLevel ?? this.logLevel,
      nativeLogLevel: nativeLogLevel ?? this.nativeLogLevel,
      toolsEnabled: toolsEnabled ?? this.toolsEnabled,
      toolDeclarations: toolDeclarations ?? this.toolDeclarations,
      thinkingEnabled: thinkingEnabled ?? this.thinkingEnabled,
      thinkingBudgetTokens: thinkingBudgetTokens ?? this.thinkingBudgetTokens,
      singleTurnMode: singleTurnMode ?? this.singleTurnMode,
      modelSupportsVision: modelSupportsVision ?? this.modelSupportsVision,
      modelSupportsAudio: modelSupportsAudio ?? this.modelSupportsAudio,
      directMediaInput: directMediaInput ?? this.directMediaInput,
      modelBytesHint: modelBytesHint ?? this.modelBytesHint,
    );
  }
}
