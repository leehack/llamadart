import 'package:llamadart/llamadart.dart';

import '../../../shared/openai_http_exception.dart';
import 'message_parsing/assistant_tool_calls_parser.dart';
import 'message_parsing/message_content_part_parser.dart';
import 'message_parsing/message_content_utils.dart';
import 'message_parsing/message_role_parser.dart';
import 'message_parsing/tool_message_parser.dart';

/// Parses an ordered OpenAI chat transcript.
///
/// Tool-result messages use an earlier assistant tool-call ID to recover the
/// function name required by native chat templates.
List<LlamaChatMessage> parseChatMessages(List<Object?> rawMessages) {
  final pendingToolNames = <String, String>{};
  final messages = <LlamaChatMessage>[];

  for (final raw in rawMessages) {
    final message = parseChatMessage(raw, pendingToolNames: pendingToolNames);
    messages.add(message);

    if (message.role == LlamaChatRole.assistant) {
      for (final toolCall in message.parts.whereType<LlamaToolCallContent>()) {
        final id = toolCall.id!;
        if (pendingToolNames.containsKey(id)) {
          throw OpenAiHttpException.invalidRequest(
            'Assistant tool call IDs must be unique within the transcript.',
            param: 'messages.tool_calls.id',
          );
        }
        pendingToolNames[id] = toolCall.name;
      }
    } else if (message.role == LlamaChatRole.tool) {
      final toolResult = message.parts.single as LlamaToolResultContent;
      pendingToolNames.remove(toolResult.id);
    }
  }

  return List<LlamaChatMessage>.unmodifiable(messages);
}

LlamaChatMessage parseChatMessage(
  Object? raw, {
  Map<String, String>? pendingToolNames,
}) {
  if (raw is! Map) {
    throw OpenAiHttpException.invalidRequest(
      'Each message must be a JSON object.',
      param: 'messages',
    );
  }

  final message = Map<String, dynamic>.from(raw);
  final roleRaw = message['role'];
  if (roleRaw is! String || roleRaw.isEmpty) {
    throw OpenAiHttpException.invalidRequest(
      'Message `role` must be a non-empty string.',
      param: 'messages.role',
    );
  }

  final role = parseMessageRole(roleRaw);
  if (role == LlamaChatRole.tool) {
    return parseToolRoleMessage(
      message,
      pendingToolNames: pendingToolNames ?? const <String, String>{},
    );
  }

  final parts = parseContentParts(message['content'], role);
  if (role == LlamaChatRole.assistant) {
    _appendAssistantParts(parts, message);
  }

  if (parts.isEmpty) {
    if (role != LlamaChatRole.assistant) {
      throw OpenAiHttpException.invalidRequest(
        'Message content cannot be empty for role `${role.name}`.',
        param: 'messages.content',
      );
    }
    parts.add(const LlamaTextContent(''));
  }

  return LlamaChatMessage.withContent(role: role, content: parts);
}

void _appendAssistantParts(
  List<LlamaContentPart> parts,
  Map<String, dynamic> message,
) {
  final reasoning = readContentAsString(message['reasoning_content']).trim();
  if (reasoning.isNotEmpty) {
    parts.add(LlamaThinkingContent(reasoning));
  }

  parts.addAll(parseAssistantToolCalls(message['tool_calls']));
}
