import 'dart:convert';

import 'package:dinja/dinja.dart';

import '../../models/chat/chat_message.dart';
import '../../models/chat/chat_template_result.dart';
import '../../models/chat/completion_chunk.dart';
import '../../models/inference/tool_choice.dart';
import '../../models/tools/tool_definition.dart';
import '../chat_format.dart';
import '../chat_parse_result.dart';
import '../chat_template_handler.dart';
import '../template_internal_metadata.dart';
import '../thinking_utils.dart';
import '../tool_call_grammar_utils.dart';
import '../tool_call_parsing_utils.dart';
import '../tool_schema_utils.dart';

/// Handler for Command R7B format.
///
/// Uses `<|START_ACTION|>` / `<|END_ACTION|>` for tool calls.
/// Tool call format: `<|START_ACTION|>{"tool_name": "fn", "parameters": {...}}<|END_ACTION|>`
///
/// Supports thinking with `<|START_THINKING|>` / `<|END_THINKING|>`.
class CommandR7BHandler extends ChatTemplateHandler {
  static const String _startAction = '<|START_ACTION|>';
  static const String _startText = '<|START_TEXT|>';
  static const String _startResponse = '<|START_RESPONSE|>';

  /// Finds where [parse] may find a tool-call or text opening in [text].
  ///
  /// Returns the first index at or after [from] where `<|START_ACTION|>`,
  /// `<|START_TEXT|>`, `<|START_RESPONSE|>` or a bare JSON array of objects
  /// starts, or where the rest of [text] is the start of one, and
  /// `text.length` when there is none.
  static int toolCallOpening(String text, [int from = 0]) {
    final literal = ToolCallParsingUtils.literalOpening(text, const [
      _startAction,
      _startText,
      _startResponse,
    ], from);
    for (var index = from; index < literal; index++) {
      if (text.codeUnitAt(index) != 0x5B) {
        continue;
      }
      var next = index + 1;
      while (next < text.length && _isJsonWhitespace(text.codeUnitAt(next))) {
        next++;
      }
      if (next == text.length || text.codeUnitAt(next) == 0x7B) {
        return index;
      }
    }
    return literal;
  }

  static bool _isJsonWhitespace(int codeUnit) =>
      codeUnit == 0x20 ||
      codeUnit == 0x09 ||
      codeUnit == 0x0A ||
      codeUnit == 0x0D;

  @override
  ChatFormat get format => ChatFormat.commandR7B;

  @override
  TemplateToolCallSerialization get toolCallSerialization =>
      TemplateToolCallSerialization.normalizeOnly;

  @override
  String get thinkingStartTag => '<|START_THINKING|>';

  @override
  String get thinkingEndTag => '<|END_THINKING|>';

  @override
  List<String> get additionalStops => ['<|END_RESPONSE|>'];

  @override
  List<String> getStops({bool hasTools = false, bool enableThinking = true}) {
    return [...additionalStops, if (hasTools) '<|END_ACTION|>'];
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
    final template = Template(templateSource);
    var prompt = renderTemplate(
      template,
      metadata: metadata,
      context: {
        'messages': templateMessages(messages, templateSource: templateSource),
        'add_generation_prompt': addAssistant,
        'tools': tools?.map((t) => t.toJson()).toList(),
        'bos_token':
            metadata['tokenizer.ggml.bos_token'] ?? '<|START_OF_TURN_TOKEN|>',
        'eos_token':
            metadata['tokenizer.ggml.eos_token'] ?? '<|END_OF_TURN_TOKEN|>',
        'enable_thinking': enableThinking,
        'reasoning': enableThinking,
        'skip_thinking': !enableThinking,
      },
    );

    // Handle enableThinking post-render logic
    var thinkingForcedOpen = false;
    if (isThinkingForcedOpen(prompt, startTag: thinkingStartTag)) {
      if (!enableThinking) {
        prompt = '${prompt.trimRight()}$thinkingEndTag\n';
      } else {
        thinkingForcedOpen = true;
      }
    }

    final hasTools = tools != null && tools.isNotEmpty;
    final toolChoice = metadata[internalToolChoiceMetadataKey];
    final toolChoiceRequired = toolChoice == ToolChoice.required.name;
    return LlamaChatTemplateResult(
      prompt: prompt,
      format: format.index,
      grammar: buildGrammar(tools),
      grammarLazy: hasTools && !toolChoiceRequired,
      thinkingForcedOpen: thinkingForcedOpen,
      additionalStops: getStops(
        hasTools: hasTools,
        enableThinking: enableThinking,
      ),
      grammarTriggers: hasTools
          ? [const GrammarTrigger(type: 0, value: '<|START_ACTION|>')]
          : [],
    );
  }

