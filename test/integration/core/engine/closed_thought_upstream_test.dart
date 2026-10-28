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
import 'package:test/test.dart';

final Map<String, dynamic> _fixture =
    jsonDecode(
          File('test/fixtures/closed_thought_upstream.json').readAsStringSync(),
        )
        as Map<String, dynamic>;

final ToolDefinition _weatherTool = ToolDefinition(
  name: 'weather',
  description: 'w',
  parameters: [ToolParam.string('city', required: true)],
  handler: (_) async => 'Sunny',
);

List<String> _calls(Iterable<({String? name, String? arguments})> calls) => [
  for (final call in calls) '${call.name} ${jsonDecode(call.arguments!)}',
];

// With thinking off, these templates end the prompt with an empty thought,
// and llama.cpp then parses the reply as content, thinking tags included.
void main() {
  for (final entry
      in (_fixture['templates'] as List).cast<Map<String, dynamic>>()) {
    final templatePath = entry['template'] as String;
    group(templatePath.split('/').last, () {
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
          tools: [_weatherTool],
          enableThinking: false,
        ),
      );

      test('closes the thought as llama.cpp does', () {
        expect(
          rendered.format,
          ChatFormat.values.byName(entry['format'] as String).index,
        );
        expect(rendered.prompt, endsWith(entry['generation_prompt'] as String));
        expect(rendered.thinkingForcedOpen, isFalse);
      });

      for (final c in (entry['cases'] as List).cast<Map<String, dynamic>>()) {
        final output = c['output'] as String;
        final upstream = c['upstream'] as Map<String, dynamic>;
        test('${c['name']} parses and streams as llama.cpp parses', () async {
          final parsed = ChatTemplateEngine.parse(
            rendered.format,
            output,
            thinkingForcedClosed: true,
            tools: [_weatherTool],
          );
          // llamadart trims some whitespace around content that llama.cpp
          // keeps.
          expect(parsed.content.trim(), (upstream['content'] as String).trim());
          expect(parsed.reasoningContent, isNull);
          final upstreamCalls = _calls([
            for (final call
                in (upstream['tool_calls'] as List)
                    .cast<Map<String, dynamic>>())
              (
                name: call['name'] as String,
                arguments: call['arguments'] as String,
              ),
          ]);
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

          final textParse = ChatTemplateEngine.parse(
            rendered.format,
            output,
            parseToolCalls: false,
            thinkingForcedClosed: true,
          );
          expect(textParse.reasoningContent, isNull);

          for (final withTools in [true, false]) {
            for (final tokens in [
              [output],
              output.split(''),
            ]) {
              final chunks = await ChatCompletionStreamParser.parse(
                tokenStream: Stream.fromIterable(tokens),
                templateResult: rendered,
                parseToolCallsEnabled: withTools,
                enableThinking: false,
                modelName: 'test-model',
                completionId: 'closed-thought-upstream',
                tools: withTools ? [_weatherTool] : null,
              ).toList();
              final deltas = chunks.map((chunk) => chunk.choices.single.delta);
              final reason = '${tokens.length} tokens, tools: $withTools';
              expect(
                deltas.map((delta) => delta.content ?? '').join(),
                withTools ? parsed.content : textParse.content,
                reason: reason,
              );
              expect(
                deltas.map((delta) => delta.thinking ?? '').join(),
                isEmpty,
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
                withTools ? upstreamCalls : isEmpty,
                reason: reason,
              );
            }
          }
        });
      }
    });
  }

  test('other formats and a forced-open thought keep the reasoning', () {
    expect(
      ChatTemplateEngine.parse(
        ChatFormat.deepseekR1.index,
        '<think>Plan</think>Sunny.',
        thinkingForcedClosed: true,
      ).reasoningContent,
      'Plan',
    );
    expect(
      ChatTemplateEngine.parse(
        ChatFormat.hermes.index,
        'Plan</think>Sunny.',
        thinkingForcedOpen: true,
        thinkingForcedClosed: true,
      ).reasoningContent,
      'Plan',
    );
  });

  // llama.cpp still parses a leading thought after a prompt that does not
  // close one, such as Bielik's with thinking off.
  test('a prompt without an empty thought keeps the reasoning', () async {
    for (final prompt in ['<|im_start|>assistant\n', 'x</think>']) {
      final chunks = await ChatCompletionStreamParser.parse(
        tokenStream: Stream.value('<think>Plan</think>Sunny.'),
        templateResult: LlamaChatTemplateResult(
          prompt: prompt,
          format: ChatFormat.hermes.index,
        ),
        parseToolCallsEnabled: false,
        enableThinking: false,
        modelName: 'test-model',
        completionId: 'open-prompt',
      ).toList();
      expect(
        chunks.map((chunk) => chunk.choices.single.delta.content ?? '').join(),
        'Sunny.',
        reason: prompt,
      );
    }
  });
}
