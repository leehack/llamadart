import 'dart:convert';

import 'package:dinja/dinja.dart';

import '../../exceptions.dart';
import '../../grammar/json_schema_converter.dart';
import '../../models/chat/chat_message.dart';
import '../../models/chat/chat_template_result.dart';
import '../../models/chat/completion_chunk.dart';
import '../../models/inference/tool_choice.dart';
import '../../models/tools/tool_definition.dart';
import '../chat_format.dart';
import '../chat_parse_result.dart';
import '../chat_template_handler.dart';
import '../thinking_utils.dart';
import '../tool_call_grammar_utils.dart';
import '../tool_call_parsing_utils.dart';
import '../tool_schema_utils.dart';
import '../template_internal_metadata.dart';
import 'glm45_handler.dart';

abstract class _DirectJinjaHandler extends ChatTemplateHandler {
  @override
  TemplateToolCallSerialization get toolCallSerialization =>
      TemplateToolCallSerialization.normalizeOnly;

  String get defaultBosToken => '';

  String get defaultEosToken => '';

  List<String> get grammarTriggerValues => const [];

  String? buildRequiredGrammar(List<ToolDefinition>? tools) =>
      buildGrammar(tools);

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
      context: <String, dynamic>{
        'messages': templateMessages(messages),
        'add_generation_prompt': addAssistant,
        'tools': tools?.map((tool) => tool.toJson()).toList(),
        'enable_thinking': enableThinking,
        'thinking': enableThinking,
        'thinking_mode': enableThinking ? 'enabled' : 'disabled',
        'bos_token': metadata['tokenizer.ggml.bos_token'] ?? defaultBosToken,
        'eos_token': metadata['tokenizer.ggml.eos_token'] ?? defaultEosToken,
        'current_date': resolveTemplateNow(
          metadata,
        ).toIso8601String().substring(0, 10),
      },
    );

    var thinkingForcedOpen = false;
    if (isThinkingForcedOpen(prompt, startTag: thinkingStartTag)) {
      if (enableThinking) {
        thinkingForcedOpen = true;
      } else {
        prompt = '${prompt.trimRight()}$thinkingEndTag';
      }
    }

    final hasTools = tools != null && tools.isNotEmpty;
    final toolCallsRequired =
        metadata[internalToolChoiceMetadataKey] == ToolChoice.required.name;
    return LlamaChatTemplateResult(
      prompt: prompt,
      format: format.index,
      grammar: toolCallsRequired
          ? buildRequiredGrammar(tools)
          : buildGrammar(tools),
      grammarLazy: hasTools && !toolCallsRequired,
      thinkingForcedOpen: thinkingForcedOpen,
      additionalStops: getStops(
        hasTools: hasTools,
        enableThinking: enableThinking,
      ),
      preservedTokens: hasTools ? preservedTokens : const [],
      grammarTriggers: hasTools
          ? grammarTriggerValues
                .map((value) => GrammarTrigger(type: 0, value: value))
                .toList(growable: false)
          : const [],
    );
  }
}

/// Handler for Kimi K3's XTML response and typed tool-call protocol.
class KimiK3Handler extends _DirectJinjaHandler {
  static const _open = '<|open|>';
  static const _close = '<|close|>';
  static const _sep = '<|sep|>';
  static const _thinkClose =
      '$_close'
      'think$_sep';
  static const _responseStart =
      '$_open'
      'response$_sep';
  static const _responseEnd =
      '$_close'
      'response$_sep';
  static const _toolsStart =
      '$_open'
      'tools$_sep';
  static const _toolsEnd =
      '$_close'
      'tools$_sep';

  @override
  ChatFormat get format => ChatFormat.kimiK3;

  @override
  String get thinkingStartTag =>
      '$_open'
      'think$_sep';

  @override
  String get thinkingEndTag => _thinkClose;

  @override
  List<String> get additionalStops => const ['<|end_of_msg|>'];

  @override
  List<String> get preservedTokens => const [
    '<|open|>',
    '<|close|>',
    '<|sep|>',
    '<|end_of_msg|>',
  ];

  @override
  List<String> get grammarTriggerValues => const [_toolsStart];

  @override
  ChatParseResult parse(
    String output, {
    bool isPartial = false,
    bool parseToolCalls = true,
    bool thinkingForcedOpen = false,
  }) {
    return parseWithTools(
      output,
      isPartial: isPartial,
      parseToolCalls: parseToolCalls,
      thinkingForcedOpen: thinkingForcedOpen,
    );
  }

  /// Parses Kimi K3 output using [tools] to validate emitted names and values.
  ChatParseResult parseWithTools(
    String output, {
    List<ToolDefinition>? tools,
    bool isPartial = false,
    bool parseToolCalls = true,
    bool thinkingForcedOpen = false,
  }) {
    var remaining = output;
    String? reasoning;
    final thinkEnd = remaining.indexOf(_thinkClose);
    if (thinkEnd >= 0) {
      reasoning = remaining.substring(0, thinkEnd).trim();
      remaining = remaining.substring(thinkEnd + _thinkClose.length);
    } else if (thinkingForcedOpen) {
      final responseIndex = remaining.indexOf(_responseStart);
      if (responseIndex < 0) {
        return ChatParseResult(
          content: '',
          reasoningContent: remaining.trim().isEmpty ? null : remaining.trim(),
        );
      }
      reasoning = remaining.substring(0, responseIndex).trim();
      remaining = remaining.substring(responseIndex);
    }

    var content = '';
    final responseStart = remaining.indexOf(_responseStart);
    if (responseStart >= 0) {
      final bodyStart = responseStart + _responseStart.length;
      final responseEnd = remaining.indexOf(_responseEnd, bodyStart);
      if (responseEnd < 0) {
        if (isPartial) {
          return ChatParseResult(
            content: remaining.substring(bodyStart),
            reasoningContent: _nullIfEmpty(reasoning),
          );
        }
        return ChatParseResult(
          content: output.trim(),
          reasoningContent: _nullIfEmpty(reasoning),
        );
      }
      content = remaining.substring(bodyStart, responseEnd);
      remaining = remaining.substring(responseEnd + _responseEnd.length);
    }

    if (!parseToolCalls) {
      return ChatParseResult(
        content: '$content${_stripKimiTurnEnd(remaining)}'.trim(),
        reasoningContent: _nullIfEmpty(reasoning),
      );
    }

    final parsed = _parseKimiTools(
      remaining,
      isPartial: isPartial,
      schemas: toolSchemas(tools),
    );
    if (!parsed.success) {
      final preserved = '$content${_stripKimiTurnEnd(remaining)}'.trim();
      return ChatParseResult(
        content: preserved,
        reasoningContent: _nullIfEmpty(reasoning),
      );
    }
    return ChatParseResult(
      content: '$content${parsed.remaining}'.trim(),
      reasoningContent: _nullIfEmpty(reasoning),
      toolCalls: parsed.calls,
    );
  }

  _ParsedCalls _parseKimiTools(
    String input, {
    required bool isPartial,
    required Map<String, Map<String, dynamic>> schemas,
  }) {
    final scopeStart = input.indexOf(_toolsStart);
    if (scopeStart < 0) {
      return _ParsedCalls(
        calls: const [],
        remaining: _stripKimiTurnEnd(
          isPartial ? _hideIncompleteProtocolSuffix(input, _toolsStart) : input,
        ),
      );
    }
    final bodyStart = scopeStart + _toolsStart.length;
    final scopeEnd = input.indexOf(_toolsEnd, bodyStart);
    if (scopeEnd < 0) {
      return isPartial
          ? _ParsedCalls(
              calls: const [],
              remaining: input.substring(0, scopeStart),
            )
          : _ParsedCalls.failure();
    }

    final body = input.substring(bodyStart, scopeEnd);
    final callPattern = RegExp(
      r'<\|open\|>call\s+tool="([^"]+)"(?:\s+index="[^"]+")?<\|sep\|>([\s\S]*?)<\|close\|>call<\|sep\|>',
    );
    final matches = callPattern.allMatches(body).toList(growable: false);
    if (matches.isEmpty || body.replaceAll(callPattern, '').trim().isNotEmpty) {
      return _ParsedCalls.failure();
    }

    final calls = <LlamaCompletionChunkToolCall>[];
    for (final match in matches) {
      final name = _decodeCanonicalAttribute(match.group(1) ?? '');
      final callBody = match.group(2) ?? '';
      final schema = name == null ? null : schemas[name];
      if (name == null ||
          name.isEmpty ||
          (schemas.isNotEmpty && schema == null)) {
        return _ParsedCalls.failure();
      }
      final arguments = _parseKimiArguments(callBody, schema: schema);
      if (arguments == null) {
        return _ParsedCalls.failure();
      }
      calls.add(
        ToolCallParsingUtils.createFunctionToolCall(
          index: calls.length,
          name: name,
          arguments: arguments,
        ),
      );
    }

    final removeEnd = scopeEnd + _toolsEnd.length;
    final remaining = input.replaceRange(scopeStart, removeEnd, '');
    return _ParsedCalls(calls: calls, remaining: _stripKimiTurnEnd(remaining));
  }

