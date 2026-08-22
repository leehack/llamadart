import 'dart:convert';

import 'package:llamadart/src/core/engine/chat_completion_stream_parser.dart';
import 'package:llamadart/src/core/models/chat/chat_template_result.dart';
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
  });
}

final _weatherTool = ToolDefinition(
  name: 'weather',
  description: 'Weather',
  parameters: [ToolParam.string('city', required: true)],
  handler: (_) async => null,
);
