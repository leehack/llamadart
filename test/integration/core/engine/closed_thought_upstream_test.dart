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
import 'package:llamadart/src/core/template/chat_template_handler.dart';
import 'package:llamadart/src/core/template/handlers/deepseek_v3_handler.dart';
import 'package:llamadart/src/core/template/handlers/hermes_handler.dart';
import 'package:llamadart/src/core/template/handlers/qwen3_coder_xml_handler.dart';
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

/// [output] whole, bytewise, in 3-character chunks and split in two at every
/// point.
List<List<String>> _chunkings(String output) => [
  [output],
  output.split(''),
  [
    for (var i = 0; i < output.length; i += 3)
      output.substring(i, i + 3 > output.length ? output.length : i + 3),
  ],
  for (var split = 1; split < output.length; split++)
    [output.substring(0, split), output.substring(split)],
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

      // With thinking on, the same templates leave the thought open.
      test('streams each reply with thinking on as it parses', () async {
        final forcedOpen = ChatTemplateEngine.render(
          templateSource: File(templatePath).readAsStringSync(),
          messages: [
            LlamaChatMessage.fromText(
              role: LlamaChatRole.user,
              text: _fixture['user_prompt'] as String,
            ),
          ],
          metadata: const {},
          tools: [_weatherTool],
        );
        // Qwen3-4B leaves opening a thought to the model.
        final opensThought = !templatePath.endsWith('/Qwen3-4B.jinja');
        expect(forcedOpen.thinkingForcedOpen, opensThought);
        if (!opensThought) return;
        for (final c in (entry['cases'] as List).cast<Map<String, dynamic>>()) {
          final output = c['output'] as String;
          for (final withTools in const [true, false]) {
            final parsed = ChatTemplateEngine.parse(
              forcedOpen.format,
              output,
              parseToolCalls: withTools,
              thinkingForcedOpen: true,
              tools: withTools ? [_weatherTool] : null,
            );
            for (final tokens in _chunkings(output)) {
              final deltas = (await ChatCompletionStreamParser.parse(
                tokenStream: Stream.fromIterable(tokens),
                templateResult: forcedOpen,
                parseToolCallsEnabled: withTools,
                enableThinking: true,
                modelName: 'test-model',
                completionId: 'forced-open-upstream',
                tools: withTools ? [_weatherTool] : null,
              ).toList()).map((chunk) => chunk.choices.single.delta);
              final reason = '${c['name']} $tokens, tools: $withTools';
              expect(
                deltas.map((delta) => delta.content ?? '').join(),
                parsed.content,
                reason: reason,
              );
              expect(
                deltas.map((delta) => delta.thinking ?? '').join(),
                parsed.reasoningContent ?? '',
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
                _calls([
                  for (final call in parsed.toolCalls)
                    (
                      name: call.function?.name,
                      arguments: call.function?.arguments,
                    ),
                ]),
                reason: reason,
              );
            }
          }
        }
      });
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
        expect(thoughtClosedForThinkingOffOf(rendered), isTrue);
      });

      test('keeps the mark through grammar and token counts', () async {
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
          expect(result.prompt, endsWith('</think>\n'), reason: '$index');
          expect(
            thoughtClosedForThinkingOffOf(result),
            isTrue,
            reason: '$index',
          );
        }
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

            for (final tokens in _chunkings(output)) {
              for (final enableThinking in const [false, true]) {
                final chunks = await ChatCompletionStreamParser.parse(
                  tokenStream: Stream.fromIterable(tokens),
                  templateResult: rendered,
                  parseToolCallsEnabled: withTools,
                  enableThinking: enableThinking,
                  modelName: 'test-model',
                  completionId: 'open-thought-upstream',
                  tools: withTools ? [_weatherTool] : null,
                ).toList();
                final deltas = chunks.map(
                  (chunk) => chunk.choices.single.delta,
                );
                final streamReason =
                    '$tokens, thinking: $enableThinking, $reason';
                expect(
                  deltas.map((delta) => delta.content ?? '').join().trim(),
                  (upstream['content'] as String).trim(),
                  reason: streamReason,
                );
                expect(
                  deltas.map((delta) => delta.thinking ?? '').join(),
                  enableThinking
                      ? (upstream['reasoning_content'] as String).trim()
                      : isEmpty,
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

  // With thinking off, a handler closes a thought its template opened. The
  // stream then holds a reply's leading text where the parse may still end
  // that thought at an end tag.
  test('marks a thought a handler closes where the parse ends it', () {
    // These handlers do not mark one yet (#1553).
    const unmarked = {
      ChatFormat.commandR7B,
      ChatFormat.cohere2Moe,
      ChatFormat.seedOss,
    };
    for (final registration in chatFormatRegistrations) {
      final format = registration.format;
      final handler = registration.createHandler();
      final opened = '<|im_start|>assistant\n${handler.thinkingStartTag}';
      LlamaChatTemplateResult render({required bool enableThinking}) =>
          handler.render(
            templateSource: '{{ ${jsonEncode(opened)} }}',
            messages: const [
              LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'Hi'),
            ],
            metadata: const {},
            enableThinking: enableThinking,
          );
      final closed = render(enableThinking: false);
      final handlerClosed =
          closed.prompt != opened && !closed.thinkingForcedOpen;
      final bool parsesThought;
      try {
        parsesThought =
            ChatTemplateEngine.parse(
              format.index,
              'Plan${handler.thinkingEndTag}Sunny.',
              parseToolCalls: false,
            ).reasoningContent ==
            'Plan';
      } on StateError {
        // PEG formats parse only with the parser their render returns.
        expect(handlerClosed, isFalse, reason: format.name);
        expect(thoughtClosedForThinkingOffOf(closed), isFalse);
        continue;
      }
      expect(
        thoughtClosedForThinkingOffOf(closed),
        handlerClosed && parsesThought && !unmarked.contains(format),
        reason: format.name,
      );
      expect(
        thoughtClosedForThinkingOffOf(render(enableThinking: true)),
        isFalse,
        reason: format.name,
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

  // A template that always opens the thought, as StepFun's does, renders no
  // empty thought; the handler's own close with thinking off must not count.
  test(
    'a thought the handler closes keeps parsing the reply thought',
    () async {
      for (final (ChatTemplateHandler handler, templateSource) in [
        (HermesHandler(), '<|im_start|>assistant\n<think>\n'),
        (DeepseekV3Handler(), '<｜Assistant｜><think>'),
        (Qwen3CoderXmlHandler(), '<|im_start|>assistant\n<think>\n'),
      ]) {
        final rendered = handler.render(
          templateSource: templateSource,
          messages: const [
            LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'Hi'),
          ],
          metadata: const {},
          enableThinking: false,
        );
        expect(rendered.prompt, endsWith('<think></think>\n'));
        final chunks = await ChatCompletionStreamParser.parse(
          tokenStream: Stream.value('<think>Plan</think>Sunny.'),
          templateResult: rendered,
          parseToolCallsEnabled: false,
          enableThinking: false,
          modelName: 'test-model',
          completionId: 'handler-closed',
        ).toList();
        expect(
          chunks
              .map((chunk) => chunk.choices.single.delta.content ?? '')
              .join(),
          'Sunny.',
          reason: handler.format.name,
        );
      }
    },
  );
}