  Map<String, dynamic>? _parseKimiArguments(
    String body, {
    Map<String, dynamic>? schema,
  }) {
    final jsonPattern = RegExp(
      r'<\|open\|>json\s+type="object"<\|sep\|>([\s\S]*?)<\|close\|>json<\|sep\|>',
    );
    final jsonMatch = jsonPattern.firstMatch(body);
    if (jsonMatch != null) {
      if (body.replaceFirst(jsonPattern, '').trim().isNotEmpty) {
        return null;
      }
      final decoded = ToolCallParsingUtils.decodeJsonObject(
        jsonMatch.group(1) ?? '',
      );
      if (decoded == null || schema == null) {
        return decoded;
      }
      final validated = validateToolSchemaValue(decoded, schema);
      return validated.valid
          ? Map<String, dynamic>.from(validated.value! as Map)
          : null;
    }

    final argumentPattern = RegExp(
      r'<\|open\|>argument\s+key="([^"]+)"\s+type="([^"]+)"<\|sep\|>([\s\S]*?)<\|close\|>argument<\|sep\|>',
    );
    if (body.replaceAll(argumentPattern, '').trim().isNotEmpty) {
      return null;
    }
    final result = <String, dynamic>{};
    final properties = schema == null ? null : schemaProperties(schema);
    for (final match in argumentPattern.allMatches(body)) {
      final key = _decodeCanonicalAttribute(match.group(1) ?? '');
      final type = match.group(2) ?? '';
      final raw = match.group(3) ?? '';
      final propertySchema = key == null ? null : properties?[key];
      if (key == null ||
          key.isEmpty ||
          result.containsKey(key) ||
          (properties != null && propertySchema == null) ||
          (propertySchema != null && type != _kimiTypeName(propertySchema))) {
        return null;
      }
      if (propertySchema != null) {
        final decoded = decodeToolSchemaText(raw, propertySchema);
        if (!decoded.valid) {
          return null;
        }
        result[key] = decoded.value;
      } else if (type == 'string') {
        result[key] = raw;
      } else {
        final decoded = ToolCallParsingUtils.decodeJsonValue(raw);
        if (decoded == null && raw.trim() != 'null') {
          return null;
        }
        result[key] = decoded;
      }
    }
    if (schema != null &&
        !result.keys.toSet().containsAll(schemaRequired(schema))) {
      return null;
    }
    return result;
  }

  String _stripKimiTurnEnd(String input) => input
      .replaceAll(
        '$_close'
            'message$_sep',
        '',
      )
      .replaceAll('<|end_of_msg|>', '')
      .trim();

  @override
  String? buildGrammar(List<ToolDefinition>? tools) {
    return _KimiK3GrammarBuilder(tools).build();
  }

  @override
  String? buildRequiredGrammar(List<ToolDefinition>? tools) {
    return _KimiK3GrammarBuilder(tools).build(required: true);
  }
}

/// Handler for MiniMax M1 newline-delimited JSON tool calls.
class MinimaxM1Handler extends _DirectJinjaHandler {
  @override
  ChatFormat get format => ChatFormat.minimaxM1;

  @override
  List<String> get additionalStops => const ['<end_of_sentence>'];

  @override
  List<String> get preservedTokens => const [
    '<tool_calls>',
    '</tool_calls>',
    '<end_of_sentence>',
  ];

  @override
  List<String> get grammarTriggerValues => const ['<tool_calls>'];

  @override
  ChatParseResult parse(
    String output, {
    bool isPartial = false,
    bool parseToolCalls = true,
    bool thinkingForcedOpen = false,
  }) {
    return parseWithTools(
      output,
      isPartial: isPartial,
      parseToolCalls: parseToolCalls,
      thinkingForcedOpen: thinkingForcedOpen,
    );
  }

  /// Parses MiniMax M1 output using [tools] to validate emitted call objects.
  ChatParseResult parseWithTools(
    String output, {
    List<ToolDefinition>? tools,
    bool isPartial = false,
    bool parseToolCalls = true,
    bool thinkingForcedOpen = false,
  }) {
    if (!parseToolCalls) {
      return ChatParseResult(content: output.trim());
    }
    const start = '<tool_calls>';
    const end = '</tool_calls>';
    final startIndex = output.indexOf(start);
    if (startIndex < 0) {
      return ChatParseResult(
        content:
            (isPartial ? _hideIncompleteProtocolSuffix(output, start) : output)
                .trim(),
      );
    }
    final endIndex = output.indexOf(end, startIndex + start.length);
    if (endIndex < 0) {
      return ChatParseResult(
        content: isPartial
            ? output.substring(0, startIndex).trim()
            : output.trim(),
      );
    }

    final body = output.substring(startIndex + start.length, endIndex);
    final calls = _parseJsonObjectSequence(body, schemas: toolSchemas(tools));
    if (calls == null) {
      return ChatParseResult(content: output.trim());
    }
    final remaining = output.replaceRange(
      startIndex,
      endIndex + end.length,
      '',
    );
    return ChatParseResult(content: remaining.trim(), toolCalls: calls);
  }

  @override
  String? buildGrammar(List<ToolDefinition>? tools) {
    if (tools == null || tools.isEmpty) {
      return null;
    }
    _requireUniqueToolNames(tools, format: 'MiniMax M1');

    final converter = JsonSchemaConverter();
    final callRules = <String>[];
    for (var i = 0; i < tools.length; i++) {
      final tool = tools[i];
      final schema = tool.toJsonSchema();
      converter.resolveRefs(schema, schema);
      final argumentsRule = converter.visit(schema, 'tool-$i-arguments');
      final callRule = 'tool-$i-call';
      converter.rules[callRule] =
          '"{" space "\\"name\\"" space ":" space '
          '${ToolCallGrammarUtils.literal(jsonEncode(tool.name))} space "," space '
          '"\\"arguments\\"" space ":" space $argumentsRule "}" space';
      callRules.add(callRule);
    }

    final buffer = StringBuffer()
      ..writeln('root ::= "<tool_calls>\\n" tool-call+ "</tool_calls>"')
      ..writeln('tool-call ::= tool-choice "\\n"')
      ..writeln('tool-choice ::= ${callRules.join(' | ')}');
    final otherRules = converter.rules.entries.toList(growable: false)
      ..sort((a, b) => a.key.compareTo(b.key));
    for (final entry in otherRules) {
      buffer.writeln('${entry.key} ::= ${entry.value}');
    }
    return buffer.toString();
  }
}

/// Handler for MiniMax M3 namespaced XML tool calls.
class MinimaxM3Handler extends _DirectJinjaHandler {
  /// Namespace prefix emitted before every MiniMax M3 tool tag.
  static const namespace = ']<]minimax[>[';

  @override
  ChatFormat get format => ChatFormat.minimaxM3;

  @override
  String get thinkingStartTag => '<mm:think>';

  @override
  String get thinkingEndTag => '</mm:think>';

  @override
  List<String> get additionalStops => const ['[e~['];

  @override
  List<String> get preservedTokens => const [
    '<mm:think>',
    '</mm:think>',
    namespace,
  ];

  @override
  List<String> get grammarTriggerValues => const ['$namespace<tool_call>'];

  @override
  ChatParseResult parse(
    String output, {
    bool isPartial = false,
    bool parseToolCalls = true,
    bool thinkingForcedOpen = false,
  }) {
    return parseWithTools(
      output,
      isPartial: isPartial,
      parseToolCalls: parseToolCalls,
      thinkingForcedOpen: thinkingForcedOpen,
    );
  }

