@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:llamadart/src/core/models/chat/chat_message.dart';
import 'package:llamadart/src/core/models/chat/chat_role.dart';
import 'package:llamadart/src/core/models/chat/content_part.dart';
import 'package:llamadart/src/core/models/tools/tool_definition.dart';
import 'package:llamadart/src/core/models/tools/tool_param.dart';
import 'package:llamadart/src/core/template/chat_template_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final Map<String, dynamic> _fixture =
    jsonDecode(
          File('test/fixtures/bos_eos_render_upstream.json').readAsStringSync(),
        )
        as Map<String, dynamic>;

final ToolDefinition _weatherTool = ToolDefinition(
  name: 'get_weather',
  description: 'Get the current weather for a city.',
  parameters: [ToolParam.string('location', required: true)],
);

LlamaChatMessage _message(Map<String, dynamic> message) {
  final role = LlamaChatRole.values.byName(message['role'] as String);
  if (message['tool_calls'] case final List calls) {
    return LlamaChatMessage.withContent(
      role: role,
      content: [
        for (final call in calls.cast<Map<String, dynamic>>())
          LlamaToolCallContent(
            id: call['id'] as String,
            name: (call['function'] as Map)['name'] as String,
            arguments:
                jsonDecode((call['function'] as Map)['arguments'] as String)
                    as Map<String, dynamic>,
            rawJson: (call['function'] as Map)['arguments'] as String,
          ),
      ],
    );
  }
  if (role == LlamaChatRole.tool) {
    return LlamaChatMessage.withContent(
      role: role,
      content: [
        LlamaToolResultContent(
          id: message['tool_call_id'] as String,
          name: message['name'] as String,
          result: message['content'],
        ),
      ],
    );
  }
  return LlamaChatMessage.fromText(
    role: role,
    text: message['content'] as String,
  );
}

void main() {
  test('sends llama-server the tool the cases render', () {
    expect(_fixture['tools'], [_weatherTool.toJson()]);
  });

  final scenarios = _fixture['scenarios'] as Map<String, dynamic>;
  for (final entry
      in (_fixture['cases'] as List).cast<Map<String, dynamic>>()) {
    final template = entry['template'] as String;
    final scenario =
        scenarios[entry['scenario'] as String] as Map<String, dynamic>;

    test('${p.basename(template)} ${entry['scenario']} places BOS and EOS '
        'as llama-server does', () {
      final source = File(template).readAsStringSync();
      expect(
        sha256.convert(utf8.encode(source)).toString(),
        entry['template_sha256'],
      );

      final result = ChatTemplateEngine.render(
        templateSource: source,
        messages: [
          for (final message
              in (scenario['messages'] as List).cast<Map<String, dynamic>>())
            _message(message),
        ],
        metadata: {
          'tokenizer.ggml.bos_token': _fixture['bos_token'] as String,
          'tokenizer.ggml.eos_token': _fixture['eos_token'] as String,
        },
        tools: scenario['tools'] as bool ? [_weatherTool] : null,
      );

      expect(result.prompt, entry['prompt']);
    });
  }
}