  @override
  ChatParseResult parse(
    String output, {
    bool isPartial = false,
    bool parseToolCalls = true,
    bool thinkingForcedOpen = false,
  }) {
    final thinking = extractThinking(
      output,
      thinkingForcedOpen: thinkingForcedOpen,
      startTag: thinkingStartTag,
      endTag: thinkingEndTag,
    );
    final text = thinking.content;

    const endAction = '<|END_ACTION|>';
    const endText = '<|END_TEXT|>';
    const endResponse = '<|END_RESPONSE|>';

    final textStart = text.indexOf(_startText);
    if (textStart != -1) {
      final prelude = text.substring(0, textStart);
      final bodyStart = textStart + _startText.length;
      final textEnd = text.indexOf(endText, bodyStart);
      final bodyEnd = textEnd == -1 ? text.length : textEnd;
      final trailing = textEnd == -1
          ? ''
          : text.substring(textEnd + endText.length).trim();
      if (trailing.isNotEmpty) {
        return ChatParseResult(
          content: text.trim(),
          reasoningContent: thinking.reasoning,
        );
      }

      return ChatParseResult(
        content: '$prelude${text.substring(bodyStart, bodyEnd)}'.trim(),
        reasoningContent: thinking.reasoning,
      );
    }

    if (!parseToolCalls) {
      return ChatParseResult(
        content: text.trim(),
        reasoningContent: thinking.reasoning,
      );
    }

    final actionStart = text.indexOf(_startAction);
    if (actionStart != -1) {
      final prelude = text.substring(0, actionStart);
      final afterStart = text.substring(actionStart + _startAction.length);
      final jsonSlice = ToolCallParsingUtils.extractLeadingJsonValue(
        afterStart,
        0,
      );
      if (jsonSlice == null) {
        return ChatParseResult(
          content: text.trim(),
          reasoningContent: thinking.reasoning,
        );
      }

      final decodedCalls = jsonSlice.value is List
          ? jsonSlice.value
          : <Object?>[jsonSlice.value];

      final toolCalls = ToolCallParsingUtils.parseToolCallArray(
        decodedCalls,
        nameKeys: const <String>['tool_name'],
        argumentKeys: const <String>['parameters'],
        idKeys: const <String>['tool_call_id'],
        assignFallbackIds: false,
      );
      if (toolCalls == null) {
        return ChatParseResult(
          content: text.trim(),
          reasoningContent: thinking.reasoning,
        );
      }

      final actionEndOffset = jsonSlice.end;
      var endCursor = actionEndOffset;
      while (endCursor < afterStart.length &&
          afterStart.codeUnitAt(endCursor) <= 0x20) {
        endCursor++;
      }
      if (!afterStart.startsWith(endAction, endCursor)) {
        return ChatParseResult(
          content: text.trim(),
          reasoningContent: thinking.reasoning,
        );
      }

      final trailing = afterStart.substring(endCursor + endAction.length);
      if (trailing.isNotEmpty) {
        return ChatParseResult(
          content: text.trim(),
          reasoningContent: thinking.reasoning,
        );
      }

      return ChatParseResult(
        content: prelude.trim(),
        reasoningContent: thinking.reasoning,
        toolCalls: toolCalls,
      );
    }

    final bareToolCalls = _parseBareActionPayload(text.trim());
    if (bareToolCalls != null) {
      return ChatParseResult(
        content: bareToolCalls.content,
        reasoningContent: thinking.reasoning,
        toolCalls: bareToolCalls.toolCalls,
      );
    }

    final responseStart = text.indexOf(_startResponse);
    if (responseStart != -1) {
      final prelude = text.substring(0, responseStart);
      final responseBodyStart = responseStart + _startResponse.length;
      final responseEnd = text.indexOf(endResponse, responseBodyStart);
      if (responseEnd == -1) {
        return ChatParseResult(
          content: text.trim(),
          reasoningContent: thinking.reasoning,
        );
      }

      final trailing = text.substring(responseEnd + endResponse.length);
      if (trailing.isNotEmpty) {
        return ChatParseResult(
          content: text.trim(),
          reasoningContent: thinking.reasoning,
        );
      }

      final responseBody = text.substring(responseBodyStart, responseEnd);
      return ChatParseResult(
        content: '$prelude$responseBody'.trim(),
        reasoningContent: thinking.reasoning,
      );
    }

    return ChatParseResult(
      content: text.trim(),
      reasoningContent: thinking.reasoning,
    );
  }

