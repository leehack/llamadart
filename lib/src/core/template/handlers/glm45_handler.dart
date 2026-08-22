import 'package:dinja/dinja.dart';

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

/// Handler for GLM 4.5 format.
///
/// Uses `<|observation|>` as a stop token for tool call observation.
/// Tool call format:
/// `<tool_call>func_name<arg_key>key</arg_key><arg_value>value</arg_value></tool_call>`
///
/// Supports `<think>`/`</think>` for reasoning.
class Glm45Handler extends ChatTemplateHandler
    implements ToolSchemaAwareChatTemplateHandler {
  static final RegExp _toolCallBlockPattern = RegExp(
    r'<tool_call>\s*([\s\S]*?)</tool_call>',
  );
  static final RegExp _argPairPattern = RegExp(
    r'<arg_key>\s*([\s\S]*?)\s*</arg_key>\s*<arg_value>\s*([\s\S]*?)\s*</arg_value>',
  );

  @override
  ChatFormat get format => ChatFormat.glm45;

  @override
  TemplateToolCallSerialization get toolCallSerialization =>
      TemplateToolCallSerialization.normalizeOnly;

  @override
  List<String> get additionalStops => ['<|user|>', '<|observation|>'];

  @override
  List<String> get preservedTokens => const [
    '<|endoftext|>',
    '[MASK]',
    '[gMASK]',
    '[sMASK]',
    '<sop>',
    '<eop>',
    '<|system|>',
    '<|user|>',
    '<|assistant|>',
    '<|observation|>',
    '<|begin_of_image|>',
    '<|end_of_image|>',
    '<|begin_of_video|>',
    '<|end_of_video|>',
    '<|begin_of_audio|>',
    '<|end_of_audio|>',
    '<|begin_of_transcription|>',
    '<|end_of_transcription|>',
    '<|code_prefix|>',
    '<|code_middle|>',
    '<|code_suffix|>',
    '/nothink',
    '<think>',
    '</think>',
    '<tool_call>',
    '</tool_call>',
    '<arg_key>',
    '</arg_key>',
    '<arg_value>',
    '</arg_value>',
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
    var prompt = renderTemplate(
      template,
      metadata: metadata,
      context: {
        'messages': templateMessages(messages),
        'add_generation_prompt': addAssistant,
        'tools': tools?.map((t) => t.toJson()).toList(),
        'bos_token': metadata['tokenizer.ggml.bos_token'] ?? '[gMASK]<sop>',
        'eos_token': metadata['tokenizer.ggml.eos_token'] ?? '<|user|>',
        'clear_thinking': false,
      },
    );

    // Handle enableThinking post-render logic
    var thinkingForcedOpen = false;
    if (isThinkingForcedOpen(prompt)) {
      if (!enableThinking) {
        prompt = '${prompt.trimRight()}</think>\n';
      } else {
        thinkingForcedOpen = true;
      }
    }

    final hasTools = tools != null && tools.isNotEmpty;
    // GLM 4.5 tool calls are wrapped in <tool_call> XML blocks.
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
          ? [const GrammarTrigger(type: 0, value: '<tool_call>')]
          : const [],
    );
  }

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
      thinkingForcedOpen: thinkingForcedOpen,
    );
    final text = thinking.content;

    if (!parseToolCalls) {
      return ChatParseResult(
        content: text.trim(),
        reasoningContent: thinking.reasoning,
      );
    }

    var parseableText = text;
    if (isPartial) {
      final incompleteStart = text.lastIndexOf('<tool_call>');
      if (incompleteStart >= 0 &&
          text.indexOf('</tool_call>', incompleteStart) < 0) {
        parseableText = text.substring(0, incompleteStart);
      } else {
        final partialStart = _glmPartialMarkerStart(text, '<tool_call>');
        if (partialStart != null) {
          parseableText = text.substring(0, partialStart);
        }
      }
    }
    final extractedFromContent = _extractToolCalls(parseableText, tools: tools);
    final toolCalls = <LlamaCompletionChunkToolCall>[
      ...extractedFromContent.toolCalls,
    ];
    var contentText = extractedFromContent.remainingContent;

    return ChatParseResult(
      content: contentText.trim(),
      reasoningContent: thinking.reasoning,
      toolCalls: toolCalls,
    );
  }

  @override
  String? buildGrammar(List<ToolDefinition>? tools) {
    if (tools == null || tools.isEmpty) {
      return null;
    }

    final toolChoiceRules = <String>[];
    final toolRules = <String>[];

    for (final tool in tools) {
      final toolRuleName = '${ToolCallGrammarUtils.ruleName(tool.name)}-call';
      toolChoiceRules.add(toolRuleName);

      final argParts = <String>[];
      for (final parameter in tool.parameters) {
        final paramSchema = parameter.toJsonSchema();
        final paramRuleName =
            '${ToolCallGrammarUtils.ruleName(tool.name)}-arg-'
            '${ToolCallGrammarUtils.ruleName(parameter.name)}';
        final valueRuleName =
            '${ToolCallGrammarUtils.ruleName(tool.name)}-arg-'
            '${ToolCallGrammarUtils.ruleName(parameter.name)}-value';

        final valueRules = _buildValueRules(
          valueRuleName: valueRuleName,
          schema: paramSchema,
        );

        toolRules.addAll(valueRules);
        toolRules.add(
          '$paramRuleName ::= "<arg_key>${_escapeLiteral(parameter.name)}</arg_key>\\n<arg_value>" $valueRuleName "</arg_value>\\n"',
        );
        argParts.add(parameter.required ? paramRuleName : '($paramRuleName)?');
      }

      final argsRule = argParts.join(' ');
      toolRules.add(
        '$toolRuleName ::= "${_escapeLiteral(tool.name)}\\n" $argsRule',
      );
    }

    final toolChoiceRule = 'tool-choice ::= ${toolChoiceRules.join(' | ')}';

    return [
      'root ::= tool-call+',
      'tool-call ::= "\\n"? "<tool_call>" tool-choice "</tool_call>\\n"',
      toolChoiceRule,
      ...toolRules,
      'space ::= " "?',
      'string ::= "\\"" ([^"\\\\] | "\\\\" .)* "\\""',
      'number ::= "-"? ([0-9] | [1-9] [0-9]*) ("." [0-9]+)? ([eE] [+-]? [0-9]+)?',
      'boolean ::= "true" | "false"',
      'null ::= "null"',
      'value ::= string | number | boolean | null | arr | obj',
      'arr ::= "[" space (value ("," space value)*)? "]"',
      'obj ::= "{" space (string ":" space value ("," space string ":" space value)*)? "}"',
    ].join('\n');
  }

  List<String> _buildValueRules({
    required String valueRuleName,
    required Map<String, dynamic> schema,
  }) {
    final type = schema['type'];
    final enumValues = schema['enum'];

    if (type == 'string') {
      if (enumValues is List && enumValues.isNotEmpty) {
        final rawEnum = enumValues
            .whereType<String>()
            .map((value) => '"${_escapeLiteral(value)}"')
            .join(' | ');
        final jsonEnum = enumValues
            .whereType<String>()
            .map((value) => '"\\"${_escapeLiteral(value)}\\""')
            .join(' | ');
        return ['$valueRuleName ::= $rawEnum | $jsonEnum'];
      }
      return [
        '$valueRuleName ::= $valueRuleName-raw-0',
        ..._glmUntilLiteralRules('$valueRuleName-raw', '</arg_value>'),
      ];
    }

    if (type == 'integer' || type == 'number') {
      return ['$valueRuleName ::= number'];
    }

    if (type == 'boolean') {
      return ['$valueRuleName ::= boolean'];
    }

    if (type == 'array') {
      return ['$valueRuleName ::= arr'];
    }

    if (type == 'object') {
      return ['$valueRuleName ::= obj'];
    }

    return ['$valueRuleName ::= value'];
  }

  String _escapeLiteral(String input) {
    return input.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
  }

  Object? _decodeArgValue(String value) {
    if (value.isEmpty) {
      return '';
    }

    return ToolCallParsingUtils.decodeJsonValueOrString(value);
  }

  _ExtractedToolCalls _extractToolCalls(
    String input, {
    required List<ToolDefinition>? tools,
  }) {
    final toolCalls = <LlamaCompletionChunkToolCall>[];
    var remaining = input;
    _ExtractedToolCalls schemaFailure() =>
        _ExtractedToolCalls(toolCalls: const [], remainingContent: input);

    final matches = _toolCallBlockPattern.allMatches(input);
    for (final match in matches) {
      final block = match.group(1) ?? '';
      final firstArgIdx = block.indexOf('<arg_key>');
      final toolName = firstArgIdx == -1
          ? block.trim()
          : block.substring(0, firstArgIdx).trim();
      final tool = _glmToolByName(tools, toolName);
      if (tools != null && tool == null) {
        return schemaFailure();
      }
      final args = <String, dynamic>{};
      final argumentBody = firstArgIdx == -1
          ? ''
          : block.substring(firstArgIdx);
      if (argumentBody.replaceAll(_argPairPattern, '').trim().isNotEmpty) {
        if (tools != null) {
          return schemaFailure();
        }
        continue;
      }
      var validArguments = true;
      for (final argMatch in _argPairPattern.allMatches(block)) {
        final key = (argMatch.group(1) ?? '').trim();
        final rawValue = (argMatch.group(2) ?? '').trim();
        if (key.isEmpty) {
          if (tools != null) {
            validArguments = false;
            break;
          }
          continue;
        }
        if (tools != null && args.containsKey(key)) {
          validArguments = false;
          break;
        }
        final schema = tool?.toJsonSchema();
        final property = schema?['properties']?[key];
        if (tool != null && property is! Map<String, dynamic>) {
          validArguments = false;
          break;
        }
        final decoded = property is Map<String, dynamic>
            ? _decodeGlmSchemaValue(rawValue, property)
            : _decodeArgValue(rawValue);
        if (identical(decoded, _glmSchemaFailure)) {
          validArguments = false;
          break;
        }
        args[key] = decoded;
      }

      final schemaMatches =
          tool == null || _glmObjectMatchesSchema(args, tool.toJsonSchema());
      if (toolName.isEmpty || !validArguments || !schemaMatches) {
        if (tools != null) {
          return schemaFailure();
        }
        continue;
      }

      final index = toolCalls.length;
      toolCalls.add(
        ToolCallParsingUtils.createFunctionToolCall(
          index: index,
          name: toolName,
          arguments: args,
        ),
      );

      final fullBlock = match.group(0);
      if (fullBlock != null && fullBlock.isNotEmpty) {
        remaining = remaining.replaceFirst(fullBlock, '');
      }
    }

    return _ExtractedToolCalls(
      toolCalls: toolCalls,
      remainingContent: remaining,
    );
  }
}

