import 'dart:async';
import 'models/model_params.dart';
import 'models/generation_params.dart';
import 'models/llama_chat_message.dart';
import 'models/llama_chat_template_result.dart';

/// Internal interface for model and context management across platforms.
///
/// This separates the high-level orchestration (LlamaEngine) from the
/// platform-specific implementation (FFI for native, Wasm for web).
abstract class LlamaBackend {
  /// Whether the backend is currently initialized and ready.
  bool get isReady;

  /// Loads a model from the given [path]. Returns a unique handle for the model.
  Future<int> modelLoad(String path, ModelParams params);

  /// Loads a model from a [url]. Returns a unique handle for the model.
  Future<int> modelLoadFromUrl(String url, ModelParams params);

  /// Frees a model by its [modelHandle].
  Future<void> modelFree(int modelHandle);

  /// Creates a context for a given model. Returns a unique handle for the context.
  Future<int> contextCreate(int modelHandle, ModelParams params);

  /// Frees a context by its [contextHandle].
  Future<void> contextFree(int contextHandle);

  /// Generates a stream of token bytes for a given prompt and context.
  ///
  /// The [cancelTokenAddress] is a pointer to an integer that, when set to 1,
  /// should immediately stop the generation process.
  Stream<List<int>> generate(
    int contextHandle,
    String prompt,
    GenerationParams params,
    int cancelTokenAddress,
  );

  /// Tokenizes [text] for a given model.
  Future<List<int>> tokenize(
    int modelHandle,
    String text, {
    bool addSpecial = true,
  });

  /// Detokenizes [tokens] back into a string for a given model.
  Future<String> detokenize(
    int modelHandle,
    List<int> tokens, {
    bool special = false,
  });

  /// Retrieves all metadata for a given model.
  Future<Map<String, String>> modelMetadata(int modelHandle);

  /// Applies a chat template to a list of messages for a given model.
  Future<LlamaChatTemplateResult> applyChatTemplate(
    int modelHandle,
    List<LlamaChatMessage> messages, {
    bool addAssistant = true,
  });

  /// Sets or updates a LoRA adapter's scale for a given context.
  Future<void> setLoraAdapter(int contextHandle, String path, double scale);

  /// Removes a LoRA adapter from a given context.
  Future<void> removeLoraAdapter(int contextHandle, String path);

  /// Clears all LoRA adapters from a given context.
  Future<void> clearLoraAdapters(int contextHandle);

  /// Returns the name of the backend (e.g., 'Native', 'Wasm').
  Future<String> getBackendName();

  /// Returns whether the backend supports GPU acceleration on the current hardware.
  Future<bool> isGpuSupported();

  /// Disposes the backend and releases all shared resources.
  Future<void> dispose();
}
