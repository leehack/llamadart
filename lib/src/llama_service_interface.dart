import 'dart:async';

/// GPU backend selection for runtime device preference.
///
/// Note: The actual availability of backends depends on compile-time configuration.
/// If a backend is not compiled in, selection will fall back to the next available.
enum GpuBackend {
  /// Automatically select the best available backend (recommended).
  /// Priority: Metal > Vulkan > CPU
  auto,

  /// Force CPU-only inference (no GPU acceleration).
  cpu,

  /// Use Vulkan backend (cross-platform GPU support).
  vulkan,

  /// Use Apple Metal backend (macOS/iOS only, auto-enabled on Apple platforms).
  metal,

  /// Use BLAS backend (CPU acceleration).
  blas,
}

/// Configuration parameters for loading the model.
class ModelParams {
  /// Context size (n_ctx). Defaults to 2048.
  final int contextSize;

  /// Number of layers to offload to GPU (n_gpu_layers). Defaults to 99 (all).
  /// Set to 0 to force CPU-only inference regardless of preferred backend.
  final int gpuLayers;

  /// Preferred GPU backend for inference.
  /// Defaults to [GpuBackend.auto] which selects the best available.
  final GpuBackend preferredBackend;

  /// Creates configuration for the model.
  const ModelParams({
    this.contextSize = 0, // 0 = Auto detect from model
    this.gpuLayers = 99,
    this.preferredBackend = GpuBackend.auto,
  });

  /// Creates a copy of this [ModelParams] with updated fields.
  ModelParams copyWith({
    int? contextSize,
    int? gpuLayers,
    GpuBackend? preferredBackend,
  }) {
    return ModelParams(
      contextSize: contextSize ?? this.contextSize,
      gpuLayers: gpuLayers ?? this.gpuLayers,
      preferredBackend: preferredBackend ?? this.preferredBackend,
    );
  }
}

/// A message in a chat conversation.
class LlamaChatMessage {
  /// The role of the message (e.g., 'user', 'assistant', 'system').
  final String role;

  /// The content of the message.
  final String content;

  /// Creates a message with a role and content.
  const LlamaChatMessage({required this.role, required this.content});
}

/// Parameters for text generation.
class GenerationParams {
  /// Maximum number of tokens to generate.
  final int maxTokens;

  /// Temperature for sampling (0.0 - 2.0).
  final double temp;

  /// Top-K sampling (0 to disable).
  final int topK;

  /// Top-P sampling.
  final double topP;

  /// Repeat penalty.
  final double penalty;

  /// Random seed.
  final int? seed;

  /// Custom sequences that will stop generation when found.
  final List<String> stopSequences;

  /// Creates generation parameters with default values.
  const GenerationParams({
    this.maxTokens = 512,
    this.temp = 0.8,
    this.topK = 40,
    this.topP = 0.9,
    this.penalty = 1.1,
    this.seed,
    this.stopSequences = const [],
  });
}

/// Platform-agnostic interface for LLM inference.
abstract class LlamaServiceBase {
  /// Whether the service is initialized and ready to use.
  bool get isReady;

  /// Initialize with a local file path (Primary for Native).
  ///
  /// On web, this might not be supported or might expect a VFS path.
  Future<void> init(String modelPath, {ModelParams? modelParams});

  /// Initialize from a URL (Primary for Web).
  ///
  /// Downloads the model to a temporary location (native) or loads directly (web).
  Future<void> initFromUrl(String modelUrl, {ModelParams? modelParams});

  /// Generate text based on the [prompt].
  Stream<String> generate(String prompt, {GenerationParams? params});

  /// Tokenize the given [text] into a list of token IDs.
  Future<List<int>> tokenize(String text);

  /// Detokenize the given [tokens] back into a string.
  Future<String> detokenize(List<int> tokens);

  /// Get metadata value as a string by key name.
  /// Returns null if not found.
  Future<String?> getModelMetadata(String key);

  /// Cancels the current generation.
  void cancelGeneration();

  /// Applies the model's chat template to a list of messages.
  ///
  /// This uses the jinja template stored in the model's metadata (if available)
  /// or a suitable fallback. Returns the formatted prompt.
  Future<String> applyChatTemplate(
    List<LlamaChatMessage> messages, {
    bool addAssistant = true,
  });

  /// Disposes the service and releases resources.
  void dispose();

  /// Returns the name of the GPU backend compiled into the library (e.g., 'Metal', 'CUDA', 'Vulkan', 'CPU').
  Future<String> getBackendName();

  /// Returns true if the hardware supports GPU offloading for the current backend.
  Future<bool> isGpuSupported();

  /// Returns the resolved context size used by the current model session.
  Future<int> getContextSize();

  /// Returns the number of tokens in the given [text].
  Future<int> getTokenCount(String text);

  /// Returns all available metadata from the model as a map.
  Future<Map<String, String>> getAllMetadata();
}
