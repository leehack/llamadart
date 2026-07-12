import 'package:llamadart/llamadart.dart';

import '../../../../shared/openai_http_exception.dart';
import 'message_content_utils.dart';

LlamaChatMessage parseToolRoleMessage(
  Map<String, dynamic> message, {
  required Map<String, String> pendingToolNames,
}) {
  final toolCallId = message['tool_call_id'];
  if (toolCallId is! String || toolCallId.trim().isEmpty) {
    throw OpenAiHttpException.invalidRequest(
      '`tool_call_id` must be a non-empty string.',
      param: 'messages.tool_call_id',
    );
  }

  final name = pendingToolNames[toolCallId];
  if (name == null) {
    throw OpenAiHttpException.invalidRequest(
      '`tool_call_id` must reference an earlier assistant tool call.',
      param: 'messages.tool_call_id',
    );
  }

  if (!message.containsKey('content')) {
    throw OpenAiHttpException.invalidRequest(
      'Tool messages require `content`.',
      param: 'messages.content',
    );
  }

  final suppliedName = message['name'];
  if (suppliedName != null && suppliedName is! String) {
    throw OpenAiHttpException.invalidRequest(
      '`name` must be a string when provided on a tool message.',
      param: 'messages.name',
    );
  }
  if (suppliedName is String &&
      suppliedName.isNotEmpty &&
      suppliedName != name) {
    throw OpenAiHttpException.invalidRequest(
      'Tool message `name` must match the referenced assistant tool call.',
      param: 'messages.name',
    );
  }

  final content = readContentAsString(message['content']);

  return LlamaChatMessage.withContent(
    role: LlamaChatRole.tool,
    content: <LlamaContentPart>[
      LlamaToolResultContent(id: toolCallId, name: name, result: content),
    ],
  );
}