  /// Parses MiniMax M3 output using [tools] for schema-directed argument types.
  ChatParseResult parseWithTools(
    String output, {
    List<ToolDefinition>? tools,
    bool isPartial = false,
    bool parseToolCalls = true,
    bool thinkingForcedOpen = false,
  }) {
    final schemas = toolSchemas(tools);
    final thinking = extractThinking(
      output,
      startTag: thinkingStartTag,
      endTag: thinkingEndTag,
      thinkingForcedOpen: thinkingForcedOpen,
    );
    if (!parseToolCalls) {
      return ChatParseResult(
        content: thinking.content,
        reasoningContent: thinking.reasoning,
      );
    }
    final rawContent = thinking.content;
    const namespacedScopeStart = '$namespace<tool_call>';
    const namespacedScopeEnd = '$namespace</tool_call>';
    final scopeStartIndex = rawContent.indexOf(namespacedScopeStart);
    if (scopeStartIndex < 0) {
      return ChatParseResult(
        content: isPartial
            ? _hideIncompleteProtocolSuffix(rawContent, namespacedScopeStart)
            : rawContent,
        reasoningContent: thinking.reasoning,
      );
    }
    final scopeEndIndex = rawContent.indexOf(
      namespacedScopeEnd,
      scopeStartIndex + namespacedScopeStart.length,
    );
    if (scopeEndIndex < 0 && !isPartial) {
      return ChatParseResult(
        content: rawContent,
        reasoningContent: thinking.reasoning,
      );
    }
    final parsed = _parseInvokeScope(
      rawContent,
      scopeStart: namespacedScopeStart,
      scopeEnd: namespacedScopeEnd,
      invokeStartPattern: RegExp(
        '${RegExp.escape(namespace)}<invoke name="([^"]+)">',
      ),
      invokeEnd: '$namespace</invoke>',
      parseArguments: (name, body) {
        final schema = schemas[name];
        if (schemas.isNotEmpty && schema == null) {
          return null;
        }
        return _parseDynamicTagArguments(
          body,
          schema: schema,
          tagPrefix: namespace,
        );
      },
      isPartial: isPartial,
    );
    return ChatParseResult(
      content: parsed.success ? parsed.remaining.trim() : rawContent,
      reasoningContent: thinking.reasoning,
      toolCalls: parsed.success ? parsed.calls : const [],
    );
  }

  @override
  String? buildGrammar(List<ToolDefinition>? tools) {
    return _MinimaxM3GrammarBuilder(tools).build();
  }

  @override
  String? buildRequiredGrammar(List<ToolDefinition>? tools) {
    return _MinimaxM3GrammarBuilder(tools).build(required: true);
  }
}

abstract class _DeepseekDsmlHandler extends _DirectJinjaHandler {
  static const _prefix = '<｜DSML｜';

  String get _callsEnvelope;

  String get _callsStart => '$_prefix$_callsEnvelope>';

  String get _callsEnd => '</｜DSML｜$_callsEnvelope>';

  @override
  List<String> get additionalStops => const ['<｜end▁of▁sentence｜>'];

  @override
  List<String> get preservedTokens => [
    '<think>',
    '</think>',
    _callsStart,
    _callsEnd,
  ];

  @override
  List<String> get grammarTriggerValues => [_callsStart];

  @override
  ChatParseResult parse(
    String output, {
    bool isPartial = false,
    bool parseToolCalls = true,
    bool thinkingForcedOpen = false,
  }) {
    return parseWithTools(
      output,
      isPartial: isPartial,
      parseToolCalls: parseToolCalls,
      thinkingForcedOpen: thinkingForcedOpen,
    );
  }

  /// Parses DSML output using [tools] to enforce exact emitted schemas.
  ChatParseResult parseWithTools(
    String output, {
    List<ToolDefinition>? tools,
    bool isPartial = false,
    bool parseToolCalls = true,
    bool thinkingForcedOpen = false,
  }) {
    final thinking = _extractDsmlThinking(
      output,
      callsStart: _callsStart,
      thinkingForcedOpen: thinkingForcedOpen,
    );
    if (!parseToolCalls) {
      return ChatParseResult(
        content: thinking.content,
        reasoningContent: thinking.reasoning,
      );
    }
    final parsed = _parseInvokeScope(
      thinking.content,
      scopeStart: _callsStart,
      scopeEnd: _callsEnd,
      invokeStartPattern: RegExp(r'<｜DSML｜invoke name="([^"]+)">'),
      invokeEnd: '</｜DSML｜invoke>',
      parseArguments: (name, body) {
        final schemas = toolSchemas(tools);
        final schema = schemas[name];
        if (schemas.isNotEmpty && schema == null) {
          return null;
        }
        return _parseDsmlArguments(body, schema: schema);
      },
      isPartial: isPartial,
    );
    return ChatParseResult(
      content: parsed.success ? parsed.remaining.trim() : thinking.content,
      reasoningContent: thinking.reasoning,
      toolCalls: parsed.success ? parsed.calls : const [],
    );
  }

  @override
  String? buildGrammar(List<ToolDefinition>? tools) {
    return _DsmlGrammarBuilder(tools, envelope: _callsEnvelope).build();
  }

  @override
  String? buildRequiredGrammar(List<ToolDefinition>? tools) {
    return _DsmlGrammarBuilder(
      tools,
      envelope: _callsEnvelope,
    ).build(required: true);
  }
}

/// Handler for DeepSeek V3.2 DSML function calls.
class DeepseekV32Handler extends _DeepseekDsmlHandler {
  @override
  ChatFormat get format => ChatFormat.deepseekV32;

  @override
  String get _callsEnvelope => 'function_calls';
}

/// Handler for DeepSeek V4 DSML tool calls.
class DeepseekV4Handler extends _DeepseekDsmlHandler {
  @override
  ChatFormat get format => ChatFormat.deepseekV4;

  @override
  String get _callsEnvelope => 'tool_calls';
}

/// Handler for Muse Glimmer recipient channels and ATEM tool calls.
class MuseGlimmerHandler extends _DirectJinjaHandler {
  @override
  ChatFormat get format => ChatFormat.museGlimmer;

  @override
  List<String> get additionalStops => const ['<|eot|>'];

  @override
  List<String> get preservedTokens => const [
    '<|start|>',
    '<|message|>',
    '<|eom|>',
    '<|eot|>',
    '<atem:function_calls>',
    '</atem:function_calls>',
  ];

  @override
  List<String> get grammarTriggerValues => const ['<atem:function_calls>'];

  @override
  ChatParseResult parse(
    String output, {
    bool isPartial = false,
    bool parseToolCalls = true,
    bool thinkingForcedOpen = false,
  }) {
    return parseWithTools(
      output,
      isPartial: isPartial,
      parseToolCalls: parseToolCalls,
      thinkingForcedOpen: thinkingForcedOpen,
    );
  }

  /// Parses Muse output using [tools] for schema-directed argument types.
  ChatParseResult parseWithTools(
    String output, {
    List<ToolDefinition>? tools,
    bool isPartial = false,
    bool parseToolCalls = true,
    bool thinkingForcedOpen = false,
  }) {
    final schemas = toolSchemas(tools);
    final channelPattern = RegExp(
      r'(?:<\|start\|>assistant)?\s+to=([^<]+)<\|message\|>([\s\S]*?)(<\|eom\|>|<\|eot\|>|$)',
    );
    final matches = channelPattern.allMatches(output).toList(growable: false);
    if (matches.isEmpty) {
      return ChatParseResult(
        content: (isPartial ? _hideIncompleteMuseRoute(output) : output).trim(),
      );
    }

    final content = StringBuffer();
    final reasoning = StringBuffer();
    final calls = <LlamaCompletionChunkToolCall>[];
    int? lastContentCodeUnit;
    var cursor = 0;
    for (final match in matches) {
      lastContentCodeUnit = _appendMuseContent(
        content,
        lastContentCodeUnit,
        output.substring(cursor, match.start),
      );
      final recipient = (match.group(1) ?? '').trim();
      final body = match.group(2) ?? '';
      if (recipient == 'self') {
        if (reasoning.isNotEmpty) reasoning.writeln();
        reasoning.write(body);
      } else if (recipient == 'user') {
        lastContentCodeUnit = _appendMuseContent(
          content,
          lastContentCodeUnit,
          body,
          channelBody: true,
        );
      } else if (parseToolCalls) {
        final parsed = _parseAtemCalls(body, calls.length, schemas: schemas);
        if (parsed == null) {
          final terminator = match.group(3) ?? '';
          if (!isPartial || terminator.isNotEmpty) {
            lastContentCodeUnit = _appendMuseContent(
              content,
              lastContentCodeUnit,
              match.group(0) ?? body,
              channelBody: true,
            );
          }
        } else {
          calls.addAll(parsed);
        }
      } else {
        lastContentCodeUnit = _appendMuseContent(
          content,
          lastContentCodeUnit,
          body,
          channelBody: true,
        );
      }
      cursor = match.end;
    }
    final trailing = output.substring(cursor);
    _appendMuseContent(
      content,
      lastContentCodeUnit,
      isPartial ? _hideIncompleteMuseRoute(trailing) : trailing,
    );

    return ChatParseResult(
      content: content.toString().trim(),
      reasoningContent: _nullIfEmpty(reasoning.toString()),
      toolCalls: calls,
    );
  }

