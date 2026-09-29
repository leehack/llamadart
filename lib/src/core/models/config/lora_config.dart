/// Configuration for a LoRA (Low-Rank Adaptation) adapter.
class LoraAdapterConfig {
  /// Path to the LoRA adapter file (.gguf or .bin): a local file path, or a
  /// URL on WebGPU.
  final String path;

  /// The strength of the adapter (typically 0.0 to 1.0).
  final double scale;

  /// Creates a LoRA adapter configuration.
  const LoraAdapterConfig({required this.path, this.scale = 1.0});
}
