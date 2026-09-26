import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:llamadart/src/core/engine/chat_completion_stream_parser.dart';
import 'package:llamadart/src/core/llama_logger.dart';
import 'package:llamadart/src/core/models/chat/chat_message.dart';
import 'package:llamadart/src/core/models/chat/chat_role.dart';
import 'package:llamadart/src/core/models/chat/chat_template_result.dart';
import 'package:llamadart/src/core/models/config/log_level.dart';
import 'package:llamadart/src/core/models/tools/tool_definition.dart';
import 'package:llamadart/src/core/models/tools/tool_param.dart';
import 'package:llamadart/src/core/template/chat_format.dart';
import 'package:llamadart/src/core/template/chat_template_engine.dart';
import 'package:llamadart/src/core/template/chat_template_handler.dart';
import 'package:llamadart/src/core/template/handlers/ministral_handler.dart';
import 'package:llamadart/src/core/template/handlers/qwen3_coder_xml_handler.dart';
import 'package:llamadart/src/core/template/handlers/solar_open_handler.dart';
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

    test('finishes with length when the stream ended at a limit', () async {
      var stoppedAtLimit = false;
      Stream<String> tokens() async* {
        yield 'par';
        yield 'tial';
        stoppedAtLimit = true;
      }

      final chunks = await ChatCompletionStreamParser.parse(
        tokenStream: tokens(),
        templateResult: const LlamaChatTemplateResult(prompt: 'prompt'),
        parseToolCallsEnabled: false,
        enableThinking: true,
        modelName: 'test-model',
        completionId: '124',
        stoppedAtLimit: () => stoppedAtLimit,
      ).toList();

      final content = chunks
          .map((chunk) => chunk.choices.single.delta.content ?? '')
          .join();
      expect(content, 'partial');
      expect(chunks.last.choices.single.finishReason, 'length');
    });

    test('finishes with stop when the stream ended without a limit', () async {
      final chunks = await ChatCompletionStreamParser.parse(
        tokenStream: Stream.fromIterable(['done']),
        templateResult: const LlamaChatTemplateResult(prompt: 'prompt'),
        parseToolCallsEnabled: false,
        enableThinking: true,
        modelName: 'test-model',
        completionId: '125',
        stoppedAtLimit: () => false,
      ).toList();

      expect(chunks.last.choices.single.finishReason, 'stop');
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

    for (final (name, tokens) in <(String, List<String>)>[
      ('one token', [_hermesDoubleBrace]),
      ('characters', _hermesDoubleBrace.split('')),
    ]) {
      test(
        'streams no content for a double-brace Hermes call as $name',
        () async {
          final chunks = await ChatCompletionStreamParser.parse(
            tokenStream: Stream.fromIterable(tokens),
            templateResult: LlamaChatTemplateResult(
              prompt: 'prompt',
              format: ChatFormat.hermes.index,
            ),
            parseToolCallsEnabled: true,
            enableThinking: true,
            modelName: 'test-model',
            completionId: 'double-brace',
            tools: [_weatherTool],
          ).toList();

          expect(
            chunks
                .map((chunk) => chunk.choices.single.delta.content ?? '')
                .join(),
            isEmpty,
          );
          final toolCall = chunks
              .expand(
                (chunk) => chunk.choices.single.delta.toolCalls ?? const [],
              )
              .single;
          expect(toolCall.function?.name, 'weather');
          expect(jsonDecode(toolCall.function!.arguments!), {'city': 'Paris'});
          expect(chunks.last.choices.single.finishReason, 'tool_calls');
        },
      );
    }

    group('Hermes content matches the final parse', () {
      const call =
          '<tool_call>\n'
          '{"name": "weather", "arguments": {"city": "Paris"}}\n'
          '</tool_call>';
      const doubleBraceCall =
          '<tool_call>\n'
          '{{"name": "weather", "arguments": {"city": "Paris"}}}\n'
          '</tool_call>';
      const londonCall =
          '<tool_call>\n'
          '{"name": "weather", "arguments": {"city": "London"}}\n'
          '</tool_call>';
      const outputs = <String, String>{
        'text then a call': 'Let me check.\n$call',
        'text then a double-brace call': 'Let me check.\n$doubleBraceCall',
        'text then two calls': 'Checking both.\n$call\n$londonCall',
        'text after the call': 'Let me check.\n$call\nOne moment.',
        'padded text then a call': ' \n Let me check.  $call\n',
        'thinking, text, then a call':
            '<think>\nPlan.\n</think>\n\nLet me check.\n$call',
        'a bare < then a call': 'If a < b, b > a.\n$call',
        'a fenced call':
            'Sure:\n```json\n'
            '{"name": "weather", "arguments": {"city": "Paris"}}\n```',
        'a call first': '$call\nDone.',
      };
      const forcedOpenOutputs = <String>[
        'Plan.\n</think>\n\nLet me check.\n$call',
        'Plan. $call',
      ];

      Future<void> expectParsedContent(String output, bool forcedOpen) {
        return _expectStreamMatchesParse(
          ChatFormat.hermes,
          output,
          forcedOpen: forcedOpen,
          openings: const ['<tool_call>'],
        );
      }

      for (final MapEntry(key: name, value: output) in outputs.entries) {
        test(name, () => expectParsedContent(output, false));
      }

      test('plain text', () async {
        for (final output in const [
          'If a < b, use {x} or {"a": 1}.\n',
          'Let me check.\n<th',
        ]) {
          await expectParsedContent(output, false);
        }
      });

      test('after a forced-open thought', () async {
        for (final output in forcedOpenOutputs) {
          await expectParsedContent(output, true);
        }
      });

      test('trims each thought', () async {
        for (final output in const [
          '<think>\nPlan it.\n</think>\n\n$call',
          '<think>\n  Plan it.  \n</think>\n\nIt is sunny.',
          '<think>\n Plan \n\n it. \n',
          '<think>\nA.\n</think>\nOk.<think> </think>\n<think>\tB. </think>$call',
          r'<think> Use "a\nb" \</think>Done.',
          r'<think>a\\nb\r</think>',
          '<think>Plan </thi',
        ]) {
          await expectParsedContent(output, false);
        }
      });

      test('trims a forced-open thought that ends', () async {
        for (final output in const [
          '\nPlan it.\n</think>\n\n$call',
          '  </think>\nOk.\n<think>\nMore.\n</think>\n$call',
        ]) {
          await expectParsedContent(output, true);
        }
      });

      test('keeps trailing space of a forced-open thought that never ends', () {
        return expectParsedContent('Plan it.  \n\n', true);
      });

      test('holds back only a possible envelope opening', () {
        return _expectContentAfterEachToken(ChatFormat.hermes, const [
          ('If a', 'If a'),
          (' <', 'If a'),
          (' b,', 'If a < b,'),
          (' use {', 'If a < b, use'),
          ('x}.', 'If a < b, use {x}.'),
          ('\n', 'If a < b, use {x}.'),
          ('Let me check.\n<tool', 'If a < b, use {x}.\nLet me check.'),
          ('_call>\n{"name', 'If a < b, use {x}.\nLet me check.'),
        ]);
      });
    });

    group('text-first tool calls match the final parse', () {
      const qwenXmlCall =
          '<tool_call>\n'
          '<function=weather>\n'
          '<parameter=city>\nParis\n</parameter>\n'
          '</function>\n'
          '</tool_call>';
      const commandRCall =
          '<|START_ACTION|>'
          '[{"tool_call_id":"0","tool_name":"weather",'
          '"parameters":{"city":"Paris"}}]'
          '<|END_ACTION|>';
      const deepseekCalls = '<｜tool▁calls▁begin｜><｜tool▁call▁begin｜>';
      // Formats whose streams are gated, with a call their parse extracts.
      const gatedCalls = <ChatFormat, String>{
        ChatFormat.mistralNemo:
            '[TOOL_CALLS][{"name": "weather", "arguments": {"city": "Paris"}, '
            '"id": "abcdefghi"}]',
        ChatFormat.magistral:
            '[TOOL_CALLS][{"name":"weather","arguments":{"city":"Paris"}}]',
        ChatFormat.qwen3CoderXml: qwenXmlCall,
        ChatFormat.deepseekR1:
            '${deepseekCalls}function<｜tool▁sep｜>weather\n'
            '```json\n{"city":"Paris"}\n```<｜tool▁call▁end｜>'
            '<｜tool▁calls▁end｜>',
        ChatFormat.deepseekV3:
            '${deepseekCalls}weather<｜tool▁sep｜>{"city":"Paris"}'
            '<｜tool▁call▁end｜><｜tool▁calls▁end｜>',
        ChatFormat.commandR7B: commandRCall,
        ChatFormat.cohere2Moe: commandRCall,
        ChatFormat.granite:
            '<|tool_call|>[{"name":"weather","arguments":{"city":"Paris"}}]',
        ChatFormat.nemotronV2:
            '<TOOLCALL>[{"name":"weather","arguments":{"city":"Paris"}}]'
            '</TOOLCALL>',
        ChatFormat.apertus:
            '<|tools_prefix|>[{"weather":{"city":"Paris"}}]<|tools_suffix|>',
        ChatFormat.seedOss:
            '<seed:tool_call><function=weather><parameter=city>Paris'
            '</parameter></function></seed:tool_call>',
        ChatFormat.minimaxM2:
            '<minimax:tool_call>\n<invoke name="weather">\n'
            '<parameter name="city">Paris</parameter>\n</invoke>\n'
            '</minimax:tool_call>',
        ChatFormat.apriel15:
            '<tool_calls>[{"name": "weather", "arguments": {"city": "Paris"}}]'
            '</tool_calls>',
        ChatFormat.xiaomiMimo:
            '<tool_call>\n{"name": "weather", "arguments": {"city": "Paris"}\n'
            '</tool_call>',
        ChatFormat.exaoneMoe:
            '<tool_call>{"name":"weather","arguments":{"city":"Paris"}}'
            '</tool_call>',
        ChatFormat.minicpm5:
            '<function name="weather"><param name="city">Paris</param>'
            '</function>',
        ChatFormat.hunyuanV3:
            '<tool_calls:opensource>\n'
            '<tool_call:opensource>weather<tool_sep:opensource>\n'
            '<arg_key:opensource>city</arg_key:opensource>\n'
            '<arg_value:opensource>Paris</arg_value:opensource>\n'
            '</tool_call:opensource>\n'
            '</tool_calls:opensource>',
      };
      // These parses ignore a forced-open thought.
      const ungatedWhenForcedOpen = <ChatFormat>{
        ChatFormat.seedOss,
        ChatFormat.minimaxM2,
        ChatFormat.apriel15,
        ChatFormat.xiaomiMimo,
      };
      // These parses keep a forced-open thought that never ends as content.
      const unendedForcedThoughtIsContent = <ChatFormat>{
        ChatFormat.deepseekV3,
        ChatFormat.exaoneMoe,
      };

      /// Text-first and other outputs around [call], with the format's tags.
      List<String> outputs(ChatFormat format, String call) {
        final tags = ChatTemplateEngine.thinkingTagsFor(format.index);
        return [
          'Let me check.\n$call',
          ' \n Let me check.  $call\n',
          'Let me check.\n$call\nDone.',
          '$call\nDone.',
          'If a < b, use {x} or [y].\n',
          'Let me check.\n${call.substring(0, 6)}',
          '${tags.startTag}\nPlan.\n${tags.endTag}\n\nLet me check.\n$call',
        ];
      }

      List<String> openings(String call) => [call.substring(0, 16)];

      for (final MapEntry(key: format, value: call) in gatedCalls.entries) {
        test(format.name, () async {
          for (final output in outputs(format, call)) {
            await _expectStreamMatchesParse(
              format,
              output,
              openings: openings(call),
            );
          }
        });

        if (ungatedWhenForcedOpen.contains(format)) {
          continue;
        }
        final tags = ChatTemplateEngine.thinkingTagsFor(format.index);
        test('${format.name} after a forced-open thought', () async {
          for (final output in [
            'Plan.\n${tags.endTag}\n\nLet me check.\n$call',
            if (!unendedForcedThoughtIsContent.contains(format)) ...[
              'Plan. $call',
              'Plan it.\n',
            ],
          ]) {
            await _expectStreamMatchesParse(
              format,
              output,
              forcedOpen: true,
              openings: openings(call),
            );
          }
        });
      }

      test('keeps parses that ignore a forced-open thought ungated', () async {
        for (final format in ungatedWhenForcedOpen) {
          await _expectStreamMatchesParse(
            format,
            'Plan it.\n',
            forcedOpen: true,
          );
        }
      });

      test('Qwen3-Coder XML ends a forced-open thought at a call', () async {
        for (final output in const [
          'Plan.\n$qwenXmlCall',
          'Plan.  $qwenXmlCall\nDone.',
          'Plan. <tool_c',
          'Plan. $qwenXmlCall\n</think>\nDone.',
        ]) {
          await _expectStreamMatchesParse(
            ChatFormat.qwen3CoderXml,
            output,
            forcedOpen: true,
            openings: const ['<tool_call>', '</think>'],
          );
        }
      });

      test('Command R holds back a bare JSON call array', () async {
        for (final output in const [
          'Let me check. [{"tool_call_id":"0","tool_name":"weather",'
              '"parameters":{"city":"Paris"}}]',
          'Use [x] or [ {"a": 1}] here.',
          'Let me check. <|START_TEXT|>Sure.<|END_TEXT|>',
        ]) {
          await _expectStreamMatchesParse(
            ChatFormat.commandR7B,
            output,
            openings: const ['[{"tool', '<|START_TEXT|>'],
          );
        }
      });

      test('DeepSeek holds back every tool-call opening', () async {
        for (final opening in const [
          '<｜tool▁calls▁begin｜>',
          '<｜tool_calls_begin｜>',
          '<｜tool calls begin｜>',
          r'<｜tool\_calls\_begin｜>',
          '<｜tool▁calls｜>',
        ]) {
          await _expectStreamMatchesParse(
            ChatFormat.deepseekR1,
            'Let me check.\n$opening<｜tool▁call▁begin｜>function'
            '<｜tool▁sep｜>weather\n```json\n{"city":"Paris"}\n```'
            '<｜tool▁call▁end｜><｜tool▁calls▁end｜>',
            openings: [opening],
          );
        }
      });

      test('Hunyuan V3 holds back a call and the end token', () async {
        for (final output in const [
          'Let me check.\n<tool_call:opensource>weather<tool_sep:opensource>'
              '\n<arg_key:opensource>city</arg_key:opensource>\n'
              '<arg_value:opensource>Paris</arg_value:opensource>\n'
              '</tool_call:opensource>',
          'Done.<｜hy_eos:opensource｜>',
        ]) {
          await _expectStreamMatchesParse(
            ChatFormat.hunyuanV3,
            output,
            openings: const ['<tool_call:opensource>', '<｜hy_eos'],
          );
        }
      });

      group('with a PEG parser', () {
        String parser(
          ChatTemplateHandler handler, {
          String templateSource = '{{ messages[0]["content"] }}',
          bool enableThinking = true,
        }) {
          return handler
              .render(
                templateSource: templateSource,
                messages: const [
                  LlamaChatMessage.fromText(
                    role: LlamaChatRole.user,
                    text: 'hello',
                  ),
                ],
                metadata: const {},
                tools: [_weatherTool],
                enableThinking: enableThinking,
              )
              .parser!;
        }

        const nemotronV3Template =
            '{% set truncate_history_thinking = true %}'
            '<tool_call><function><function=weather><parameters>'
            '<parameter=city><think>';

        test('Qwen3-Coder XML with a Nemotron V3 parser', () async {
          for (final format in const [
            ChatFormat.qwen3CoderXml,
            ChatFormat.pegConstructed,
          ]) {
            final withoutThinking = parser(
              Qwen3CoderXmlHandler(),
              templateSource: nemotronV3Template,
              enableThinking: false,
            );
            for (final output in outputs(format, qwenXmlCall).take(6)) {
              await _expectStreamMatchesParse(
                format,
                output,
                parser: withoutThinking,
                openings: const ['<tool_call>'],
              );
            }
            await _expectStreamMatchesParse(
              format,
              'Plan.\n</think>\nLet me check.\n$qwenXmlCall',
              forcedOpen: true,
              parser: parser(
                Qwen3CoderXmlHandler(),
                templateSource: '$nemotronV3Template\n',
              ),
              openings: const ['<tool_call>', '</think>'],
            );
          }
        });

        test('Ministral', () async {
          final ministral = parser(MinistralHandler());
          const call = '[TOOL_CALLS]weather[ARGS]{"city":"Paris"}';
          for (final format in const [
            ChatFormat.ministral,
            ChatFormat.pegNative,
          ]) {
            for (final output in [
              ...outputs(format, call).take(6),
              '[THINK]Plan.[/THINK]Let me check.\n$call',
            ]) {
              await _expectStreamMatchesParse(
                format,
                output,
                parser: ministral,
                openings: const ['[TOOL_CALLS]', '[/THINK]'],
              );
            }
          }
        });

        test('Solar Open', () async {
          final solarOpen = parser(SolarOpenHandler());
          for (final output in const [
            '<|content|>Let me check.\n<|end|><|begin|>assistant'
                '<|tool_calls|><|tool_call:begin|>0<|tool_call:name|>weather'
                '<|tool_call:args|>{"city":"Paris"}<|tool_call:end|>',
            '<|content|>If a < b, use {x} or [y].\n',
          ]) {
            await _expectStreamMatchesParse(
              ChatFormat.solarOpen,
              output,
              parser: solarOpen,
              openings: const ['<|end|>', '<|tool_calls|>'],
            );
          }
        });
      });

      test('Qwen3-Coder XML holds back only a possible opening', () {
        return _expectContentAfterEachToken(ChatFormat.qwen3CoderXml, const [
          ('If a', 'If a'),
          (' <', 'If a'),
          (' b,', 'If a < b,'),
          (' use <tool', 'If a < b, use'),
          ('s>.', 'If a < b, use <tools>.'),
          ('\n', 'If a < b, use <tools>.'),
          ('Let me check.\n<tool', 'If a < b, use <tools>.\nLet me check.'),
          ('_call>\n<function=', 'If a < b, use <tools>.\nLet me check.'),
        ]);
      });

      test('Mistral Nemo holds back only a possible opening', () {
        return _expectContentAfterEachToken(ChatFormat.mistralNemo, const [
          ('Use [x]', 'Use [x]'),
          (' or [TOOL', 'Use [x] or'),
          ('S].', 'Use [x] or [TOOLS].'),
          (' Let me check.[TOOL_', 'Use [x] or [TOOLS]. Let me check.'),
          ('CALLS][{"name', 'Use [x] or [TOOLS]. Let me check.'),
        ]);
      });

      group('forced-open thoughts', () {
        const hermesCall =
            '<tool_call>\n'
            '{"name": "weather", "arguments": {"city": "Paris"}}\n'
            '</tool_call>';
        final forcedGatedCalls = <ChatFormat, String>{
          ChatFormat.hermes: hermesCall,
          for (final MapEntry(key: format, value: call) in gatedCalls.entries)
            if (!ungatedWhenForcedOpen.contains(format)) format: call,
        };

        Future<void> expectForced(
          ChatFormat format,
          String output, {
          List<String> openings = const [],
        }) {
          final tags = ChatTemplateEngine.thinkingTagsFor(format.index);
          return _expectStreamMatchesParse(
            format,
            output,
            forcedOpen: true,
            openings: [tags.startTag, tags.endTag, ...openings],
          );
        }

        for (final MapEntry(key: format, value: call)
            in forcedGatedCalls.entries) {
          final tags = ChatTemplateEngine.thinkingTagsFor(format.index);
          final s = tags.startTag;
          final e = tags.endTag;

          test('${format.name} drops a repeated start tag', () async {
            for (final output in [
              '$s\nPlan.\n$e\n\nSure.',
              ' \n$s Plan.$e\nLet me check.\n$call',
              '$s\nPlan.\n$e\n\n$call',
              '$s\nPlan.',
              '$s\nPlan. $call',
              '$s $e\nSure.${s}More.$e',
              s,
              s.substring(0, 3),
            ]) {
              await expectForced(format, output, openings: [call]);
            }
          });

          test('${format.name} keeps a second end tag as content', () async {
            for (final output in [
              'Plan.$e\n${e}Text',
              'Plan.$e Text $e more.',
              'Plan.$e\n${e}Let me check.\n$call',
              '$e$e',
            ]) {
              await expectForced(format, output, openings: [call]);
            }
          });
        }

        test('ends a thought at a stray end tag after a start tag', () async {
          // The parse ends a thought at an end tag that follows a start tag
          // and keeps one as content otherwise. A stream can match only when
          // the tag arrives with the text before it.
          for (final (output, forcedOpen) in const [
            ('<think>\nPlan.</think>\nMore.</think> Sure.', true),
            ('Plan.</think>A<think>B</think>C</think>D', true),
            ('</think>Text </think> more.', false),
          ]) {
            final parsed = ChatTemplateEngine.parse(
              ChatFormat.hermes.index,
              output,
              thinkingForcedOpen: forcedOpen,
              tools: [_weatherTool],
            );
            final chunks = await ChatCompletionStreamParser.parse(
              tokenStream: Stream.value(output),
              templateResult: LlamaChatTemplateResult(
                prompt: 'prompt',
                format: ChatFormat.hermes.index,
                thinkingForcedOpen: forcedOpen,
              ),
              parseToolCallsEnabled: true,
              enableThinking: true,
              modelName: 'test-model',
              completionId: 'stray-end-tag',
              tools: [_weatherTool],
            ).toList();
            final deltas = chunks.map((chunk) => chunk.choices.single.delta);
            expect(
              deltas.map((delta) => delta.thinking ?? '').join(),
              parsed.reasoningContent ?? '',
              reason: output,
            );
            expect(
              deltas.map((delta) => delta.content ?? '').join(),
              parsed.content,
              reason: output,
            );
          }
        });

        test('the issue chunks stream the parsed reasoning', () async {
          for (final format in const [
            ChatFormat.deepseekR1,
            ChatFormat.qwen3CoderXml,
            ChatFormat.hermes,
          ]) {
            final chunks = await ChatCompletionStreamParser.parse(
              tokenStream: Stream.fromIterable(const [
                '<think>',
                '\n',
                'Plan',
                '.',
                '\n',
                '</think>',
                '\n\n',
                'Sure',
                '.',
              ]),
              templateResult: LlamaChatTemplateResult(
                prompt: 'prompt',
                format: format.index,
                thinkingForcedOpen: true,
              ),
              parseToolCallsEnabled: true,
              enableThinking: true,
              modelName: 'test-model',
              completionId: 'repeated-start-tag',
              tools: [_weatherTool],
            ).toList();
            final deltas = chunks.map((chunk) => chunk.choices.single.delta);
            expect(
              deltas.map((delta) => delta.thinking ?? '').join(),
              'Plan.',
              reason: format.name,
            );
            expect(
              deltas.map((delta) => delta.content ?? '').join(),
              'Sure.',
              reason: format.name,
            );
          }
        });

        test('Qwen3-Coder XML keeps escapes before a call', () async {
          for (final output in [
            r"Split on '\n'. Then call"
                '\n$qwenXmlCall',
            r'Plan \r\n x \\n.'
                ' $qwenXmlCall',
            r'Plan\r x.'
                ' $qwenXmlCall',
            r'Plan \n x.</think>Done.',
            r'Plan \n x.',
            r'Plan \',
          ]) {
            await expectForced(
              ChatFormat.qwen3CoderXml,
              output,
              openings: const [r'\n', r'\r', '<tool_call>'],
            );
          }
        });

        test(
          'DeepSeek V3 and EXAONE MoE keep an unended thought as content',
          () async {
            for (final format in unendedForcedThoughtIsContent) {
              final call = gatedCalls[format]!;
              final tags = ChatTemplateEngine.thinkingTagsFor(format.index);
              for (final output in [
                'Plan it out',
                'Plan it.\n',
                'Plan. $call',
                'Plan.\n$call\nDone.',
                '${tags.startTag}\nPlan.',
                '${tags.startTag}\nPlan.\n${tags.endTag}\n\nSure.',
              ]) {
                await expectForced(format, output, openings: [call]);
              }
            }
          },
        );

        test('reasoning streams as each token arrives', () async {
          await _expectStreamedAfterEachToken(
            ChatFormat.hermes,
            forcedOpen: true,
            const [
              ('Plan', 'Plan', ''),
              (' <tool', 'Plan <tool', ''),
              ('> x\n', 'Plan <tool> x', ''),
              ('</think>\n\nSure', 'Plan <tool> x', 'Sure'),
            ],
          );
          await _expectStreamedAfterEachToken(
            ChatFormat.hermes,
            forcedOpen: true,
            const [('<th', '', ''), ('ink>\nPlan', 'Plan', '')],
          );
          await _expectStreamedAfterEachToken(
            ChatFormat.qwen3CoderXml,
            forcedOpen: true,
            const [
              ('Plan', 'Plan', ''),
              (' <tool', 'Plan', ''),
              ('s> x', 'Plan <tools> x', ''),
              (r' \', 'Plan <tools> x', ''),
              ('n y', 'Plan <tools> x', ''),
              ('</think>', 'Plan <tools> x \n y', ''),
              ('<think>Next', 'Plan <tools> x \n y\nNext', ''),
              (' <tool', 'Plan <tools> x \n y\nNext <tool', ''),
              (r' \n z', 'Plan <tools> x \n y\nNext <tool \n z', ''),
            ],
          );
          await _expectStreamedAfterEachToken(
            ChatFormat.qwen3CoderXml,
            forcedOpen: true,
            const [
              ('<think>Plan', 'Plan', ''),
              (' <tool', 'Plan <tool', ''),
              (r' \n x', 'Plan <tool \n x', ''),
            ],
          );
          await _expectStreamedAfterEachToken(
            ChatFormat.deepseekV3,
            forcedOpen: true,
            const [
              ('Plan', '', ''),
              (' it.\n', '', ''),
              ('</think>', 'Plan it.', ''),
              ('Sure', 'Plan it.', 'Sure'),
              ('<think>More', 'Plan it.\nMore', 'Sure'),
            ],
          );
          await _expectStreamedAfterEachToken(ChatFormat.deepseekV3, const [
            ('<think>Plan', 'Plan', ''),
            (' it.', 'Plan it.', ''),
          ]);
        });
      });
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

const _hermesDoubleBrace =
    '<tool_call>\n{{"name": "weather", "arguments": {"city": "Paris"}}\n</tool_call>';

/// Splits [output] whole, into 1- and 2-character pieces, into random pieces,
/// and in two at every index inside each of [openings].
List<List<String>> _chunkings(String output, List<String> openings) {
  final random = Random(output.length);
  List<String> pieces(int Function() size) {
    final result = <String>[];
    for (var i = 0; i < output.length;) {
      final end = min(output.length, i + size());
      result.add(output.substring(i, end));
      i = end;
    }
    return result;
  }

  return [
    [output],
    pieces(() => 1),
    pieces(() => 2),
    for (var run = 0; run < 5; run++) pieces(() => 1 + random.nextInt(7)),
    for (final opening in openings)
      for (
        var at = output.indexOf(opening);
        at >= 0;
        at = output.indexOf(opening, at + 1)
      )
        for (var split = at + 1; split < at + opening.length; split++)
          [output.substring(0, split), output.substring(split)],
  ];
}

/// Expects streamed content, reasoning and calls of [output] to equal
/// [ChatTemplateEngine.parse] for every chunking.
Future<void> _expectStreamMatchesParse(
  ChatFormat format,
  String output, {
  bool forcedOpen = false,
  String? parser,
  List<String> openings = const [],
}) async {
  final parsed = ChatTemplateEngine.parse(
    format.index,
    output,
    thinkingForcedOpen: forcedOpen,
    parser: parser,
    tools: [_weatherTool],
  );
  for (final tokens in _chunkings(output, openings)) {
    final chunks = await ChatCompletionStreamParser.parse(
      tokenStream: Stream.fromIterable(tokens),
      templateResult: LlamaChatTemplateResult(
        prompt: 'prompt',
        format: format.index,
        thinkingForcedOpen: forcedOpen,
        parser: parser,
      ),
      parseToolCallsEnabled: true,
      enableThinking: true,
      modelName: 'test-model',
      completionId: 'stream-matches-parse',
      tools: [_weatherTool],
    ).toList();

    final calls = chunks
        .expand((chunk) => chunk.choices.single.delta.toolCalls ?? const [])
        .toList();
    expect(
      chunks.map((chunk) => chunk.choices.single.delta.content ?? '').join(),
      parsed.content,
      reason: '$tokens',
    );
    expect(
      chunks.map((chunk) => chunk.choices.single.delta.thinking ?? '').join(),
      parsed.reasoningContent ?? '',
      reason: '$tokens',
    );
    expect(
      [
        for (final call in calls)
          '${call.function?.name} ${call.function?.arguments}',
      ],
      [
        for (final call in parsed.toolCalls)
          '${call.function?.name} ${call.function?.arguments}',
      ],
      reason: '$tokens',
    );
    expect(
      chunks.last.choices.single.finishReason,
      parsed.hasToolCalls ? 'tool_calls' : 'stop',
    );
  }
}

/// Feeds each token of [steps] and expects the content streamed so far.
Future<void> _expectContentAfterEachToken(
  ChatFormat format,
  List<(String token, String streamed)> steps,
) async {
  final tokens = StreamController<String>();
  final content = StringBuffer();
  final subscription = ChatCompletionStreamParser.parse(
    tokenStream: tokens.stream,
    templateResult: LlamaChatTemplateResult(
      prompt: 'prompt',
      format: format.index,
    ),
    parseToolCallsEnabled: true,
    enableThinking: true,
    modelName: 'test-model',
    completionId: 'latency',
    tools: [_weatherTool],
  ).listen((chunk) => content.write(chunk.choices.single.delta.content ?? ''));
  addTearDown(subscription.cancel);
  addTearDown(tokens.close);

  for (final (token, streamed) in steps) {
    tokens.add(token);
    await pumpEventQueue();
    expect(content.toString(), streamed, reason: token);
  }
}

/// Feeds each token of [steps] and expects the reasoning and content streamed
/// so far.
Future<void> _expectStreamedAfterEachToken(
  ChatFormat format,
  List<(String token, String reasoning, String content)> steps, {
  bool forcedOpen = false,
}) async {
  final tokens = StreamController<String>();
  final reasoning = StringBuffer();
  final content = StringBuffer();
  final subscription =
      ChatCompletionStreamParser.parse(
        tokenStream: tokens.stream,
        templateResult: LlamaChatTemplateResult(
          prompt: 'prompt',
          format: format.index,
          thinkingForcedOpen: forcedOpen,
        ),
        parseToolCallsEnabled: true,
        enableThinking: true,
        modelName: 'test-model',
        completionId: 'latency',
        tools: [_weatherTool],
      ).listen((chunk) {
        reasoning.write(chunk.choices.single.delta.thinking ?? '');
        content.write(chunk.choices.single.delta.content ?? '');
      });
  addTearDown(subscription.cancel);
  addTearDown(tokens.close);

  for (final (token, streamedReasoning, streamedContent) in steps) {
    tokens.add(token);
    await pumpEventQueue();
    expect(reasoning.toString(), streamedReasoning, reason: token);
    expect(content.toString(), streamedContent, reason: token);
  }
}