  @override
  String? buildGrammar(List<ToolDefinition>? tools) {
    return _MuseGrammarBuilder(tools).build();
  }

  @override
  String? buildRequiredGrammar(List<ToolDefinition>? tools) {
    return _MuseGrammarBuilder(tools).build(required: true);
  }
}

/// Poolside Laguna uses GLM-style argument tags with a distinct turn stop.
class LagunaHandler extends _DirectJinjaHandler {
  @override
  ChatFormat get format => ChatFormat.laguna;

  @override
  List<String> get additionalStops => const ['</assistant>'];

  @override
  List<String> get preservedTokens => const [
    '<think>',
    '</think>',
    '<tool_call>',
    '</tool_call>',
    '<arg_key>',
    '</arg_key>',
    '<arg_value>',
    '</arg_value>',
    '</assistant>',
  ];

  @override
  List<String> get grammarTriggerValues => const ['<tool_call>'];

  @override
  ChatParseResult parse(
    String output, {
    bool isPartial = false,
    bool parseToolCalls = true,
    bool thinkingForcedOpen = false,
  }) {
    return parseWithTools(
      output,
      isPartial: isPartial,
      parseToolCalls: parseToolCalls,
      thinkingForcedOpen: thinkingForcedOpen,
    );
  }

  /// Parses Laguna output using [tools] for schema-directed argument types.
  ChatParseResult parseWithTools(
    String output, {
    List<ToolDefinition>? tools,
    bool isPartial = false,
    bool parseToolCalls = true,
    bool thinkingForcedOpen = false,
  }) {
    if (parseToolCalls && _hasMalformedLagunaToolBlock(output)) {
      final thinking = extractThinking(
        output,
        thinkingForcedOpen: thinkingForcedOpen,
      );
      return ChatParseResult(
        content: thinking.content,
        reasoningContent: thinking.reasoning,
      );
    }
    return Glm45Handler().parseWithTools(
      output,
      tools: tools,
      isPartial: isPartial,
      parseToolCalls: parseToolCalls,
      thinkingForcedOpen: thinkingForcedOpen,
    );
  }

  bool _hasMalformedLagunaToolBlock(String output) {
    final blockPattern = RegExp(r'<tool_call>\s*([\s\S]*?)</tool_call>');
    final pairPattern = RegExp(
      r'<arg_key>\s*[\s\S]*?\s*</arg_key>\s*<arg_value>\s*[\s\S]*?\s*</arg_value>',
    );
    for (final block in blockPattern.allMatches(output)) {
      final body = block.group(1) ?? '';
      final firstArgument = body.indexOf('<arg_key>');
      if (firstArgument < 0) {
        continue;
      }
      final argumentBody = body.substring(firstArgument);
      if (argumentBody.replaceAll(pairPattern, '').trim().isNotEmpty) {
        return true;
      }
    }
    return false;
  }

  @override
  String? buildGrammar(List<ToolDefinition>? tools) {
    return Glm45Handler().buildGrammar(tools);
  }

  @override
  String? buildRequiredGrammar(List<ToolDefinition>? tools) {
    final grammar = buildGrammar(tools);
    return grammar == null
        ? null
        : _withRequiredPrefix(
            grammar,
            delimiter: '\n<tool_call>',
            prefixName: 'laguna-required-prefix',
          );
  }
}

int? _appendMuseContent(
  StringBuffer content,
  int? lastCodeUnit,
  String value, {
  bool channelBody = false,
}) {
  if (value.isEmpty) {
    return lastCodeUnit;
  }
  if (channelBody &&
      lastCodeUnit != null &&
      !_isWhitespace(lastCodeUnit) &&
      !_isWhitespace(value.codeUnitAt(0))) {
    content.writeln();
  }
  content.write(value);
  return value.codeUnitAt(value.length - 1);
}

String _hideIncompleteMuseRoute(String input) {
  const routeStarts = ['<|start|>assistant to=', ' to='];
  var hideFrom = input.length;
  for (final routeStart in routeStarts) {
    for (var length = 1; length < routeStart.length; length++) {
      final prefix = routeStart.substring(0, length);
      if (input.endsWith(prefix)) {
        hideFrom = hideFrom < input.length - length
            ? hideFrom
            : input.length - length;
      }
    }
    final completeStart = input.lastIndexOf(routeStart);
    if (completeStart >= 0 &&
        input.indexOf('<|message|>', completeStart + routeStart.length) < 0) {
      hideFrom = hideFrom < completeStart ? hideFrom : completeStart;
    }
  }
  return input.substring(0, hideFrom);
}

class _KimiK3GrammarBuilder {
  final List<ToolDefinition>? tools;
  final JsonSchemaConverter _converter = JsonSchemaConverter();
  final List<String> _rules = <String>[];

  _KimiK3GrammarBuilder(this.tools);

  String? build({bool required = false}) {
    final resolvedTools = tools;
    if (resolvedTools == null || resolvedTools.isEmpty) {
      return null;
    }
    _requireUniqueToolNames(resolvedTools, format: 'Kimi K3');

    final callRules = <String>[];
    String? stringValueRule;
    for (var toolIndex = 0; toolIndex < resolvedTools.length; toolIndex++) {
      final tool = resolvedTools[toolIndex];
      _requireNonEmptyProtocolName(tool.name, format: 'Kimi K3', kind: 'tool');
      final schema = tool.toJsonSchema();
      final properties = schemaProperties(schema);
      final required = schemaRequired(schema);
      final requiredRules = <String>[];
      final optionalRules = <String>[];
      var propertyIndex = 0;
      for (final entry in properties.entries) {
        _requireNonEmptyProtocolName(
          entry.key,
          format: 'Kimi K3',
          kind: 'parameter',
        );
        final argumentRule = 'kimi-tool-$toolIndex-arg-${propertyIndex++}';
        final typeName = _kimiTypeName(entry.value);
        const close = '<|close|>argument<|sep|>';
        final valueRule = typeName == 'string'
            ? (stringValueRule ??= _addUntilRules(
                _rules,
                'kimi-string-value',
                close,
              ))
            : _converter.visit(entry.value, '$argumentRule-value');
        final opening =
            '<|open|>argument key="${_escapeAttribute(entry.key)}" '
            'type="$typeName"<|sep|>';
        _rules.add(
          '$argumentRule ::= ${ToolCallGrammarUtils.literal(opening)} '
          '$valueRule ${ToolCallGrammarUtils.literal(close)}',
        );
        (required.contains(entry.key) ? requiredRules : optionalRules).add(
          argumentRule,
        );
      }

      _converter.resolveRefs(schema, schema);
      final jsonRule = _converter.visit(schema, 'kimi-tool-$toolIndex-json');
      final rawArguments = <String>[
        ...requiredRules,
        ...optionalRules.map((rule) => '($rule)?'),
      ].join(' ');
      final rawArgumentsRule = rawArguments.isEmpty ? '""' : rawArguments;
      final arguments = properties.isEmpty
          ? '(kimi-empty-arguments | kimi-json-$toolIndex)'
          : '(kimi-raw-$toolIndex | kimi-json-$toolIndex)';
      _rules
        ..add('kimi-raw-$toolIndex ::= $rawArgumentsRule')
        ..add(
          'kimi-json-$toolIndex ::= '
          '${ToolCallGrammarUtils.literal('<|open|>json type="object"<|sep|>')} '
          '$jsonRule '
          '${ToolCallGrammarUtils.literal('<|close|>json<|sep|>')}',
        );
      final callRule = 'kimi-tool-$toolIndex';
      final callOpen = '<|open|>call tool="${_escapeAttribute(tool.name)}"';
      _rules.add(
        '$callRule ::= ${ToolCallGrammarUtils.literal(callOpen)} '
        '(" index=\\"" [0-9]+ "\\"")? '
        '${ToolCallGrammarUtils.literal('<|sep|>')} $arguments '
        '${ToolCallGrammarUtils.literal('<|close|>call<|sep|>')}',
      );
      callRules.add(callRule);
    }

    final buffer = StringBuffer()
      ..writeln(
        'root ::= ${ToolCallGrammarUtils.literal('<|open|>tools<|sep|>')} '
        'kimi-tool+ '
        '${ToolCallGrammarUtils.literal('<|close|>tools<|sep|>')} '
        '${ToolCallGrammarUtils.literal('<|close|>message<|sep|>')}',
      )
      ..writeln('kimi-tool ::= ${callRules.join(' | ')}')
      ..writeln('kimi-empty-arguments ::= ""');
    for (final rule in _rules) {
      buffer.writeln(rule);
    }
    _appendJsonRules(buffer, _converter);
    final grammar = buffer.toString();
    return required
        ? _withRequiredPrefix(
            grammar,
            delimiter: '<|open|>tools<|sep|>',
            prefixName: 'kimi-required-prefix',
          )
        : grammar;
  }
}

