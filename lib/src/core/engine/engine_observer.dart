import '../models/chat/chat_message.dart';
import '../models/chat/completion_chunk.dart';
import '../models/chat/content_part.dart';
import '../models/inference/generation_params.dart';
import '../models/inference/generation_usage.dart';
import '../models/inference/model_params.dart';
import '../models/inference/tool_choice.dart';
import '../models/tools/tool_definition.dart';

/// Observes the operations of a `LlamaEngine`, for tracing, metrics or
/// logging.
///
/// Pass observers to the `LlamaEngine` constructor. [onStart] runs in the
/// zone that called the engine method, so it can read the caller's trace
/// context. An exception thrown by an observer is logged and never reaches
/// the caller.
///
/// Operations carry prompts and messages. An observer that exports telemetry
/// should record them only when its user opts in.
abstract class LlamaEngineObserver {
  /// Creates a [LlamaEngineObserver].
  const LlamaEngineObserver();

  /// Called when [operation] starts. Returns the observer of the rest of the
  /// operation, or null to ignore it.
  ///
  /// A `create` or `generate` operation starts when its stream is listened
  /// to; the others start when their method is called.
  LlamaOperationObserver? onStart(LlamaOperation operation);
}

/// Observes one [LlamaOperation] after [LlamaEngineObserver.onStart].
///
/// Its methods run in the zone that called the engine method.
abstract class LlamaOperationObserver {
  /// Creates a [LlamaOperationObserver].
  const LlamaOperationObserver();

  /// Called with each chunk of a [LlamaChatOperation], as the caller
  /// receives it.
  void onChunk(LlamaCompletionChunk chunk) {}

  /// Called with each text piece of a [LlamaTextCompletionOperation], as
  /// the caller receives it.
  void onText(String text) {}

  /// Called once when the operation ends: completed, failed or cancelled.
  void onEnd(LlamaOperationResult result);
}

/// The inference runtime that runs a loaded model.
enum LlamaRuntime {
  /// llama.cpp, for GGUF models, native or through the WebGPU bridge.
  llamaCpp,

  /// LiteRT-LM, for `.litertlm` bundles, native or web.
  liteRtLm,
}

/// An operation of a `LlamaEngine`.
sealed class LlamaOperation {
  /// The loaded model's `general.name` metadata, or its file name when the
  /// metadata has none. For a [LlamaModelLoadOperation], the file name of
  /// the model being loaded.
  ///
  /// Never a directory path, URL query or credential.
  final String? model;

  /// The runtime of the loaded model, or null when the backend does not
  /// report it or no model is loaded yet.
  final LlamaRuntime? runtime;

  const LlamaOperation._({required this.model, required this.runtime});
}

/// A chat completion: `LlamaEngine.create`, `createStructuredJson` or
/// `ChatSession.create`.
final class LlamaChatOperation extends LlamaOperation {
  /// The request messages.
  final List<LlamaChatMessage> messages;

  /// The generation parameters the caller passed.
  final GenerationParams params;

  /// The tools offered to the model, if any.
  final List<ToolDefinition>? tools;

  /// The requested tool choice, or null when the caller passed none.
  final ToolChoice? toolChoice;

  /// The requested structured-output format, if any.
  final Map<String, dynamic>? responseFormat;

  /// Creates a [LlamaChatOperation].
  const LlamaChatOperation({
    required super.model,
    required super.runtime,
    required this.messages,
    required this.params,
    this.tools,
    this.toolChoice,
    this.responseFormat,
  }) : super._();
}

/// A raw-prompt text completion: `LlamaEngine.generate`.
final class LlamaTextCompletionOperation extends LlamaOperation {
  /// The raw prompt.
  final String prompt;

  /// The generation parameters.
  final GenerationParams params;

  /// The media parts of the prompt, if any.
  final List<LlamaContentPart>? parts;

  /// Creates a [LlamaTextCompletionOperation].
  const LlamaTextCompletionOperation({
    required super.model,
    required super.runtime,
    required this.prompt,
    required this.params,
    this.parts,
  }) : super._();
}

/// An embeddings request: `LlamaEngine.embed` or `embedBatch`.
final class LlamaEmbeddingsOperation extends LlamaOperation {
  /// The texts to embed.
  final List<String> inputs;

  /// Whether the vectors are L2-normalized.
  final bool normalize;

  /// Creates a [LlamaEmbeddingsOperation].
  const LlamaEmbeddingsOperation({
    required super.model,
    required super.runtime,
    required this.inputs,
    required this.normalize,
  }) : super._();
}

/// A model load: `LlamaEngine.loadModel` or `loadModelFromUrl`, including
/// the load that `loadModelSource` performs after resolving its source.
final class LlamaModelLoadOperation extends LlamaOperation {
  /// The model parameters.
  final ModelParams modelParams;

  /// Creates a [LlamaModelLoadOperation].
  const LlamaModelLoadOperation({
    required super.model,
    required this.modelParams,
  }) : super._(runtime: null);
}

/// How a [LlamaOperation] ended.
final class LlamaOperationResult {
  /// The error the operation failed with, or null.
  final Object? error;

  /// The stack trace of [error], or null.
  final StackTrace? stackTrace;

  /// Whether the operation was cancelled, by `LlamaEngine.cancelGeneration`
  /// or by cancelling its stream subscription.
  final bool cancelled;

  /// Why generation stopped: `stop`, `length` or `tool_calls`, as on the
  /// final `create` chunk. Null for operations that do not generate, and for
  /// a failed or cancelled generation.
  final String? finishReason;

  /// The generation's token counts and timings, when the backend reports
  /// them.
  final LlamaGenerationUsage? usage;

  /// Creates a [LlamaOperationResult].
  const LlamaOperationResult({
    this.error,
    this.stackTrace,
    this.cancelled = false,
    this.finishReason,
    this.usage,
  });
}
