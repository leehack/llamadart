@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:llamadart/src/core/engine/chat_completion_stream_parser.dart';
import 'package:llamadart/src/core/engine/chat_template_renderer.dart';
import 'package:llamadart/src/core/models/chat/chat_message.dart';
import 'package:llamadart/src/core/models/chat/chat_role.dart';
import 'package:llamadart/src/core/models/chat/chat_template_result.dart';
import 'package:llamadart/src/core/models/inference/tool_choice.dart';
import 'package:llamadart/src/core/models/tools/tool_definition.dart';
import 'package:llamadart/src/core/models/tools/tool_param.dart';
import 'package:llamadart/src/core/template/chat_format.dart';
import 'package:llamadart/src/core/template/chat_format_registry.dart';
import 'package:llamadart/src/core/template/chat_parse_result.dart';
import 'package:llamadart/src/core/template/chat_template_engine.dart';
import 'package:llamadart/src/core/template/thinking_utils.dart';
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
        expect(thinkingForcedClosedOf(rendered), isTrue);
      });

      test(
        'keeps the closed thought through grammar and token counts',
        () async {
          final source = File(templatePath).readAsStringSync();
          final messages = [
            LlamaChatMessage.fromText(
              role: LlamaChatRole.user,
              text: _fixture['user_prompt'] as String,
            ),
          ];
          final results = [
            ChatTemplateEngine.render(
              templateSource: source,
              messages: messages,
              metadata: const {},
              tools: [_weatherTool],
              toolChoice: ToolChoice.required,
              enableThinking: false,
            ),
            ChatTemplateEngine.render(
              templateSource: source,
              messages: messages,
              metadata: const {},
              responseFormat: const {
                'type': 'json_schema',
                'json_schema': {
                  'schema': {'type': 'object'},
                },
              },
              enableThinking: false,
            ),
            await ChatTemplateRenderer.render(
              loadMetadata: () async => {'tokenizer.chat_template': source},
              tokenize: (text, {bool addSpecial = true}) async => const [1],
              messages: messages,
              enableThinking: false,
            ),
          ];
          for (final (index, result) in results.indexed) {
            // A response schema renders DeepSeek V3 and Hermes templates as
            // content-only, where the closed thought does not apply.
            if (result.format == ChatFormat.contentOnly.index) continue;
            expect(result.format, rendered.format, reason: '$index');
            expect(thinkingForcedClosedOf(result), isTrue, reason: '$index');
          }
        },
      );

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

          // A thinking kwarg can turn thinking on for a prompt that closes
          // the thought; the reply still has none.
          for (final (withTools, enableThinking) in const [
            (true, false),
            (false, false),
            (true, true),
          ]) {
            for (final tokens in [
              [output],
              output.split(''),
            ]) {
              final chunks = await ChatCompletionStreamParser.parse(
                tokenStream: Stream.fromIterable(tokens),
                templateResult: rendered,
                parseToolCallsEnabled: withTools,
                enableThinking: enableThinking,
                modelName: 'test-model',
                completionId: 'closed-thought-upstream',
                tools: withTools ? [_weatherTool] : null,
              ).toList();
              final deltas = chunks.map((chunk) => chunk.choices.single.delta);
              final reason =
                  '${tokens.length} tokens, tools: $withTools, '
                  'enableThinking: $enableThinking';
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

  // With thinking off, these templates still leave the thought open, so
  // llama.cpp parses the reply's leading thought as reasoning. llamadart
  // closes that thought in the prompt, which must not make the reply content.
  for (final entry
      in (_fixture['open_thought_templates'] as List)
          .cast<Map<String, dynamic>>()) {
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

      test('leaves the thought open in the template render', () {
        expect(
          rendered.format,
          ChatFormat.values.byName(entry['format'] as String).index,
        );
        final generationPrompt = (entry['generation_prompt'] as String)
            .trimRight();
        expect(rendered.prompt, endsWith('$generationPrompt</think>\n'));
        expect(rendered.thinkingForcedOpen, isFalse);
        expect(thinkingForcedClosedOf(rendered), isFalse);
      });

      for (final c in (entry['cases'] as List).cast<Map<String, dynamic>>()) {
        final output = c['output'] as String;
        test('${c['name']} parses and streams as llama.cpp parses', () async {
          for (final withTools in const [true, false]) {
            final upstream =
                c[withTools ? 'upstream' : 'upstream_without_tools']
                    as Map<String, dynamic>;
            final upstreamCalls = _calls([
              for (final call
                  in (upstream['tool_calls'] as List)
                      .cast<Map<String, dynamic>>())
                (
                  name: call['name'] as String,
                  arguments: call['arguments'] as String,
                ),
            ]);
            final parsed = ChatTemplateEngine.parse(
              rendered.format,
              output,
              parseToolCalls: withTools,
              thinkingForcedClosed: thinkingForcedClosedOf(rendered),
              tools: withTools ? [_weatherTool] : null,
            );
            final reason = 'tools: $withTools';
            expect(
              parsed.content.trim(),
              (upstream['content'] as String).trim(),
              reason: reason,
            );
            expect(
              parsed.reasoningContent?.trim() ?? '',
              (upstream['reasoning_content'] as String).trim(),
              reason: reason,
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
              reason: reason,
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
                parseToolCallsEnabled: withTools,
                enableThinking: false,
                modelName: 'test-model',
                completionId: 'open-thought-upstream',
                tools: withTools ? [_weatherTool] : null,
              ).toList();
              final deltas = chunks.map((chunk) => chunk.choices.single.delta);
              final streamReason = '${tokens.length} tokens, $reason';
              // A chunked stream already emits a thought that has no start
              // tag as content before its end tag arrives, as on main.
              if (tokens.length == 1) {
                expect(
                  deltas.map((delta) => delta.content ?? '').join().trim(),
                  (upstream['content'] as String).trim(),
                  reason: streamReason,
                );
              }
              // With thinking off, the stream drops the reasoning.
              expect(
                deltas.map((delta) => delta.thinking ?? '').join(),
                isEmpty,
                reason: streamReason,
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
                reason: streamReason,
              );
            }
          }
        });
      }
    });
  }

  // The stream keeps thinking tags as content for exactly these formats.
  test('only formats with the trait parse no thought after a closed one', () {
    for (final registration in chatFormatRegistrations) {
      final index = registration.format.index;
      final tags = ChatTemplateEngine.thinkingTagsFor(index);
      final output = '${tags.startTag}Plan${tags.endTag}Sunny.';
      final keepsTags = registration.traits.closedThoughtKeepsTagsAsContent;
      final ChatParseResult open;
      try {
        open = ChatTemplateEngine.parse(index, output, parseToolCalls: false);
      } on StateError {
        // PEG formats parse only with the parser their render returns.
        expect(keepsTags, isFalse, reason: registration.format.name);
        continue;
      }
      final closed = ChatTemplateEngine.parse(
        index,
        output,
        parseToolCalls: false,
        thinkingForcedClosed: true,
      );
      expect(open.reasoningContent, keepsTags ? 'Plan' : anything);
      expect(
        closed.reasoningContent,
        keepsTags ? isNull : open.reasoningContent,
        reason: registration.format.name,
      );
    }
  });

  test('a forced-open thought keeps the reasoning', () async {
    expect(
      ChatTemplateEngine.parse(
        ChatFormat.hermes.index,
        'Plan</think>Sunny.',
        thinkingForcedOpen: true,
        thinkingForcedClosed: true,
      ).reasoningContent,
      'Plan',
    );
    final chunks = await ChatCompletionStreamParser.parse(
      tokenStream: Stream.fromIterable('Plan</think>Sunny.'.split('')),
      templateResult: withThinkingForcedClosed(
        LlamaChatTemplateResult(
          prompt: '<|im_start|>assistant\n<think>\n',
          format: ChatFormat.hermes.index,
          thinkingForcedOpen: true,
        ),
        closed: true,
      ),
      parseToolCallsEnabled: false,
      enableThinking: true,
      modelName: 'test-model',
      completionId: 'forced-open',
    ).toList();
    final deltas = chunks.map((chunk) => chunk.choices.single.delta);
    expect(deltas.map((delta) => delta.thinking ?? '').join(), 'Plan');
    expect(deltas.map((delta) => delta.content ?? '').join(), 'Sunny.');
  });

  // llama.cpp still parses a leading thought after a prompt that does not
  // close one, such as Bielik's with thinking off. Only the template's own
  // render decides: llamadart closing an open thought does not count.
  test('a result without a closed thought keeps the reasoning', () async {
    for (final closed in const [false, true]) {
      final chunks = await ChatCompletionStreamParser.parse(
        tokenStream: Stream.value('<think>Plan</think>Sunny.'),
        templateResult: withThinkingForcedClosed(
          LlamaChatTemplateResult(
            prompt: '<|im_start|>assistant\n<think></think>\n',
            format: ChatFormat.hermes.index,
          ),
          closed: closed,
        ),
        parseToolCallsEnabled: false,
        enableThinking: false,
        modelName: 'test-model',
        completionId: 'open-prompt',
      ).toList();
      expect(
        chunks.map((chunk) => chunk.choices.single.delta.content ?? '').join(),
        closed ? '<think>Plan</think>Sunny.' : 'Sunny.',
        reason: 'thinkingForcedClosed: $closed',
      );
    }
  });
}