int? _glmPartialMarkerStart(String input, String marker) {
  final lowerBound = input.length > marker.length
      ? input.length - marker.length
      : 0;
  for (var index = lowerBound; index < input.length; index++) {
    if (marker.startsWith(input.substring(index))) {
      return index;
    }
  }
  return null;
}

class _ExtractedToolCalls {
  final List<LlamaCompletionChunkToolCall> toolCalls;
  final String remainingContent;

  const _ExtractedToolCalls({
    required this.toolCalls,
    required this.remainingContent,
  });
}

ToolDefinition? _glmToolByName(List<ToolDefinition>? tools, String name) {
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

Object? _decodeGlmSchemaValue(String raw, Map<String, dynamic> schema) {
  if (schema['type'] == 'string') {
    final decoded = ToolCallParsingUtils.decodeJsonValue(raw);
    final value = decoded is String ? decoded : raw;
    final enumValues = schema['enum'];
    return enumValues is List && !enumValues.contains(value)
        ? _glmSchemaFailure
        : value;
  }
  final decoded = ToolCallParsingUtils.decodeJsonValue(raw);
  if (decoded == null && raw.trim() != 'null') {
    return _glmSchemaFailure;
  }
  return _glmValueMatchesSchema(decoded, schema) ? decoded : _glmSchemaFailure;
}

bool _glmObjectMatchesSchema(
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
        !_glmValueMatchesSchema(entry.value, property)) {
      return false;
    }
  }
  return true;
}

