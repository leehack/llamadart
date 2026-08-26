import 'package:dinja/dinja.dart';

import '../../grammar/json_schema_converter.dart';
import '../../models/chat/chat_message.dart';
import '../../models/chat/chat_role.dart';
import '../../models/chat/chat_template_result.dart';
import '../../models/chat/completion_chunk.dart';
import '../../models/chat/content_part.dart';
import '../../models/inference/tool_choice.dart';
import '../../models/tools/tool_definition.dart';
import '../chat_format.dart';
import '../chat_parse_result.dart';
import '../chat_template_handler.dart';
import '../template_internal_metadata.dart';
import '../thinking_utils.dart';
import '../tool_call_fallback_parser.dart';
import '../tool_call_grammar_utils.dart';
import '../tool_call_parsing_utils.dart';
import '../tool_schema_utils.dart';

/// Handler for Gemma 4 chat templates.
///
/// Gemma 4 uses `<|turn>/<turn|>` message frames, optional
/// `<|channel>thought...<channel|>` reasoning blocks, and
/// `<|tool_call>call:name{args}<tool_call|>` tool-call envelopes.
class Gemma4Handler extends ChatTemplateHandler
    implements ToolSchemaAwareChatTemplateHandler {
  static const String _turnEnd = '<turn|>';
  static const String _toolCallStart = '<|tool_call>';
  static const String _toolCallEnd = '<tool_call|>';
  static const String _callMarker = 'call:';
  static const String _channelStart = '<|channel>';
  static const String _channelEnd = '<channel|>';
  static const List<String> _customQuoteTokens = <String>['<|\\"|>', '<|"|>'];
  static const Set<String> _invalidToolNames = <String>{
    'func_name',
    'function_name',
    'name',
  };

  @override
  ChatFormat get format => ChatFormat.gemma4;

  @override
  String get thinkingStartTag => '<|channel>thought\n';

  @override
  String get thinkingEndTag => _channelEnd;

  @override
  List<String> get additionalStops => const [_turnEnd, _toolCallEnd];

  @override
  List<String> getStops({bool hasTools = false, bool enableThinking = true}) {
    return hasTools ? const [_toolCallEnd, _turnEnd] : const <String>[_turnEnd];
  }

  @override
  LlamaChatTemplateResult render({
    required String templateSource,
    required List<LlamaChatMessage> messages,
    required Map<String, String> metadata,
    bool addAssistant = true,
    List<ToolDefinition>? tools,
    bool enableThinking = true,
  }) {
    return _renderInternal(
      templateSource: templateSource,
      messages: messages,
      metadata: metadata,
      addAssistant: addAssistant,
      tools: tools,
      enableThinking: enableThinking,
      multimodalContent: false,
    );
  }

  @override
  LlamaChatTemplateResult renderWithMultimodalContent({
    required String templateSource,
    required List<LlamaChatMessage> messages,
    required Map<String, String> metadata,
    bool addAssistant = true,
    List<ToolDefinition>? tools,
    bool enableThinking = true,
  }) {
    return _renderInternal(
      templateSource: templateSource,
      messages: messages,
      metadata: metadata,
      addAssistant: addAssistant,
      tools: tools,
      enableThinking: enableThinking,
      multimodalContent: true,
    );
  }

  LlamaChatTemplateResult _renderInternal({
    required String templateSource,
    required List<LlamaChatMessage> messages,
    required Map<String, String> metadata,
    required bool addAssistant,
    required List<ToolDefinition>? tools,
    required bool enableThinking,
    required bool multimodalContent,
  }) {
    final template = Template(templateSource);
    var prompt = renderTemplate(
      template,
      metadata: metadata,
      context: {
        'messages': _serializeMessages(
          messages,
          multimodalContent: multimodalContent,
        ),
        'add_generation_prompt': addAssistant,
        'tools': tools?.map((t) => t.toJson()).toList(),
        'enable_thinking': enableThinking,
        'bos_token': metadata['tokenizer.ggml.bos_token'] ?? '<bos>',
        'eos_token': metadata['tokenizer.ggml.eos_token'] ?? _turnEnd,
      },
    );

    var thinkingForcedOpen = false;
    if (isThinkingForcedOpen(prompt, startTag: thinkingStartTag.trimRight())) {
      if (!enableThinking) {
        prompt = '${prompt.trimRight()}$_channelEnd\n';
      } else {
        thinkingForcedOpen = true;
      }
    }

    final hasTools = tools != null && tools.isNotEmpty;
    // Upstream llama.cpp only makes the Gemma 4 tool grammar eager for
    // `required`; `auto` stays unconstrained so the model can answer in prose.
    final toolChoiceRequired =
        metadata[internalToolChoiceMetadataKey] == ToolChoice.required.name;
    return LlamaChatTemplateResult(
      prompt: prompt,
      format: format.index,
      grammar: hasTools && toolChoiceRequired ? buildGrammar(tools) : null,
      grammarLazy: false,
      thinkingForcedOpen: thinkingForcedOpen,
      additionalStops: getStops(
        hasTools: hasTools,
        enableThinking: enableThinking,
      ),
      grammarTriggers: const [],
    );
  }

  List<Map<String, dynamic>> _serializeMessages(
    List<LlamaChatMessage> messages, {
    required bool multimodalContent,
  }) {
    return messages
        .map((message) {
          if (message.role == LlamaChatRole.tool) {
            return _serializeToolMessage(message);
          }

          return multimodalContent
              ? message.toJsonMultimodal()
              : message.toJson();
        })
        .toList(growable: false);
  }

  Map<String, dynamic> _serializeToolMessage(LlamaChatMessage message) {
    final toolResults = message.parts
        .whereType<LlamaToolResultContent>()
        .toList();
    if (toolResults.isEmpty) {
      return message.toJson();
    }

    return {
      'role': 'tool',
      'content': null,
      'tool_responses': toolResults
          .map(
            (result) => {
              'name': result.name,
              'response': _normalizeToolResponse(result.result),
            },
          )
          .toList(growable: false),
    };
  }

  Map<String, dynamic> _normalizeToolResponse(Object? result) {
    if (result == null) {
      return {'value': null};
    }

    final map = ToolCallParsingUtils.coerceMap(result);
    if (map != null) {
      return map;
    }

    if (result is String) {
      final decoded = ToolCallParsingUtils.decodeJsonObject(result);
      if (decoded != null) {
        return decoded;
      }
      return {'value': result};
    }

    return {'value': result};
  }

  @override
  ChatParseResult parse(
    String output, {
    bool isPartial = false,
    bool parseToolCalls = true,
    bool thinkingForcedOpen = false,
  }) => _parseInternal(
    output,
    tools: null,
    isPartial: isPartial,
    parseToolCalls: parseToolCalls,
    thinkingForcedOpen: thinkingForcedOpen,
  );

  @override
  ChatParseResult parseWithTools(
    String output, {
    List<ToolDefinition>? tools,
    bool isPartial = false,
    bool parseToolCalls = true,
    bool thinkingForcedOpen = false,
  }) => _parseInternal(
    output,
    tools: tools,
    isPartial: isPartial,
    parseToolCalls: parseToolCalls,
    thinkingForcedOpen: thinkingForcedOpen,
  );

  ChatParseResult _parseInternal(
    String output, {
    required List<ToolDefinition>? tools,
    required bool isPartial,
    required bool parseToolCalls,
    required bool thinkingForcedOpen,
  }) {
    final reasoning = _extractReasoning(
      output,
      isPartial: isPartial,
      thinkingForcedOpen: thinkingForcedOpen,
    );

    if (!parseToolCalls) {
      final sanitized = _extractToolCalls(
        reasoning.content,
        isPartial: isPartial,
        tools: tools,
      );
      return ChatParseResult(
        content: _visibleContent(
          sanitized.content,
          hasToolCalls: sanitized.toolCalls.isNotEmpty,
        ),
        reasoningContent: reasoning.reasoning,
      );
    }

    final parsed = _extractToolCalls(
      reasoning.content,
      isPartial: isPartial,
      tools: tools,
    );
    if (parsed.toolCalls.isEmpty) {
      final fallback = parseToolCallsFromLooseText(parsed.content);
      if (fallback.toolCalls.isNotEmpty) {
        return ChatParseResult(
          content: fallback.content,
          reasoningContent: reasoning.reasoning,
          toolCalls: fallback.toolCalls,
        );
      }
    }
    return ChatParseResult(
      content: _visibleContent(
        parsed.content,
        hasToolCalls: parsed.toolCalls.isNotEmpty,
      ),
      reasoningContent: reasoning.reasoning,
      toolCalls: parsed.toolCalls,
    );
  }

  String _visibleContent(String content, {required bool hasToolCalls}) {
    // A pure structured call may be surrounded by protocol whitespace that
    // should not become an assistant message. Once there is ordinary visible
    // text, preserve its whitespace exactly.
    return hasToolCalls && content.trim().isEmpty ? '' : content;
  }

  ({String content, String? reasoning}) _extractReasoning(
    String output, {
    required bool isPartial,
    required bool thinkingForcedOpen,
  }) {
    final reasoningParts = <String>[];
    final content = StringBuffer();
    var cursor = 0;

    while (cursor < output.length) {
      if (thinkingForcedOpen) {
        final end = output.indexOf(_channelEnd, cursor);
        if (end == -1) {
          final remaining = output.substring(cursor);
          final heldPrefixLength = _controlMarkerPrefixLength(
            remaining,
            _channelEnd,
            isPartial: isPartial,
          );
          final reasoning = remaining.substring(
            0,
            remaining.length - heldPrefixLength,
          );
          if (reasoning.isNotEmpty) {
            reasoningParts.add(reasoning);
          }
          break;
        }

        final reasoning = output.substring(cursor, end);
        if (reasoning.isNotEmpty) {
          reasoningParts.add(reasoning);
        }
        cursor = end + _channelEnd.length;
        thinkingForcedOpen = false;
        continue;
      }

      final start = output.indexOf(_channelStart, cursor);
      if (start == -1) {
        final remaining = output.substring(cursor);
        final heldPrefixLength = _max(
          _controlMarkerPrefixLength(
            remaining,
            _channelStart,
            isPartial: isPartial,
          ),
          _controlMarkerPrefixLength(
            remaining,
            _channelEnd,
            isPartial: isPartial,
          ),
        );
        content.write(
          remaining
              .substring(0, remaining.length - heldPrefixLength)
              .replaceAll(_channelEnd, ''),
        );
        break;
      }

      final end = output.indexOf(_channelEnd, start + _channelStart.length);
      if (end == -1) {
        content.write(output.substring(cursor, start));
        final partial = _parseChannelBlock(
          output.substring(start),
          isPartial: true,
        );
        if (partial != null && partial.channel == 'thought') {
          if (partial.body.isNotEmpty) {
            reasoningParts.add(partial.body);
          }
        } else if (!isPartial && partial != null && partial.body.isNotEmpty) {
          content.write(partial.body);
        }
        break;
      }

      content.write(output.substring(cursor, start));
      final parsed = _parseChannelBlock(
        output.substring(start, end + _channelEnd.length),
        isPartial: false,
      );
      final channel = parsed?.channel;
      final body = parsed?.body ?? '';

      if (channel == 'thought') {
        if (body.isNotEmpty) {
          reasoningParts.add(body);
        }
      } else {
        content.write(body);
      }

      cursor = end + _channelEnd.length;
    }

    return (
      content: content.toString(),
      reasoning: reasoningParts.isEmpty ? null : reasoningParts.join('\n'),
    );
  }

  ({String channel, String body})? _parseChannelBlock(
    String input, {
    required bool isPartial,
  }) {
    if (!input.startsWith(_channelStart)) {
      return null;
    }

    final blockEnd = isPartial
        ? input.length
        : input.indexOf(_channelEnd, _channelStart.length);
    if (blockEnd == -1) {
      return null;
    }

    final block = input.substring(_channelStart.length, blockEnd);
    final newline = block.indexOf('\n');
    if (newline == -1) {
      return isPartial
          ? (channel: block.trim(), body: '')
          : (channel: block.trim(), body: '');
    }

    final rawBody = block.substring(newline + 1);
    final heldPrefixLength = isPartial
        ? _trailingMarkerPrefixLength(rawBody, _channelEnd)
        : 0;
    return (
      channel: block.substring(0, newline).trim(),
      body: rawBody.substring(0, rawBody.length - heldPrefixLength),
    );
  }

  ({String content, List<LlamaCompletionChunkToolCall> toolCalls})
  _extractToolCalls(
    String output, {
    required bool isPartial,
    required List<ToolDefinition>? tools,
  }) {
    final toolCalls = <LlamaCompletionChunkToolCall>[];
    final content = StringBuffer();
    var cursor = 0;

    while (cursor < output.length) {
      final start = output.indexOf(_toolCallStart, cursor);
      if (start == -1) {
        final remaining = output.substring(cursor);
        final heldPrefixLength = _max(
          _controlMarkerPrefixLength(
            remaining,
            _toolCallStart,
            isPartial: isPartial,
          ),
          _controlMarkerPrefixLength(
            remaining,
            _toolCallEnd,
            isPartial: isPartial,
          ),
        );
        content.write(
          remaining
              .substring(0, remaining.length - heldPrefixLength)
              .replaceAll(_toolCallEnd, ''),
        );
        break;
      }

      content.write(output.substring(cursor, start));
      final parsed = _parseToolCall(
        output,
        start,
        toolCalls.length,
        tools: tools,
      );
      if (parsed == null) {
        break;
      }

      toolCalls.add(parsed.toolCall);
      cursor = parsed.end;
    }

    return (content: content.toString(), toolCalls: toolCalls);
  }

  ({int end, LlamaCompletionChunkToolCall toolCall})? _parseToolCall(
    String output,
    int start,
    int index, {
    required List<ToolDefinition>? tools,
  }) {
    var cursor = _skipWhitespace(output, start + _toolCallStart.length);

    if (output.startsWith('call', cursor)) {
      cursor += 4;
      cursor = _skipWhitespace(output, cursor);
      if (cursor < output.length && output.codeUnitAt(cursor) == 0x3A) {
        cursor++;
      }
      cursor = _skipWhitespace(output, cursor);
    }

    final parsedName = _parseToolName(output, cursor, tools: tools);
    if (parsedName == null) {
      return null;
    }
    final name = parsedName.name;
    cursor = parsedName.argumentsStart;

    final endBrace = _findMatchingBrace(output, cursor);
    if (endBrace == -1) {
      return null;
    }

    var end = _skipWhitespace(output, endBrace + 1);
    if (output.startsWith(_toolCallEnd, end)) {
      end += _toolCallEnd.length;
    }

    final arguments = _normalizePseudoJson(
      output.substring(cursor, endBrace + 1),
    );
    final decodedArguments = normalizeFallbackToolArguments(
      decodeToolArgumentsObject(arguments),
    );
    final normalizedName = normalizeFallbackToolName(
      name,
      arguments: decodedArguments,
    );

    return (
      end: end,
      toolCall: ToolCallParsingUtils.createFunctionToolCall(
        index: index,
        name: normalizedName,
        arguments: decodedArguments,
      ),
    );
  }

  String _normalizePseudoJson(String input) {
    final normalizedQuotes = input
        .replaceAll(RegExp(r'<\|\\?"\|>'), '"')
        .replaceAll('<escape>', '"');

    return normalizedQuotes.replaceAllMapped(
      RegExp(r'(^|[{,])\s*([a-zA-Z_][\w\.-]*)\s*:'),
      (match) => '${match.group(1)}"${match.group(2)}":',
    );
  }

  int _findMatchingBrace(String text, int start) {
    var depth = 0;
    var inString = false;
    var escaped = false;

    for (var i = start; i < text.length; i++) {
      final quoteTokenLength = _customQuoteTokenLengthAt(text, i);

      if (inString) {
        if (quoteTokenLength != null) {
          inString = false;
          i += quoteTokenLength - 1;
          continue;
        }

        final codeUnit = text.codeUnitAt(i);
        if (escaped) {
          escaped = false;
          continue;
        }
        if (codeUnit == 0x5C) {
          escaped = true;
          continue;
        }
        if (codeUnit == 0x22) {
          inString = false;
        }
        continue;
      }

      if (quoteTokenLength != null) {
        inString = true;
        i += quoteTokenLength - 1;
        continue;
      }

      final codeUnit = text.codeUnitAt(i);
      if (codeUnit == 0x22) {
        inString = true;
      } else if (codeUnit == 0x7B) {
        depth++;
      } else if (codeUnit == 0x7D) {
        depth--;
        if (depth == 0) {
          return i;
        }
      }
    }
    return -1;
  }

  int? _customQuoteTokenLengthAt(String text, int index) {
    for (final token in _customQuoteTokens) {
      if (text.startsWith(token, index)) {
        return token.length;
      }
    }
    return null;
  }

  int _skipWhitespace(String text, int start) {
    var offset = start;
    while (offset < text.length && _isWhitespace(text.codeUnitAt(offset))) {
      offset++;
    }
    return offset;
  }

  ({String name, int argumentsStart})? _parseToolName(
    String output,
    int start, {
    required List<ToolDefinition>? tools,
  }) {
    if (tools != null && tools.isNotEmpty) {
      ToolDefinition? bestMatch;
      var bestArgumentsStart = -1;
      for (final tool in tools) {
        if (!output.startsWith(tool.name, start)) {
          continue;
        }
        final argumentsStart = _skipWhitespace(
          output,
          start + tool.name.length,
        );
        if (argumentsStart >= output.length ||
            output.codeUnitAt(argumentsStart) != 0x7B) {
          continue;
        }
        if (bestMatch == null || tool.name.length > bestMatch.name.length) {
          bestMatch = tool;
          bestArgumentsStart = argumentsStart;
        }
      }
      if (bestMatch == null) {
        return _parseUndeclaredToolName(output, start);
      }
      return (name: bestMatch.name, argumentsStart: bestArgumentsStart);
    }

    return _parseUndeclaredToolName(output, start);
  }

  ({String name, int argumentsStart})? _parseUndeclaredToolName(
    String output,
    int start,
  ) {
    var cursor = start;
    while (cursor < output.length && output.codeUnitAt(cursor) != 0x7B) {
      cursor++;
    }
    final name = output.substring(start, cursor).trimRight();
    if (name.isEmpty || _invalidToolNames.contains(name)) {
      return null;
    }
    if (cursor >= output.length || output.codeUnitAt(cursor) != 0x7B) {
      return null;
    }
    return (name: name, argumentsStart: cursor);
  }

  int _trailingMarkerPrefixLength(String text, String marker) {
    final maxLength = text.length < marker.length
        ? text.length
        : marker.length - 1;
    for (var length = maxLength; length > 0; length--) {
      if (text.endsWith(marker.substring(0, length))) {
        return length;
      }
    }
    return 0;
  }

  int _controlMarkerPrefixLength(
    String text,
    String marker, {
    required bool isPartial,
  }) {
    final length = _trailingMarkerPrefixLength(text, marker);
    return isPartial || length >= 2 ? length : 0;
  }

  int _max(int a, int b) => a > b ? a : b;

  bool _isWhitespace(int codeUnit) {
    return codeUnit == 0x20 ||
        codeUnit == 0x0A ||
        codeUnit == 0x0D ||
        codeUnit == 0x09;
  }

  /// Builds a grammar admitting exactly one
  /// `<|tool_call>call:<name>{args}<tool_call|>` envelope.
  ///
  /// Arguments use standard JSON, which [parse] already accepts alongside the
  /// model's pseudo-JSON spelling.
  @override
  String? buildGrammar(List<ToolDefinition>? tools) {
    if (tools == null || tools.isEmpty) {
      return null;
    }

    // Grammar alternatives and parser routing both depend on exact tool and
    // parameter identities. Reject lossy duplicates before constructing rules.
    toolSchemas(tools);

    final converter = JsonSchemaConverter();
    final callRules = <String>[];

    for (var i = 0; i < tools.length; i++) {
      final tool = tools[i];
      final schema = tool.toJsonSchema();
      converter.resolveRefs(schema, schema);
      final argsRule = converter.visit(schema, 'tool-$i-args');
      final callRule = 'tool-$i-call';
      converter.rules[callRule] =
          '${ToolCallGrammarUtils.literal('$_toolCallStart$_callMarker${tool.name}')} '
          '$argsRule '
          '${ToolCallGrammarUtils.literal(_toolCallEnd)}';
      callRules.add(callRule);
    }

    final buffer = StringBuffer()..writeln('root ::= ${callRules.join(' | ')}');
    final otherRules = converter.rules.entries.toList(growable: false)
      ..sort((a, b) => a.key.compareTo(b.key));
    for (final entry in otherRules) {
      if (entry.key == 'root') {
        continue;
      }
      buffer.writeln('${entry.key} ::= ${entry.value}');
    }

    return buffer.toString();
  }
}
