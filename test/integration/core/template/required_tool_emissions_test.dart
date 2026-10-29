@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:llamadart/src/core/models/chat/chat_message.dart';
import 'package:llamadart/src/core/models/chat/chat_role.dart';
import 'package:llamadart/src/core/models/inference/tool_choice.dart';
import 'package:llamadart/src/core/models/tools/tool_definition.dart';
import 'package:llamadart/src/core/models/tools/tool_param.dart';
import 'package:llamadart/src/core/template/chat_format.dart';
import 'package:llamadart/src/core/template/chat_template_engine.dart';
import 'package:test/test.dart';

const _fixturePath =
    'test/fixtures/required_tool_emissions/required_tool_emissions.json';

void main() {
  final fixture =
      jsonDecode(File(_fixturePath).readAsStringSync()) as Map<String, dynamic>;
  final messages = [
    for (final message in fixture['messages'] as List<dynamic>)
      LlamaChatMessage.fromText(
        role: LlamaChatRole.values.byName(
          (message as Map<String, dynamic>)['role'] as String,
        ),
        text: message['content'] as String,
      ),
  ];
  final tool = ToolDefinition(
    name: 'get_weather',
    description: 'Returns current weather for a city.',
    parameters: [ToolParam.string('location', description: 'City name')],
    handler: (_) async => null,
  );

  for (final raw in fixture['cases'] as List<dynamic>) {
    final fixtureCase = raw as Map<String, dynamic>;
    group(fixtureCase['name'], () {
      final templateBytes = File(
        fixtureCase['template'] as String,
      ).readAsBytesSync();
      final rendered = ChatTemplateEngine.render(
        templateSource: utf8.decode(templateBytes),
        messages: messages,
        metadata: const {},
        tools: [tool],
        toolChoice: ToolChoice.required,
        enableThinking: false,
      );

      test('renders the recorded prompt with a non-lazy grammar', () {
        expect(
          sha256.convert(templateBytes).toString(),
          fixtureCase['template_sha256'],
        );
        expect(
          rendered.format,
          ChatFormat.values.byName(fixtureCase['format'] as String).index,
        );
        expect(rendered.prompt, fixtureCase['prompt']);
        expect(rendered.grammar, isNotNull);
        expect(rendered.grammarLazy, isFalse);
      });

      test('parses the grammar-constrained emission as one call', () {
        final parsed = ChatTemplateEngine.parse(
          rendered.format,
          fixtureCase['emission'] as String,
          thinkingForcedOpen: rendered.thinkingForcedOpen,
          tools: [tool],
        );
        final expected = fixtureCase['tool_call'] as Map<String, dynamic>;
        expect(parsed.content, isEmpty);
        expect(parsed.toolCalls, hasLength(1));
        expect(parsed.toolCalls.single.function?.name, expected['name']);
        expect(
          jsonDecode(parsed.toolCalls.single.function!.arguments!),
          expected['arguments'],
        );
      });
    });
  }
}
