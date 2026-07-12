import 'dart:convert';

import 'package:llamadart/llamadart.dart';

import '../../../../shared/openai_http_exception.dart';
import 'message_content_utils.dart';

List<LlamaToolCallContent> parseAssistantToolCalls(Object? rawToolCalls) {
  if (rawToolCalls == null) {
    return const <LlamaToolCallContent>[];
  }

  if (rawToolCalls is! List) {
    throw OpenAiHttpException.invalidRequest(
      '`tool_calls` must be an array.',
      param: 'messages.tool_calls',
    );
  }

  final result = <LlamaToolCallContent>[];

  for (final rawToolCall in rawToolCalls) {
    if (rawToolCall is! Map) {
      throw OpenAiHttpException.invalidRequest(
        'Each tool call must be an object.',
        param: 'messages.tool_calls',
      );
    }

    final call = Map<String, dynamic>.from(rawToolCall);

    final id = call['id'];
    if (id is! String || id.trim().isEmpty) {
      throw OpenAiHttpException.invalidRequest(
        'Tool call IDs must be non-empty strings.',
        param: 'messages.tool_calls.id',
      );
    }

    if (call['type'] != 'function') {
      throw OpenAiHttpException.invalidRequest(
        'Only `type = "function"` tool calls are supported.',
        param: 'messages.tool_calls.type',
      );
    }

    final function = call['function'];
    if (function is! Map) {
      throw OpenAiHttpException.invalidRequest(
        'Tool calls require a `function` object.',
        param: 'messages.tool_calls.function',
      );
    }

    final functionMap = Map<String, dynamic>.from(function);
    final name = functionMap['name'];
    if (name is! String || name.isEmpty) {
      throw OpenAiHttpException.invalidRequest(
        'Tool call function name must be a non-empty string.',
        param: 'messages.tool_calls.function.name',
      );
    }

    if (!functionMap.containsKey('arguments')) {
      throw OpenAiHttpException.invalidRequest(
        'Tool calls require `function.arguments`.',
        param: 'messages.tool_calls.function.arguments',
      );
    }

    final rawArguments = functionMap['arguments'];
    final arguments = parseToolArguments(rawArguments);
    final rawJson = rawArguments is String && rawArguments.trim().isNotEmpty
        ? rawArguments
        : jsonEncode(arguments);

    result.add(
      LlamaToolCallContent(
        id: id,
        name: name,
        arguments: arguments,
        rawJson: rawJson,
      ),
    );
  }

  return result;
}
