@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:llamadart/src/core/models/tools/tool_definition.dart';
import 'package:llamadart/src/core/models/tools/tool_param.dart';
import 'package:llamadart/src/core/template/handlers/lfm2_handler.dart';
import 'package:test/test.dart';

void main() {
  final fixture =
      jsonDecode(
            File(
              'test/fixtures/lfm2_quoted_tool_delimiter_compat.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  final weather = ToolDefinition(
    name: 'weather',
    description: 'Weather',
    parameters: [ToolParam.string('city')],
  );
  final cases = fixture['cases'] as List;
  for (var i = 0; i < cases.length; i++) {
    final input = (cases[i] as Map)['input'] as String;
    test('schema dispatch preserves delimiter compatibility case $i', () {
      final baseline = Lfm2Handler().parse(input);
      final candidate = Lfm2Handler().parseWithTools(input, tools: [weather]);
      expect(candidate.content, baseline.content);
      expect(candidate.reasoningContent, baseline.reasoningContent);
      expect(
        [
          for (final call in candidate.toolCalls)
            [call.function?.name, call.function?.arguments],
        ],
        [
          for (final call in baseline.toolCalls)
            [call.function?.name, call.function?.arguments],
        ],
      );
    });
  }

  Map<String, dynamic> arguments(String payload, ToolDefinition tool) {
    final parsed = Lfm2Handler().parseWithTools(
      '<|tool_call_start|>[$payload]<|tool_call_end|>',
      tools: [tool],
    );
    return jsonDecode(parsed.toolCalls.single.function!.arguments!)
        as Map<String, dynamic>;
  }

  test('raw schema retains explicitly allowed additional properties', () {
    expect(
      arguments(
        'f(extra=True)',
        ToolDefinition.fromJsonSchema(
          name: 'f',
          description: 'Test',
          schema: {'type': 'object', 'properties': <String, dynamic>{}},
        ),
      ),
      {'extra': true},
    );
  });

  test('raw schema preserves string values in type alternatives', () {
    expect(
      arguments(
        'f(value=False)',
        ToolDefinition.fromJsonSchema(
          name: 'f',
          description: 'Test',
          schema: {
            'type': 'object',
            'properties': {
              'value': {
                'type': ['string', 'null'],
              },
            },
          },
        ),
      ),
      {'value': 'False'},
    );
  });

  test('open schemas retain non-map additional wrapper-named values', () {
    expect(
      arguments(
        'f(input="text")',
        ToolDefinition.fromJsonSchema(
          name: 'f',
          description: 'Test',
          schema: {'type': 'object', 'properties': <String, dynamic>{}},
        ),
      ),
      {'input': 'text'},
    );
  });

  test('nested JSON object strings preserve baseline escape decoding', () {
    const output =
        r'<|tool_call_start|>[f(config={"text":"line\nnext"})]<|tool_call_end|>';
    final tool = ToolDefinition(
      name: 'f',
      description: 'Test',
      parameters: [
        ToolParam.object('config', properties: [ToolParam.string('text')]),
      ],
    );
    final baseline = Lfm2Handler().parse(output);
    final candidate = Lfm2Handler().parseWithTools(output, tools: [tool]);
    // The schema repairs the lost config key, while the pre-existing JSON
    // string decoding within the object must remain the same.
    final oldValue =
        jsonDecode(baseline.toolCalls.single.function!.arguments!) as Map;
    final newValue =
        jsonDecode(candidate.toolCalls.single.function!.arguments!) as Map;
    expect((newValue['config'] as Map)['text'], oldValue['text']);
  });
}
