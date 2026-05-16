import 'dart:convert';

import 'package:llamadart/src/core/models/chat/chat_message.dart';
import 'package:llamadart/src/core/models/chat/chat_role.dart';
import 'package:llamadart/src/core/models/inference/tool_choice.dart';
import 'package:llamadart/src/core/models/tools/tool_definition.dart';
import 'package:llamadart/src/core/models/tools/tool_param.dart';
import 'package:llamadart/src/core/template/chat_format.dart';
import 'package:llamadart/src/core/template/chat_template_engine.dart';
import 'package:test/test.dart';

void main() {
  const baseTemplate = '{{ "BASE:" ~ messages[0]["content"] }}';
  const customTemplate = '{{ "CUSTOM:" ~ messages[0]["content"] }}';

  final messages = [const LlamaChatMessage(role: 'user', content: 'hello')];

  group('ChatTemplateEngine template routing', () {
    test('supports per-call custom template override', () {
      final result = ChatTemplateEngine.render(
        templateSource: baseTemplate,
        messages: messages,
        metadata: const {},
        customTemplate: customTemplate,
      );

      expect(result.prompt, contains('CUSTOM:hello'));
      expect(result.prompt, isNot(contains('BASE:hello')));
    });
  });

  group('ChatTemplateEngine grammar routing', () {
    final tools = [
      ToolDefinition(
        name: 'get_weather',
        description: 'Get weather',
        parameters: [ToolParam.string('city')],
        handler: _noopHandler,
      ),
    ];

    const grammarMessages = [
      LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'hello'),
    ];

    test('applies generic tool grammar for generic templates', () {
      const template =
          '<|im_start|>user\n{{ messages[0]["content"] }}<|im_end|>\n<|im_start|>assistant\n';

      final result = ChatTemplateEngine.render(
        templateSource: template,
        messages: grammarMessages,
        metadata: const {},
        tools: tools,
      );

      expect(result.format, equals(ChatFormat.generic.index));
      expect(result.grammar, isNotNull);
      expect(result.grammarLazy, isFalse);
    });

    test('uses format-native grammar for format-specific handlers', () {
      const template = '>>>all\n{{ messages[0]["content"] }}';

      final result = ChatTemplateEngine.render(
        templateSource: template,
        messages: grammarMessages,
        metadata: const {},
        tools: tools,
      );

      expect(result.format, equals(ChatFormat.functionaryV32.index));
      expect(result.grammar, isNotNull);
      expect(result.grammar!, contains('tool-0-call'));
    });

    test('uses generic routing for tools + schema requests', () {
      const template =
          '<|END_THINKING|><|START_ACTION|>{{ messages[0]["content"] }}';

      final result = ChatTemplateEngine.render(
        templateSource: template,
        messages: grammarMessages,
        metadata: const {},
        tools: tools,
        responseFormat: const {
          'type': 'json_schema',
          'json_schema': {
            'schema': {
              'type': 'object',
              'properties': {
                'ok': {'type': 'boolean'},
              },
              'required': ['ok'],
            },
          },
        },
      );

      expect(result.format, equals(ChatFormat.generic.index));
    });

    test('uses content-only routing for schema-disabled formats', () {
      const template = '<tool_call>{{ messages[0]["content"] }}</tool_call>';

      final result = ChatTemplateEngine.render(
        templateSource: template,
        messages: grammarMessages,
        metadata: const {},
        responseFormat: const {'type': 'json_object'},
      );

      expect(result.format, equals(ChatFormat.contentOnly.index));
    });

    test('disables lazy grammar for required tool choice when needed', () {
      const template =
          '<tool_call>\n<function=\n<function>\n<parameters>\n<parameter=\n{{ messages[0]["content"] }}';

      final result = ChatTemplateEngine.render(
        templateSource: template,
        messages: grammarMessages,
        metadata: const {},
        tools: tools,
        toolChoice: ToolChoice.required,
      );

      expect(result.format, equals(ChatFormat.qwen3CoderXml.index));
      expect(result.grammar, isNotNull);
      expect(result.grammarLazy, isFalse);
    });

    test('routes LFM2 tool requests to generic tool grammar', () {
      const template =
          '{%- set keep_past_thinking = true -%}\n'
          '<|im_start|>user\n{{ messages[0]["content"] }}<|im_end|>';

      final result = ChatTemplateEngine.render(
        templateSource: template,
        messages: grammarMessages,
        metadata: const {},
        tools: tools,
        toolChoice: ToolChoice.required,
      );

      expect(result.format, equals(ChatFormat.generic.index));
      expect(result.grammar, isNotNull);
      expect(result.grammarLazy, isFalse);
    });

    test('keeps strict LFM2 marker templates on LFM2 handler', () {
      const template =
          'List of tools: <|tool_list_start|>[{"name":"x"}]<|tool_list_end|>'
          '<|im_start|>user\n{{ messages[0]["content"] }}<|im_end|>';

      final result = ChatTemplateEngine.render(
        templateSource: template,
        messages: grammarMessages,
        metadata: const {},
        tools: tools,
        toolChoice: ToolChoice.required,
      );

      expect(result.format, equals(ChatFormat.lfm2.index));
      expect(result.grammar, isNull);
    });

    test('keeps lazy grammar for strict LFM2 force-json-schema mode', () {
      const template =
          'List of tools: <|tool_list_start|>[{"name":"x"}]<|tool_list_end|>'
          '{% if messages[0]["role"] == "system" %}'
          '<|im_start|>system\n{{ messages[0]["content"] }}<|im_end|>'
          '{% endif %}'
          '<|im_start|>user\n{{ messages[1]["content"] }}<|im_end|>';

      final result = ChatTemplateEngine.render(
        templateSource: template,
        messages: const [
          LlamaChatMessage.fromText(
            role: LlamaChatRole.system,
            text: 'Force JSON schema.\nSystem prompt',
          ),
          LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'ping'),
        ],
        metadata: const {},
        tools: tools,
        toolChoice: ToolChoice.required,
      );

      expect(result.format, equals(ChatFormat.lfm2.index));
      expect(result.grammar, isNotNull);
      expect(result.grammarLazy, isTrue);
    });

    test('routes Gemma tool requests to generic tool grammar', () {
      const template =
          '{%- if messages -%}<start_of_turn>user\n'
          '{{ messages[0]["content"] }}<end_of_turn>\n'
          '<start_of_turn>model\n{%- endif -%}';

      final result = ChatTemplateEngine.render(
        templateSource: template,
        messages: grammarMessages,
        metadata: const {},
        tools: tools,
        toolChoice: ToolChoice.auto,
      );

      expect(result.format, equals(ChatFormat.generic.index));
      expect(result.grammar, isNotNull);
      expect(result.grammarLazy, isFalse);
      expect(result.additionalStops, contains('<end_of_turn>'));
      expect(result.additionalStops, isNot(contains('<|im_end|>')));
    });

    test('routes Gemma no-tool requests to content-only', () {
      const template =
          '{%- if messages -%}<start_of_turn>user\n'
          '{{ messages[0]["content"] }}<end_of_turn>\n'
          '<start_of_turn>model\n{%- endif -%}';

      final result = ChatTemplateEngine.render(
        templateSource: template,
        messages: grammarMessages,
        metadata: const {},
        tools: const [],
      );

      expect(result.format, equals(ChatFormat.contentOnly.index));
    });

    test('routes Gemma tool_choice none requests to content-only', () {
      const template =
          '{%- if messages -%}<start_of_turn>user\n'
          '{{ messages[0]["content"] }}<end_of_turn>\n'
          '<start_of_turn>model\n{%- endif -%}';

      final result = ChatTemplateEngine.render(
        templateSource: template,
        messages: grammarMessages,
        metadata: const {},
        tools: tools,
        toolChoice: ToolChoice.none,
      );

      expect(result.format, equals(ChatFormat.contentOnly.index));
      expect(result.grammar, isNull);
      expect(result.prompt, isNot(contains('Respond in JSON format')));
    });

    test('routes FunctionGemma-like templates to the FunctionGemma handler', () {
      const template =
          '<start_of_turn>user\n{{ messages[0]["content"] }}<end_of_turn>\n'
          '<start_of_turn>model\n'
          '<start_function_call>call:get_weather{location:<escape>Seoul<escape>}'
          '<end_function_call>';

      final result = ChatTemplateEngine.render(
        templateSource: template,
        messages: grammarMessages,
        metadata: const {},
      );
      expect(result.format, equals(ChatFormat.functionGemma.index));
      expect(result.grammar, isNull);
    });

    test('routes Gemma 4 templates to the Gemma 4 handler', () {
      const template =
          '<|turn>user\n{{ messages[0]["content"] }}<turn|>\n'
          '<|turn>model\n'
          '{% if tools %}<|tool_call>call:get_weather{location:<|"|>Seoul<|"|>}<tool_call|>{% endif %}';

      final result = ChatTemplateEngine.render(
        templateSource: template,
        messages: grammarMessages,
        metadata: const {},
        tools: tools,
      );

      expect(result.format, equals(ChatFormat.gemma4.index));
      expect(result.grammar, isNull);
      expect(result.additionalStops, contains('<tool_call|>'));
      expect(result.additionalStops, contains('<turn|>'));
    });

    test('routes generic templates to content-only for tool_choice none', () {
      const template =
          '<|im_start|>user\n{{ messages[0]["content"] }}<|im_end|>\n'
          '<|im_start|>assistant\n';

      final result = ChatTemplateEngine.render(
        templateSource: template,
        messages: grammarMessages,
        metadata: const {},
        tools: tools,
        toolChoice: ToolChoice.none,
      );

      expect(result.format, equals(ChatFormat.contentOnly.index));
      expect(result.grammar, isNull);
      expect(result.prompt, isNot(contains('Respond in JSON format')));
    });

    test(
      'routes Mistral Nemo templates to content-only for tool_choice none',
      () {
        const template = '[TOOL_CALLS]{{ messages[0]["content"] }}';

        final result = ChatTemplateEngine.render(
          templateSource: template,
          messages: grammarMessages,
          metadata: const {},
          tools: tools,
          toolChoice: ToolChoice.none,
        );

        expect(result.format, equals(ChatFormat.contentOnly.index));
        expect(result.grammar, isNull);
      },
    );

    test('routes Ministral templates to Ministral handler', () {
      const template =
          '[SYSTEM_PROMPT]x[/SYSTEM_PROMPT]'
          '[TOOL_CALLS]get_weather[ARGS]{}';

      final result = ChatTemplateEngine.render(
        templateSource: template,
        messages: grammarMessages,
        metadata: const {},
        tools: tools,
        toolChoice: ToolChoice.auto,
      );

      expect(result.format, equals(ChatFormat.ministral.index));
      expect(result.grammar, isNotNull);
      expect(result.grammarLazy, isTrue);
      expect(result.parser, isNotNull);
      expect(result.parser, isNotEmpty);
    });

    test('parses Ministral output through PEG parser payload', () {
      const template =
          '[SYSTEM_PROMPT]x[/SYSTEM_PROMPT]'
          '[TOOL_CALLS]get_weather[ARGS]{}';

      final result = ChatTemplateEngine.render(
        templateSource: template,
        messages: grammarMessages,
        metadata: const {},
        tools: tools,
        toolChoice: ToolChoice.auto,
      );

      final parsed = ChatTemplateEngine.parse(
        result.format,
        '[THINK]t[/THINK]'
        '[TOOL_CALLS]get_weather[ARGS]{"location":"Seoul"}',
        parser: result.parser,
      );

      expect(parsed.reasoningContent, equals('t'));
      expect(parsed.content, isEmpty);
      expect(parsed.toolCalls, hasLength(1));
      expect(parsed.toolCalls.first.function?.name, equals('get_weather'));
      expect(
        parsed.toolCalls.first.function?.arguments,
        equals('{"location":"Seoul"}'),
      );
    });

    test('Ministral tool_choice none keeps parser in content mode', () {
      const template =
          '[SYSTEM_PROMPT]x[/SYSTEM_PROMPT]'
          '[TOOL_CALLS]get_weather[ARGS]{}';

      final result = ChatTemplateEngine.render(
        templateSource: template,
        messages: grammarMessages,
        metadata: const {},
        tools: tools,
        toolChoice: ToolChoice.none,
      );

      final parsed = ChatTemplateEngine.parse(
        result.format,
        '[TOOL_CALLS]get_weather[ARGS]{"location":"Seoul"}',
        parser: result.parser,
      );

      expect(parsed.toolCalls, isEmpty);
      expect(parsed.content, contains('[TOOL_CALLS]'));
      expect(parsed.content, contains('get_weather[ARGS]'));
    });

    test('Ministral parser respects required/parallel bounds', () {
      const template =
          '[SYSTEM_PROMPT]x[/SYSTEM_PROMPT]'
          '[TOOL_CALLS]get_weather[ARGS]{}';
      const templateParallel =
          '[SYSTEM_PROMPT]x[/SYSTEM_PROMPT]'
          '[TOOL_CALLS]get_weather[ARGS]{}'
          '{% if tools %}{% for tool in tools %}{{ tool["function"]["name"] }}{% endfor %}{% endif %}';

      int maxCallsFromParser(String parser) {
        final decoded = jsonDecode(parser) as Map<String, dynamic>;
        final parsers = (decoded['parsers'] as List<dynamic>)
            .cast<Map<String, dynamic>>();
        final toolCallRoot = parsers.firstWhere(
          (node) => node['type'] == 'rule' && node['name'] == 'tool-call',
        );
        final repetition = parsers[(toolCallRoot['child'] as num).toInt()];
        return (repetition['max_count'] as num).toInt();
      }

      int minCallsFromParser(String parser) {
        final decoded = jsonDecode(parser) as Map<String, dynamic>;
        final parsers = (decoded['parsers'] as List<dynamic>)
            .cast<Map<String, dynamic>>();
        final toolCallRoot = parsers.firstWhere(
          (node) => node['type'] == 'rule' && node['name'] == 'tool-call',
        );
        final repetition = parsers[(toolCallRoot['child'] as num).toInt()];
        return (repetition['min_count'] as num).toInt();
      }

      final autoSingle = ChatTemplateEngine.render(
        templateSource: template,
        messages: grammarMessages,
        metadata: const {},
        tools: tools,
        toolChoice: ToolChoice.auto,
      );
      expect(minCallsFromParser(autoSingle.parser!), equals(0));
      expect(maxCallsFromParser(autoSingle.parser!), equals(1));

      final autoParallel = ChatTemplateEngine.render(
        templateSource: templateParallel,
        messages: grammarMessages,
        metadata: const {},
        tools: tools,
        toolChoice: ToolChoice.auto,
        parallelToolCalls: true,
      );
      expect(minCallsFromParser(autoParallel.parser!), equals(0));
      // Parallel stays disabled unless template capability detection
      // confirms tool-call list emission support.
      expect(maxCallsFromParser(autoParallel.parser!), equals(1));

      final requiredSingle = ChatTemplateEngine.render(
        templateSource: template,
        messages: grammarMessages,
        metadata: const {},
        tools: tools,
        toolChoice: ToolChoice.required,
      );
      expect(minCallsFromParser(requiredSingle.parser!), equals(1));
      expect(maxCallsFromParser(requiredSingle.parser!), equals(1));
    });

    test('routes Nemotron v3 templates to PEG-constructed parser path', () {
      const template =
          '<tool_call><function><function=get_weather><parameters>'
          '<parameter=city><think>';

      final result = ChatTemplateEngine.render(
        templateSource: template,
        messages: grammarMessages,
        metadata: const {},
        tools: tools,
        toolChoice: ToolChoice.auto,
      );

      expect(result.format, equals(ChatFormat.pegConstructed.index));
      expect(result.parser, isNotNull);
      expect(result.parser, isNotEmpty);
      expect(result.grammarTriggers, hasLength(1));
      expect(result.grammarTriggers.first.value, equals('<tool_call>'));

      final parsed = ChatTemplateEngine.parse(
        result.format,
        'I am thinking\n'
        '</think>\n'
        '<tool_call>\n'
        '<function=get_weather>\n'
        '<parameter=city>\n'
        'Seoul\n'
        '</parameter>\n'
        '</function>\n'
        '</tool_call>',
        parser: result.parser,
        thinkingForcedOpen: result.thinkingForcedOpen,
      );

      expect(parsed.reasoningContent, equals('I am thinking'));
      expect(parsed.toolCalls, hasLength(1));
      expect(parsed.toolCalls.first.function?.name, equals('get_weather'));
      expect(
        parsed.toolCalls.first.function?.arguments,
        equals('{"city":"Seoul"}'),
      );
    });

    test('Nemotron v3 tool_choice none uses content-only parser behavior', () {
      const template =
          '<tool_call><function><function=get_weather><parameters>'
          '<parameter=city><think>';

      final result = ChatTemplateEngine.render(
        templateSource: template,
        messages: grammarMessages,
        metadata: const {},
        tools: tools,
        toolChoice: ToolChoice.none,
      );

      expect(result.format, equals(ChatFormat.pegConstructed.index));
      expect(result.parser, isNotNull);
      expect(result.parser, isNotEmpty);
      expect(result.grammar, isNull);
      expect(result.grammarLazy, isFalse);
      expect(result.grammarTriggers, isEmpty);

      final parsed = ChatTemplateEngine.parse(
        result.format,
        'I am thinking\n'
        '</think>\n'
        '<tool_call>\n'
        '<function=get_weather>\n'
        '<parameter=city>\n'
        'Seoul\n'
        '</parameter>\n'
        '</function>\n'
        '</tool_call>',
        parser: result.parser,
        thinkingForcedOpen: result.thinkingForcedOpen,
      );

      expect(parsed.reasoningContent, equals('I am thinking'));
      expect(parsed.toolCalls, isEmpty);
      expect(parsed.content, contains('<tool_call>'));
      expect(parsed.content, contains('<function=get_weather>'));
    });

    test('Nemotron v3 parser respects required/parallel tool call bounds', () {
      const template =
          '<tool_call><function><function=get_weather><parameters>'
          '<parameter=city><think>';
      const templateParallel =
          '<tool_call><function><function=get_weather><parameters>'
          '<parameter=city><think>'
          '{% if tools %}{% for tool in tools %}'
          '{{ tool["function"]["name"] }}'
          '{% endfor %}{% endif %}';

      int maxCallsFromParser(String parser) {
        final decoded = jsonDecode(parser) as Map<String, dynamic>;
        final parsers = (decoded['parsers'] as List<dynamic>)
            .cast<Map<String, dynamic>>();
        final toolCallRoot = parsers.firstWhere(
          (node) => node['type'] == 'rule' && node['name'] == 'tool-call-root',
        );
        final repetition = parsers[(toolCallRoot['child'] as num).toInt()];
        return (repetition['max_count'] as num).toInt();
      }

      int minCallsFromParser(String parser) {
        final decoded = jsonDecode(parser) as Map<String, dynamic>;
        final parsers = (decoded['parsers'] as List<dynamic>)
            .cast<Map<String, dynamic>>();
        final toolCallRoot = parsers.firstWhere(
          (node) => node['type'] == 'rule' && node['name'] == 'tool-call-root',
        );
        final repetition = parsers[(toolCallRoot['child'] as num).toInt()];
        return (repetition['min_count'] as num).toInt();
      }

      final autoSingle = ChatTemplateEngine.render(
        templateSource: template,
        messages: grammarMessages,
        metadata: const {},
        tools: tools,
        toolChoice: ToolChoice.auto,
      );
      expect(minCallsFromParser(autoSingle.parser!), equals(0));
      expect(maxCallsFromParser(autoSingle.parser!), equals(1));

      final autoParallel = ChatTemplateEngine.render(
        templateSource: templateParallel,
        messages: grammarMessages,
        metadata: const {},
        tools: tools,
        toolChoice: ToolChoice.auto,
        parallelToolCalls: true,
      );
      expect(minCallsFromParser(autoParallel.parser!), equals(0));
      // Parallel stays disabled unless template capability detection
      // confirms tool-call list emission support.
      expect(maxCallsFromParser(autoParallel.parser!), equals(1));

      final requiredSingle = ChatTemplateEngine.render(
        templateSource: template,
        messages: grammarMessages,
        metadata: const {},
        tools: tools,
        toolChoice: ToolChoice.required,
      );
      expect(minCallsFromParser(requiredSingle.parser!), equals(1));
      expect(maxCallsFromParser(requiredSingle.parser!), equals(1));
    });

    test('keeps Ministral handler but strips grammar for tool_choice none', () {
      const template =
          '[SYSTEM_PROMPT]x[/SYSTEM_PROMPT]'
          '[TOOL_CALLS]get_weather[ARGS]{}';

      final result = ChatTemplateEngine.render(
        templateSource: template,
        messages: grammarMessages,
        metadata: const {},
        tools: tools,
        toolChoice: ToolChoice.none,
      );

      expect(result.format, equals(ChatFormat.ministral.index));
      expect(result.grammar, isNull);
      expect(result.grammarLazy, isFalse);
      expect(result.grammarTriggers, isEmpty);
      expect(result.preservedTokens, contains('[TOOL_CALLS]'));
      expect(result.preservedTokens, contains('[ARGS]'));
    });

    test('keeps generic routing for LFM2 required tool choice', () {
      const template =
          '{%- set keep_past_thinking = true -%}\n'
          '<|im_start|>system\n{{ messages[0]["content"] }}<|im_end|>'
          '<|im_start|>user\n{{ messages[1]["content"] }}<|im_end|>';

      final result = ChatTemplateEngine.render(
        templateSource: template,
        messages: const [
          LlamaChatMessage.fromText(
            role: LlamaChatRole.system,
            text: 'force json schema.\nSystem prompt',
          ),
          LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'ping'),
        ],
        metadata: const {},
        tools: tools,
        toolChoice: ToolChoice.required,
      );

      expect(result.format, equals(ChatFormat.generic.index));
      expect(result.grammar, isNotNull);
      expect(result.grammarLazy, isFalse);
    });

    test('keeps lazy grammar for formats that always use lazy mode', () {
      const template =
          '<|system_start|>{{ messages[0]["content"] }}<|system_end|><|tools_prefix|>';

      final result = ChatTemplateEngine.render(
        templateSource: template,
        messages: grammarMessages,
        metadata: const {},
        tools: tools,
        toolChoice: ToolChoice.required,
      );

      expect(result.format, equals(ChatFormat.apertus.index));
      expect(result.grammar, isNotNull);
      expect(result.grammarLazy, isTrue);
    });

    test('routes unknown templates with tools to generic handler', () {
      const template = '{{ messages[0]["content"] }}';

      final result = ChatTemplateEngine.render(
        templateSource: template,
        messages: grammarMessages,
        metadata: const {},
        tools: tools,
        toolChoice: ToolChoice.required,
      );

      expect(result.format, equals(ChatFormat.generic.index));
      expect(result.grammar, isNotNull);
    });
  });
}

Future<Object?> _noopHandler(_) async {
  return 'ok';
}
