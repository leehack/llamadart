import 'dart:convert';

import 'package:llamadart/llamadart.dart';

import '../../domain/openai_tool_call_record.dart';

/// Accumulates streaming chunks into a single non-stream OpenAI response.
class OpenAiChatCompletionAccumulator {
  final StringBuffer _content = StringBuffer();
  final StringBuffer _reasoning = StringBuffer();
  final Map<int, _ToolCallAccumulator> _toolCallsByIndex =
      <int, _ToolCallAccumulator>{};

  String _finishReason = 'stop';

  /// Adds one streaming chunk to this accumulator.
  void addChunk(LlamaCompletionChunk chunk) {
    if (chunk.choices.isEmpty) {
      return;
    }

    final choice = chunk.choices.first;

    final content = choice.delta.content;
    if (content != null) {
      _content.write(content);
    }

    final reasoning = choice.delta.thinking;
    if (reasoning != null) {
      _reasoning.write(reasoning);
    }

    final toolCalls = choice.delta.toolCalls;
    if (toolCalls != null) {
      for (final call in toolCalls) {
        final accumulator = _toolCallsByIndex.putIfAbsent(
          call.index,
          () => _ToolCallAccumulator(call.index),
        );

        accumulator.add(call);
      }
    }

    if (choice.finishReason != null) {
      _finishReason = choice.finishReason!;
    }
  }

  /// Accumulated assistant content.
  String get content => _content.toString();

  /// Accumulated assistant reasoning text.
  String get reasoningContent => _reasoning.toString();

  /// Parsed tool calls emitted in this completion.
  List<OpenAiToolCallRecord> get toolCalls {
    final accumulators = _toolCallsByIndex.values.toList(growable: false)
      ..sort((a, b) => a.index.compareTo(b.index));
    return accumulators
        .map((accumulator) => accumulator.toRecord())
        .toList(growable: false);
  }

  /// Builds a full OpenAI completion response JSON object.
  Map<String, dynamic> toResponseJson({
    required String id,
    required int created,
    required String model,
    required int promptTokens,
    required int completionTokens,
  }) {
    final toolCallJson = toolCalls
        .map((record) => record.toJson())
        .toList(growable: false);

    final hasToolCalls = toolCallJson.isNotEmpty;
    final reasoning = reasoningContent;

    final message = <String, dynamic>{
      'role': 'assistant',
      'content': hasToolCalls && content.isEmpty ? null : content,
      if (reasoning.isNotEmpty) 'reasoning_content': reasoning,
      if (hasToolCalls) 'tool_calls': toolCallJson,
    };

    return {
      'id': id,
      'object': 'chat.completion',
      'created': created,
      'model': model,
      'choices': [
        {
          'index': 0,
          'message': message,
          'finish_reason': hasToolCalls ? 'tool_calls' : _finishReason,
        },
      ],
      'usage': {
        'prompt_tokens': promptTokens,
        'completion_tokens': completionTokens,
        'total_tokens': promptTokens + completionTokens,
      },
    };
  }
}

class _ToolCallAccumulator {
  final int index;

  String? id;
  String? type;
  String? name;
  final StringBuffer arguments = StringBuffer();

  _ToolCallAccumulator(this.index);

  void add(LlamaCompletionChunkToolCall call) {
    id ??= call.id;
    type ??= call.type;

    final function = call.function;
    if (function?.name != null) {
      name = function!.name;
    }
    if (function?.arguments != null) {
      arguments.write(function!.arguments);
    }
  }

  OpenAiToolCallRecord toRecord() {
    final rawArguments = arguments.toString();
    return OpenAiToolCallRecord(
      index: index,
      id: id ?? 'call_$index',
      type: type ?? 'function',
      name: name ?? '',
      argumentsRaw: rawArguments,
      arguments: _decodeArgumentsObject(rawArguments),
    );
  }
}

Map<String, dynamic> _decodeArgumentsObject(String rawArguments) {
  final trimmed = rawArguments.trim();
  if (trimmed.isEmpty) {
    return const <String, dynamic>{};
  }

  try {
    final decoded = jsonDecode(trimmed);
    if (decoded is Map) {
      return Map<String, dynamic>.from(decoded);
    }
  } catch (_) {
    // Keep fallback empty map when the model emits non-JSON arguments.
  }

  return const <String, dynamic>{};
}
