import 'package:dinja/dinja.dart';

import '../../exceptions.dart';
import '../../models/chat/chat_message.dart';
import '../../models/chat/chat_role.dart';
import '../../models/chat/chat_template_result.dart';
import '../../models/chat/completion_chunk.dart';
import '../../models/inference/tool_choice.dart';
import '../../models/tools/tool_definition.dart';
import '../chat_format.dart';
import '../chat_parse_result.dart';
import '../chat_template_handler.dart';
import '../template_internal_metadata.dart';
import '../thinking_utils.dart';
import '../tool_call_fallback_parser.dart';
import '../tool_call_parsing_utils.dart';
import '../tool_call_grammar_utils.dart';

/// Handler for LFM2 and LFM2.5 (Liquid Foundation Model) formats.
///
/// Uses `<|tool_call_start|>` / `<|tool_call_end|>` special tokens for tool
/// calls. LFM2 templates wrap tool definitions in `<|tool_list_start|>` /
/// `<|tool_list_end|>`; LFM2.5 templates write a plain list.
class Lfm2Handler extends ChatTemplateHandler {
  /// Finds a possible tool-call list for the stream's content gate.
  static int toolCallOpening(String text, [int from = 0]) =>
      ToolCallParsingUtils.literalOpening(text, const [
        '<|tool_call_start|>',
      ], from);

  static final RegExp _forceJsonSchemaLineMarker = RegExp(
    r'force json schema\.\n',
    caseSensitive: false,
  );

  static final RegExp _forceJsonSchemaMarker = RegExp(
    r'force json schema\.',
    caseSensitive: false,
  );

  @override
  ChatFormat get format => ChatFormat.lfm2;

  @override
  List<String> get additionalStops => ['<|im_end|>'];

  @override
  List<String> getStops({bool hasTools = false, bool enableThinking = true}) {
    if (hasTools) {
      return const [];
    }

    return additionalStops;
  }

  @override
  List<String> get preservedTokens => const [
    '<|tool_call_start|>',
    '<|tool_call_end|>',
  ];

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
    final hasTools = tools != null && tools.isNotEmpty;
    final toolChoice = metadata[internalToolChoiceMetadataKey];
    final toolChoiceRequired = toolChoice == ToolChoice.required.name;
    final parallelToolCalls =
        metadata[internalParallelToolCallsMetadataKey] == 'true';
    final hasForceJsonMarker = _shouldConstrainWithJsonTools(messages);
    final shouldConstrainWithJsonTools =
        hasTools && (hasForceJsonMarker || toolChoiceRequired);
    final effectiveMessages = hasForceJsonMarker
        ? _stripForceJsonSchemaMarker(messages)
        : messages;
    final adjustedMessages = templateMessages(
      effectiveMessages,
      templateSource: templateSource,
    );
    // llama.cpp supplies the alias used by LFM2.5 templates alongside reasoning.
    for (final message in adjustedMessages) {
      if (message['reasoning_content'] case final String reasoning
          when reasoning.isNotEmpty) {
        message['thinking'] = reasoning;
      }
    }

    final prompt = renderTemplate(
      template,
      metadata: metadata,
      context: {
        'messages': adjustedMessages,
        'add_generation_prompt': addAssistant,
        'tools': _serializeToolsForTemplate(tools),
        'bos_token': metadata['tokenizer.ggml.bos_token'] ?? '',
        'eos_token': metadata['tokenizer.ggml.eos_token'] ?? '',
      },
    );

