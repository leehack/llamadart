import 'dart:convert';

import '../models/chat/chat_message.dart';
import '../models/chat/chat_role.dart';
import '../models/chat/content_part.dart';
import 'chat_format.dart';
import 'template_caps.dart';
import 'tool_call_parsing_utils.dart';

/// Template workarounds matching llama.cpp's `workaround` namespace.
///
/// These handle known quirks in model templates that need preprocessing
/// before rendering.
class TemplateWorkarounds {
  /// If the template doesn't support system role, merges system messages
  /// into the next user message.
  ///
  /// Matches llama.cpp's `workaround::system_message_not_supported`.
  static List<LlamaChatMessage> applySystemMessageWorkaround(
    List<LlamaChatMessage> messages,
    TemplateCaps caps,
  ) {
    if (caps.supportsSystemRole) return messages;
    if (messages.isEmpty) return messages;
    if (messages.first.role != LlamaChatRole.system) return messages;

    final result = List<LlamaChatMessage>.from(messages);
    final systemMsg = result.removeAt(0);

    if (result.isNotEmpty) {
      final next = result[0];
      result[0] = LlamaChatMessage.fromText(
        role: next.role,
        text: '${systemMsg.content}\n${next.content}',
      );
    }

    return result;
  }

  /// Applies format-specific workaround chain and returns transformed messages.
  static List<LlamaChatMessage> applyFormatWorkarounds(
    List<LlamaChatMessage> messages,
    ChatFormat format,
  ) {
    final needsFuncArgsNormalization = _formatsNeedFuncArgsNormalization
        .contains(format);
    final needsGenericSchema = _formatsNeedGenericSchema.contains(format);
    final needsMoveToolCallsToContent = _formatsNeedMoveToolCallsToContent
        .contains(format);

    if (!needsFuncArgsNormalization &&
        !needsGenericSchema &&
        !needsMoveToolCallsToContent) {
      return messages;
    }

    if (!_hasTypedToolCalls(messages)) {
      return messages;
    }

    final jsonMessages = messages.map((m) => m.toJson()).toList();

    if (needsFuncArgsNormalization) {
      normalizeToolCallArgs(jsonMessages);
    }

    if (needsGenericSchema) {
      useGenericSchema(jsonMessages);
    }

    if (needsMoveToolCallsToContent) {
      moveToolCallsToContent(jsonMessages);
    }

    return _messagesFromJson(jsonMessages, messages);
  }

  /// Ensures tool call arguments are JSON objects, not strings.
  ///
  /// Matches llama.cpp's `workaround::func_args_not_string`.
  static void normalizeToolCallArgs(List<Map<String, dynamic>> messages) {
    for (final message in messages) {
      final toolCalls = message['tool_calls'];
      if (toolCalls is! List) continue;

      for (var i = 0; i < toolCalls.length; i++) {
        final item = toolCalls[i];
        final toolCall = item is Map<String, dynamic>
            ? item
            : ToolCallParsingUtils.coerceMap(item);
        if (toolCall == null) continue;
        if (!identical(toolCall, item)) {
          toolCalls[i] = toolCall;
        }

        final function = ToolCallParsingUtils.coerceMap(toolCall['function']);
        if (function != null) {
          if (function.containsKey('arguments')) {
            function['arguments'] = _argumentsToObject(function['arguments']);
          }
          toolCall['function'] = function;
          continue;
        }

        if (toolCall.containsKey('arguments')) {
          toolCall['arguments'] = _argumentsToObject(toolCall['arguments']);
        }
      }
    }
  }

  /// Converts OpenAI-style tool call schema into generic short schema.
  ///
  /// Matches llama.cpp's `workaround::use_generic_schema`.
  static void useGenericSchema(List<Map<String, dynamic>> messages) {
    for (final message in messages) {
      final toolCalls = message['tool_calls'];
      if (toolCalls is! List) continue;

      for (var i = 0; i < toolCalls.length; i++) {
        final call = toolCalls[i];
        if (call is! Map<String, dynamic>) continue;

        final type = call['type'];
        final function = call['function'];
        if (type != 'function' || function is! Map<String, dynamic>) {
          continue;
        }

        Object? name;
        Object? arguments;
        Object? id;
        if (function.containsKey('name')) {
          name = function['name'];
        }
        if (function.containsKey('arguments')) {
          arguments = function['arguments'];
        }
        if (call.containsKey('id')) {
          id = call['id'];
        }

        call.clear();
        if (name != null) {
          call['name'] = name;
        }
        if (arguments != null) {
          call['arguments'] = arguments;
        }
        if (id != null) {
          call['id'] = id;
        }
      }
    }
  }

  /// Moves tool calls into message content as JSON string.
  ///
  /// Matches llama.cpp's `workaround::move_tool_calls_to_content`.
  static void moveToolCallsToContent(
    List<Map<String, dynamic>> messages, {
    int indentSpaces = 2,
  }) {
    for (final message in messages) {
      final toolCalls = message['tool_calls'];
      if (toolCalls is! List) continue;

      final currentContent = message['content'];
      final contentText = currentContent == null
          ? ''
          : currentContent.toString();
      final payload = {'tool_calls': toolCalls};
      final toolCallsJson = indentSpaces <= 0
          ? jsonEncode(payload)
          : JsonEncoder.withIndent(' ' * indentSpaces).convert(payload);

      message['content'] = '$contentText$toolCallsJson';
      message.remove('tool_calls');
    }
  }

