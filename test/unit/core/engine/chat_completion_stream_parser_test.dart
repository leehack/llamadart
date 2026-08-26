import 'dart:convert';

import 'package:llamadart/src/core/engine/chat_completion_stream_parser.dart';
import 'package:llamadart/src/core/llama_logger.dart';
import 'package:llamadart/src/core/models/chat/chat_template_result.dart';
import 'package:llamadart/src/core/models/config/log_level.dart';
import 'package:llamadart/src/core/models/tools/tool_definition.dart';
import 'package:llamadart/src/core/models/tools/tool_param.dart';
import 'package:llamadart/src/core/template/chat_format.dart';
import 'package:test/test.dart';

void main() {
  group('ChatCompletionStreamParser', () {
    test('streams plain content chunks and a final stop chunk', () async {
      final chunks = await ChatCompletionStreamParser.parse(
        tokenStream: Stream.fromIterable(['hel', 'lo']),
        templateResult: const LlamaChatTemplateResult(prompt: 'prompt'),
        parseToolCallsEnabled: false,
        enableThinking: true,
        modelName: 'test-model',
        completionId: '123',
      ).toList();

      final content = chunks
          .map((chunk) => chunk.choices.single.delta.content ?? '')
          .join();

      expect(content, 'hello');
      expect(chunks.last.choices.single.finishReason, 'stop');
      expect(chunks.last.model, 'test-model');
    });

    test('routes forced-open Qwen thinking into reasoning content', () async {
      final chunks = await ChatCompletionStreamParser.parse(
        tokenStream: Stream.fromIterable(<String>[
          'reasoning',
          '</think>',
          'answer',
        ]),
        templateResult: LlamaChatTemplateResult(
          prompt: 'prompt',
          format: ChatFormat.qwen3CoderXml.index,
          thinkingForcedOpen: true,
        ),
        parseToolCallsEnabled: false,
        enableThinking: true,
        modelName: 'test-model',
        completionId: '456',
      ).toList();

      final reasoning = chunks
          .map((chunk) => chunk.choices.single.delta.thinking ?? '')
          .join();
      final content = chunks
          .map((chunk) => chunk.choices.single.delta.content ?? '')
          .join();

      expect(reasoning, 'reasoning');
      expect(content, 'answer');
    });

    test(
      'does not stream a forced-open Qwen tool envelope as reasoning',
      () async {
        final chunks = await ChatCompletionStreamParser.parse(
          tokenStream: Stream.fromIterable(<String>[
            'I should look this up.',
            '<',
            't',
            'o',
            'o',
            'l',
            '_',
            'c',
            'a',
            'll>\n<function=get_weather>\n',
            '<parameter=location>\nSeoul\n</parameter>\n',
            '</function>\n</tool_call>',
          ]),
          templateResult: LlamaChatTemplateResult(
            prompt: 'prompt',
            format: ChatFormat.qwen3CoderXml.index,
            thinkingForcedOpen: true,
          ),
          parseToolCallsEnabled: true,
          enableThinking: true,
          modelName: 'test-model',
          completionId: '789',
        ).toList();

        final reasoning = chunks
            .map((chunk) => chunk.choices.single.delta.thinking ?? '')
            .join();
        final content = chunks
            .map((chunk) => chunk.choices.single.delta.content ?? '')
            .join();
        final toolChunk = chunks.firstWhere(
          (chunk) => chunk.choices.single.delta.toolCalls != null,
        );

        expect(reasoning, 'I should look this up.');
        expect(reasoning, isNot(contains('<tool_call')));
        expect(content, isEmpty);
        expect(
          toolChunk.choices.single.delta.toolCalls!.single.function!.name,
          'get_weather',
        );
        expect(chunks.last.choices.single.finishReason, 'tool_calls');
      },
    );

    test(
      'does not stream a Qwen tool envelope after a forced thought closes',
      () async {
        final chunks = await ChatCompletionStreamParser.parse(
          tokenStream: Stream.fromIterable(<String>[
            'I should look this up.',
            '</think>',
            '<',
            't',
            'o',
            'o',
            'l',
            '_',
            'c',
            'a',
            'll>\n<function=get_weather>\n',
            '<parameter=location>\nSeoul\n</parameter>\n',
            '</function>\n</tool_call>',
          ]),
          templateResult: LlamaChatTemplateResult(
            prompt: 'prompt',
            format: ChatFormat.qwen3CoderXml.index,
            thinkingForcedOpen: true,
          ),
          parseToolCallsEnabled: true,
          enableThinking: true,
          modelName: 'test-model',
          completionId: '012',
        ).toList();

        final reasoning = chunks
            .map((chunk) => chunk.choices.single.delta.thinking ?? '')
            .join();
        final content = chunks
            .map((chunk) => chunk.choices.single.delta.content ?? '')
            .join();
        final toolChunk = chunks.firstWhere(
          (chunk) => chunk.choices.single.delta.toolCalls != null,
        );

        expect(reasoning, 'I should look this up.');
        expect(content, isEmpty);
        expect(
          toolChunk.choices.single.delta.toolCalls!.single.function!.name,
          'get_weather',
        );
        expect(chunks.last.choices.single.finishReason, 'tool_calls');
      },
    );

    test(
      'Gemma 4 withholds a character-split tool envelope after thinking',
      () async {
        const output =
            'private reasoning<channel|>'
            '<|tool_call>call:weather{"city":"Seoul"}<tool_call|>';
        final chunks = await ChatCompletionStreamParser.parse(
          tokenStream: Stream.fromIterable(output.split('')),
          templateResult: LlamaChatTemplateResult(
            prompt: 'prompt',
            format: ChatFormat.gemma4.index,
            thinkingForcedOpen: true,
          ),
          parseToolCallsEnabled: true,
          enableThinking: true,
          modelName: 'test-model',
          completionId: 'gemma4-character-split',
          tools: [_weatherTool],
        ).toList();

        final reasoning = chunks
            .map((chunk) => chunk.choices.single.delta.thinking ?? '')
            .join();
        final content = chunks
            .map((chunk) => chunk.choices.single.delta.content ?? '')
            .join();
        final toolCall = chunks
            .expand((chunk) => chunk.choices.single.delta.toolCalls ?? const [])
            .single;

        expect(reasoning, 'private reasoning');
        expect(content, isEmpty);
        expect(content, isNot(contains('<|tool_call>')));
        expect(toolCall.function?.name, 'weather');
        expect(jsonDecode(toolCall.function!.arguments!), {'city': 'Seoul'});
        expect(chunks.last.choices.single.finishReason, 'tool_calls');
      },
    );

    test(
      'Gemma 4 withholds a character-split tool envelope after content',
      () async {
        const output =
            'Visible answer.'
            '<|tool_call>call:weather{"city":"Seoul"}<tool_call|>';
        final chunks = await ChatCompletionStreamParser.parse(
          tokenStream: Stream.fromIterable(output.split('')),
          templateResult: LlamaChatTemplateResult(
            prompt: 'prompt',
            format: ChatFormat.gemma4.index,
          ),
          parseToolCallsEnabled: true,
          enableThinking: true,
          modelName: 'test-model',
          completionId: 'gemma4-content-tool-split',
          tools: [_weatherTool],
        ).toList();

        final content = chunks
            .map((chunk) => chunk.choices.single.delta.content ?? '')
            .join();
        final toolCall = chunks
            .expand((chunk) => chunk.choices.single.delta.toolCalls ?? const [])
            .single;

        expect(content, 'Visible answer.');
        expect(content, isNot(contains('<|tool_call>')));
        expect(toolCall.function?.name, 'weather');
        expect(jsonDecode(toolCall.function!.arguments!), {'city': 'Seoul'});
      },
    );

    test(
      'Gemma 4 suppresses split tool controls when parsing is disabled',
      () async {
        const output =
            'Visible answer.'
            '<|tool_call>call:weather{"city":"Seoul"}<tool_call|>';
        final chunks = await ChatCompletionStreamParser.parse(
          tokenStream: Stream.fromIterable(output.split('')),
          templateResult: LlamaChatTemplateResult(
            prompt: 'prompt',
            format: ChatFormat.gemma4.index,
          ),
          parseToolCallsEnabled: false,
          enableThinking: true,
          modelName: 'test-model',
          completionId: 'gemma4-no-tool-parse',
          tools: [_weatherTool],
        ).toList();

        final content = chunks
            .map((chunk) => chunk.choices.single.delta.content ?? '')
            .join();

        expect(content, 'Visible answer.');
        expect(content, isNot(contains('<|tool_call>')));
        expect(
          chunks.expand(
            (chunk) => chunk.choices.single.delta.toolCalls ?? const [],
          ),
          isEmpty,
        );
        expect(chunks.last.choices.single.finishReason, 'stop');
      },
    );

    test('Gemma 4 preserves ordinary raw whitespace exactly', () async {
      const output = ' \tVisible answer.  \n';

      for (final parseToolCallsEnabled in <bool>[true, false]) {
        final chunks = await ChatCompletionStreamParser.parse(
          tokenStream: Stream.fromIterable(output.split('')),
          templateResult: LlamaChatTemplateResult(
            prompt: 'prompt',
            format: ChatFormat.gemma4.index,
          ),
          parseToolCallsEnabled: parseToolCallsEnabled,
          enableThinking: true,
          modelName: 'test-model',
          completionId: 'gemma4-raw-whitespace-$parseToolCallsEnabled',
          tools: [_weatherTool],
        ).toList();

        final content = chunks
            .map((chunk) => chunk.choices.single.delta.content ?? '')
            .join();

        expect(content, output, reason: 'parse tools: $parseToolCallsEnabled');
        expect(
          chunks.expand(
            (chunk) => chunk.choices.single.delta.toolCalls ?? const [],
          ),
          isEmpty,
        );
      }
    });

    test(
      'Gemma 4 character-split explicit thinking never becomes content',
      () async {
        const output = '<|channel>thought\ninternal draft<channel|>';

        for (final enableThinking in <bool>[true, false]) {
          final chunks = await ChatCompletionStreamParser.parse(
            tokenStream: Stream.fromIterable(output.split('')),
            templateResult: LlamaChatTemplateResult(
              prompt: 'prompt',
              format: ChatFormat.gemma4.index,
            ),
            parseToolCallsEnabled: true,
            enableThinking: enableThinking,
            modelName: 'test-model',
            completionId: 'gemma4-thinking-$enableThinking',
            tools: [_weatherTool],
          ).toList();

          final reasoning = chunks
              .map((chunk) => chunk.choices.single.delta.thinking ?? '')
              .join();
          final content = chunks
              .map((chunk) => chunk.choices.single.delta.content ?? '')
              .join();

          expect(content, isEmpty);
          expect(content, isNot(contains('<|channel>')));
          expect(content, isNot(contains('<channel|>')));
          expect(reasoning, enableThinking ? 'internal draft' : isEmpty);
        }
      },
    );

    test('debug logging records only parsed output metadata', () async {
      final messages = <String>[];
      LlamaLogger.instance
        ..setLevel(LlamaLogLevel.debug)
        ..setHandler((record) => messages.add(record.message));

      try {
        await ChatCompletionStreamParser.parse(
          tokenStream: Stream.value(
            '<|channel>thought\ninternal draft<channel|>'
            '<|tool_call>call:weather{"city":"Seoul"}<tool_call|>',
          ),
          templateResult: LlamaChatTemplateResult(
            prompt: 'prompt',
            format: ChatFormat.gemma4.index,
          ),
          parseToolCallsEnabled: true,
          enableThinking: true,
          modelName: 'test-model',
          completionId: 'safe-debug-log',
          tools: [_weatherTool],
        ).toList();
      } finally {
        LlamaLogger.instance
          ..setHandler(null)
          ..setLevel(LlamaLogLevel.none);
      }

      expect(messages, [
        'Parsed completion: contentChars=0, reasoningChars=14, '
            'toolCallCount=1',
      ]);
    });

    test('carries tool schemas into specialized final parsing', () async {
      const namespace = ']<]minimax[>[';
      final tool = ToolDefinition(
        name: 'inspect',
        description: 'Inspect',
        parameters: [ToolParam.string('code', required: true)],
        handler: (_) async => null,
      );
      final chunks = await ChatCompletionStreamParser.parse(
        tokenStream: Stream.value(
          '$namespace<tool_call>$namespace<invoke name="inspect">'
          '$namespace<code>123$namespace</code>'
          '$namespace</invoke>$namespace</tool_call>',
        ),
        templateResult: LlamaChatTemplateResult(
          prompt: 'prompt',
          format: ChatFormat.minimaxM3.index,
        ),
        parseToolCallsEnabled: true,
        enableThinking: true,
        modelName: 'test-model',
        completionId: 'schema',
        tools: [tool],
      ).toList();

      final toolCall = chunks
          .expand((chunk) => chunk.choices.single.delta.toolCalls ?? const [])
          .single;
      expect(jsonDecode(toolCall.function!.arguments!), {'code': '123'});
      expect(chunks.last.choices.single.finishReason, 'tool_calls');
    });

    test('preserves MiniMax M3 schema types across split tokens', () async {
      const namespace = ']<]minimax[>[';
      const output =
          '$namespace<tool_call>'
          '$namespace<invoke name="inspect">'
          '$namespace<code>123$namespace</code>'
          '$namespace<options>$namespace</options>'
          '$namespace<items>$namespace</items>'
          '$namespace</invoke>$namespace</tool_call>';
      final chunks = await ChatCompletionStreamParser.parse(
        tokenStream: Stream.fromIterable(<String>[
          output.substring(0, 7),
          output.substring(7, 31),
          output.substring(31, 58),
          output.substring(58, 87),
          output.substring(87),
        ]),
        templateResult: LlamaChatTemplateResult(
          prompt: 'prompt',
          format: ChatFormat.minimaxM3.index,
        ),
        parseToolCallsEnabled: true,
        enableThinking: true,
        modelName: 'test-model',
        completionId: 'm3-typed-split',
        tools: [_typedStreamTool],
      ).toList();

      final content = chunks
          .map((chunk) => chunk.choices.single.delta.content ?? '')
          .join();
      final toolCall = chunks
          .expand((chunk) => chunk.choices.single.delta.toolCalls ?? const [])
          .single;
      expect(content, isEmpty);
      expect(jsonDecode(toolCall.function!.arguments!), {
        'code': '123',
        'options': <String, dynamic>{},
        'items': <Object?>[],
      });
    });

    test('does not stream partial Laguna tool markup as content', () async {
      final chunks = await ChatCompletionStreamParser.parse(
        tokenStream: Stream.fromIterable(<String>[
          'Visible answer.',
          '<',
          'tool_call>weather\n',
          '<arg_key>city</arg_key><arg_value>Seoul</arg_value>',
          '</tool_call>',
        ]),
        templateResult: LlamaChatTemplateResult(
          prompt: 'prompt',
          format: ChatFormat.laguna.index,
        ),
        parseToolCallsEnabled: true,
        enableThinking: true,
        modelName: 'test-model',
        completionId: 'laguna-partial',
        tools: [_weatherTool],
      ).toList();

      final content = chunks
          .map((chunk) => chunk.choices.single.delta.content ?? '')
          .join();
      final toolCall = chunks
          .expand((chunk) => chunk.choices.single.delta.toolCalls ?? const [])
          .single;
      expect(content, 'Visible answer.');
      expect(content, isNot(contains('<tool')));
      expect(toolCall.function?.name, 'weather');
      expect(jsonDecode(toolCall.function!.arguments!), {'city': 'Seoul'});
    });

    test('does not stream partial GLM tool markup as content', () async {
      final chunks = await ChatCompletionStreamParser.parse(
        tokenStream: Stream.fromIterable(<String>[
          'Visible answer.',
          '<',
          'tool_call>weather\n',
          '<arg_key>city</arg_key><arg_value>Seoul</arg_value>',
          '</tool_call>',
        ]),
        templateResult: LlamaChatTemplateResult(
          prompt: 'prompt',
          format: ChatFormat.glm45.index,
        ),
        parseToolCallsEnabled: true,
        enableThinking: true,
        modelName: 'test-model',
        completionId: 'glm-partial',
        tools: [_weatherTool],
      ).toList();

      final content = chunks
          .map((chunk) => chunk.choices.single.delta.content ?? '')
          .join();
      final toolCall = chunks
          .expand((chunk) => chunk.choices.single.delta.toolCalls ?? const [])
          .single;
      expect(content, 'Visible answer.');
      expect(content, isNot(contains('<tool')));
      expect(toolCall.function?.name, 'weather');
      expect(jsonDecode(toolCall.function!.arguments!), {'city': 'Seoul'});
    });

    test('does not stream partial Muse routing markup as content', () async {
      const atem =
          '<atem:function_calls><atem:invoke name="weather">'
          '<atem:parameter name="city">Seoul</atem:parameter>'
          '</atem:invoke></atem:function_calls>';
      final chunks = await ChatCompletionStreamParser.parse(
        tokenStream: Stream.fromIterable(<String>[
          'Visible answer.',
          '<',
          '|start|>assistant to=weather<|mess',
          'age|>$atem<|eot|>',
        ]),
        templateResult: LlamaChatTemplateResult(
          prompt: 'prompt',
          format: ChatFormat.museGlimmer.index,
        ),
        parseToolCallsEnabled: true,
        enableThinking: true,
        modelName: 'test-model',
        completionId: 'muse-partial',
        tools: [_weatherTool],
      ).toList();

      final content = chunks
          .map((chunk) => chunk.choices.single.delta.content ?? '')
          .join();
      final toolCall = chunks
          .expand((chunk) => chunk.choices.single.delta.toolCalls ?? const [])
          .single;
      expect(content, 'Visible answer.');
      expect(content, isNot(contains('<|start|>')));
      expect(toolCall.function?.name, 'weather');
      expect(jsonDecode(toolCall.function!.arguments!), {'city': 'Seoul'});
    });

    test('character-split Muse routing never leaks protocol content', () async {
      const atem =
          '<atem:function_calls><atem:invoke name="weather">'
          '<atem:parameter name="city">Seoul</atem:parameter>'
          '</atem:invoke></atem:function_calls>';
      const output =
          'Visible answer.<|start|>assistant to=weather<|message|>'
          '$atem<|eot|>';
      final chunks = await ChatCompletionStreamParser.parse(
        tokenStream: Stream.fromIterable(output.split('')),
        templateResult: LlamaChatTemplateResult(
          prompt: 'prompt',
          format: ChatFormat.museGlimmer.index,
        ),
        parseToolCallsEnabled: true,
        enableThinking: true,
        modelName: 'test-model',
        completionId: 'muse-character-split',
        tools: [_weatherTool],
      ).toList();

      final content = chunks
          .map((chunk) => chunk.choices.single.delta.content ?? '')
          .join();
      expect(content, 'Visible answer.');
      expect(content, isNot(contains('<|')));
      expect(content, isNot(contains('<atem:')));
      expect(
        chunks
            .expand((chunk) => chunk.choices.single.delta.toolCalls ?? const [])
            .single
            .function
            ?.name,
        'weather',
      );
    });

    test(
      'specialized formats suppress split envelopes and reconcile malformed finals',
      () async {
        const namespace = ']<]minimax[>[';
        final cases =
            <
              ({
                String name,
                int format,
                String marker,
                String valid,
                String malformed,
              })
            >[
              (
                name: 'Kimi K3',
                format: ChatFormat.kimiK3.index,
                marker: '<|open|>tools',
                valid:
                    'Visible answer.<|open|>tools<|sep|>'
                    '<|open|>call tool="weather"<|sep|>'
                    '<|open|>argument key="city" type="string"<|sep|>Seoul'
                    '<|close|>argument<|sep|><|close|>call<|sep|>'
                    '<|close|>tools<|sep|><|close|>message<|sep|>',
                malformed:
                    'Visible answer.<|open|>tools<|sep|>'
                    '<|open|>call tool="unknown"<|sep|>'
                    '<|open|>argument key="city" type="string"<|sep|>Seoul'
                    '<|close|>argument<|sep|><|close|>call<|sep|>'
                    '<|close|>tools<|sep|><|close|>message<|sep|>',
              ),
              (
                name: 'MiniMax M1',
                format: ChatFormat.minimaxM1.index,
                marker: '<tool_calls>',
                valid:
                    'Visible answer.<tool_calls>\n'
                    '{"name":"weather","arguments":{"city":"Seoul"}}\n'
                    '</tool_calls>',
                malformed:
                    'Visible answer.<tool_calls>\n'
                    '{"name":"unknown","arguments":{"city":"Seoul"}}\n'
                    '</tool_calls>',
              ),
              (
                name: 'MiniMax M3',
                format: ChatFormat.minimaxM3.index,
                marker: '$namespace<tool_call>',
                valid:
                    'Visible answer.$namespace<tool_call>'
                    '$namespace<invoke name="weather">'
                    '$namespace<city>Seoul$namespace</city>'
                    '$namespace</invoke>$namespace</tool_call>',
                malformed:
                    'Visible answer.$namespace<tool_call>'
                    '$namespace<invoke name="unknown">'
                    '$namespace<city>Seoul$namespace</city>'
                    '$namespace</invoke>$namespace</tool_call>',
              ),
              (
                name: 'DeepSeek V3.2',
                format: ChatFormat.deepseekV32.index,
                marker: '<｜DSML｜function_calls>',
                valid:
                    'Visible answer.<｜DSML｜function_calls>'
                    '<｜DSML｜invoke name="weather">'
                    '<｜DSML｜parameter name="city" string="true">Seoul'
                    '</｜DSML｜parameter></｜DSML｜invoke>'
                    '</｜DSML｜function_calls>',
                malformed:
                    'Visible answer.<｜DSML｜function_calls>'
                    '<｜DSML｜invoke name="unknown">'
                    '<｜DSML｜parameter name="city" string="true">Seoul'
                    '</｜DSML｜parameter></｜DSML｜invoke>'
                    '</｜DSML｜function_calls>',
              ),
              (
                name: 'DeepSeek V4',
                format: ChatFormat.deepseekV4.index,
                marker: '<｜DSML｜tool_calls>',
                valid:
                    'Visible answer.<｜DSML｜tool_calls>'
                    '<｜DSML｜invoke name="weather">'
                    '<｜DSML｜parameter name="city" string="true">Seoul'
                    '</｜DSML｜parameter></｜DSML｜invoke>'
                    '</｜DSML｜tool_calls>',
                malformed:
                    'Visible answer.<｜DSML｜tool_calls>'
                    '<｜DSML｜invoke name="unknown">'
                    '<｜DSML｜parameter name="city" string="true">Seoul'
                    '</｜DSML｜parameter></｜DSML｜invoke>'
                    '</｜DSML｜tool_calls>',
              ),
            ];

        for (final testCase in cases) {
          final markerIndex = testCase.valid.indexOf(testCase.marker);
          final validChunks = await ChatCompletionStreamParser.parse(
            tokenStream: Stream.fromIterable([
              testCase.valid.substring(0, markerIndex + 1),
              testCase.valid.substring(markerIndex + 1, markerIndex + 3),
              testCase.valid.substring(markerIndex + 3),
            ]),
            templateResult: LlamaChatTemplateResult(
              prompt: 'prompt',
              format: testCase.format,
            ),
            parseToolCallsEnabled: true,
            enableThinking: true,
            modelName: 'test-model',
            completionId: '${testCase.name}-valid',
            tools: [_weatherTool],
          ).toList();
          final validContent = validChunks
              .map((chunk) => chunk.choices.single.delta.content ?? '')
              .join();
          final toolCall = validChunks
              .expand(
                (chunk) => chunk.choices.single.delta.toolCalls ?? const [],
              )
              .single;
          expect(validContent, 'Visible answer.', reason: testCase.name);
          expect(
            validContent,
            isNot(contains(testCase.marker)),
            reason: testCase.name,
          );
          expect(toolCall.function?.name, 'weather', reason: testCase.name);
          expect(jsonDecode(toolCall.function!.arguments!), {
            'city': 'Seoul',
          }, reason: testCase.name);

          final malformedMarkerIndex = testCase.malformed.indexOf(
            testCase.marker,
          );
          final malformedChunks = await ChatCompletionStreamParser.parse(
            tokenStream: Stream.fromIterable([
              testCase.malformed.substring(0, malformedMarkerIndex + 1),
              testCase.malformed.substring(
                malformedMarkerIndex + 1,
                malformedMarkerIndex + 3,
              ),
              testCase.malformed.substring(malformedMarkerIndex + 3),
            ]),
            templateResult: LlamaChatTemplateResult(
              prompt: 'prompt',
              format: testCase.format,
            ),
            parseToolCallsEnabled: true,
            enableThinking: true,
            modelName: 'test-model',
            completionId: '${testCase.name}-malformed',
            tools: [_weatherTool],
          ).toList();
          final malformedContent = malformedChunks
              .map((chunk) => chunk.choices.single.delta.content ?? '')
              .join();
          final expectedMalformedContent = switch (testCase.format) {
            final format when format == ChatFormat.kimiK3.index =>
              testCase.malformed.replaceAll('<|close|>message<|sep|>', ''),
            _ => testCase.malformed,
          };
          expect(
            malformedContent,
            expectedMalformedContent,
            reason: '${testCase.name} final rollback',
          );
          expect(
            malformedContent,
            contains(testCase.marker),
            reason: '${testCase.name} malformed protocol preservation',
          );
          expect(
            malformedChunks.expand(
              (chunk) => chunk.choices.single.delta.toolCalls ?? const [],
            ),
            isEmpty,
            reason: testCase.name,
          );
          expect(
            malformedChunks.last.choices.single.finishReason,
            'stop',
            reason: testCase.name,
          );
        }
      },
    );

    test(
      'specialized thinking prefixes do not leak following tool markup',
      () async {
        const namespace = ']<]minimax[>[';
        final cases =
            <({String name, int format, String output, String marker})>[
              (
                name: 'Kimi K3',
                format: ChatFormat.kimiK3.index,
                output:
                    'reasoning<|close|>think<|sep|>'
                    '<|open|>tools<|sep|>'
                    '<|open|>call tool="weather"<|sep|>'
                    '<|open|>argument key="city" type="string"<|sep|>Seoul'
                    '<|close|>argument<|sep|><|close|>call<|sep|>'
                    '<|close|>tools<|sep|><|close|>message<|sep|>',
                marker: '<|open|>tools',
              ),
              (
                name: 'MiniMax M3',
                format: ChatFormat.minimaxM3.index,
                output:
                    '<mm:think>reasoning</mm:think>'
                    '$namespace<tool_call>'
                    '$namespace<invoke name="weather">'
                    '$namespace<city>Seoul$namespace</city>'
                    '$namespace</invoke>$namespace</tool_call>',
                marker: '$namespace<tool_call>',
              ),
              (
                name: 'DeepSeek V3.2',
                format: ChatFormat.deepseekV32.index,
                output:
                    'reasoning</think>'
                    '<｜DSML｜function_calls>'
                    '<｜DSML｜invoke name="weather">'
                    '<｜DSML｜parameter name="city" string="true">Seoul'
                    '</｜DSML｜parameter></｜DSML｜invoke>'
                    '</｜DSML｜function_calls>',
                marker: '<｜DSML｜function_calls>',
              ),
            ];

        for (final testCase in cases) {
          final markerIndex = testCase.output.indexOf(testCase.marker);
          final chunks = await ChatCompletionStreamParser.parse(
            tokenStream: Stream.fromIterable([
              testCase.output.substring(0, markerIndex + 1),
              testCase.output.substring(markerIndex + 1),
            ]),
            templateResult: LlamaChatTemplateResult(
              prompt: 'prompt',
              format: testCase.format,
              thinkingForcedOpen: testCase.name != 'MiniMax M3',
            ),
            parseToolCallsEnabled: true,
            enableThinking: true,
            modelName: 'test-model',
            completionId: '${testCase.name}-thinking',
            tools: [_weatherTool],
          ).toList();
          final content = chunks
              .map((chunk) => chunk.choices.single.delta.content ?? '')
              .join();
          final reasoning = chunks
              .map((chunk) => chunk.choices.single.delta.thinking ?? '')
              .join();

          expect(content, isEmpty, reason: testCase.name);
          expect(reasoning, 'reasoning', reason: testCase.name);
          expect(reasoning, isNot(contains(testCase.marker)));
          expect(
            chunks
                .expand(
                  (chunk) => chunk.choices.single.delta.toolCalls ?? const [],
                )
                .single
                .function
                ?.name,
            'weather',
            reason: testCase.name,
          );
        }
      },
    );

    test(
      'forced-open DSML withholds character-split envelopes from reasoning',
      () async {
        for (final testCase in const [
          (
            name: 'DeepSeek V3.2',
            format: ChatFormat.deepseekV32,
            envelope: 'function_calls',
          ),
          (
            name: 'DeepSeek V4',
            format: ChatFormat.deepseekV4,
            envelope: 'tool_calls',
          ),
        ]) {
          final callsStart = '<｜DSML｜${testCase.envelope}>';
          final callsEnd = '</｜DSML｜${testCase.envelope}>';
          final valid =
              'reasoning$callsStart'
              '<｜DSML｜invoke name="weather">'
              '<｜DSML｜parameter name="city" string="true">Seoul'
              '</｜DSML｜parameter></｜DSML｜invoke>$callsEnd';
          final chunks = await ChatCompletionStreamParser.parse(
            tokenStream: Stream.fromIterable(valid.split('')),
            templateResult: LlamaChatTemplateResult(
              prompt: 'prompt',
              format: testCase.format.index,
              thinkingForcedOpen: true,
            ),
            parseToolCallsEnabled: true,
            enableThinking: true,
            modelName: 'test-model',
            completionId: '${testCase.name}-split-forced-open',
            tools: [_weatherTool],
          ).toList();
          final reasoning = chunks
              .map((chunk) => chunk.choices.single.delta.thinking ?? '')
              .join();
          final content = chunks
              .map((chunk) => chunk.choices.single.delta.content ?? '')
              .join();

          expect(reasoning, 'reasoning', reason: testCase.name);
          expect(reasoning, isNot(contains('<｜DSML｜')));
          expect(content, isEmpty, reason: testCase.name);
          expect(
            chunks
                .expand(
                  (chunk) => chunk.choices.single.delta.toolCalls ?? const [],
                )
                .single
                .function
                ?.name,
            'weather',
            reason: testCase.name,
          );

          final malformed = valid.replaceFirst('name="weather"', 'name="bad"');
          final malformedChunks = await ChatCompletionStreamParser.parse(
            tokenStream: Stream.fromIterable(malformed.split('')),
            templateResult: LlamaChatTemplateResult(
              prompt: 'prompt',
              format: testCase.format.index,
              thinkingForcedOpen: true,
            ),
            parseToolCallsEnabled: true,
            enableThinking: true,
            modelName: 'test-model',
            completionId: '${testCase.name}-split-malformed',
            tools: [_weatherTool],
          ).toList();
          expect(
            malformedChunks
                .map((chunk) => chunk.choices.single.delta.thinking ?? '')
                .join(),
            'reasoning',
            reason: '${testCase.name} malformed reasoning',
          );
          expect(
            malformedChunks
                .map((chunk) => chunk.choices.single.delta.content ?? '')
                .join(),
            malformed.substring('reasoning'.length),
            reason: '${testCase.name} malformed content rollback',
          );
          expect(
            malformedChunks.expand(
              (chunk) => chunk.choices.single.delta.toolCalls ?? const [],
            ),
            isEmpty,
            reason: testCase.name,
          );
        }
      },
    );
  });
}

final _weatherTool = ToolDefinition(
  name: 'weather',
  description: 'Weather',
  parameters: [ToolParam.string('city', required: true)],
  handler: (_) async => null,
);

final _typedStreamTool = ToolDefinition(
  name: 'inspect',
  description: 'Inspect typed values',
  parameters: [
    ToolParam.string('code', required: true),
    ToolParam.object('options', properties: const [], required: true),
    ToolParam.array(
      'items',
      itemType: ToolParam.string('item'),
      required: true,
    ),
  ],
  handler: (_) async => null,
);
