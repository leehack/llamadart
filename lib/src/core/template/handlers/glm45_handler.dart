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
import '../tool_schema_utils.dart';

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
  }) {
    return parseWithTools(
      output,
      isPartial: isPartial,
      parseToolCalls: parseToolCalls,
      thinkingForcedOpen: thinkingForcedOpen,
    );
  }

  /// Parses GLM output using [tools] for schema-directed argument types.
  @override
  ChatParseResult parseWithTools(
    String output, {
    List<ToolDefinition>? tools,
    bool isPartial = false,
    bool parseToolCalls = true,
    bool thinkingForcedOpen = false,
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

    final parseText = isPartial ? _hideIncompleteToolCallBlock(text) : text;
    final extractedFromContent = _extractToolCalls(
      parseText,
      schemas: toolSchemas(tools),
    );
    if (extractedFromContent == null) {
      return ChatParseResult(
        content: parseText.trim(),
        reasoningContent: thinking.reasoning,
      );
    }
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
      'tool-call ::= "\\n<tool_call>" tool-choice "</tool_call>\\n"',
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

  _ExtractedToolCalls? _extractToolCalls(
    String input, {
    required Map<String, Map<String, dynamic>> schemas,
  }) {
    final toolCalls = <LlamaCompletionChunkToolCall>[];
    var remaining = input;

    final matches = _toolCallBlockPattern.allMatches(input);
    for (final match in matches) {
      final block = match.group(1) ?? '';
      final firstArgIdx = block.indexOf('<arg_key>');
      final toolName = firstArgIdx == -1
          ? block.trim()
          : block.substring(0, firstArgIdx).trim();
      if (firstArgIdx >= 0 &&
          block
              .substring(firstArgIdx)
              .replaceAll(_argPairPattern, '')
              .trim()
              .isNotEmpty) {
        return null;
      }
      final schema = schemas[toolName];
      if (schemas.isNotEmpty && schema == null) {
        return null;
      }
      final properties = schema == null ? null : schemaProperties(schema);
      final required = schema == null
          ? const <String>{}
          : schemaRequired(schema);
      final args = <String, dynamic>{};
      for (final argMatch in _argPairPattern.allMatches(block)) {
        final key = (argMatch.group(1) ?? '').trim();
        final rawValue = (argMatch.group(2) ?? '').trim();
        if (key.isEmpty) {
          return null;
        }
        if (args.containsKey(key)) {
          return null;
        }
        final propertySchema = properties?[key];
        if (properties != null && propertySchema == null) {
          return null;
        }
        if (propertySchema == null) {
          args[key] = _decodeArgValue(rawValue);
        } else {
          final decoded = _decodeGlmSchemaText(rawValue, propertySchema);
          if (!decoded.valid) {
            return null;
          }
          args[key] = decoded.value;
        }
      }

      if (toolName.isEmpty || !args.keys.toSet().containsAll(required)) {
        return null;
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

ToolSchemaValueResult _decodeGlmSchemaText(
  String raw,
  Map<String, dynamic> schema,
) {
  if (schemaResolvesToString(schema)) {
    final decoded = ToolCallParsingUtils.decodeJsonValue(raw);
    return validateToolSchemaValue(decoded is String ? decoded : raw, schema);
  }
  return decodeToolSchemaText(raw, schema);
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
        '"${_escapeGlmLiteralCharacter(character)}" $ruleBase-$next',
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

String _escapeGlmLiteralCharacter(String character) {
  return character.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
}

String _hideIncompleteToolCallBlock(String input) {
  const marker = '<tool_call>';
  final open = input.lastIndexOf(marker);
  final close = input.lastIndexOf('</tool_call>');
  if (open > close) {
    return input.substring(0, open);
  }
  for (var length = 1; length < marker.length; length++) {
    if (input.endsWith(marker.substring(0, length))) {
      return input.substring(0, input.length - length);
    }
  }
  return input;
}

class _ExtractedToolCalls {
  final List<LlamaCompletionChunkToolCall> toolCalls;
  final String remainingContent;

  const _ExtractedToolCalls({
    required this.toolCalls,
    required this.remainingContent,
  });
}
