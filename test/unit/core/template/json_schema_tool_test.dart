import 'dart:convert';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/core/template/handlers/glm45_handler.dart';
import 'package:llamadart/src/core/template/handlers/hunyuan_v3_handler.dart';
import 'package:llamadart/src/core/template/handlers/hermes_handler.dart';
import 'package:llamadart/src/core/template/handlers/llama_cpp_specialized_handlers.dart';
import 'package:llamadart/src/core/template/tool_schema_utils.dart';
import 'package:test/test.dart';

import '../../../support/raw_tool_schema_fixture.dart';

void main() {
  test('Hermes builds nullable and constrained canonical argument grammar', () {
    final grammar = HermesHandler().buildGrammar([rawSchemaTool()])!;
    expect(grammar, contains('null'));
    expect(grammar, contains('code'));
    expect(grammar, isNot(contains('undefined')));
  });

  test('GLM integer rules are defined for legacy and canonical tools', () {
    for (final tool in [
      rawScalarTool(),
      ToolDefinition(
        name: 'legacy',
        description: 'Legacy',
        parameters: [ToolParam.integer('count')],
      ),
    ]) {
      final grammar = Glm45Handler().buildGrammar([tool])!;
      expect(grammar, contains('integer ::='));
    }
  });

  test(
    'schema tools reject response grammars that replace tool constraints',
    () {
      expect(
        () => ChatTemplateEngine.render(
          templateSource: null,
          messages: const [],
          metadata: const {},
          tools: [rawSchemaTool()],
          responseFormat: {
            'type': 'json_schema',
            'json_schema': {
              'schema': {'type': 'object'},
            },
          },
        ),
        throwsA(isA<LlamaUnsupportedException>()),
      );
    },
  );

  test('Hunyuan canonical strings retain JSON-looking raw values', () {
    final tool = ToolDefinition.fromJsonSchema(
      name: 'echo',
      description: 'Echo',
      schema: {
        'type': 'object',
        'properties': {
          'text': {'type': 'string'},
        },
        'required': ['text'],
        'additionalProperties': false,
      },
    );
    for (final value in ['true', 'false', 'null', '123', '"true"']) {
      final output =
          '<tool_calls:opensource><tool_call:opensource>echo<tool_sep:opensource><arg_key:opensource>text</arg_key:opensource><arg_value:opensource>$value</arg_value:opensource></tool_call:opensource></tool_calls:opensource>';
      final parsed = ChatTemplateEngine.parse(
        ChatFormat.hunyuanV3.index,
        output,
        tools: [tool],
      );
      expect(jsonDecode(parsed.toolCalls.single.function!.arguments!), {
        'text': value == '"true"' ? 'true' : value,
      });
    }
  });

  test('schema numeric enums decode as numbers rather than strings', () {
    const schema = {
      'type': 'integer',
      'enum': [1, 2],
    };
    expect(decodeToolSchemaText('2', schema), (valid: true, value: 2));
    expect(decodeToolSchemaText('3', schema).valid, isFalse);
  });

  for (final format in [
    ChatFormat.generic,
    ChatFormat.mistralNemo,
    ChatFormat.hermes,
  ]) {
    test('canonical schema survives final $format parsing', () {
      final tool = rawSchemaTool();
      final args = jsonEncode(rawToolArguments);
      final output = switch (format) {
        ChatFormat.mistralNemo =>
          '[TOOL_CALLS][{"id":"abcdefghi","name":"inspect","arguments":$args}]',
        ChatFormat.hermes =>
          '<tool_call>{"name":"inspect","arguments":$args}</tool_call>',
        _ => '{"tool_call":{"name":"inspect","arguments":$args}}',
      };
      final parsed = ChatTemplateEngine.parse(
        format.index,
        output,
        tools: [tool],
      );
      expect(
        jsonDecode(parsed.toolCalls.single.function!.arguments!),
        rawToolArguments,
      );
      final malformed = output.replaceFirst('"mode":2', '"mode":"2"');
      expect(
        () => ChatTemplateEngine.parse(format.index, malformed, tools: [tool]),
        throwsA(isA<LlamaInferenceException>()),
      );
      expect(
        () => ChatTemplateEngine.parse(
          format.index,
          malformed,
          tools: [tool],
          isPartial: true,
        ),
        returnsNormally,
      );
    });
  }

  test(
    'GLM/Laguna and Hunyuan grammar read properties from the canonical schema',
    () {
      final tool = rawScalarTool();
      expect(tool.parameters, isEmpty);
      for (final handler in <ChatTemplateHandler>[
        Glm45Handler(),
        LagunaHandler(),
        HunyuanV3Handler(),
      ]) {
        final grammar = handler.buildGrammar([tool])!;
        expect(grammar, contains('city'));
        expect(grammar, contains('count'));
        expect(grammar, contains('integer'));
      }
    },
  );

  test(
    'fixed-argument formats reject open objects and richer constraints early',
    () {
      final open = ToolDefinition.fromJsonSchema(
        name: 'open',
        description: 'Open',
        schema: {
          'type': 'object',
          'properties': {
            'x': {'type': 'string'},
          },
        },
      );
      for (final handler in <ChatTemplateHandler>[
        Glm45Handler(),
        LagunaHandler(),
        HunyuanV3Handler(),
      ]) {
        expect(
          () => handler.buildGrammar([open]),
          throwsA(isA<LlamaUnsupportedException>()),
        );
        expect(
          () => handler.buildGrammar([rawSchemaTool()]),
          throwsA(isA<LlamaUnsupportedException>()),
        );
      }
    },
  );

  test(
    'new schema serialization works with auto/required/none and thinking',
    () {
      final tool = rawSchemaTool();
      for (final choice in ToolChoice.values) {
        for (final thinking in [true, false]) {
          final result = ChatTemplateEngine.render(
            templateSource: null,
            messages: [
              LlamaChatMessage.fromText(
                role: LlamaChatRole.user,
                text: 'inspect',
              ),
            ],
            metadata: {},
            tools: [tool],
            toolChoice: choice,
            enableThinking: thinking,
            parallelToolCalls: true,
          );
          if (choice == ToolChoice.none) {
            expect(result.grammar, isNull);
          } else {
            expect(result.prompt, contains('inspect'));
            expect(result.grammar, isNotEmpty);
          }
        }
      }
    },
  );
}
