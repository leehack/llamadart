import 'gpu_backend.dart';
import 'llama_log_level.dart';
import 'lora_adapter_config.dart';

/// Configuration parameters for loading a Llama model.
class ModelParams {
  /// Context size (n_ctx) in tokens.
  final int contextSize;

  /// Number of model layers to offload to the GPU (n_gpu_layers).
  final int gpuLayers;

  /// Preferred GPU backend for inference.
  final GpuBackend preferredBackend;

  /// Minimum log level for console output from the native engine.
  final LlamaLogLevel logLevel;

  /// Initial LoRA adapters to load along with the model.
  final List<LoraAdapterConfig> loras;

  /// Creates configuration for the model.
  const ModelParams({
    this.contextSize = 0,
    this.gpuLayers = 99,
    this.preferredBackend = GpuBackend.auto,
    this.logLevel = LlamaLogLevel.warn,
    this.loras = const [],
  });

  /// Creates a copy of this [ModelParams] with updated fields.
  ModelParams copyWith({
    int? contextSize,
    int? gpuLayers,
    GpuBackend? preferredBackend,
    LlamaLogLevel? logLevel,
    List<LoraAdapterConfig>? loras,
  }) {
    return ModelParams(
      contextSize: contextSize ?? this.contextSize,
      gpuLayers: gpuLayers ?? this.gpuLayers,
      preferredBackend: preferredBackend ?? this.preferredBackend,
      logLevel: logLevel ?? this.logLevel,
      loras: loras ?? this.loras,
    );
  }
}
