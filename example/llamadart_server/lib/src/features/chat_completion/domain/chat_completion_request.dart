import 'package:llamadart/llamadart.dart';

/// Parsed and validated request payload for `/v1/chat/completions`.
class OpenAiChatCompletionRequest {
  /// Model ID requested by the client.
  final String model;

  /// Conversation messages converted to llamadart messages.
  final List<LlamaChatMessage> messages;

  /// Generation controls mapped from OpenAI request fields.
  final GenerationParams params;

  /// Whether SSE streaming mode is enabled.
  final bool stream;

  /// Whether the model may emit a separate reasoning channel.
  final bool enableThinking;

  /// Whether the request permits parallel tool calls when the template supports them.
  final bool parallelToolCalls;

  /// Optional tool definitions included in the request.
  final List<ToolDefinition>? tools;

  /// Optional tool choice behavior.
  final ToolChoice? toolChoice;

  /// Creates a parsed request model.
  const OpenAiChatCompletionRequest({
    required this.model,
    required this.messages,
    required this.params,
    required this.stream,
    required this.enableThinking,
    required this.parallelToolCalls,
    this.tools,
    this.toolChoice,
  });
}