bool _glmValueMatchesSchema(Object? value, Map<String, dynamic> schema) {
  final enumValues = schema['enum'];
  if (enumValues is List && !enumValues.contains(value)) {
    return false;
  }
  return switch (schema['type']) {
    'string' => value is String,
    'integer' => value is int,
    'number' => value is num,
    'boolean' => value is bool,
    'null' => value == null,
    'array' =>
      value is List &&
          (schema['items'] is! Map<String, dynamic> ||
              value.every(
                (item) => _glmValueMatchesSchema(
                  item,
                  schema['items'] as Map<String, dynamic>,
                ),
              )),
    'object' || null =>
      value is Map &&
          _glmObjectMatchesSchema(Map<String, dynamic>.from(value), schema),
    _ => false,
  };
}

const _glmSchemaFailure = _GlmSchemaFailure();

class _GlmSchemaFailure {
  const _GlmSchemaFailure();
}

List<String> _glmUntilLiteralRules(String ruleBase, String delimiter) {
  final marker = delimiter.runes
      .map(String.fromCharCode)
      .toList(growable: false);
  final alphabet = marker.toSet().toList(growable: false);
  final lines = <String>[
    '$ruleBase-other ::= [^${alphabet.map(_escapeGlmCharacterClass).join()}]',
  ];
  for (var state = 0; state < marker.length; state++) {
    final alternatives = <String>['$ruleBase-other $ruleBase-0'];
    for (final character in alphabet) {
      final next = _glmDelimiterTransition(marker, state, character);
      if (next == marker.length) {
        continue;
      }
      alternatives.add(
        '"${_escapeLiteralCharacter(character)}" $ruleBase-$next',
      );
    }
    lines.add('$ruleBase-$state ::= (${alternatives.join(' | ')})?');
  }
  return lines;
}

int _glmDelimiterTransition(List<String> marker, int state, String character) {
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

String _escapeGlmCharacterClass(String character) {
  return switch (character) {
    r'\' => r'\\',
    ']' => r'\]',
    '-' => r'\-',
    '^' => r'\^',
    _ => character,
  };
}

String _escapeLiteralCharacter(String character) {
  return character.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
}
