@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:llamadart/src/core/models/chat/chat_message.dart';
import 'package:llamadart/src/core/models/chat/chat_role.dart';
import 'package:llamadart/src/core/models/chat/content_part.dart';
import 'package:llamadart/src/core/models/inference/tool_choice.dart';
import 'package:llamadart/src/core/template/chat_template_engine.dart';
import 'package:test/test.dart';

void main() {
  test('exact Qwen3.5 template accepts structured typed tool results', () {
    final source = File(
      'test/fixtures/templates/Qwen3_5-0_8B.jinja',
    ).readAsStringSync();
    final payload = {
      'city': 'Montréal 👋',
      'temperature_celsius': 17,
      'nested': [true, null],
      'escaped': '"quoted"\nline',
    };
    final messages = [
      const LlamaChatMessage.fromText(
        role: LlamaChatRole.user,
        text: 'Call get_weather for Montréal.',
      ),
      const LlamaChatMessage.withContent(
        role: LlamaChatRole.assistant,
        content: [
          LlamaToolCallContent(
            id: 'call_0',
            name: 'get_weather',
            arguments: {'city': 'Montréal'},
            rawJson: '{"city":"Montréal"}',
          ),
        ],
      ),
      LlamaChatMessage.withContent(
        role: LlamaChatRole.tool,
        content: [
          LlamaToolResultContent(
            id: 'call_0',
            name: 'get_weather',
            result: payload,
          ),
        ],
      ),
      const LlamaChatMessage.fromText(
        role: LlamaChatRole.user,
        text: 'What is the temperature_celsius?',
      ),
    ];
    final output = ChatTemplateEngine.render(
      templateSource: source,
      messages: messages,
      metadata: const {},
      toolChoice: ToolChoice.none,
      enableThinking: false,
    );
    expect(
      output.prompt,
      contains('<tool_response>\n${jsonEncode(payload)}\n</tool_response>'),
    );
    expect(output.prompt, contains('<function=get_weather>'));
    expect(output.prompt, contains('Montréal'));
    expect(messages[2].toJson()['content'], same(payload));
    expect(output.prompt, isNot(contains('{city:')));
  });
}
