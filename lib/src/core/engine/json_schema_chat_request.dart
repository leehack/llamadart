import 'dart:convert';

import '../exceptions.dart';
import '../grammar/response_schema_validation.dart';
import '../models/chat/chat_message.dart';
import '../models/chat/chat_role.dart';
import '../models/chat/content_part.dart';
import '../models/inference/generation_params.dart';

/// Validates the bounded schema-chat SPI and snapshots its JSON payload.
String jsonSchemaChatPayload(Map<String, dynamic> schema) {
  validateResponseSchema(schema);
  const scalars = {'string', 'integer', 'number', 'boolean', 'null'};
  const rootKeys = {
    'type',
    'properties',
    'required',
    'additionalProperties',
    'title',
    'description',
    r'$schema',
    r'$id',
    r'$comment',
  };
  const leafKeys = {'type', 'enum', 'const', 'title', 'description'};
  Never unsupported(String path) => throw LlamaUnsupportedException(
    'Native JSON Schema chat supports object schemas with scalar properties, '
    'required, enum, const and additionalProperties only; unsupported $path.',
  );
  if (schema['type'] != 'object') unsupported(r'$.type');
  for (final key in schema.keys) {
    if (!rootKeys.contains(key)) unsupported('\$.$key');
  }
  final properties = schema['properties'];
  if (properties != null) {
    if (properties is! Map<String, dynamic>) unsupported(r'$.properties');
    for (final entry in properties.entries) {
      final leaf = entry.value;
      final path = '\$.properties.${entry.key}';
      if (leaf is! Map<String, dynamic> || !scalars.contains(leaf['type'])) {
        unsupported('$path.type');
      }
      for (final key in leaf.keys) {
        if (!leafKeys.contains(key)) unsupported('$path.$key');
      }
      for (final value in [
        if (leaf.containsKey('const')) leaf['const'],
        ...?leaf['enum'] as List?,
      ]) {
        if (value is Map || value is List) unsupported(path);
      }
    }
  }
  if (schema.containsKey('additionalProperties') &&
      schema['additionalProperties'] is! bool) {
    unsupported(r'$.additionalProperties');
  }
  return jsonEncode(schema);
}

/// Rejects request modes outside the schema-chat SPI before native admission.
void validateJsonSchemaChatRequest(
  List<LlamaChatMessage> messages,
  GenerationParams params, {
  bool hasTools = false,
  bool requiredTools = false,
  bool parallelToolCalls = false,
  bool enableThinking = false,
}) {
  String? reason;
  if (hasTools || requiredTools || parallelToolCalls) {
    reason = 'tools and parallel tool calls';
  } else if (enableThinking || params.thinkingBudget != null) {
    reason =
        'thinking; pass enableThinking: false, set no enable_thinking or '
        'thinking chat template kwarg to true, and set no thinking budget';
  } else if (params.isSpeculativeDecodingEnabled) {
    reason = 'speculative decoding';
  } else if (params.stopSequences.isNotEmpty) {
    reason = 'caller stop sequences';
  } else if (params.grammar != null ||
      params.grammarLazy ||
      params.grammarTriggers.isNotEmpty ||
      params.preservedTokens.isNotEmpty ||
      params.grammarRoot != 'root') {
    reason = 'GBNF grammar parameters';
  } else if (messages.isEmpty ||
      messages.last.role != LlamaChatRole.user ||
      messages.any(
        (message) =>
            message.role == LlamaChatRole.tool ||
            message.continuesPreviousTurn ||
            message.parts.any((part) => part is! LlamaTextContent),
      )) {
    reason =
        'media, reasoning, tool messages, or assistant continuation; '
        'use system/user/assistant text ending in a user message';
  }
  if (reason != null) {
    throw LlamaUnsupportedException(
      'Native JSON Schema chat does not support $reason.',
    );
  }
}