String _kimiTypeName(Map<String, dynamic> schema) {
  if (schemaResolvesToString(schema)) {
    return 'string';
  }
  return switch (schema['type']) {
    'integer' || 'number' => 'number',
    'boolean' => 'boolean',
    'null' => 'null',
    'object' => 'object',
    'array' => 'array',
    _ => 'string',
  };
}

class _MinimaxM3GrammarBuilder {
  static const _namespace = MinimaxM3Handler.namespace;

  final List<ToolDefinition>? tools;
  final JsonSchemaConverter _converter = JsonSchemaConverter();
  final List<String> _rules = <String>[];

  _MinimaxM3GrammarBuilder(this.tools);

  String? build({bool required = false}) {
    final resolvedTools = tools;
    if (resolvedTools == null || resolvedTools.isEmpty) {
      return null;
    }
    _requireUniqueToolNames(resolvedTools, format: 'MiniMax M3');
    final toolRules = <String>[];
    for (var toolIndex = 0; toolIndex < resolvedTools.length; toolIndex++) {
      final tool = resolvedTools[toolIndex];
      _requireNonEmptyProtocolName(
        tool.name,
        format: 'MiniMax M3',
        kind: 'tool',
      );
      final schema = tool.toJsonSchema();
      final arguments = _members(schema, 'm3-tool-$toolIndex-arg');
      final toolRule = 'm3-tool-$toolIndex';
      _rules.add(
        '$toolRule ::= '
        '${ToolCallGrammarUtils.literal('$_namespace<invoke name="${_escapeAttribute(tool.name)}">')} '
        'm3-space $arguments m3-space '
        '${ToolCallGrammarUtils.literal('$_namespace</invoke>')} m3-space',
      );
      toolRules.add(toolRule);
    }

    final buffer = StringBuffer()
      ..writeln(
        'root ::= '
        '${ToolCallGrammarUtils.literal('$_namespace<tool_call>')} m3-space '
        'm3-tool+ ${ToolCallGrammarUtils.literal('$_namespace</tool_call>')}',
      )
      ..writeln('m3-tool ::= ${toolRules.join(' | ')}')
      ..writeln(r'm3-space ::= [ \t\n\r]*');
    for (final rule in _rules) {
      buffer.writeln(rule);
    }
    _appendJsonRules(buffer, _converter);
    final grammar = buffer.toString();
    return required
        ? _withRequiredPrefix(
            grammar,
            delimiter: '$_namespace<tool_call>',
            prefixName: 'm3-required-prefix',
          )
        : grammar;
  }

  String _members(Map<String, dynamic> schema, String prefix) {
    final properties = schemaProperties(schema);
    final required = schemaRequired(schema);
    final requiredMembers = <String>[];
    final optionalMembers = <String>[];
    var propertyIndex = 0;
    for (final entry in properties.entries) {
      final rule = _element(
        entry.key,
        entry.value,
        '$prefix-${propertyIndex++}',
      );
      (required.contains(entry.key) ? requiredMembers : optionalMembers).add(
        rule,
      );
    }
    return <String>[
      ...requiredMembers.map((rule) => '$rule m3-space'),
      ...optionalMembers.map((rule) => '($rule m3-space)?'),
    ].join(' ');
  }

  String _element(String tag, Map<String, dynamic> schema, String rule) {
    _requireDynamicTagName(tag, format: 'MiniMax M3');
    final closingText = '$_namespace</$tag>';
    final valueRule = _value(schema, '$rule-value', closingText);
    _rules.add(
      '$rule ::= ${ToolCallGrammarUtils.literal('$_namespace<$tag>')} '
      '$valueRule ${ToolCallGrammarUtils.literal(closingText)}',
    );
    return rule;
  }

  String _value(
    Map<String, dynamic> schema,
    String prefix,
    String closingText,
  ) {
    if (schemaResolvesToString(schema)) {
      return _addUntilRules(_rules, '$prefix-string', closingText);
    }
    if (schema['type'] == 'object') {
      return _members(schema, '$prefix-member');
    }
    if (schema['type'] == 'array' && schema['items'] is Map) {
      final item = _element(
        'item',
        Map<String, dynamic>.from(schema['items'] as Map),
        '$prefix-item',
      );
      return '($item m3-space)*';
    }
    return _converter.visit(schema, prefix);
  }
}

class _DsmlGrammarBuilder {
  static const _prefix = '｜DSML｜';

  final List<ToolDefinition>? tools;
  final String envelope;
  final JsonSchemaConverter _converter = JsonSchemaConverter();
  final List<String> _rules = <String>[];

  _DsmlGrammarBuilder(this.tools, {required this.envelope});

  String? build({bool required = false}) {
    final resolvedTools = tools;
    if (resolvedTools == null || resolvedTools.isEmpty) {
      return null;
    }
    _requireUniqueToolNames(resolvedTools, format: 'DeepSeek DSML');

    final callsStart = '<$_prefix$envelope>';
    final callsEnd = '</$_prefix$envelope>';
    final toolRules = <String>[];
    for (var toolIndex = 0; toolIndex < resolvedTools.length; toolIndex++) {
      final tool = resolvedTools[toolIndex];
      _requireNonEmptyProtocolName(
        tool.name,
        format: 'DeepSeek DSML',
        kind: 'tool',
      );
      final schema = tool.toJsonSchema();
      _converter.resolveRefs(schema, schema);
      final properties = schemaProperties(schema);
      final requiredNames = schemaRequired(schema);
      final requiredRules = <String>[];
      final optionalRules = <String>[];
      var propertyIndex = 0;
      for (final entry in properties.entries) {
        _requireNonEmptyProtocolName(
          entry.key,
          format: 'DeepSeek DSML',
          kind: 'parameter',
        );
        final argumentRule = 'dsml-tool-$toolIndex-arg-${propertyIndex++}';
        final isString = schemaResolvesToString(entry.value);
        const close = '</｜DSML｜parameter>';
        final valueRule = isString
            ? _addUntilRules(_rules, '$argumentRule-string', close)
            : _converter.visit(entry.value, '$argumentRule-value');
        final opening =
            '<｜DSML｜parameter name="${_escapeAttribute(entry.key)}" '
            'string="${isString ? 'true' : 'false'}">';
        _rules.add(
          '$argumentRule ::= ${ToolCallGrammarUtils.literal(opening)} '
          '$valueRule ${ToolCallGrammarUtils.literal(close)}',
        );
        (requiredNames.contains(entry.key) ? requiredRules : optionalRules).add(
          argumentRule,
        );
      }

      final arguments = <String>[
        ...requiredRules.map((rule) => '$rule dsml-space'),
        ...optionalRules.map((rule) => '($rule dsml-space)?'),
      ].join(' ');

      final toolRule = 'dsml-tool-$toolIndex';
      _rules.add(
        '$toolRule ::= '
        '${ToolCallGrammarUtils.literal('<｜DSML｜invoke name="${_escapeAttribute(tool.name)}">')} '
        'dsml-space $arguments '
        '${ToolCallGrammarUtils.literal('</｜DSML｜invoke>')} dsml-space',
      );
      toolRules.add(toolRule);
    }

    final buffer = StringBuffer()
      ..writeln(
        'root ::= ${ToolCallGrammarUtils.literal(callsStart)} dsml-space '
        'dsml-tool+ ${ToolCallGrammarUtils.literal(callsEnd)}',
      )
      ..writeln('dsml-tool ::= ${toolRules.join(' | ')}')
      ..writeln(r'dsml-space ::= [ \t\n\r]*');
    for (final rule in _rules) {
      buffer.writeln(rule);
    }
    _appendJsonRules(buffer, _converter);
    final grammar = buffer.toString();
    return required
        ? _withRequiredPrefix(
            grammar,
            delimiter: callsStart,
            prefixName: 'dsml-required-prefix',
          )
        : grammar;
  }
}

