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

abstract class _DirectJinjaHandler extends ChatTemplateHandler {
  @override
  TemplateToolCallSerialization get toolCallSerialization =>
      TemplateToolCallSerialization.normalizeOnly;

  String get defaultBosToken => '';

  String get defaultEosToken => '';

  List<String> get grammarTriggerValues => const [];

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
      grammar: buildGrammar(tools),
      grammarLazy: hasTools,
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
        content: content.isEmpty
            ? _stripKimiTurnEnd(remaining)
            : content.trim(),
        reasoningContent: _nullIfEmpty(reasoning),
      );
    }

    final parsed = _parseKimiTools(remaining, isPartial: isPartial);
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

  _ParsedCalls _parseKimiTools(String input, {required bool isPartial}) {
    final scopeStart = input.indexOf(_toolsStart);
    if (scopeStart < 0) {
      return _ParsedCalls(calls: const [], remaining: _stripKimiTurnEnd(input));
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
      final arguments = _parseKimiArguments(callBody);
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

  Map<String, dynamic>? _parseKimiArguments(String body) {
    final jsonPattern = RegExp(
      r'<\|open\|>json\s+type="object"<\|sep\|>([\s\S]*?)<\|close\|>json<\|sep\|>',
    );
    final jsonMatch = jsonPattern.firstMatch(body);
    if (jsonMatch != null) {
      if (body.replaceFirst(jsonPattern, '').trim().isNotEmpty) {
        return null;
      }
      return ToolCallParsingUtils.decodeJsonObject(jsonMatch.group(1) ?? '');
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
      if (key.isEmpty) {
        return null;
      }
      if (type == 'string') {
        result[key] = raw;
      } else {
        final decoded = ToolCallParsingUtils.decodeJsonValue(raw);
        if (decoded == null && raw.trim() != 'null') {
          return null;
        }
        result[key] = decoded;
      }
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
    if (tools == null || tools.isEmpty) {
      return null;
    }
    final names = tools
        .map((tool) => ToolCallGrammarUtils.literal(tool.name))
        .join(' | ');
    final converter = JsonSchemaConverter();
    const objectSchema = <String, dynamic>{'type': 'object'};
    converter.resolveRefs(objectSchema, objectSchema);
    final objectRule = converter.visit(objectSchema, 'json-object');
    final buffer = StringBuffer()
      ..writeln(
        'root ::= "<|open|>tools<|sep|>" call+ '
        '"<|close|>tools<|sep|><|close|>message<|sep|>"',
      )
      ..writeln(
        'call ::= "<|open|>call tool=\\"" tool-name '
        '"\\"" (" index=\\"" [0-9]+ "\\"")? "<|sep|>" '
        '(argument* | json-block) "<|close|>call<|sep|>"',
      )
      ..writeln(
        'argument ::= "<|open|>argument key=\\"" identifier '
        '"\\" type=\\"" value-type "\\"<|sep|>" raw '
        '"<|close|>argument<|sep|>"',
      )
      ..writeln(
        'json-block ::= "<|open|>json type=\\"object\\"<|sep|>" '
        '$objectRule "<|close|>json<|sep|>"',
      )
      ..writeln('tool-name ::= $names')
      ..writeln(
        'value-type ::= "string" | "number" | "boolean" | "null" | '
        '"object" | "array"',
      )
      ..writeln('identifier ::= [A-Za-z_] [A-Za-z0-9_.-]*')
      ..writeln('raw ::= [^<]*');
    final jsonRules = converter.rules.entries.toList(growable: false)
      ..sort((a, b) => a.key.compareTo(b.key));
    for (final entry in jsonRules) {
      buffer.writeln('${entry.key} ::= ${entry.value}');
    }
    return buffer.toString();
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
    if (!parseToolCalls) {
      return ChatParseResult(content: output.trim());
    }
    const start = '<tool_calls>';
    const end = '</tool_calls>';
    final startIndex = output.indexOf(start);
    if (startIndex < 0) {
      return ChatParseResult(content: output.trim());
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
    final calls = _parseJsonObjectSequence(body);
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
          '${ToolCallGrammarUtils.literal(tool.name)} space "," space '
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
        content: rawContent,
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
      parseArguments: _parseDynamicTagArguments,
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
    if (tools == null || tools.isEmpty) {
      return null;
    }
    final names = tools
        .map((tool) => ToolCallGrammarUtils.literal(tool.name))
        .join(' | ');
    return '''
root ::= "$namespace<tool_call>\\n" invoke+ "$namespace</tool_call>"
invoke ::= "$namespace<invoke name=\\"" tool-name "\\">" parameter* "$namespace</invoke>\\n"
parameter ::= "$namespace<" identifier ">" m3-value "$namespace</" identifier ">"
tool-name ::= $names
identifier ::= [A-Za-z_] [A-Za-z0-9_.-]*
m3-value ::= raw | parameter+
raw ::= [^]]*
''';
  }
}

/// Handler for DeepSeek V3.2/V4 DSML tool calls.
class DeepseekV4Handler extends _DirectJinjaHandler {
  static const _prefix = '<｜DSML｜';

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
    );
    if (!parseToolCalls) {
      return ChatParseResult(
        content: thinking.content,
        reasoningContent: thinking.reasoning,
      );
    }
    final parsed = _parseInvokeScope(
      thinking.content,
      scopeStart:
          '$_prefix'
          'tool_calls>',
      scopeEnd: '</｜DSML｜tool_calls>',
      invokeStartPattern: RegExp(r'<｜DSML｜invoke name="([^"]+)">'),
      invokeEnd: '</｜DSML｜invoke>',
      parseArguments: _parseDsmlArguments,
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
    if (tools == null || tools.isEmpty) {
      return null;
    }
    final names = tools
        .map((tool) => ToolCallGrammarUtils.literal(tool.name))
        .join(' | ');
    return '''
root ::= "<｜DSML｜tool_calls>\\n" invoke+ "</｜DSML｜tool_calls>"
invoke ::= "<｜DSML｜invoke name=\\"" tool-name "\\">\\n" parameter* "</｜DSML｜invoke>\\n"
parameter ::= "<｜DSML｜parameter name=\\"" identifier "\\" string=\\"" boolean "\\">" raw "</｜DSML｜parameter>\\n"
tool-name ::= $names
identifier ::= [A-Za-z_] [A-Za-z0-9_.-]*
boolean ::= "true" | "false"
raw ::= [^<]*
''';
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
  }) {
    final channelPattern = RegExp(
      r'(?:<\|start\|>assistant)?\s+to=([^<]+)<\|message\|>([\s\S]*?)(<\|eom\|>|<\|eot\|>|$)',
    );
    final matches = channelPattern.allMatches(output).toList(growable: false);
    if (matches.isEmpty) {
      return ChatParseResult(content: output.trim());
    }

    final content = StringBuffer();
    final reasoning = StringBuffer();
    final calls = <LlamaCompletionChunkToolCall>[];
    for (final match in matches) {
      final recipient = (match.group(1) ?? '').trim();
      final body = match.group(2) ?? '';
      if (recipient == 'self') {
        if (reasoning.isNotEmpty) reasoning.writeln();
        reasoning.write(body);
      } else if (recipient == 'user') {
        if (content.isNotEmpty) content.writeln();
        content.write(body);
      } else if (parseToolCalls) {
        final parsed = _parseAtemCalls(body, calls.length);
        if (parsed == null) {
          final terminator = match.group(3) ?? '';
          if (!isPartial || terminator.isNotEmpty) {
            if (content.isNotEmpty) content.writeln();
            content.write(body);
          }
        } else {
          calls.addAll(parsed);
        }
      } else {
        if (content.isNotEmpty) content.writeln();
        content.write(body);
      }
    }

    return ChatParseResult(
      content: content.toString().trim(),
      reasoningContent: _nullIfEmpty(reasoning.toString()),
      toolCalls: calls,
    );
  }

  @override
  String? buildGrammar(List<ToolDefinition>? tools) {
    if (tools == null || tools.isEmpty) {
      return null;
    }
    final names = tools
        .map((tool) => ToolCallGrammarUtils.literal(tool.name))
        .join(' | ');
    return '''
root ::= "<atem:function_calls>\\n" invoke "</atem:function_calls>"
invoke ::= "<atem:invoke name=\\"" tool-name "\\">\\n" parameter* "</atem:invoke>\\n"
parameter ::= "<atem:parameter name=\\"" identifier "\\">" raw "</atem:parameter>\\n"
tool-name ::= $names
identifier ::= [A-Za-z_] [A-Za-z0-9_.-]*
raw ::= [^<]*
''';
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
    return Glm45Handler().parse(
      output,
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

List<LlamaCompletionChunkToolCall>? _parseJsonObjectSequence(String body) {
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

_ParsedCalls _parseInvokeScope(
  String input, {
  required String scopeStart,
  required String scopeEnd,
  required RegExp invokeStartPattern,
  required String invokeEnd,
  required Map<String, dynamic>? Function(String) parseArguments,
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
    final arguments = parseArguments(body.substring(argumentsStart, end));
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

Map<String, dynamic>? _parseDynamicTagArguments(String body) {
  final parsed = _parseDynamicElements(body);
  if (parsed == null || parsed.elements.isEmpty) {
    return null;
  }
  final result = <String, dynamic>{};
  for (final element in parsed.elements) {
    result[element.name] = element.value;
  }
  return result;
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
    Object? value;
    if (children != null && children.elements.isNotEmpty) {
      if (children.elements.every((element) => element.name == 'item')) {
        value = children.elements
            .map((element) => element.value)
            .toList(growable: false);
      } else {
        value = <String, dynamic>{
          for (final element in children.elements) element.name: element.value,
        };
      }
    } else {
      value = ToolCallParsingUtils.decodeJsonValueOrString(raw);
    }
    elements.add(_DynamicElement(name: name, value: value));
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

Map<String, dynamic>? _parseDsmlArguments(String body) {
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
    if (key.isEmpty) {
      return null;
    }
    if (match.group(2) == 'true') {
      result[key] = raw;
    } else {
      final decoded = ToolCallParsingUtils.decodeJsonValue(raw);
      if (decoded == null && raw.trim() != 'null') {
        return null;
      }
      result[key] = decoded;
    }
  }
  return result;
}

List<LlamaCompletionChunkToolCall>? _parseAtemCalls(String body, int start) {
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
      if (key.isEmpty) {
        return null;
      }
      arguments[key] = ToolCallParsingUtils.decodeJsonValueOrString(raw);
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
