import 'dart:convert';

import 'package:dinja/dinja.dart';

import '../../grammar/json_schema_converter.dart';
import '../../models/chat/chat_message.dart';
import '../../models/chat/chat_template_result.dart';
import '../../models/chat/completion_chunk.dart';
import '../../models/tools/tool_definition.dart';
import '../chat_format.dart';
import '../chat_parse_result.dart';
import '../chat_template_handler.dart';
import '../thinking_utils.dart';
import '../tool_call_grammar_utils.dart';
import '../tool_call_parsing_utils.dart';
import 'glm45_handler.dart';

abstract class _DirectJinjaHandler extends ChatTemplateHandler
    implements ToolSchemaAwareChatTemplateHandler, RequiredToolGrammarHandler {
  @override
  TemplateToolCallSerialization get toolCallSerialization =>
      TemplateToolCallSerialization.normalizeOnly;

  String get defaultBosToken => '';

  String get defaultEosToken => '';

  List<String> get grammarTriggerValues => const [];

  List<String> grammarTriggerValuesForTemplate(String templateSource) =>
      grammarTriggerValues;

  List<String> preservedTokensForTemplate(String templateSource) =>
      preservedTokens;

  String? buildGrammarForTemplate(
    String templateSource,
    List<ToolDefinition>? tools,
  ) => buildGrammar(tools);

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
    return LlamaChatTemplateResult(
      prompt: prompt,
      format: format.index,
      grammar: buildGrammarForTemplate(templateSource, tools),
      grammarLazy: hasTools,
      thinkingForcedOpen: thinkingForcedOpen,
      additionalStops: getStops(
        hasTools: hasTools,
        enableThinking: enableThinking,
      ),
      preservedTokens: hasTools
          ? preservedTokensForTemplate(templateSource)
          : const [],
      grammarTriggers: hasTools
          ? grammarTriggerValuesForTemplate(templateSource)
                .map((value) => GrammarTrigger(type: 0, value: value))
                .toList(growable: false)
          : const [],
    );
  }

  @override
  ChatParseResult parseWithTools(
    String output, {
    required List<ToolDefinition>? tools,
    bool isPartial = false,
    bool parseToolCalls = true,
    bool thinkingForcedOpen = false,
  }) {
    return parse(
      output,
      isPartial: isPartial,
      parseToolCalls: parseToolCalls,
      thinkingForcedOpen: thinkingForcedOpen,
    );
  }

  @override
  String buildRequiredToolGrammar({
    required String grammar,
    required String trigger,
  }) => _buildRequiredPrefixGrammar(grammar, trigger);
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
  }) => _parse(
    output,
    tools: null,
    isPartial: isPartial,
    parseToolCalls: parseToolCalls,
    thinkingForcedOpen: thinkingForcedOpen,
  );

  @override
  ChatParseResult parseWithTools(
    String output, {
    required List<ToolDefinition>? tools,
    bool isPartial = false,
    bool parseToolCalls = true,
    bool thinkingForcedOpen = false,
  }) => _parse(
    output,
    tools: tools,
    isPartial: isPartial,
    parseToolCalls: parseToolCalls,
    thinkingForcedOpen: thinkingForcedOpen,
  );

  ChatParseResult _parse(
    String output, {
    required List<ToolDefinition>? tools,
    required bool isPartial,
    required bool parseToolCalls,
    required bool thinkingForcedOpen,
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
      tools: tools,
      isPartial: isPartial,
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
    required List<ToolDefinition>? tools,
    required bool isPartial,
  }) {
    final scopeStart = input.indexOf(_toolsStart);
    if (scopeStart < 0) {
      final partialStart = isPartial
          ? _partialMarkerStart(input, const [_toolsStart])
          : null;
      return _ParsedCalls(
        calls: const [],
        remaining: _stripKimiTurnEnd(
          partialStart == null ? input : input.substring(0, partialStart),
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
      final name = _unescapeAttribute(match.group(1) ?? '');
      final callBody = match.group(2) ?? '';
      final tool = _toolByName(tools, name);
      if (tools != null && tool == null) {
        return _ParsedCalls.failure();
      }
      final arguments = _parseKimiArguments(
        callBody,
        schema: tool?.toJsonSchema(),
      );
      if (name.isEmpty || arguments == null) {
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
    required Map<String, dynamic>? schema,
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
      if (decoded == null ||
          (schema != null && !_objectMatchesSchema(decoded, schema))) {
        return null;
      }
      return decoded;
    }

    final argumentPattern = RegExp(
      r'<\|open\|>argument\s+key="([^"]+)"\s+type="([^"]+)"<\|sep\|>([\s\S]*?)<\|close\|>argument<\|sep\|>',
    );
    if (body.replaceAll(argumentPattern, '').trim().isNotEmpty) {
      return null;
    }
    final result = <String, dynamic>{};
    for (final match in argumentPattern.allMatches(body)) {
      final key = _unescapeAttribute(match.group(1) ?? '');
      final type = match.group(2) ?? '';
      final raw = match.group(3) ?? '';
      if (key.isEmpty || result.containsKey(key)) {
        return null;
      }
      final property = schema?['properties']?[key];
      if (schema != null && property is! Map<String, dynamic>) {
        return null;
      }
      if (property is Map<String, dynamic>) {
        if (type != _schemaProtocolType(property)) {
          return null;
        }
        final decoded = _decodeRawBySchema(raw, property);
        if (identical(decoded, _schemaDecodeFailure)) {
          return null;
        }
        result[key] = decoded;
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
    if (schema != null && !_objectMatchesSchema(result, schema)) {
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
    return _buildKimiK3Grammar(tools);
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
  }) => _parse(
    output,
    tools: null,
    isPartial: isPartial,
    parseToolCalls: parseToolCalls,
  );

  @override
  ChatParseResult parseWithTools(
    String output, {
    required List<ToolDefinition>? tools,
    bool isPartial = false,
    bool parseToolCalls = true,
    bool thinkingForcedOpen = false,
  }) => _parse(
    output,
    tools: tools,
    isPartial: isPartial,
    parseToolCalls: parseToolCalls,
  );

  ChatParseResult _parse(
    String output, {
    required List<ToolDefinition>? tools,
    required bool isPartial,
    required bool parseToolCalls,
  }) {
    if (!parseToolCalls) {
      return ChatParseResult(content: output.trim());
    }
    const start = '<tool_calls>';
    const end = '</tool_calls>';
    final startIndex = output.indexOf(start);
    if (startIndex < 0) {
      final partialStart = isPartial
          ? _partialMarkerStart(output, const [start])
          : null;
      return ChatParseResult(
        content:
            (partialStart == null ? output : output.substring(0, partialStart))
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
    final calls = _parseJsonObjectSequence(body, tools: tools);
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
  }) => _parse(
    output,
    tools: null,
    isPartial: isPartial,
    parseToolCalls: parseToolCalls,
    thinkingForcedOpen: thinkingForcedOpen,
  );

  @override
  ChatParseResult parseWithTools(
    String output, {
    required List<ToolDefinition>? tools,
    bool isPartial = false,
    bool parseToolCalls = true,
    bool thinkingForcedOpen = false,
  }) => _parse(
    output,
    tools: tools,
    isPartial: isPartial,
    parseToolCalls: parseToolCalls,
    thinkingForcedOpen: thinkingForcedOpen,
  );

  ChatParseResult _parse(
    String output, {
    required List<ToolDefinition>? tools,
    required bool isPartial,
    required bool parseToolCalls,
    required bool thinkingForcedOpen,
  }) {
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
      final partialStart = isPartial
          ? _partialMarkerStart(rawContent, const [namespacedScopeStart])
          : null;
      return ChatParseResult(
        content: partialStart == null
            ? rawContent
            : rawContent.substring(0, partialStart).trim(),
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
    final scopeEndExclusive = scopeEndIndex < 0
        ? rawContent.length
        : scopeEndIndex + namespacedScopeEnd.length;
    final normalizedScope = rawContent
        .substring(scopeStartIndex, scopeEndExclusive)
        .replaceAll('$namespace<', '<');
    final normalized = rawContent.replaceRange(
      scopeStartIndex,
      scopeEndExclusive,
      normalizedScope,
    );
    final parsed = _parseInvokeScope(
      normalized,
      scopeStart: '<tool_call>',
      scopeEnd: '</tool_call>',
      invokeStartPattern: RegExp(r'<invoke name="([^"]+)">'),
      invokeEnd: '</invoke>',
      parseArguments: (name, body) {
        final tool = _toolByName(tools, name);
        if (tools != null && tool == null) {
          return null;
        }
        return _parseDynamicTagArguments(body, schema: tool?.toJsonSchema());
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
    return _buildMinimaxM3Grammar(tools);
  }
}

/// Handler for DeepSeek V3.2/V4 DSML tool calls.
class DeepseekV4Handler extends _DirectJinjaHandler {
  static const _v3Scope = 'function_calls';
  static const _v4Scope = 'tool_calls';

  @override
  ChatFormat get format => ChatFormat.deepseekV4;

  @override
  List<String> get additionalStops => const ['<｜end▁of▁sentence｜>'];

  @override
  List<String> get preservedTokens => const [
    '<think>',
    '</think>',
    '<｜DSML｜tool_calls>',
    '</｜DSML｜tool_calls>',
  ];

  @override
  List<String> get grammarTriggerValues => const ['<｜DSML｜tool_calls>'];

  bool _usesV3Envelope(String templateSource) =>
      templateSource.contains('function_calls>');

  @override
  List<String> grammarTriggerValuesForTemplate(String templateSource) => [
    '<｜DSML｜${_usesV3Envelope(templateSource) ? _v3Scope : _v4Scope}>',
  ];

  @override
  List<String> preservedTokensForTemplate(String templateSource) {
    final scope = _usesV3Envelope(templateSource) ? _v3Scope : _v4Scope;
    return ['<think>', '</think>', '<｜DSML｜$scope>', '</｜DSML｜$scope>'];
  }

  @override
  String? buildGrammarForTemplate(
    String templateSource,
    List<ToolDefinition>? tools,
  ) => _buildDsmlGrammar(
    tools,
    scope: _usesV3Envelope(templateSource) ? _v3Scope : _v4Scope,
  );

  @override
  ChatParseResult parse(
    String output, {
    bool isPartial = false,
    bool parseToolCalls = true,
    bool thinkingForcedOpen = false,
  }) => _parse(
    output,
    tools: null,
    isPartial: isPartial,
    parseToolCalls: parseToolCalls,
    thinkingForcedOpen: thinkingForcedOpen,
  );

  @override
  ChatParseResult parseWithTools(
    String output, {
    required List<ToolDefinition>? tools,
    bool isPartial = false,
    bool parseToolCalls = true,
    bool thinkingForcedOpen = false,
  }) => _parse(
    output,
    tools: tools,
    isPartial: isPartial,
    parseToolCalls: parseToolCalls,
    thinkingForcedOpen: thinkingForcedOpen,
  );

  ChatParseResult _parse(
    String output, {
    required List<ToolDefinition>? tools,
    required bool isPartial,
    required bool parseToolCalls,
    required bool thinkingForcedOpen,
  }) {
    final thinking = _extractDsmlThinking(
      output,
      isPartial: isPartial,
      thinkingForcedOpen: thinkingForcedOpen,
    );
    if (!parseToolCalls) {
      return ChatParseResult(
        content: thinking.content,
        reasoningContent: thinking.reasoning,
      );
    }
    final scope = _findDsmlScope(thinking.content);
    if (scope == null) {
      final partialStart = isPartial
          ? _partialMarkerStart(thinking.content, const [
              '<｜DSML｜function_calls>',
              '<｜DSML｜tool_calls>',
            ])
          : null;
      return ChatParseResult(
        content: partialStart == null
            ? thinking.content
            : thinking.content.substring(0, partialStart).trim(),
        reasoningContent: thinking.reasoning,
      );
    }
    final parsed = _parseInvokeScope(
      thinking.content,
      scopeStart: '<｜DSML｜${scope.name}>',
      scopeEnd: '</｜DSML｜${scope.name}>',
      invokeStartPattern: RegExp(r'<｜DSML｜invoke name="([^"]+)">'),
      invokeEnd: '</｜DSML｜invoke>',
      parseArguments: (name, body) {
        final tool = _toolByName(tools, name);
        if (tools != null && tool == null) {
          return null;
        }
        return _parseDsmlArguments(body, schema: tool?.toJsonSchema());
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
    return _buildDsmlGrammar(tools, scope: _v4Scope);
  }
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
  }) => _parse(
    output,
    tools: null,
    isPartial: isPartial,
    parseToolCalls: parseToolCalls,
  );

  @override
  ChatParseResult parseWithTools(
    String output, {
    required List<ToolDefinition>? tools,
    bool isPartial = false,
    bool parseToolCalls = true,
    bool thinkingForcedOpen = false,
  }) => _parse(
    output,
    tools: tools,
    isPartial: isPartial,
    parseToolCalls: parseToolCalls,
  );

  ChatParseResult _parse(
    String output, {
    required List<ToolDefinition>? tools,
    required bool isPartial,
    required bool parseToolCalls,
  }) {
    final channelPattern = RegExp(
      r'(?:<\|start\|>assistant)?\s+to=([^<]+)<\|message\|>([\s\S]*?)(<\|eom\|>|<\|eot\|>|$)',
    );
    final matches = channelPattern.allMatches(output).toList(growable: false);
    if (matches.isEmpty) {
      final partialRoute = isPartial ? _partialMuseRouteStart(output) : null;
      return ChatParseResult(
        content: partialRoute == null
            ? output.trim()
            : output.substring(0, partialRoute).trim(),
      );
    }

    final content = StringBuffer();
    final reasoning = StringBuffer();
    final calls = <LlamaCompletionChunkToolCall>[];
    var cursor = 0;
    for (final match in matches) {
      _appendParsedText(content, output.substring(cursor, match.start));
      final recipient = (match.group(1) ?? '').trim();
      final body = match.group(2) ?? '';
      if (recipient == 'self') {
        _appendParsedText(reasoning, body);
      } else if (recipient == 'user') {
        _appendParsedText(content, body);
      } else if (parseToolCalls) {
        final parsed = _parseAtemCalls(
          body,
          calls.length,
          tools: tools,
          expectedRecipient: recipient,
        );
        if (parsed == null) {
          final terminator = match.group(3) ?? '';
          if (!isPartial || terminator.isNotEmpty) {
            _appendParsedText(content, body);
          }
        } else {
          calls.addAll(parsed);
        }
      } else {
        _appendParsedText(content, body);
      }
      cursor = match.end;
    }
    final tail = output.substring(cursor);
    final partialRoute = isPartial ? _partialMuseRouteStart(tail) : null;
    if (partialRoute == null) {
      _appendParsedText(content, tail);
    } else {
      _appendParsedText(content, tail.substring(0, partialRoute));
    }

    return ChatParseResult(
      content: content.toString().trim(),
      reasoningContent: _nullIfEmpty(reasoning.toString()),
      toolCalls: calls,
    );
  }

  @override
  String? buildGrammar(List<ToolDefinition>? tools) {
    return _buildAtemGrammar(tools);
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
  }) => _parse(
    output,
    tools: null,
    isPartial: isPartial,
    parseToolCalls: parseToolCalls,
    thinkingForcedOpen: thinkingForcedOpen,
  );

  @override
  ChatParseResult parseWithTools(
    String output, {
    required List<ToolDefinition>? tools,
    bool isPartial = false,
    bool parseToolCalls = true,
    bool thinkingForcedOpen = false,
  }) => _parse(
    output,
    tools: tools,
    isPartial: isPartial,
    parseToolCalls: parseToolCalls,
    thinkingForcedOpen: thinkingForcedOpen,
  );

  ChatParseResult _parse(
    String output, {
    required List<ToolDefinition>? tools,
    required bool isPartial,
    required bool parseToolCalls,
    required bool thinkingForcedOpen,
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
}

ThinkingExtraction _extractDsmlThinking(
  String output, {
  required bool isPartial,
  required bool thinkingForcedOpen,
}) {
  if (!thinkingForcedOpen) {
    return extractThinking(output);
  }
  final markerStart = _partialMarkerStart(output, const [
    '<｜DSML｜function_calls>',
    '<｜DSML｜tool_calls>',
  ], includePartial: isPartial);
  final explicitEnd = output.indexOf('</think>');
  if (markerStart != null && (explicitEnd < 0 || markerStart < explicitEnd)) {
    final reasoning = output.substring(0, markerStart).trim();
    return (
      content: output.substring(markerStart).trim(),
      reasoning: reasoning.isEmpty ? null : reasoning,
    );
  }
  return extractThinking(output, thinkingForcedOpen: true);
}

({String name, int start})? _findDsmlScope(String output) {
  ({String name, int start})? result;
  for (final name in const ['function_calls', 'tool_calls']) {
    final start = output.indexOf('<｜DSML｜$name>');
    if (start >= 0 && (result == null || start < result.start)) {
      result = (name: name, start: start);
    }
  }
  return result;
}

int? _partialMarkerStart(
  String input,
  List<String> markers, {
  bool includePartial = true,
}) {
  int? earliest;
  for (final marker in markers) {
    final complete = input.indexOf(marker);
    if (complete >= 0 && (earliest == null || complete < earliest)) {
      earliest = complete;
    }
    if (!includePartial) {
      continue;
    }
    final lowerBound = input.length > marker.length
        ? input.length - marker.length
        : 0;
    for (var index = lowerBound; index < input.length; index++) {
      if (marker.startsWith(input.substring(index)) &&
          (earliest == null || index < earliest)) {
        earliest = index;
      }
    }
  }
  return earliest;
}

int? _partialMuseRouteStart(String input) {
  final match = RegExp(
    r'(?:<\|start\|>assistant)?\s+to=[^<]*$',
  ).firstMatch(input);
  final partial = _partialMarkerStart(input, const [
    '<|start|>assistant to=',
    ' to=',
  ]);
  if (match == null) {
    return partial;
  }
  if (partial == null) {
    return match.start;
  }
  return match.start < partial ? match.start : partial;
}

void _appendParsedText(StringBuffer buffer, String value) {
  buffer.write(value);
}

String? _buildKimiK3Grammar(List<ToolDefinition>? tools) {
  if (tools == null || tools.isEmpty) {
    return null;
  }
  const argumentClose = '<|close|>argument<|sep|>';
  final buffer = StringBuffer()
    ..writeln(
      'root ::= "<|open|>tools<|sep|>" call+ '
      '"<|close|>tools<|sep|><|close|>message<|sep|>"',
    );
  final converter = JsonSchemaConverter();
  final callRules = <String>[];
  for (var toolIndex = 0; toolIndex < tools.length; toolIndex++) {
    final tool = tools[toolIndex];
    final schema = tool.toJsonSchema();
    converter.resolveRefs(schema, schema);
    final requiredRules = <String>[];
    final optionalRules = <String>[];
    final properties =
        (schema['properties'] as Map<String, dynamic>?) ??
        const <String, dynamic>{};
    final required = Set<String>.from(
      (schema['required'] as List?)?.whereType<String>() ?? const <String>[],
    );
    for (final entry in properties.entries) {
      final propertySchema = entry.value as Map<String, dynamic>;
      final ruleBase = _grammarRuleName('kimi-$toolIndex-${entry.key}');
      final valueRule = _buildDelimitedOrJsonValueRule(
        buffer: buffer,
        converter: converter,
        ruleBase: '$ruleBase-value',
        schema: propertySchema,
        delimiter: argumentClose,
      );
      final propertyRule = '$ruleBase-argument';
      buffer.writeln(
        '$propertyRule ::= '
        '${ToolCallGrammarUtils.literal('<|open|>argument key="${_escapeAttribute(entry.key)}" type="${_schemaProtocolType(propertySchema)}"<|sep|>')} '
        '$valueRule ${ToolCallGrammarUtils.literal(argumentClose)}',
      );
      (required.contains(entry.key) ? requiredRules : optionalRules).add(
        propertyRule,
      );
    }

    final jsonRule = converter.visit(schema, 'kimi-$toolIndex-json-object');
    final jsonBlockRule = 'kimi-$toolIndex-json-block';
    buffer.writeln(
      '$jsonBlockRule ::= '
      '"<|open|>json type=\\"object\\"<|sep|>" $jsonRule '
      '"<|close|>json<|sep|>"',
    );
    final arguments = _buildRequiredThenOptionalBody(
      requiredRules: requiredRules,
      optionalRules: optionalRules,
      separatorRule: null,
    );
    final body = requiredRules.isEmpty && optionalRules.isEmpty
        ? '($jsonBlockRule)?'
        : '(($arguments) | $jsonBlockRule)';
    final callRule = 'kimi-$toolIndex-call';
    buffer.writeln(
      '$callRule ::= '
      '${ToolCallGrammarUtils.literal('<|open|>call tool="${_escapeAttribute(tool.name)}"')} '
      '(" index=\\"" [0-9]+ "\\"")? "<|sep|>" $body '
      '"<|close|>call<|sep|>"',
    );
    callRules.add(callRule);
  }
  buffer.writeln('call ::= ${callRules.join(' | ')}');
  _appendJsonRules(buffer, converter);
  return buffer.toString();
}

String? _buildMinimaxM3Grammar(List<ToolDefinition>? tools) {
  if (tools == null || tools.isEmpty) {
    return null;
  }
  const namespace = MinimaxM3Handler.namespace;
  final buffer = StringBuffer()
    ..writeln(
      'root ::= "$namespace<tool_call>\\n" invoke+ '
      '"$namespace</tool_call>"',
    );
  final converter = JsonSchemaConverter();
  final invokeRules = <String>[];
  for (var toolIndex = 0; toolIndex < tools.length; toolIndex++) {
    final tool = tools[toolIndex];
    final schema = tool.toJsonSchema();
    converter.resolveRefs(schema, schema);
    final argsRule = _buildMinimaxObjectBodyRule(
      buffer: buffer,
      converter: converter,
      ruleBase: 'm3-$toolIndex-arguments',
      schema: schema,
    );
    final invokeRule = 'm3-$toolIndex-invoke';
    buffer.writeln(
      '$invokeRule ::= '
      '${ToolCallGrammarUtils.literal('$namespace<invoke name="${tool.name}">')} '
      'space $argsRule space "$namespace</invoke>\\n"',
    );
    invokeRules.add(invokeRule);
  }
  buffer.writeln('invoke ::= ${invokeRules.join(' | ')}');
  _appendJsonRules(buffer, converter);
  return buffer.toString();
}

String _buildMinimaxObjectBodyRule({
  required StringBuffer buffer,
  required JsonSchemaConverter converter,
  required String ruleBase,
  required Map<String, dynamic> schema,
}) {
  final properties =
      (schema['properties'] as Map<String, dynamic>?) ??
      const <String, dynamic>{};
  final required = Set<String>.from(
    (schema['required'] as List?)?.whereType<String>() ?? const <String>[],
  );
  final requiredRules = <String>[];
  final optionalRules = <String>[];
  for (final entry in properties.entries) {
    final propertyRule = _buildMinimaxElementRule(
      buffer: buffer,
      converter: converter,
      ruleBase: '$ruleBase-${_grammarRuleName(entry.key)}',
      tagName: entry.key,
      schema: entry.value as Map<String, dynamic>,
    );
    (required.contains(entry.key) ? requiredRules : optionalRules).add(
      propertyRule,
    );
  }
  final body = _buildRequiredThenOptionalBody(
    requiredRules: requiredRules,
    optionalRules: optionalRules,
    separatorRule: 'space',
  );
  buffer.writeln('$ruleBase ::= $body');
  return ruleBase;
}

String _buildMinimaxElementRule({
  required StringBuffer buffer,
  required JsonSchemaConverter converter,
  required String ruleBase,
  required String tagName,
  required Map<String, dynamic> schema,
}) {
  const namespace = MinimaxM3Handler.namespace;
  final close = '$namespace</$tagName>';
  final type = schema['type'];
  late final String valueRule;
  if (_schemaResolvesToString(schema)) {
    final enumValues = schema['enum'];
    if (enumValues is List && enumValues.isNotEmpty) {
      valueRule = enumValues
          .whereType<String>()
          .map(ToolCallGrammarUtils.literal)
          .join(' | ');
    } else {
      valueRule = _appendUntilLiteralRules(buffer, '$ruleBase-text', close);
    }
  } else if (type == 'object' ||
      (type == null && schema.containsKey('properties'))) {
    valueRule = _buildMinimaxObjectBodyRule(
      buffer: buffer,
      converter: converter,
      ruleBase: '$ruleBase-object',
      schema: schema,
    );
  } else if (type == 'array') {
    final itemSchema =
        schema['items'] as Map<String, dynamic>? ??
        const <String, dynamic>{'type': 'string'};
    final itemRule = _buildMinimaxElementRule(
      buffer: buffer,
      converter: converter,
      ruleBase: '$ruleBase-item',
      tagName: 'item',
      schema: itemSchema,
    );
    valueRule = '($itemRule)*';
  } else {
    valueRule = converter.visit(schema, '$ruleBase-json');
  }
  buffer.writeln(
    '$ruleBase ::= ${ToolCallGrammarUtils.literal('$namespace<$tagName>')} '
    '($valueRule) ${ToolCallGrammarUtils.literal(close)}',
  );
  return ruleBase;
}

String? _buildDsmlGrammar(
  List<ToolDefinition>? tools, {
  required String scope,
}) {
  if (tools == null || tools.isEmpty) {
    return null;
  }
  const parameterClose = '</｜DSML｜parameter>';
  final buffer = StringBuffer()
    ..writeln('root ::= "<｜DSML｜$scope>\\n" invoke+ "</｜DSML｜$scope>"');
  final converter = JsonSchemaConverter();
  final invokeRules = <String>[];
  for (var toolIndex = 0; toolIndex < tools.length; toolIndex++) {
    final tool = tools[toolIndex];
    final schema = tool.toJsonSchema();
    converter.resolveRefs(schema, schema);
    final propertyRules = _buildNamedParameterRules(
      buffer: buffer,
      converter: converter,
      ruleBase: 'dsml-$toolIndex',
      schema: schema,
      openFor: (name, propertySchema) =>
          '<｜DSML｜parameter name="$name" string="${_schemaResolvesToString(propertySchema)}">',
      close: parameterClose,
      trailing: '\n',
    );
    final invokeRule = 'dsml-$toolIndex-invoke';
    buffer.writeln(
      '$invokeRule ::= '
      '${ToolCallGrammarUtils.literal('<｜DSML｜invoke name="${tool.name}">\n')} '
      '$propertyRules space "</｜DSML｜invoke>\\n"',
    );
    invokeRules.add(invokeRule);
  }
  buffer.writeln('invoke ::= ${invokeRules.join(' | ')}');
  _appendJsonRules(buffer, converter);
  return buffer.toString();
}

String? _buildAtemGrammar(List<ToolDefinition>? tools) {
  if (tools == null || tools.isEmpty) {
    return null;
  }
  const parameterClose = '</atem:parameter>';
  final buffer = StringBuffer()
    ..writeln(
      'root ::= "<atem:function_calls>\\n" invoke+ '
      '"</atem:function_calls>"',
    );
  final converter = JsonSchemaConverter();
  final invokeRules = <String>[];
  for (var toolIndex = 0; toolIndex < tools.length; toolIndex++) {
    final tool = tools[toolIndex];
    final schema = tool.toJsonSchema();
    converter.resolveRefs(schema, schema);
    final propertyRules = _buildNamedParameterRules(
      buffer: buffer,
      converter: converter,
      ruleBase: 'atem-$toolIndex',
      schema: schema,
      openFor: (name, _) => '<atem:parameter name="$name">',
      close: parameterClose,
      trailing: '\n',
    );
    final invokeRule = 'atem-$toolIndex-invoke';
    buffer.writeln(
      '$invokeRule ::= '
      '${ToolCallGrammarUtils.literal('<atem:invoke name="${tool.name}">\n')} '
      '$propertyRules space "</atem:invoke>\\n"',
    );
    invokeRules.add(invokeRule);
  }
  buffer.writeln('invoke ::= ${invokeRules.join(' | ')}');
  _appendJsonRules(buffer, converter);
  return buffer.toString();
}

String _buildNamedParameterRules({
  required StringBuffer buffer,
  required JsonSchemaConverter converter,
  required String ruleBase,
  required Map<String, dynamic> schema,
  required String Function(String, Map<String, dynamic>) openFor,
  required String close,
  required String trailing,
}) {
  final properties =
      (schema['properties'] as Map<String, dynamic>?) ??
      const <String, dynamic>{};
  final required = Set<String>.from(
    (schema['required'] as List?)?.whereType<String>() ?? const <String>[],
  );
  final requiredRules = <String>[];
  final optionalRules = <String>[];
  for (final entry in properties.entries) {
    final propertySchema = entry.value as Map<String, dynamic>;
    final propertyRule = '$ruleBase-${_grammarRuleName(entry.key)}-parameter';
    final valueRule = _buildDelimitedOrJsonValueRule(
      buffer: buffer,
      converter: converter,
      ruleBase: '$propertyRule-value',
      schema: propertySchema,
      delimiter: close,
    );
    buffer.writeln(
      '$propertyRule ::= ${ToolCallGrammarUtils.literal(openFor(entry.key, propertySchema))} '
      '$valueRule ${ToolCallGrammarUtils.literal('$close$trailing')}',
    );
    (required.contains(entry.key) ? requiredRules : optionalRules).add(
      propertyRule,
    );
  }
  final argsRule = '$ruleBase-arguments';
  final body = _buildRequiredThenOptionalBody(
    requiredRules: requiredRules,
    optionalRules: optionalRules,
    separatorRule: 'space',
  );
  buffer.writeln('$argsRule ::= $body');
  return argsRule;
}

String _buildRequiredThenOptionalBody({
  required List<String> requiredRules,
  required List<String> optionalRules,
  required String? separatorRule,
}) {
  final separator = separatorRule == null ? ' ' : ' $separatorRule ';
  var body = requiredRules.isEmpty ? '""' : requiredRules.join(separator);
  if (optionalRules.isEmpty) {
    return body;
  }
  final optionalChoice = optionalRules.length == 1
      ? optionalRules.single
      : '(${optionalRules.join(' | ')})';
  final repeatedSeparator = separatorRule == null ? '' : '$separatorRule ';
  body = '$body ($repeatedSeparator$optionalChoice)*';
  return body;
}

String _buildDelimitedOrJsonValueRule({
  required StringBuffer buffer,
  required JsonSchemaConverter converter,
  required String ruleBase,
  required Map<String, dynamic> schema,
  required String delimiter,
}) {
  if (_schemaResolvesToString(schema)) {
    final enumValues = schema['enum'];
    if (enumValues is List && enumValues.isNotEmpty) {
      return enumValues
          .whereType<String>()
          .map(ToolCallGrammarUtils.literal)
          .join(' | ');
    }
    return _appendUntilLiteralRules(buffer, ruleBase, delimiter);
  }
  return converter.visit(schema, ruleBase);
}

void _appendJsonRules(StringBuffer buffer, JsonSchemaConverter converter) {
  final rules = converter.rules.entries.toList(growable: false)
    ..sort((a, b) => a.key.compareTo(b.key));
  for (final entry in rules) {
    buffer.writeln('${entry.key} ::= ${entry.value}');
  }
}

String _grammarRuleName(String value) {
  return ToolCallGrammarUtils.ruleName(value);
}

String _appendUntilLiteralRules(
  StringBuffer buffer,
  String ruleBase,
  String delimiter,
) {
  final rules = _buildUntilLiteralRuleLines(ruleBase, delimiter);
  for (final line in rules) {
    buffer.writeln(line);
  }
  return '$ruleBase-0';
}

String _buildRequiredPrefixGrammar(String grammar, String trigger) {
  final lines = grammar.trimRight().split('\n');
  final rootIndex = lines.indexWhere((line) => line.startsWith('root ::= '));
  if (rootIndex < 0) {
    return grammar;
  }
  final rootExpression = lines[rootIndex].substring('root ::= '.length);
  lines[rootIndex] = 'root ::= required-prefix-0 required-tool-root';
  lines.insert(rootIndex + 1, 'required-tool-root ::= $rootExpression');
  lines.insertAll(
    rootIndex + 2,
    _buildUntilLiteralRuleLines('required-prefix', trigger),
  );
  return '${lines.join('\n')}\n';
}

List<String> _buildUntilLiteralRuleLines(String ruleBase, String delimiter) {
  final marker = delimiter.runes
      .map(String.fromCharCode)
      .toList(growable: false);
  if (marker.isEmpty) {
    return ['$ruleBase-0 ::= ""'];
  }
  final alphabet = marker.toSet().toList(growable: false);
  final lines = <String>[
    '$ruleBase-other ::= [^${alphabet.map(_escapeGbnfCharacterClass).join()}]',
  ];
  for (var state = 0; state < marker.length; state++) {
    final alternatives = <String>['$ruleBase-other $ruleBase-0'];
    for (final character in alphabet) {
      final next = _delimiterTransition(marker, state, character);
      if (next == marker.length) {
        continue;
      }
      alternatives.add(
        '${ToolCallGrammarUtils.literal(character)} $ruleBase-$next',
      );
    }
    lines.add('$ruleBase-$state ::= (${alternatives.join(' | ')})?');
  }
  return lines;
}

int _delimiterTransition(List<String> marker, int state, String character) {
  final candidate = <String>[...marker.take(state), character];
  final max = candidate.length < marker.length
      ? candidate.length
      : marker.length;
  for (var length = max; length >= 0; length--) {
    var matches = true;
    for (var index = 0; index < length; index++) {
      if (candidate[candidate.length - length + index] != marker[index]) {
        matches = false;
        break;
      }
    }
    if (matches) {
      return length;
    }
  }
  return 0;
}

String _escapeGbnfCharacterClass(String character) {
  return switch (character) {
    r'\' => r'\\',
    ']' => r'\]',
    '-' => r'\-',
    '^' => r'\^',
    _ => character,
  };
}

List<LlamaCompletionChunkToolCall>? _parseJsonObjectSequence(
  String body, {
  List<ToolDefinition>? tools,
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
    if (tools != null) {
      final value = Map<String, dynamic>.from(slice.value as Map);
      final name = value['name'];
      final arguments = value['arguments'];
      final tool = name is String ? _toolByName(tools, name) : null;
      if (tool == null ||
          arguments is! Map ||
          !_objectMatchesSchema(
            Map<String, dynamic>.from(arguments),
            tool.toJsonSchema(),
          )) {
        return null;
      }
    }
    final parsed = ToolCallParsingUtils.parseToolCallArray(<Object?>[
      slice.value,
    ], startIndex: calls.length);
    if (parsed == null || parsed.length != 1) {
      return null;
    }
    calls.add(parsed.single);
    cursor = slice.end;
  }
  return calls.isEmpty ? null : calls;
}

ToolDefinition? _toolByName(List<ToolDefinition>? tools, String name) {
  if (tools == null) {
    return null;
  }
  for (final tool in tools) {
    if (tool.name == name) {
      return tool;
    }
  }
  return null;
}

bool _schemaResolvesToString(Map<String, dynamic> schema) {
  final type = schema['type'];
  if (type == 'string') {
    return true;
  }
  final enumValues = schema['enum'];
  return enumValues is List && enumValues.every((value) => value is String);
}

String _schemaProtocolType(Map<String, dynamic> schema) {
  if (_schemaResolvesToString(schema)) {
    return 'string';
  }
  return switch (schema['type']) {
    'integer' || 'number' => 'number',
    'boolean' => 'boolean',
    'null' => 'null',
    'object' => 'object',
    'array' => 'array',
    _ => 'object',
  };
}

Object? _decodeRawBySchema(String raw, Map<String, dynamic> schema) {
  if (_schemaResolvesToString(schema)) {
    return _valueMatchesSchema(raw, schema) ? raw : _schemaDecodeFailure;
  }
  final decoded = ToolCallParsingUtils.decodeJsonValue(raw);
  if (decoded == null && raw.trim() != 'null') {
    return _schemaDecodeFailure;
  }
  return _valueMatchesSchema(decoded, schema) ? decoded : _schemaDecodeFailure;
}

bool _valueMatchesSchema(Object? value, Map<String, dynamic> schema) {
  final enumValues = schema['enum'];
  if (enumValues is List && !enumValues.contains(value)) {
    return false;
  }

  final type = schema['type'];
  if (type is List) {
    return type.any(
      (candidate) => _valueMatchesSchema(value, <String, dynamic>{
        ...schema,
        'type': candidate,
      }),
    );
  }

  switch (type) {
    case 'string':
      return value is String;
    case 'integer':
      return value is int;
    case 'number':
      return value is num;
    case 'boolean':
      return value is bool;
    case 'null':
      return value == null;
    case 'array':
      if (value is! List) {
        return false;
      }
      final itemSchema = schema['items'];
      return itemSchema is! Map<String, dynamic> ||
          value.every((item) => _valueMatchesSchema(item, itemSchema));
    case 'object':
    case null:
      if (value is! Map) {
        return false;
      }
      final stringMap = <String, dynamic>{};
      for (final entry in value.entries) {
        if (entry.key is! String) {
          return false;
        }
        stringMap[entry.key as String] = entry.value;
      }
      return _objectMatchesSchema(stringMap, schema);
    default:
      return false;
  }
}

bool _objectMatchesSchema(
  Map<String, dynamic> value,
  Map<String, dynamic> schema,
) {
  final properties =
      (schema['properties'] as Map<String, dynamic>?) ??
      const <String, dynamic>{};
  final required = Set<String>.from(
    (schema['required'] as List?)?.whereType<String>() ?? const <String>[],
  );
  if (!value.keys.toSet().containsAll(required)) {
    return false;
  }
  for (final entry in value.entries) {
    final property = properties[entry.key];
    if (property is! Map<String, dynamic> ||
        !_valueMatchesSchema(entry.value, property)) {
      return false;
    }
  }
  return true;
}

const _schemaDecodeFailure = _SchemaDecodeFailure();

class _SchemaDecodeFailure {
  const _SchemaDecodeFailure();
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
    return _ParsedCalls(calls: const [], remaining: input);
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
    final name = start.group(1) ?? '';
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
}) {
  final parsed = _parseDynamicElements(body);
  if (parsed == null) {
    return null;
  }
  if (schema != null) {
    return _coerceDynamicObject(parsed.elements, schema);
  }
  final result = <String, dynamic>{};
  for (final element in parsed.elements) {
    if (result.containsKey(element.name)) {
      return null;
    }
    result[element.name] = _inferDynamicValue(element);
  }
  return result;
}

Map<String, dynamic>? _coerceDynamicObject(
  List<_DynamicElement> elements,
  Map<String, dynamic> schema,
) {
  final properties =
      (schema['properties'] as Map<String, dynamic>?) ??
      const <String, dynamic>{};
  final required = Set<String>.from(
    (schema['required'] as List?)?.whereType<String>() ?? const <String>[],
  );
  final result = <String, dynamic>{};
  for (final element in elements) {
    final propertySchema = properties[element.name];
    if (propertySchema is! Map<String, dynamic> ||
        result.containsKey(element.name)) {
      return null;
    }
    final value = _coerceDynamicElement(element, propertySchema);
    if (identical(value, _schemaDecodeFailure)) {
      return null;
    }
    result[element.name] = value;
  }
  if (!result.keys.toSet().containsAll(required)) {
    return null;
  }
  return result;
}

Object? _coerceDynamicElement(
  _DynamicElement element,
  Map<String, dynamic> schema,
) {
  if (_schemaResolvesToString(schema)) {
    return _valueMatchesSchema(element.raw, schema)
        ? element.raw
        : _schemaDecodeFailure;
  }
  final type = schema['type'];
  if (type == 'object' || (type == null && schema.containsKey('properties'))) {
    final children = element.children;
    if (children == null) {
      return _schemaDecodeFailure;
    }
    return _coerceDynamicObject(children, schema) ?? _schemaDecodeFailure;
  }
  if (type == 'array') {
    final children = element.children;
    final itemSchema = schema['items'];
    if (children == null || itemSchema is! Map<String, dynamic>) {
      return _schemaDecodeFailure;
    }
    final result = <Object?>[];
    for (final child in children) {
      if (child.name != 'item') {
        return _schemaDecodeFailure;
      }
      final value = _coerceDynamicElement(child, itemSchema);
      if (identical(value, _schemaDecodeFailure)) {
        return _schemaDecodeFailure;
      }
      result.add(value);
    }
    return result;
  }
  return _decodeRawBySchema(element.raw, schema);
}

Object? _inferDynamicValue(_DynamicElement element) {
  final children = element.children;
  if (children != null && children.isNotEmpty) {
    if (children.every((child) => child.name == 'item')) {
      return children.map(_inferDynamicValue).toList(growable: false);
    }
    return <String, dynamic>{
      for (final child in children) child.name: _inferDynamicValue(child),
    };
  }
  return ToolCallParsingUtils.decodeJsonValueOrString(element.raw);
}

_DynamicElements? _parseDynamicElements(String input) {
  final elements = <_DynamicElement>[];
  var cursor = 0;
  while (cursor < input.length) {
    while (cursor < input.length && _isWhitespace(input.codeUnitAt(cursor))) {
      cursor++;
    }
    if (cursor == input.length) {
      break;
    }
    final opening = RegExp(
      r'<([A-Za-z_][A-Za-z0-9_.-]*)>',
    ).matchAsPrefix(input, cursor);
    if (opening == null) {
      return null;
    }
    final name = opening.group(1)!;
    final close = _findMatchingDynamicClose(input, name, opening.end);
    if (close == null) {
      return null;
    }
    final raw = input.substring(opening.end, close.start);
    final children = _parseDynamicElements(raw);
    elements.add(
      _DynamicElement(name: name, raw: raw, children: children?.elements),
    );
    cursor = close.end;
  }
  return _DynamicElements(elements);
}

({int start, int end})? _findMatchingDynamicClose(
  String input,
  String name,
  int start,
) {
  final tagPattern = RegExp('<(/?)${RegExp.escape(name)}>');
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
  for (final match in pattern.allMatches(body)) {
    final key = match.group(1) ?? '';
    final raw = match.group(3) ?? '';
    if (key.isEmpty || result.containsKey(key)) {
      return null;
    }
    final property = schema?['properties']?[key];
    if (schema != null && property is! Map<String, dynamic>) {
      return null;
    }
    if (property is Map<String, dynamic>) {
      final expectsString = _schemaResolvesToString(property);
      if ((match.group(2) == 'true') != expectsString) {
        return null;
      }
      final decoded = _decodeRawBySchema(raw, property);
      if (identical(decoded, _schemaDecodeFailure)) {
        return null;
      }
      result[key] = decoded;
    } else if (match.group(2) == 'true') {
      result[key] = raw;
    } else {
      final decoded = ToolCallParsingUtils.decodeJsonValue(raw);
      if (decoded == null && raw.trim() != 'null') {
        return null;
      }
      result[key] = decoded;
    }
  }
  if (schema != null && !_objectMatchesSchema(result, schema)) {
    return null;
  }
  return result;
}

List<LlamaCompletionChunkToolCall>? _parseAtemCalls(
  String body,
  int start, {
  List<ToolDefinition>? tools,
  String? expectedRecipient,
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
    final name = invoke.group(1) ?? '';
    final params = invoke.group(2) ?? '';
    final tool = _toolByName(tools, name);
    if ((tools != null && tool == null) ||
        (expectedRecipient != null &&
            expectedRecipient.isNotEmpty &&
            name != expectedRecipient)) {
      return null;
    }
    final parameterPattern = RegExp(
      r'<atem:parameter name="([^"]+)">([\s\S]*?)</atem:parameter>',
    );
    if (name.isEmpty ||
        params.replaceAll(parameterPattern, '').trim().isNotEmpty) {
      return null;
    }
    final arguments = <String, dynamic>{};
    for (final parameter in parameterPattern.allMatches(params)) {
      final key = parameter.group(1) ?? '';
      final raw = parameter.group(2) ?? '';
      if (key.isEmpty || arguments.containsKey(key)) {
        return null;
      }
      final property = tool?.toJsonSchema()['properties']?[key];
      if (tool != null && property is! Map<String, dynamic>) {
        return null;
      }
      if (property is Map<String, dynamic>) {
        final decoded = _decodeRawBySchema(raw, property);
        if (identical(decoded, _schemaDecodeFailure)) {
          return null;
        }
        arguments[key] = decoded;
      } else {
        arguments[key] = ToolCallParsingUtils.decodeJsonValueOrString(raw);
      }
    }
    if (tool != null && !_objectMatchesSchema(arguments, tool.toJsonSchema())) {
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

String _unescapeAttribute(String value) =>
    value.replaceAll('&quot;', '"').replaceAll('&amp;', '&');

String _escapeAttribute(String value) =>
    value.replaceAll('&', '&amp;').replaceAll('"', '&quot;');

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
  final String raw;
  final List<_DynamicElement>? children;

  const _DynamicElement({
    required this.name,
    required this.raw,
    required this.children,
  });
}