    return LlamaChatTemplateResult(
      prompt: prompt,
      format: format.index,
      grammar: shouldConstrainWithJsonTools
          ? _jsonGrammar(tools, parallelToolCalls: parallelToolCalls)
          : null,
      grammarLazy: shouldConstrainWithJsonTools && !toolChoiceRequired,
      additionalStops: getStops(
        hasTools: hasTools,
        enableThinking: enableThinking,
      ),
      preservedTokens: hasTools ? preservedTokens : const [],
      grammarTriggers: shouldConstrainWithJsonTools
          ? [
              const GrammarTrigger(
                type: 3,
                value: r'\s*<\|tool_call_start\|>\s*\[',
              ),
            ]
          : [],
    );
  }

  bool _shouldConstrainWithJsonTools(List<LlamaChatMessage> messages) {
    if (messages.isEmpty) {
      return false;
    }

    final first = messages.first;
    if (first.role != LlamaChatRole.system) {
      return false;
    }

    final content = first.content;
    return _forceJsonSchemaLineMarker.hasMatch(content) ||
        _forceJsonSchemaMarker.hasMatch(content);
  }

  List<LlamaChatMessage> _stripForceJsonSchemaMarker(
    List<LlamaChatMessage> messages,
  ) {
    if (messages.isEmpty) {
      return messages;
    }

    final first = messages.first;
    if (first.role != LlamaChatRole.system) {
      return messages;
    }

    var stripped = first.content.replaceFirst(_forceJsonSchemaLineMarker, '');
    if (stripped == first.content) {
      stripped = first.content.replaceFirst(_forceJsonSchemaMarker, '');
    }
    if (stripped == first.content) {
      return messages;
    }

    return <LlamaChatMessage>[
      first.copyWith(content: stripped),
      ...messages.skip(1),
    ];
  }

  /// Passes each tool as `name`, `description` and `parameters`, the shape
  /// LiquidAI's LFM2 and LFM2.5 model cards show. This deliberately differs
  /// from llama-server, which passes the OpenAI shape (`type`, `function`).
  List<Map<String, dynamic>>? _serializeToolsForTemplate(
    List<ToolDefinition>? tools,
  ) {
    if (tools == null || tools.isEmpty) {
      return null;
    }

    return tools
        .map(
          (tool) => <String, dynamic>{
            'name': tool.name,
            'description': tool.description,
            'parameters': tool.toJsonSchema(),
          },
        )
        .toList(growable: false);
  }

  @override
  ChatParseResult parse(
    String output, {
    bool isPartial = false,
    bool parseToolCalls = true,
    bool thinkingForcedOpen = false,
  }) {
    if (!parseToolCalls) {
      final thinking = extractThinking(
        output,
        thinkingForcedOpen: thinkingForcedOpen,
      );
      return ChatParseResult(
        content: thinking.content.trim(),
        reasoningContent: thinking.reasoning,
      );
    }

    const opening = '<|tool_call_start|>';
    const closing = '<|tool_call_end|>';
    final toolCalls = <LlamaCompletionChunkToolCall>[];
    final content = StringBuffer();
    var from = 0;
    while (true) {
      final start = output.indexOf(opening, from);
      if (start == -1) break;
      final payloadStart = start + opening.length;
      final firstEnd = output.indexOf(closing, payloadStart);
      if (firstEnd == -1) break;
      var end = _toolCallEnd(output, payloadStart, firstEnd);
      var parsedCalls = _parseCallList(
        output.substring(payloadStart, end).trim(),
        startIndex: toolCalls.length,
      );
      // Only extend a legacy envelope when it contains a complete call list.
      // Otherwise an unmatched quote could consume a later call or prose.
      if (end != firstEnd && parsedCalls == null) {
        end = firstEnd;
        parsedCalls = _parseCallList(
          output.substring(payloadStart, end).trim(),
          startIndex: toolCalls.length,
        );
      }
      if (parsedCalls != null) {
        toolCalls.addAll(parsedCalls);
      }
      content.write(output.substring(from, start));
      from = end + closing.length;
    }
    content.write(output.substring(from));
    final contentText = content.toString();

    final thinking = extractThinking(
      contentText,
      thinkingForcedOpen: thinkingForcedOpen,
    );

    return ChatParseResult(
      content: thinking.content.trim(),
      reasoningContent: thinking.reasoning,
      toolCalls: toolCalls,
    );
  }

  int _toolCallEnd(String output, int from, int firstEnd) {
    int? quote;
    for (var i = from; i < output.length; i++) {
      final codeUnit = output.codeUnitAt(i);
      if (quote != null) {
        if (codeUnit == 0x5c) {
          i++;
        } else if (codeUnit == quote) {
          quote = null;
        }
      } else if (codeUnit == 0x22 || codeUnit == 0x27) {
        quote = codeUnit;
      } else if (output.startsWith('<|tool_call_end|>', i)) {
        return i;
      }
    }
    // Preserve the existing malformed/unclosed-quote handling.
    return firstEnd;
  }

  @override
  String? buildGrammar(List<ToolDefinition>? tools) =>
      _jsonGrammar(tools, parallelToolCalls: false);

  String? _jsonGrammar(
    List<ToolDefinition>? tools, {
    required bool parallelToolCalls,
  }) => ToolCallGrammarUtils.buildWrappedArrayGrammar(
    tools: tools,
    prefix: '<|tool_call_start|>',
    suffix: '<|tool_call_end|>',
    allowParallelToolCalls: parallelToolCalls,
  );

  List<LlamaCompletionChunkToolCall>? _parseCallList(
    String payload, {
    required int startIndex,
  }) {
    try {
      return ToolCallParsingUtils.parseToolCallArray(
            ToolCallParsingUtils.decodeJsonValue(payload),
            startIndex: startIndex,
            failOnInvalidItem: false,
            assignFallbackIds: true,
          ) ??
          _parsePythonStyleToolCallList(payload, startIndex: startIndex);
    } on LlamaInferenceException {
      // Arguments the wire format refuses (too deep, not finite) are model
      // text, not a caller error, so they must not throw out of parse.
      return null;
    } on StackOverflowError {
      // dart2js converts a list recursively, and a list under a map key only
      // when the key is read, past any catch in the JSON helpers. A depth limit
      // would also refuse lists that decode, since the overflow depends on the
      // stack, and the partial conversion is discarded here.
      return null;
    }
  }

  List<LlamaCompletionChunkToolCall>? _parsePythonStyleToolCallList(
    String payload, {
    required int startIndex,
  }) {
    var body = payload.trim();
    if (body.startsWith('[') && body.endsWith(']')) {
      body = body.substring(1, body.length - 1).trim();
    }
    if (body.isEmpty) {
      return const <LlamaCompletionChunkToolCall>[];
    }

    final parts = _splitPythonStyleToolCalls(body);
    if (parts.isEmpty) {
      return null;
    }

    final calls = <LlamaCompletionChunkToolCall>[];
    for (final part in parts) {
      final parsed = parseToolCallsFromLooseText(part);
      if (parsed.toolCalls.length != 1 || parsed.content.isNotEmpty) {
        return null;
      }
      final call = parsed.toolCalls.single;
      calls.add(
        LlamaCompletionChunkToolCall(
          index: startIndex + calls.length,
          id: call.id,
          type: call.type,
          function: call.function,
        ),
      );
    }

    return calls;
  }

  List<String> _splitPythonStyleToolCalls(String body) {
    final parts = <String>[];
    final buffer = StringBuffer();
    String? quote;
    var depth = 0;

    for (var i = 0; i < body.length; i++) {
      final ch = body[i];
      if (quote != null) {
        buffer.write(ch);
        if (ch == r'\' && i + 1 < body.length) {
          i++;
          buffer.write(body[i]);
        } else if (ch == quote) {
          quote = null;
        }
        continue;
      }

      if (ch == '"' || ch == "'") {
        quote = ch;
        buffer.write(ch);
      } else if (ch == '(' || ch == '[' || ch == '{') {
        depth++;
        buffer.write(ch);
      } else if (ch == ')' || ch == ']' || ch == '}') {
        if (depth > 0) {
          depth--;
        }
        buffer.write(ch);
      } else if (ch == ',' && depth == 0) {
        final part = buffer.toString().trim();
        if (part.isNotEmpty) {
          parts.add(part);
        }
        buffer.clear();
      } else {
        buffer.write(ch);
      }
    }

    final tail = buffer.toString().trim();
    if (tail.isNotEmpty) {
      parts.add(tail);
    }

    return parts;
  }
}
