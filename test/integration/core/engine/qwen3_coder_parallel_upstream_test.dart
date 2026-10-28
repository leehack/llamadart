@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:llamadart/src/core/engine/chat_completion_stream_parser.dart';
import 'package:llamadart/src/core/models/chat/chat_message.dart';
import 'package:llamadart/src/core/models/chat/chat_role.dart';
import 'package:llamadart/src/core/models/chat/chat_template_result.dart';
import 'package:llamadart/src/core/models/tools/tool_definition.dart';
import 'package:llamadart/src/core/models/tools/tool_param.dart';
import 'package:llamadart/src/core/template/chat_format.dart';
import 'package:llamadart/src/core/template/chat_template_engine.dart';
import 'package:llamadart/src/core/template/thinking_utils.dart';
import 'package:test/test.dart';

final Map<String, dynamic> _fixture =
    jsonDecode(
          File(
            'test/fixtures/qwen3_coder_parallel_upstream.json',
          ).readAsStringSync(),
        )
        as Map<String, dynamic>;

final ToolDefinition _tool = ToolDefinition(
  name: 'get_weather',
  description: 'w',
  parameters: [ToolParam.string('location', required: true)],
  handler: (_) async => 'Sunny',
);

String _call(String location) =>
    '<tool_call>\n'
    '<function=get_weather>\n'
    '<parameter=location>\n$location\n</parameter>\n'
    '</function>\n'
    '</tool_call>';

List<String> _calls(Iterable<({String? name, String? arguments})> calls) => [
  for (final call in calls) '${call.name} ${jsonDecode(call.arguments!)}',
];

// With parallel tool calls, llama.cpp parses each call of a Qwen3-Coder XML
// reply in its own `<tool_call>` scope.
void main() {
  for (final entry
      in (_fixture['templates'] as List).cast<Map<String, dynamic>>()) {
    final templatePath = entry['template'] as String;
    final enableThinking = entry['enable_thinking'] as bool;
    group('${templatePath.split('/').last}, thinking $enableThinking', () {
      late LlamaChatTemplateResult rendered;

      setUpAll(
        () => rendered = ChatTemplateEngine.render(
          templateSource: File(templatePath).readAsStringSync(),
          messages: [
            LlamaChatMessage.fromText(
              role: LlamaChatRole.user,
              text: _fixture['user_prompt'] as String,
            ),
          ],
          metadata: const {},
          tools: [_tool],
          parallelToolCalls: true,
          enableThinking: enableThinking,
        ),
      );

      for (final c in (entry['cases'] as List).cast<Map<String, dynamic>>()) {
        final cities = (c['cities'] as List).cast<String>();
        final output =
            '${c['prefix']}'
            '${cities.map(_call).join(c['separator'] as String)}'
            '${c['suffix']}';
        final upstream = c['upstream'] as Map<String, dynamic>;
        final upstreamCalls = [
          for (final city in cities) 'get_weather {location: $city}',
        ];
        test(
          '${cities.length} calls after ${jsonEncode(c['prefix'])}, '
          'separated by ${jsonEncode(c['separator'])}, then '
          '${jsonEncode(c['suffix'])}, parse and stream as llama.cpp parses',
          () async {
            expect(rendered.format, ChatFormat.qwen3CoderXml.index);
            final thinkingForcedClosed =
                !rendered.thinkingForcedOpen &&
                thinkingForcedClosedOf(rendered);
            final parsed = ChatTemplateEngine.parse(
              rendered.format,
              output,
              thinkingForcedOpen: rendered.thinkingForcedOpen,
              thinkingForcedClosed: thinkingForcedClosed,
              tools: [_tool],
            );
            // llamadart trims some whitespace around content and reasoning
            // that llama.cpp keeps.
            expect(
              parsed.content.trim(),
              (upstream['content'] as String).trim(),
            );
            expect(
              (parsed.reasoningContent ?? '').trim(),
              (upstream['reasoning_content'] as String).trim(),
            );
            expect(
              _calls([
                for (final call in parsed.toolCalls)
                  (
                    name: call.function?.name,
                    arguments: call.function?.arguments,
                  ),
              ]),
              upstreamCalls,
            );

            for (final tokens in [
              [output],
              output.split(''),
              [
                for (var i = 0; i < output.length; i += 3)
                  output.substring(
                    i,
                    i + 3 > output.length ? output.length : i + 3,
                  ),
              ],
            ]) {
              final chunks = await ChatCompletionStreamParser.parse(
                tokenStream: Stream.fromIterable(tokens),
                templateResult: rendered,
                parseToolCallsEnabled: true,
                enableThinking: enableThinking,
                modelName: 'test-model',
                completionId: 'qwen3-coder-parallel-upstream',
                tools: [_tool],
              ).toList();
              final deltas = chunks.map((chunk) => chunk.choices.single.delta);
              final reason = '${tokens.length} tokens';
              expect(
                deltas.map((delta) => delta.content ?? '').join().trim(),
                (upstream['content'] as String).trim(),
                reason: reason,
              );
              expect(
                deltas.map((delta) => delta.thinking ?? '').join().trim(),
                (upstream['reasoning_content'] as String).trim(),
                reason: reason,
              );
              expect(
                _calls([
                  for (final delta in deltas)
                    for (final call in delta.toolCalls ?? const [])
                      (
                        name: call.function?.name,
                        arguments: call.function?.arguments,
                      ),
                ]),
                upstreamCalls,
                reason: reason,
              );
            }
          },
        );
      }
    });
  }
}