class _MuseGrammarBuilder {
  static const _scopeStart = '<atem:function_calls>';
  static const _scopeEnd = '</atem:function_calls>';

  final List<ToolDefinition>? tools;
  final JsonSchemaConverter _converter = JsonSchemaConverter();
  final List<String> _rules = <String>[];

  _MuseGrammarBuilder(this.tools);

  String? build({bool required = false}) {
    final resolvedTools = tools;
    if (resolvedTools == null || resolvedTools.isEmpty) {
      return null;
    }
    _requireUniqueToolNames(resolvedTools, format: 'Muse Glimmer');

    final toolRules = <String>[];
    final requiredToolRules = <String>[];
    for (var toolIndex = 0; toolIndex < resolvedTools.length; toolIndex++) {
      final tool = resolvedTools[toolIndex];
      _requireMuseRecipientName(tool.name);
      final schema = tool.toJsonSchema();
      _converter.resolveRefs(schema, schema);
      final properties = schemaProperties(schema);
      final requiredNames = schemaRequired(schema);
      final requiredRules = <String>[];
      final optionalRules = <String>[];
      var propertyIndex = 0;
      for (final entry in properties.entries) {
        _requireNonEmptyProtocolName(
          entry.key,
          format: 'Muse Glimmer',
          kind: 'parameter',
        );
        final argumentRule = 'muse-tool-$toolIndex-arg-${propertyIndex++}';
        const close = '</atem:parameter>';
        final valueRule = schemaResolvesToString(entry.value)
            ? _addUntilRules(_rules, '$argumentRule-string', close)
            : _converter.visit(entry.value, '$argumentRule-value');
        final opening =
            '<atem:parameter name="${_escapeAttribute(entry.key)}">';
        _rules.add(
          '$argumentRule ::= ${ToolCallGrammarUtils.literal(opening)} '
          '$valueRule ${ToolCallGrammarUtils.literal(close)}',
        );
        (requiredNames.contains(entry.key) ? requiredRules : optionalRules).add(
          argumentRule,
        );
      }

      final arguments = <String>[
        ...requiredRules.map((rule) => '$rule muse-space'),
        ...optionalRules.map((rule) => '($rule muse-space)?'),
      ].join(' ');

      final toolRule = 'muse-tool-$toolIndex';
      _rules.add(
        '$toolRule ::= '
        '${ToolCallGrammarUtils.literal('<atem:invoke name="${_escapeAttribute(tool.name)}">')} '
        'muse-space $arguments '
        '${ToolCallGrammarUtils.literal('</atem:invoke>')} muse-space',
      );
      toolRules.add(toolRule);

      final requiredToolRule = 'muse-required-tool-$toolIndex';
      _rules.add(
        '$requiredToolRule ::= '
        '${ToolCallGrammarUtils.literal(' to=${tool.name}<|message|>$_scopeStart')} '
        'muse-space $toolRule ${ToolCallGrammarUtils.literal(_scopeEnd)}',
      );
      requiredToolRules.add(requiredToolRule);
    }

    final buffer = StringBuffer();
    if (required) {
      final analysisBody = _addUntilRules(
        _rules,
        'muse-analysis-body',
        '<|eom|>',
      );
      buffer
        ..writeln(
          'root ::= (${ToolCallGrammarUtils.literal('<|start|>assistant')})? '
          'muse-analysis* muse-required-tool',
        )
        ..writeln(
          'muse-analysis ::= '
          '${ToolCallGrammarUtils.literal(' to=self<|message|>')} '
          '$analysisBody '
          '${ToolCallGrammarUtils.literal('<|eom|><|start|>assistant')}',
        )
        ..writeln('muse-required-tool ::= ${requiredToolRules.join(' | ')}');
    } else {
      buffer
        ..writeln(
          'root ::= ${ToolCallGrammarUtils.literal(_scopeStart)} muse-space '
          'muse-tool+ ${ToolCallGrammarUtils.literal(_scopeEnd)}',
        )
        ..writeln('muse-tool ::= ${toolRules.join(' | ')}');
    }
    buffer.writeln(r'muse-space ::= [ \t\n\r]*');
    for (final rule in _rules) {
      buffer.writeln(rule);
    }
    _appendJsonRules(buffer, _converter);
    return buffer.toString();
  }
}

String _withRequiredPrefix(
  String grammar, {
  required String delimiter,
  required String prefixName,
}) {
  final lines = grammar.split('\n');
  final rootIndex = lines.indexWhere((line) => line.startsWith('root ::= '));
  if (rootIndex < 0) {
    return grammar;
  }
  lines[rootIndex] = lines[rootIndex].replaceFirst(
    'root ::= ',
    'required-tool-section ::= ',
  );
  final prefixRules = <String>[];
  final prefixRule = _addUntilRules(prefixRules, prefixName, delimiter);
  return <String>[
    'root ::= $prefixRule required-tool-section',
    ...lines,
    ...prefixRules,
  ].join('\n');
}

void _appendJsonRules(StringBuffer buffer, JsonSchemaConverter converter) {
  final rules = converter.rules.entries.toList(growable: false)
    ..sort((a, b) => a.key.compareTo(b.key));
  for (final entry in rules) {
    buffer.writeln('${entry.key} ::= ${entry.value}');
  }
}

String _addUntilRules(List<String> rules, String name, String delimiter) {
  final pattern = delimiter.runes
      .map(String.fromCharCode)
      .toList(growable: false);
  final alphabet = <String>[];
  for (final character in pattern) {
    if (!alphabet.contains(character)) {
      alphabet.add(character);
    }
  }
  final fallback = '[^${alphabet.map(_escapeGbnfCharClass).join()}]';
  String state(int index) => '$name-$index';

  for (var index = 0; index < pattern.length; index++) {
    final alternatives = <String>[];
    for (final character in alphabet) {
      final candidate = <String>[...pattern.take(index), character];
      var next = candidate.length;
      while (next > 0 &&
          !_endsWithCharacters(candidate, pattern.take(next).toList())) {
        next--;
      }
      if (next == pattern.length) {
        continue;
      }
      alternatives.add(
        '${ToolCallGrammarUtils.literal(character)} ${state(next)}',
      );
    }
    alternatives.add('$fallback ${state(0)}');
    rules.add('${state(index)} ::= (${alternatives.join(' | ')})?');
  }
  rules.add('$name ::= ${state(0)}');
  return name;
}

bool _endsWithCharacters(List<String> value, List<String> suffix) {
  if (suffix.length > value.length) {
    return false;
  }
  final offset = value.length - suffix.length;
  for (var index = 0; index < suffix.length; index++) {
    if (value[offset + index] != suffix[index]) {
      return false;
    }
  }
  return true;
}

String _escapeGbnfCharClass(String character) {
  return switch (character) {
    r'\' => r'\\',
    ']' => r'\]',
    '^' => r'\^',
    '-' => r'\-',
    _ => character,
  };
}