  @override
  String? buildGrammar(List<ToolDefinition>? tools) {
    if (tools == null || tools.isEmpty) return null;
    toolSchemas(tools);

    // Build GBNF for Command R7B style tool calls
    final toolRules = <String>[];
    final toolChoices = <String>[];

    for (final tool in tools) {
      final ruleName = ToolCallGrammarUtils.ruleName(tool.name);
      toolChoices.add('$ruleName-call');

      final schema = tool.toJsonSchema();
      final argsRule = _jsonSchemaToGbnf(schema, '$ruleName-args');
      toolRules.add(argsRule);
      final prefix = ToolCallGrammarUtils.literal(
        '{"tool_name": ${jsonEncode(tool.name)}, "parameters": ',
      );
      toolRules.add('$ruleName-call ::= $prefix $ruleName-args "}"');
    }

    final choiceRule = 'tool-choice ::= ${toolChoices.join(' | ')}';
    final actionArray =
        'action-array ::= "[" space tool-choice ("," space tool-choice)* space "]"';
    final root =
        'root ::= "<|START_ACTION|>" space action-array space "<|END_ACTION|>" | action-array';

    return [
      root,
      actionArray,
      choiceRule,
      ...toolRules,
      _commonGbnfRules(),
    ].join('\n');
  }

  _CommandBareActionPayload? _parseBareActionPayload(String text) {
    final markerStart = _trailingJsonArrayStart(text);
    if (markerStart == null) {
      return null;
    }

    final calls = ToolCallParsingUtils.parseToolCallArray(
      ToolCallParsingUtils.decodeJsonValue(text.substring(markerStart)),
      nameKeys: const <String>['tool_name'],
      argumentKeys: const <String>['parameters'],
      idKeys: const <String>['tool_call_id'],
      assignFallbackIds: false,
    );
    if (calls == null || calls.isEmpty) {
      return null;
    }

    return _CommandBareActionPayload(
      content: text.substring(0, markerStart).trim(),
      toolCalls: calls,
    );
  }

  /// Returns where a JSON array ending the trimmed [text] would start.
  ///
  /// At most one suffix of [text] is a JSON array: a later `[` is either
  /// structural in the earlier array, so it closes before the end, or inside
  /// one of its strings, which leaves the two parses in opposite string states
  /// through the end. Within a valid suffix the backslashes before each quote
  /// say whether it delimits a string, so one backward pass tracks strings and
  /// depth exactly. The caller still decodes the suffix to validate it.
  static int? _trailingJsonArrayStart(String text) {
    if (!text.endsWith(']')) {
      return null;
    }

    var depth = 0;
    var inString = false;
    for (var index = text.length - 1; index >= 0; index--) {
      final codeUnit = text.codeUnitAt(index);
      if (codeUnit == 0x22) {
        var backslashes = 0;
        while (index > backslashes &&
            text.codeUnitAt(index - backslashes - 1) == 0x5C) {
          backslashes++;
        }
        if (backslashes.isEven) {
          inString = !inString;
        }
      } else if (inString) {
        continue;
      } else if (codeUnit == 0x5D || codeUnit == 0x7D) {
        depth++;
      } else if (codeUnit == 0x5B || codeUnit == 0x7B) {
        depth--;
        if (depth == 0) {
          return codeUnit == 0x5B ? index : null;
        }
      }
    }
    return null;
  }

  String _jsonSchemaToGbnf(Map<String, dynamic> schema, String ruleName) {
    final properties = schema['properties'] as Map<String, dynamic>? ?? {};

    if (properties.isEmpty) {
      return '$ruleName ::= "{" space "}"';
    }

    final parts = <String>[];
    var first = true;
    for (final entry in properties.entries) {
      final separator = first
          ? ''
          : '${ToolCallGrammarUtils.literal(', ')} space ';
      first = false;
      final propType = (entry.value as Map<String, dynamic>)['type'] as String?;
      final valueRule = _typeToGbnf(propType);
      final key = ToolCallGrammarUtils.literal('${jsonEncode(entry.key)}: ');
      parts.add('$separator$key space $valueRule');
    }

    return '$ruleName ::= "{" space ${parts.join(' ')} space "}"';
  }

  String _typeToGbnf(String? type) {
    switch (type) {
      case 'string':
        return 'string';
      case 'number':
      case 'integer':
        return 'number';
      case 'boolean':
        return 'boolean';
      case 'array':
        return 'arr';
      default:
        return 'value';
    }
  }

  String _commonGbnfRules() {
    return r'''
space ::= " "?
string ::= "\"" ([^"\\] | "\\\\" .)* "\""
number ::= "-"? ([0-9] | [1-9] [0-9]*) ("." [0-9]+)? ([eE] [-+]? [0-9]+)?
boolean ::= "true" | "false"
null ::= "null"
value ::= string | number | boolean | null | arr | obj
arr ::= "[" space (value ("," space value)*)? space "]"
obj ::= "{" space (string ":" space value ("," space string ":" space value)*)? space "}"''';
  }
}

class _CommandBareActionPayload {
  const _CommandBareActionPayload({
    required this.content,
    required this.toolCalls,
  });

  final String content;
  final List<LlamaCompletionChunkToolCall> toolCalls;
}
