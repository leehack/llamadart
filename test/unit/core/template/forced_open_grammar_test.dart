@TestOn('vm')
library;

import 'dart:io';

import 'package:llamadart/src/core/models/chat/chat_message.dart';
import 'package:llamadart/src/core/models/chat/chat_role.dart';
import 'package:llamadart/src/core/models/chat/chat_template_result.dart';
import 'package:llamadart/src/core/models/chat/content_part.dart';
import 'package:llamadart/src/core/models/inference/tool_choice.dart';
import 'package:llamadart/src/core/models/tools/tool_definition.dart';
import 'package:llamadart/src/core/models/tools/tool_param.dart';
import 'package:llamadart/src/core/template/chat_format.dart';
import 'package:llamadart/src/core/template/chat_template_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const Map<String, dynamic> _schema = {
  'type': 'json_schema',
  'json_schema': {
    'schema': {
      'type': 'object',
      'properties': {
        'answer': {'type': 'integer'},
      },
      'required': ['answer'],
    },
  },
};

final ToolDefinition _tool = ToolDefinition(
  name: 'get_weather',
  description: 'Weather',
  parameters: [ToolParam.string('location', required: true)],
);

// A grammar applies from the first token, so after a forced-open thought it
// must take the rest of the thought and its end tag first, or the response
// format or tool call is parsed as reasoning.
void main() {
  final templates = [
    for (final dir in const [
      'test/fixtures/llama_cpp_templates',
      'test/fixtures/media_templates',
      'test/fixtures/templates',
    ])
      ...Directory(dir).listSync().whereType<File>().where(
        (file) => file.path.endsWith('.jinja'),
      ),
  ]..sort((a, b) => a.path.compareTo(b.path));

  final requests =
      <
        ({
          String name,
          bool schema,
          List<ToolDefinition>? tools,
          ToolChoice choice,
        })
      >[
        (name: 'schema', schema: true, tools: null, choice: ToolChoice.auto),
        (name: 'tools', schema: false, tools: [_tool], choice: ToolChoice.auto),
        (
          name: 'required tools',
          schema: false,
          tools: [_tool],
          choice: ToolChoice.required,
        ),
        (
          name: 'schema and tools',
          schema: true,
          tools: [_tool],
          choice: ToolChoice.auto,
        ),
      ];

  test('an eager grammar after a forced-open thought takes the thought first, '
      'and a response format after it parses as content', () {
    var forcedOpenEager = 0;
    final failures = <String>[];
    for (final file in templates) {
      final source = file.readAsStringSync();
      for (final request in requests) {
        for (final enableThinking in [true, false]) {
          for (final media in [false, true]) {
            final LlamaChatTemplateResult result;
            try {
              result = ChatTemplateEngine.render(
                templateSource: source,
                messages: [
                  LlamaChatMessage.withContent(
                    role: LlamaChatRole.user,
                    content: [
                      if (media) const LlamaImageContent(path: '/tmp/a.png'),
                      const LlamaTextContent('What is 2+2?'),
                    ],
                  ),
                ],
                metadata: const {},
                tools: request.tools,
                toolChoice: request.choice,
                enableThinking: enableThinking,
                responseFormat: request.schema ? _schema : null,
              );
            } on Exception {
              continue;
            }
            final grammar = result.grammar;
            if (!result.thinkingForcedOpen ||
                grammar == null ||
                result.grammarLazy) {
              continue;
            }
            forcedOpenEager++;
            final label =
                '${p.basename(file.path)} ${request.name} '
                'thinking: $enableThinking media: $media';
            final root = grammar
                .split('\n')
                .firstWhere((line) => line.startsWith('root ::= '));
            if (!root.startsWith('root ::= think-body ')) {
              failures.add('$label: grammar forbids the thought');
              continue;
            }
            if ('think-body '.allMatches(root).length != 1) {
              failures.add('$label: thought taken twice');
            }
            if (request.schema && request.tools == null) {
              final endTag = ChatTemplateEngine.handlerFor(
                ChatFormat.values[result.format],
              ).thinkingEndTag;
              final parsed = ChatTemplateEngine.parse(
                result.format,
                'plan$endTag{"answer": 4}',
                thinkingForcedOpen: true,
                parser: result.parser,
              );
              if (parsed.content.trim() != '{"answer": 4}') {
                failures.add('$label: content ${parsed.content}');
              }
            }
          }
        }
      }
    }

    expect(failures, isEmpty);
    expect(forcedOpenEager, greaterThan(0));
  });
}