List<LlamaCompletionChunkToolCall>? _parseJsonObjectSequence(
  String body, {
  Map<String, Map<String, dynamic>> schemas = const {},
}) {
  final calls = <LlamaCompletionChunkToolCall>[];
  var cursor = 0;
  while (cursor < body.length) {
    while (cursor < body.length && _isWhitespace(body.codeUnitAt(cursor))) {
      cursor++;
    }
    if (cursor == body.length) {
      break;
    }
    final slice = ToolCallParsingUtils.extractLeadingJsonValue(body, cursor);
    if (slice == null || slice.value is! Map) {
      return null;
    }
    if (schemas.isEmpty) {
      final parsed = ToolCallParsingUtils.parseToolCallArray(<Object?>[
        slice.value,
      ], startIndex: calls.length);
      if (parsed == null || parsed.length != 1) {
        return null;
      }
      calls.add(parsed.single);
    } else {
      final call = Map<String, dynamic>.from(slice.value! as Map);
      if (call.length != 2 ||
          !call.containsKey('name') ||
          !call.containsKey('arguments')) {
        return null;
      }
      final name = call['name'];
      final arguments = call['arguments'];
      final schema = name is String ? schemas[name] : null;
      if (schema == null || arguments is! Map) {
        return null;
      }
      final validated = validateToolSchemaValue(arguments, schema);
      if (!validated.valid) {
        return null;
      }
      calls.add(
        ToolCallParsingUtils.createFunctionToolCall(
          index: calls.length,
          name: name,
          arguments: Map<String, dynamic>.from(validated.value! as Map),
        ),
      );
    }
    cursor = slice.end;
  }
  return calls.isEmpty ? null : calls;
}

_ParsedCalls _parseInvokeScope(
  String input, {
  required String scopeStart,
  required String scopeEnd,
  required RegExp invokeStartPattern,
  required String invokeEnd,
  required Map<String, dynamic>? Function(String, String) parseArguments,
  required bool isPartial,
}) {
  final scopeStartIndex = input.indexOf(scopeStart);
  if (scopeStartIndex < 0) {
    return _ParsedCalls(
      calls: const [],
      remaining: isPartial
          ? _hideIncompleteProtocolSuffix(input, scopeStart)
          : input,
    );
  }
  final bodyStart = scopeStartIndex + scopeStart.length;
  final scopeEndIndex = input.indexOf(scopeEnd, bodyStart);
  if (scopeEndIndex < 0 && !isPartial) {
    return _ParsedCalls.failure();
  }
  final scopeComplete = scopeEndIndex >= 0;
  final body = input.substring(
    bodyStart,
    scopeComplete ? scopeEndIndex : input.length,
  );
  final calls = <LlamaCompletionChunkToolCall>[];
  final allowPartial = isPartial && !scopeComplete;
  _ParsedCalls partialResult() => _ParsedCalls(
    calls: calls,
    remaining: input.substring(0, scopeStartIndex),
  );
  var cursor = 0;
  while (cursor < body.length) {
    final start = invokeStartPattern.firstMatch(body.substring(cursor));
    if (start == null) {
      if (body.substring(cursor).trim().isNotEmpty) {
        return allowPartial ? partialResult() : _ParsedCalls.failure();
      }
      break;
    }
    final absoluteStart = cursor + start.start;
    if (body.substring(cursor, absoluteStart).trim().isNotEmpty) {
      return allowPartial ? partialResult() : _ParsedCalls.failure();
    }
    final argumentsStart = cursor + start.end;
    final end = body.indexOf(invokeEnd, argumentsStart);
    if (end < 0) {
      return allowPartial ? partialResult() : _ParsedCalls.failure();
    }
    final name = _decodeCanonicalAttribute(start.group(1) ?? '');
    if (name == null) {
      return allowPartial ? partialResult() : _ParsedCalls.failure();
    }
    final arguments = parseArguments(name, body.substring(argumentsStart, end));
    if (name.isEmpty || arguments == null) {
      return allowPartial ? partialResult() : _ParsedCalls.failure();
    }
    calls.add(
      ToolCallParsingUtils.createFunctionToolCall(
        index: calls.length,
        name: name,
        arguments: arguments,
      ),
    );
    cursor = end + invokeEnd.length;
  }
  if (calls.isEmpty) {
    return allowPartial ? partialResult() : _ParsedCalls.failure();
  }
  if (!scopeComplete) {
    return partialResult();
  }
  final remaining = input.replaceRange(
    scopeStartIndex,
    scopeEndIndex + scopeEnd.length,
    '',
  );
  return _ParsedCalls(calls: calls, remaining: remaining);
}

Map<String, dynamic>? _parseDynamicTagArguments(
  String body, {
  Map<String, dynamic>? schema,
  String tagPrefix = '',
}) {
  final parsed = _parseDynamicElements(
    body,
    schema: schema,
    tagPrefix: tagPrefix,
  );
  if (parsed == null) {
    return null;
  }
  if (parsed.elements.isEmpty) {
    if (body.trim().isNotEmpty) {
      return null;
    }
    return schema == null || schemaRequired(schema).isEmpty
        ? <String, dynamic>{}
        : null;
  }
  if (!_haveUniqueElementNames(parsed.elements)) {
    return null;
  }
  final result = <String, dynamic>{};
  for (final element in parsed.elements) {
    result[element.name] = element.value;
  }
  if (schema != null &&
      !result.keys.toSet().containsAll(schemaRequired(schema))) {
    return null;
  }
  return result;
}

_DynamicElements? _parseDynamicElements(
  String input, {
  Map<String, dynamic>? schema,
  String tagPrefix = '',
}) {
  final elements = <_DynamicElement>[];
  final properties = schema == null ? null : schemaProperties(schema);
  var cursor = 0;
  while (cursor < input.length) {
    while (cursor < input.length && _isWhitespace(input.codeUnitAt(cursor))) {
      cursor++;
    }
    if (cursor == input.length) {
      break;
    }
    final opening = RegExp(
      '${RegExp.escape(tagPrefix)}<([A-Za-z_][A-Za-z0-9_.-]*)>',
    ).matchAsPrefix(input, cursor);
    if (opening == null) {
      return null;
    }
    final name = opening.group(1)!;
    final close = _findMatchingDynamicClose(
      input,
      name,
      opening.end,
      tagPrefix: tagPrefix,
    );
    if (close == null) {
      return null;
    }
    final raw = input.substring(opening.end, close.start);
    final propertySchema = properties?[name];
    if (properties != null && propertySchema == null) {
      return null;
    }
    Object? value;
    if (propertySchema != null && propertySchema['type'] == 'object') {
      final children = _parseDynamicElements(
        raw,
        schema: propertySchema,
        tagPrefix: tagPrefix,
      );
      if (children == null) {
        return null;
      }
      if (!_haveUniqueElementNames(children.elements)) {
        return null;
      }
      value = <String, dynamic>{
        for (final element in children.elements) element.name: element.value,
      };
      if (!(value as Map).keys.toSet().containsAll(
        schemaRequired(propertySchema),
      )) {
        return null;
      }
    } else if (propertySchema != null && propertySchema['type'] == 'array') {
      final itemSchema = propertySchema['items'];
      final itemProperties = itemSchema is Map
          ? <String, dynamic>{
              'type': 'object',
              'properties': {'item': itemSchema},
            }
          : null;
      final children = _parseDynamicElements(
        raw,
        schema: itemProperties,
        tagPrefix: tagPrefix,
      );
      if (children == null ||
          children.elements.any((element) => element.name != 'item')) {
        return null;
      }
      value = children.elements
          .map((element) => element.value)
          .toList(growable: false);
    } else if (propertySchema != null) {
      final decoded = decodeToolSchemaText(raw, propertySchema);
      if (!decoded.valid) {
        return null;
      }
      value = decoded.value;
    } else {
      final children = _parseDynamicElements(raw, tagPrefix: tagPrefix);
      if (children != null && children.elements.isNotEmpty) {
        if (children.elements.every((element) => element.name == 'item')) {
          value = children.elements
              .map((element) => element.value)
              .toList(growable: false);
        } else {
          if (!_haveUniqueElementNames(children.elements)) {
            return null;
          }
          value = <String, dynamic>{
            for (final element in children.elements)
              element.name: element.value,
          };
        }
      } else {
        value = ToolCallParsingUtils.decodeJsonValueOrString(raw);
      }
    }
    elements.add(_DynamicElement(name: name, value: value));
    cursor = close.end;
  }
  return _DynamicElements(elements);
}

bool _haveUniqueElementNames(List<_DynamicElement> elements) {
  final names = <String>{};
  return elements.every((element) => names.add(element.name));
}

