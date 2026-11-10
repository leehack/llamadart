import 'package:dinja/dinja.dart';

import '../../models/chat/chat_message.dart';
import '../../models/chat/chat_template_result.dart';
import '../../models/inference/tool_choice.dart';
import '../../models/tools/tool_definition.dart';
import '../chat_format.dart';
import '../chat_parse_result.dart';
import '../chat_template_handler.dart';
import '../peg_parser_builder.dart';
import '../template_internal_metadata.dart';
import '../thinking_utils.dart';
import '../tool_call_parsing_utils.dart';
import '../tool_schema_utils.dart';
import '../xml_tool_call_format.dart';

/// Handler for Qwen Coder and Qwen3.6 XML tool-call formats.
///
/// Uses `<tool_call><function=...><parameter=...>` envelopes.
class Qwen3CoderXmlHandler extends ChatTemplateHandler
    implements ToolSchemaAwareChatTemplateHandler {
  static const List<String> _qwenPreservedTokens = <String>[
    '<think>',
    '</think>',
    '<tool_call>',
    '</tool_call>',
    '<function=',
    '</function>',
    '<parameter=',
    '</parameter>',
  ];

  static const List<String> _nemotronV3PreservedTokens = <String>[
    '<think>',
    '</think>',
    '<tool_call>',
    '</tool_call>',
  ];

  @override
  ChatFormat get format => ChatFormat.qwen3CoderXml;

  @override
  TemplateToolCallSerialization get toolCallSerialization =>
      TemplateToolCallSerialization.normalizeOnly;

  @override
  List<String> get additionalStops => ['<|im_end|>', '</s>'];

  @override
  List<String> get preservedTokens => _qwenPreservedTokens;

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
        'enable_thinking': enableThinking,
        'bos_token': metadata['tokenizer.ggml.bos_token'] ?? '<|im_start|>',
        'eos_token': metadata['tokenizer.ggml.eos_token'] ?? '<|im_end|>',
      },
    );

    final isNemotronV3 = _isNemotronV3Template(templateSource);
    final toolChoice = metadata[internalToolChoiceMetadataKey];
    final parallelToolCalls =
        metadata[internalParallelToolCallsMetadataKey] == 'true';
    final toolChoiceNone = toolChoice == ToolChoice.none.name;
    final toolChoiceRequired = toolChoice == ToolChoice.required.name;
    // llama.cpp takes no thought from a reply to a template without one, and
    // its first call may then leave out `<tool_call>`, as Qwen3-Coder does.
    // llamadart takes such a call only for a required call, so that another
    // reply may write a declared `<function=name>` as text: llama.cpp ends the
    // content there and its lazy grammar starts there.
    final templateHasThought = templateSource.contains('<think>');
    final thinkingForcedClosed =
        isThinkingForcedClosed(prompt) || !templateHasThought;
    var thinkingForcedOpen = false;
    var thoughtClosed = false;
    if (isThinkingForcedOpen(prompt, startTag: '<think>')) {
      if (!enableThinking) {
        prompt = '${prompt.trimRight()}</think>\n';
        thoughtClosed = true;
      } else {
        thinkingForcedOpen = true;
      }
    }

    final hasTools = tools != null && tools.isNotEmpty;
    final nemotronAllowToolCalls = isNemotronV3 && hasTools && !toolChoiceNone;
    final bareFirstCall =
        hasTools && toolChoiceRequired && !isNemotronV3 && !templateHasThought;
    final parser = isNemotronV3
        ? _buildNemotronV3Parser(
            tools,
            enableThinking: enableThinking,
            thinkingForcedOpen: thinkingForcedOpen,
            allowToolCalls: nemotronAllowToolCalls,
            minToolCalls: toolChoiceRequired ? 1 : 0,
            maxToolCalls: parallelToolCalls ? -1 : 1,
          )
        : null;
    final resultFormat = isNemotronV3
        ? ChatFormat.pegConstructed.index
        : format.index;
    final grammar = buildXmlToolCallGrammar(
      tools,
      XmlToolCallFormat.qwen3Coder,
      parallelToolCalls: parallelToolCalls,
      textBeforeCalls: toolChoiceRequired && !isNemotronV3,
      bareFirstCall: bareFirstCall,
    );

    final rendered = LlamaChatTemplateResult(
      prompt: prompt,
      format: resultFormat,
      grammar: isNemotronV3
          ? (nemotronAllowToolCalls
                ? requiredGrammarAfterThought(
                    grammar,
                    metadata: metadata,
                    thinkingForcedOpen: thinkingForcedOpen,
                  )
                : null)
          : grammar,
      grammarLazy: isNemotronV3
          ? (nemotronAllowToolCalls && !toolChoiceRequired)
          : hasTools,
      thinkingForcedOpen: thinkingForcedOpen,
      additionalStops: getStops(
        hasTools: hasTools,
        enableThinking: enableThinking,
      ),
      preservedTokens: isNemotronV3
          ? _nemotronV3PreservedTokens
          : preservedTokens,
      grammarTriggers: (isNemotronV3 ? nemotronAllowToolCalls : hasTools)
          ? [
              GrammarTrigger(
                type: 0,
                value: isNemotronV3 ? '<tool_call>' : '<tool_call>\n<function=',
              ),
            ]
          : const [],
      parser: parser,
    );
    return withBareFirstCall(
      withSingleToolCall(
        withThoughtClosedForThinkingOff(
          withThinkingForcedClosed(rendered, closed: thinkingForcedClosed),
          closed: thoughtClosed,
        ),
        single: hasTools && !parallelToolCalls,
      ),
      bare: bareFirstCall,
    );
  }

  bool _isNemotronV3Template(String templateSource) {
    return templateSource.contains('truncate_history_thinking') &&
        templateSource.contains('<tool_call>') &&
        templateSource.contains('<function>') &&
        templateSource.contains('<parameters>') &&
        templateSource.contains('<think>');
  }

  String _buildNemotronV3Parser(
    List<ToolDefinition>? tools, {
    required bool enableThinking,
    required bool thinkingForcedOpen,
    required bool allowToolCalls,
    required int minToolCalls,
    required int maxToolCalls,
  }) {
    final p = ChatPegConstructedBuilder();
    final hasTools = tools != null && tools.isNotEmpty;

    PegParser reasoning = p.eps();
    if (enableThinking) {
      final reasoningContent =
          p.reasoning(p.until('</think>')) + (p.literal('</think>') | p.end());
      if (thinkingForcedOpen) {
        reasoning = reasoningContent;
      }
    }

    if (!hasTools || !allowToolCalls) {
      p.setRoot(reasoning + p.content(p.rest()));
      return p.save();
    }

    PegParser toolChoice = p.choice(<PegParser>[]);
    for (final tool in tools) {
      final name = tool.name;
      final schema = tool.toJsonSchema();
      final requiredParameters = _requiredParameters(schema);
      final properties = _schemaProperties(schema);

      PegParser args = p.eps();
      for (final entry in properties.entries) {
        final paramName = entry.key;
        final paramSchema = entry.value;
        final isRequired = requiredParameters.contains(paramName);
        final ruleName = 'tool-$name-arg-$paramName';

        final argOpen = p.toolArgOpen(
          p.literal('<parameter=') +
              p.toolArgName(p.literal(paramName)) +
              p.literal('>\n'),
        );
        final argClose = p.toolArgClose(p.literal('</parameter>\n'));

        final argValue = _resolvesToString(paramSchema)
            ? p.toolArgStringValue(
                    p.untilOneOf(<String>[
                      '\n</parameter>',
                      '\n<parameter=',
                      '\n</function>',
                    ]),
                  ) +
                  p.literal('\n')
            : p.toolArgJsonValue(
                p.schema(p.json(), '$ruleName-schema', paramSchema),
              );

        final argRule = p.rule(
          ruleName,
          argOpen + argValue + p.optional(argClose),
        );
        args += p.repeat(argRule, isRequired ? 1 : 0, 1);
      }

      final toolRule = p.rule(
        'tool-$name',
        p.toolOpen(
              p.literal('<function=') +
                  p.toolName(p.literal(name)) +
                  p.literal('>\n'),
            ) +
            args +
            p.toolClose(p.literal('</function>\n')),
      );
      toolChoice |= toolRule;
    }

    final toolCall = p.rule(
      'tool-call',
      p.literal('<tool_call>\n') +
          toolChoice +
          p.literal('</tool_call>') +
          p.space(),
    );
    final toolCalls = p.triggerRule(
      'tool-call-root',
      p.repeat(toolCall, minToolCalls, maxToolCalls),
    );

    p.setRoot(reasoning + p.content(p.until('<tool_call>')) + toolCalls);
    return p.save();
  }

  Set<String> _requiredParameters(Map<String, dynamic> schema) {
    final required = schema['required'];
    if (required is! List) {
      return const <String>{};
    }
    return required.map((item) => item.toString()).toSet();
  }

  Map<String, Map<String, dynamic>> _schemaProperties(
    Map<String, dynamic> schema,
  ) {
    final propertiesRaw = schema['properties'];
    if (propertiesRaw is! Map) {
      return const <String, Map<String, dynamic>>{};
    }
    final result = <String, Map<String, dynamic>>{};
    for (final entry in propertiesRaw.entries) {
      final value = ToolCallParsingUtils.coerceMap(entry.value);
      if (value != null) {
        result[entry.key.toString()] = value;
      }
    }
    return result;
  }

  bool _resolvesToString(Map<String, dynamic> schema) {
    final type = schema['type'];
    if (type is String) {
      return type == 'string';
    }
    if (type is List) {
      return type.length == 1 && type.first == 'string';
    }
    return false;
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

  /// Parses Qwen XML using declared tool schemas when [tools] is supplied.
  ///
  /// As in llama.cpp, the content ends at the first `<tool_call>`, the calls
  /// are those of the valid scopes that follow it, only the first with
  /// [singleToolCall], and the rest of the reply is dropped, so an invalid
  /// call never becomes an executable tool delta. With [thoughtTagsAreText],
  /// all of [output] is content and tool calls. With [bareFirstCall], a
  /// declared tool's `<function=…>` also ends the content and starts the
  /// first call, as `<tool_call>` would.
  @override
  ChatParseResult parseWithTools(
    String output, {
    List<ToolDefinition>? tools,
    bool isPartial = false,
    bool parseToolCalls = true,
    bool thinkingForcedOpen = false,
    bool thoughtTagsAreText = false,
    bool singleToolCall = false,
    bool bareFirstCall = false,
  }) {
    final result = parseXmlToolCalls(
      bareFirstCall && parseToolCalls && tools != null
          ? _withFirstScopeStart(output, tools)
          : output,
      XmlToolCallFormat.qwen3Coder,
      schemas: tools == null ? null : toolSchemas(tools),
      isPartial: isPartial,
      parseToolCalls: parseToolCalls,
      thinkingForcedOpen: thinkingForcedOpen,
      extractsThought: !thoughtTagsAreText,
      // llama.cpp (`7fe450e1`) keeps escapes in Qwen3.5 reasoning, and
      // (`620d2225`) a forced-open thought as generated.
      unescapeReasoning: false,
      verbatimForcedThought: true,
      endsAtLastCall: true,
      maxToolCalls: singleToolCall ? 1 : null,
    );
    return ChatParseResult(
      content: result.content.trim(),
      reasoningContent: result.reasoningContent,
      toolCalls: result.toolCalls,
    );
  }

  /// [output] with `<tool_call>\n` before its first call opening when that is
  /// a declared tool's `<function=…>`.
  static String _withFirstScopeStart(
    String output,
    List<ToolDefinition> tools,
  ) {
    const format = XmlToolCallFormat.qwen3Coder;
    var first = output.indexOf(format.scopeStart);
    var bare = false;
    for (final tool in tools) {
      final index = output.indexOf(format.bareCallOpening(tool.name));
      if (index >= 0 && (first < 0 || index < first)) {
        first = index;
        bare = true;
      }
    }
    return bare
        ? '${output.substring(0, first)}${format.scopeStart}\n'
              '${output.substring(first)}'
        : output;
  }

  @override
  String? buildGrammar(List<ToolDefinition>? tools) {
    return buildXmlToolCallGrammar(tools, XmlToolCallFormat.qwen3Coder);
  }
}
