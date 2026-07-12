import 'package:llamadart/llamadart.dart';

import '../../../shared/openai_http_exception.dart';

/// Converts a llamadart chunk into OpenAI-compatible chunk JSON.
Map<String, dynamic> toOpenAiChatCompletionChunk(
  LlamaCompletionChunk chunk, {
  required String model,
  required bool includeRole,
}) {
  if (chunk.choices.isEmpty) {
    throw OpenAiHttpException.server(
      'Received a completion chunk with no choices.',
    );
  }

  final choice = chunk.choices.first;
  final delta = <String, dynamic>{};

  if (includeRole) {
    delta['role'] = 'assistant';
    delta['content'] = '';
  }

  final content = choice.delta.content;
  if (content != null && content.isNotEmpty) {
    delta['content'] = content;
  }

  final toolCalls = choice.delta.toolCalls;
  if (toolCalls != null && toolCalls.isNotEmpty) {
    delta['tool_calls'] = toolCalls
        .map((LlamaCompletionChunkToolCall call) => _toolCallChunkToJson(call))
        .toList(growable: false);
  }

  final reasoning = choice.delta.thinking;
  if (reasoning != null && reasoning.isNotEmpty) {
    delta['reasoning_content'] = reasoning;
  }

  return {
    'id': chunk.id,
    'object': 'chat.completion.chunk',
    'created': chunk.created,
    'model': model,
    'choices': [
      {
        'index': choice.index,
        'delta': delta,
        'finish_reason': choice.finishReason,
      },
    ],
  };
}

Map<String, dynamic> _toolCallChunkToJson(LlamaCompletionChunkToolCall call) {
  final function = <String, dynamic>{};
  if (call.function?.name != null) {
    function['name'] = call.function!.name;
  }
  if (call.function?.arguments != null) {
    function['arguments'] = call.function!.arguments;
  }

  return {
    'index': call.index,
    if (call.id != null) 'id': call.id,
    if (call.type != null) 'type': call.type,
    if (function.isNotEmpty) 'function': function,
  };
}