({int start, int end})? _findMatchingDynamicClose(
  String input,
  String name,
  int start, {
  String tagPrefix = '',
}) {
  final tagPattern = RegExp(
    '${RegExp.escape(tagPrefix)}<(/?)${RegExp.escape(name)}>',
  );
  var depth = 1;
  for (final match in tagPattern.allMatches(input, start)) {
    if (match.group(1) == '/') {
      depth--;
      if (depth == 0) {
        return (start: match.start, end: match.end);
      }
    } else {
      depth++;
    }
  }
  return null;
}

ThinkingExtraction _extractDsmlThinking(
  String output, {
  required String callsStart,
  required bool thinkingForcedOpen,
}) {
  if (thinkingForcedOpen) {
    final callsIndex = output.indexOf(callsStart);
    final thinkEndIndex = output.indexOf('</think>');
    if (callsIndex >= 0 && (thinkEndIndex < 0 || callsIndex < thinkEndIndex)) {
      final reasoning = output.substring(0, callsIndex).trim();
      return (
        content: output.substring(callsIndex).trim(),
        reasoning: reasoning.isEmpty ? null : reasoning,
      );
    }
  }
  return extractThinking(output, thinkingForcedOpen: thinkingForcedOpen);
}

Map<String, dynamic>? _parseDsmlArguments(
  String body, {
  Map<String, dynamic>? schema,
}) {
  final pattern = RegExp(
    r'<｜DSML｜parameter name="([^"]+)" string="(true|false)">([\s\S]*?)</｜DSML｜parameter>',
  );
  if (body.replaceAll(pattern, '').trim().isNotEmpty) {
    return null;
  }
  final result = <String, dynamic>{};
  final properties = schema == null ? null : schemaProperties(schema);
  for (final match in pattern.allMatches(body)) {
    final key = _decodeCanonicalAttribute(match.group(1) ?? '');
    final stringAttribute = match.group(2) == 'true';
    final raw = match.group(3) ?? '';
    final propertySchema = key == null ? null : properties?[key];
    if (key == null ||
        key.isEmpty ||
        result.containsKey(key) ||
        (properties != null && propertySchema == null) ||
        (propertySchema != null &&
            stringAttribute != schemaResolvesToString(propertySchema))) {
      return null;
    }
    if (propertySchema != null) {
      final decoded = decodeToolSchemaText(raw, propertySchema);
      if (!decoded.valid) {
        return null;
      }
      result[key] = decoded.value;
    } else if (stringAttribute) {
      result[key] = raw;
    } else {
      final decoded = ToolCallParsingUtils.decodeJsonValue(raw);
      if (decoded == null && raw.trim() != 'null') {
        return null;
      }
      result[key] = decoded;
    }
  }
  if (schema != null &&
      !result.keys.toSet().containsAll(schemaRequired(schema))) {
    return null;
  }
  return result;
}

List<LlamaCompletionChunkToolCall>? _parseAtemCalls(
  String body,
  int start, {
  Map<String, Map<String, dynamic>> schemas = const {},
}) {
  const scopeStart = '<atem:function_calls>';
  const scopeEnd = '</atem:function_calls>';
  final scopeStartIndex = body.indexOf(scopeStart);
  final scopeEndIndex = body.indexOf(scopeEnd);
  if (scopeStartIndex < 0 || scopeEndIndex < scopeStartIndex) {
    return null;
  }
  if (body.substring(0, scopeStartIndex).trim().isNotEmpty ||
      body.substring(scopeEndIndex + scopeEnd.length).trim().isNotEmpty) {
    return null;
  }
  final scope = body.substring(
    scopeStartIndex + scopeStart.length,
    scopeEndIndex,
  );
  final invokePattern = RegExp(
    r'<atem:invoke name="([^"]+)">([\s\S]*?)</atem:invoke>',
  );
  if (scope.replaceAll(invokePattern, '').trim().isNotEmpty) {
    return null;
  }
  final calls = <LlamaCompletionChunkToolCall>[];
  for (final invoke in invokePattern.allMatches(scope)) {
    final name = _decodeCanonicalAttribute(invoke.group(1) ?? '');
    if (name == null) {
      return null;
    }
    final schema = schemas[name];
    if (schemas.isNotEmpty && schema == null) {
      return null;
    }
    final properties = schema == null ? null : schemaProperties(schema);
    final required = schema == null ? const <String>{} : schemaRequired(schema);
    final params = invoke.group(2) ?? '';
    final parameterPattern = RegExp(
      r'<atem:parameter name="([^"]+)">([\s\S]*?)</atem:parameter>',
    );
    if (name.isEmpty ||
        params.replaceAll(parameterPattern, '').trim().isNotEmpty) {
      return null;
    }
    final arguments = <String, dynamic>{};
    for (final parameter in parameterPattern.allMatches(params)) {
      final key = _decodeCanonicalAttribute(parameter.group(1) ?? '');
      final raw = parameter.group(2) ?? '';
      if (key == null || key.isEmpty || arguments.containsKey(key)) {
        return null;
      }
      final propertySchema = properties?[key];
      if (properties != null && propertySchema == null) {
        return null;
      }
      if (propertySchema == null) {
        arguments[key] = ToolCallParsingUtils.decodeJsonValueOrString(raw);
      } else {
        final decoded = decodeToolSchemaText(raw, propertySchema);
        if (!decoded.valid) {
          return null;
        }
        arguments[key] = decoded.value;
      }
    }
    if (!arguments.keys.toSet().containsAll(required)) {
      return null;
    }
    calls.add(
      ToolCallParsingUtils.createFunctionToolCall(
        index: start + calls.length,
        name: name,
        arguments: arguments,
      ),
    );
  }
  return calls.isEmpty ? null : calls;
}

String _unescapeAttribute(String value) => value
    .replaceAll('&quot;', '"')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&amp;', '&');

String? _decodeCanonicalAttribute(String value) {
  final decoded = _unescapeAttribute(value);
  return _escapeAttribute(decoded) == value ? decoded : null;
}

String _escapeAttribute(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('"', '&quot;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

void _requireDynamicTagName(String value, {required String format}) {
  if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_.-]*$').hasMatch(value)) {
    throw LlamaUnsupportedException(
      '$format cannot represent tool parameter "$value" as an XML tag. '
      'Use a name matching [A-Za-z_][A-Za-z0-9_.-]*.',
    );
  }
}

void _requireNonEmptyProtocolName(
  String value, {
  required String format,
  required String kind,
}) {
  if (value.isEmpty) {
    throw LlamaUnsupportedException(
      '$format cannot represent an empty $kind name in its tool-call '
      'protocol.',
    );
  }
}

void _requireUniqueToolNames(
  List<ToolDefinition> tools, {
  required String format,
}) {
  final names = <String>{};
  for (final tool in tools) {
    if (!names.add(tool.name)) {
      throw LlamaUnsupportedException(
        '$format cannot bind duplicate tool name "${tool.name}" to one '
        'schema-exact parser route. Use unique tool names.',
      );
    }
  }
}

void _requireMuseRecipientName(String value) {
  if (value.isEmpty ||
      value.trim() != value ||
      value == 'self' ||
      value == 'user' ||
      value.contains('<')) {
    throw LlamaUnsupportedException(
      'Muse Glimmer cannot represent tool name "$value" in its recipient '
      'channel. Use a non-empty name without surrounding whitespace or "<", '
      'and do not use the reserved names "self" or "user".',
    );
  }
}

String _hideIncompleteProtocolSuffix(String input, String marker) {
  for (var length = marker.length - 1; length > 0; length--) {
    if (input.endsWith(marker.substring(0, length))) {
      return input.substring(0, input.length - length);
    }
  }
  return input;
}

String? _nullIfEmpty(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

bool _isWhitespace(int codeUnit) =>
    codeUnit == 0x20 ||
    codeUnit == 0x0A ||
    codeUnit == 0x0D ||
    codeUnit == 0x09;

class _ParsedCalls {
  final bool success;
  final List<LlamaCompletionChunkToolCall> calls;
  final String remaining;

  const _ParsedCalls({required this.calls, required this.remaining})
    : success = true;

  const _ParsedCalls.failure()
    : success = false,
      calls = const [],
      remaining = '';
}

class _DynamicElements {
  final List<_DynamicElement> elements;

  const _DynamicElements(this.elements);
}

class _DynamicElement {
  final String name;
  final Object? value;

  const _DynamicElement({required this.name, required this.value});
}
