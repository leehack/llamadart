import 'dart:async';

import 'models/model_params.dart';
import 'models/llama_chat_message.dart';
import 'models/generation_params.dart';
import 'models/llama_chat_template_result.dart';

export 'models/gpu_backend.dart';
export 'models/llama_log_level.dart';
export 'models/lora_adapter_config.dart';
export 'models/model_params.dart';
export 'models/llama_chat_message.dart';
export 'models/generation_params.dart';
export 'models/llama_chat_template_result.dart';

/// Platform-agnostic interface for Llama model inference.
abstract class LlamaServiceBase {
  /// Whether the service is currently initialized and ready for inference.
  bool get isReady;

  /// Initializes the service using a model file at the provided [modelPath].
  ///
  /// On Native, this should be a local file system path.
  /// On Web, this can be a relative URL or a path in the virtual file system.
  Future<void> init(String modelPath, {ModelParams? modelParams});

  /// Initializes the service by downloading a model from [modelUrl].
  ///
  /// On Native, the model is downloaded to a temporary file.
  /// On Web, the model is loaded directly into the browser's persistent cache.
  Future<void> initFromUrl(String modelUrl, {ModelParams? modelParams});

  /// Generates a stream of text tokens based on the provided [prompt].
  ///
  /// This is a low-level method that does not apply any chat formatting.
  Stream<String> generate(String prompt, {GenerationParams? params});

  /// Encodes the given [text] into a list of token IDs using the model's vocabulary.
  Future<List<int>> tokenize(String text);

  /// Decodes a list of [tokens] back into a human-readable string.
  Future<String> detokenize(List<int> tokens);

  /// Retrieves a specific piece of metadata from the loaded model by its [key].
  ///
  /// Returns null if the key is not found.
  Future<String?> getModelMetadata(String key);

  /// Immediately cancels any ongoing generation process.
  void cancelGeneration();

  /// High-level chat interface that manages the conversation flow.
  ///
  /// This method automatically:
  /// 1. Applies the model's chat template to the [messages].
  /// 2. Detects appropriate stop sequences.
  /// 3. Filters those stop sequences from the output stream.
  Stream<String> chat(
    List<LlamaChatMessage> messages, {
    GenerationParams? params,
  });

  /// Formats a list of [messages] into a single prompt string using the model's chat template.
  ///
  /// Returns both the formatted prompt and any detected stop markers.
  Future<LlamaChatTemplateResult> applyChatTemplate(
    List<LlamaChatMessage> messages, {
    bool addAssistant = true,
  });

  /// Releases all allocated resources (model, context, isolates, etc.).
  Future<void> dispose();

  /// Returns the name of the active GPU backend (e.g., 'Metal', 'Vulkan', 'CPU').
  Future<String> getBackendName();

  /// Returns true if the current hardware and backend support GPU acceleration.
  Future<bool> isGpuSupported();

  /// Returns the actual context size being used by the current session.
  Future<int> getContextSize();

  /// Utility to count the number of tokens in [text] without running inference.
  Future<int> getTokenCount(String text);

  /// Returns all available metadata from the model as a Map.
  Future<Map<String, String>> getAllMetadata();

  /// Dynamically loads or updates a LoRA adapter's scale.
  ///
  /// Note: Only supported on native platforms.
  Future<void> setLoraAdapter(String path, {double scale = 1.0});

  /// Removes a specific LoRA adapter from the active session.
  ///
  /// Note: Only supported on native platforms.
  Future<void> removeLoraAdapter(String path);

  /// Removes all active LoRA adapters from the current context.
  ///
  /// Note: Only supported on native platforms.
  Future<void> clearLoraAdapters();
}
