import 'package:llamadart/llamadart.dart';

/// Exposes token generation capability.
abstract class EngineGenerationPort {
  /// Starts streaming generation.
  Stream<LlamaCompletionChunk> create(
    List<LlamaChatMessage> messages, {
    GenerationParams params,
    List<ToolDefinition>? tools,
    ToolChoice? toolChoice,
    bool parallelToolCalls = false,
    bool enableThinking = false,
  });
}