  static bool _hasTypedToolCalls(List<LlamaChatMessage> messages) {
    return messages.any(
      (message) => message.parts.any((part) => part is LlamaToolCallContent),
    );
  }

  static Map<String, dynamic> _argumentsToObject(Object? args) {
    final map = ToolCallParsingUtils.decodeJsonMapValue(args);
    if (map != null) {
      return map;
    }

    if (args is String) {
      throw const FormatException('Tool call arguments must be a JSON object.');
    }

    if (args == null) {
      return <String, dynamic>{};
    }

    throw FormatException(
      'Unsupported tool call argument type: ${args.runtimeType}',
    );
  }

  static List<LlamaChatMessage> _messagesFromJson(
    List<Map<String, dynamic>> messages,
    List<LlamaChatMessage> originals,
  ) {
    return [
      for (var i = 0; i < messages.length; i++)
        _messageFromJson(messages[i], original: originals[i]),
    ];
  }

  static LlamaChatMessage _messageFromJson(
    Map<String, dynamic> message, {
    required LlamaChatMessage original,
  }) {
    final role = _parseRole(message['role'] as String? ?? 'user');
    final parts = <LlamaContentPart>[];

    final reasoning = message['reasoning_content'];
    if (reasoning is String && reasoning.isNotEmpty) {
      parts.add(LlamaThinkingContent(reasoning));
    }

    final toolCalls = message['tool_calls'];
    if (toolCalls is List) {
      for (final item in toolCalls) {
        final toolCall = ToolCallParsingUtils.coerceMap(item);
        if (toolCall == null) continue;

        final function = ToolCallParsingUtils.coerceMap(toolCall['function']);
        final name =
            toolCall['name'] as String? ?? (function?['name'] as String?);
        final arguments = toolCall['arguments'] ?? function?['arguments'];
        if (name == null) continue;

        final argObject = _argumentsToObject(arguments);
        final rawJson = arguments is String
            ? arguments
            : ToolCallParsingUtils.encodeArguments(argObject);

        parts.add(
          LlamaToolCallContent(
            id: toolCall['id'] as String?,
            name: name,
            arguments: argObject,
            rawJson: rawJson,
          ),
        );
      }
    }

    final content = message['content'];
    if (role == LlamaChatRole.tool) {
      parts.add(
        LlamaToolResultContent(
          id: message['tool_call_id'] as String?,
          name: message['name'] as String? ?? 'tool',
          result: content,
        ),
      );
    } else {
      parts.addAll(_extractContentParts(content, original: original));
    }

    if (parts.isEmpty) {
      return LlamaChatMessage.fromText(role: role, text: '');
    }

    return LlamaChatMessage.withContent(role: role, content: parts);
  }

  static List<LlamaContentPart> _extractContentParts(
    Object? content, {
    required LlamaChatMessage original,
  }) {
    if (content == null) return const [];
    if (content is String) {
      return content.isEmpty ? const [] : [LlamaTextContent(content)];
    }
    if (content is! List) {
      final text = content.toString();
      return text.isEmpty ? const [] : [LlamaTextContent(text)];
    }

    final originalImages = original.parts
        .whereType<LlamaImageContent>()
        .toList();
    final originalAudio = original.parts
        .whereType<LlamaAudioContent>()
        .toList();
    var imageIndex = 0;
    var audioIndex = 0;
    final parts = <LlamaContentPart>[];

    for (final item in content) {
      if (item is! Map<String, dynamic>) continue;
      switch (item['type']) {
        case 'text':
          final text = item['text'];
          if (text is String && text.isNotEmpty) {
            parts.add(LlamaTextContent(text));
          }
          break;
        case 'image':
        case 'image_url':
          if (imageIndex < originalImages.length) {
            parts.add(originalImages[imageIndex++]);
          } else {
            parts.add(_imageContentFromJson(item));
          }
          break;
        case 'input_audio':
        case 'audio':
          if (audioIndex < originalAudio.length) {
            parts.add(originalAudio[audioIndex++]);
          }
          break;
      }
    }

    return parts;
  }

  static LlamaImageContent _imageContentFromJson(Map<String, dynamic> item) {
    final imageUrl = item['image_url'];
    final url = imageUrl is Map<String, dynamic> ? imageUrl['url'] : null;
    if (url is String && url.startsWith('file://')) {
      return LlamaImageContent(path: url.substring('file://'.length));
    }
    if (url is String && url.isNotEmpty) {
      return LlamaImageContent(url: url);
    }
    return const LlamaImageContent();
  }

  static LlamaChatRole _parseRole(String role) {
    switch (role) {
      case 'system':
        return LlamaChatRole.system;
      case 'assistant':
        return LlamaChatRole.assistant;
      case 'tool':
        return LlamaChatRole.tool;
      case 'user':
      default:
        return LlamaChatRole.user;
    }
  }

  static const Set<ChatFormat> _formatsNeedFuncArgsNormalization = {
    ChatFormat.commandR7B,
    ChatFormat.granite,
    ChatFormat.glm45,
    ChatFormat.qwen3CoderXml,
    ChatFormat.minimaxM2,
    ChatFormat.seedOss,
    ChatFormat.llama3,
    ChatFormat.llama3BuiltinTools,
    ChatFormat.mistralNemo,
    ChatFormat.generic,
  };

  static const Set<ChatFormat> _formatsNeedGenericSchema = {
    ChatFormat.granite,
    ChatFormat.generic,
  };

  static const Set<ChatFormat> _formatsNeedMoveToolCallsToContent = {
    ChatFormat.granite,
    ChatFormat.generic,
  };
}
