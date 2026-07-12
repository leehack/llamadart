import 'package:llamadart/llamadart.dart';

/// Exposes chat-template rendering capability.
abstract class EngineTemplatePort {
  /// Applies the chat template and returns template metadata.
  Future<LlamaChatTemplateResult> chatTemplate(
    List<LlamaChatMessage> messages, {
    bool addAssistant,
    List<ToolDefinition>? tools,
    ToolChoice toolChoice,
    bool parallelToolCalls = false,
    bool enableThinking = false,
  });
}
