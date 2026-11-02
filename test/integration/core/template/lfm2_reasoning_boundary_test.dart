import 'dart:convert';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/core/engine/chat_completion_stream_parser.dart';
import 'package:test/test.dart';

final _tools = [
  ToolDefinition(
    name: 'weather',
    description: 'Weather',
    parameters: [ToolParam.string('city', required: true)],
  ),
];
const _inner = '<|tool_call_start|>[weather(city="Paris")]<|tool_call_end|>';
const _outer = '<|tool_call_start|>[weather(city="Rome")]<|tool_call_end|>';

void main() {
  for (final scenario in [
    (
      name: 'closed thought',
      raw: '<think>Plan $_inner more.</think>Answer.',
      forced: false,
      content: 'Answer.',
      reasoning: 'Plan $_inner more.',
      cities: <String>[],
    ),
    (
      name: 'outer call after thought',
      raw: '<think>Plan $_inner more.</think>$_outer',
      forced: false,
      content: '',
      reasoning: 'Plan $_inner more.',
      cities: ['Rome'],
    ),
    (
      name: 'forced-open thought',
      raw: 'Plan $_inner more.</think>Answer.',
      forced: true,
      content: 'Answer.',
      reasoning: 'Plan $_inner more.',
      cities: <String>[],
    ),
    (
      name: 'unclosed thought',
      raw: '<think>Plan $_inner more.',
      forced: false,
      content: '',
      reasoning: 'Plan $_inner more.',
      cities: <String>[],
    ),
    (
      name: 'several thoughts and outside siblings',
      raw:
          'Before$_outer<think>A $_inner</think> '
          '<think>B $_inner</think>$_outer After',
      forced: false,
      content: 'Before  After',
      reasoning: 'A $_inner\nB $_inner',
      cities: ['Rome', 'Rome'],
    ),
    (
      name: 'thought close inside call-like reasoning is a channel boundary',
      raw:
          '<think>Plan <|tool_call_start|>[weather(city="</think>")]'
          '<|tool_call_end|>Between$_outer',
      forced: false,
      content: '")]<|tool_call_end|>Between',
      reasoning: 'Plan <|tool_call_start|>[weather(city="',
      cities: ['Rome'],
    ),
  ]) {
    test('LFM reasoning boundary ${scenario.name}', () async {
      final rendered = LlamaChatTemplateResult(
        prompt: '',
        format: ChatFormat.lfm2.index,
        thinkingForcedOpen: scenario.forced,
      );
      final direct = ChatTemplateEngine.parseRendered(
        rendered,
        scenario.raw,
        tools: _tools,
      );
      expect(direct.content, scenario.content);
      expect(direct.reasoningContent, scenario.reasoning);
      expect(
        direct.toolCalls.map((c) => jsonDecode(c.function!.arguments!)['city']),
        scenario.cities,
      );
      expect(direct.toolCalls.map((c) => c.index), [
        for (var i = 0; i < scenario.cities.length; i++) i,
      ]);
      final partitions = [
        [scenario.raw],
        scenario.raw.split(''),
        for (var i = 1; i < scenario.raw.length; i++)
          [scenario.raw.substring(0, i), scenario.raw.substring(i)],
      ];
      for (final tokens in partitions) {
        for (final ending in ['natural', 'length', 'cancel']) {
          final completion = await ChatCompletionStreamParser.parse(
            tokenStream: Stream.fromIterable(tokens),
            templateResult: rendered,
            parseToolCallsEnabled: true,
            enableThinking: true,
            modelName: 'LFM2',
            completionId: 'reasoning-boundary',
            tools: _tools,
            stoppedAtLimit: () => ending == 'length',
            cancelled: () => ending == 'cancel',
          ).collect();
          expect(completion.text, scenario.content, reason: '$ending/$tokens');
          expect(completion.thinking, scenario.reasoning);
          expect(
            completion.toolCalls.map((call) => call.arguments['city']),
            ending == 'length' ? isEmpty : scenario.cities,
          );
        }
      }
    });
  }

  test(
    'direct parsing retains legacy preopened inference without prompt context',
    () {
      final result = ChatTemplateEngine.parse(
        ChatFormat.lfm2.index,
        'Plan $_inner more.</think>Answer.',
        tools: _tools,
      );
      expect(result.toolCalls, isEmpty);
      expect(result.content, 'Answer.');
      expect(result.reasoningContent, 'Plan $_inner more.');
    },
  );

  test('partial body envelopes cannot expose quoted thought tags', () {
    const partial =
        'Before<|tool_call_start|>[weather(city="<think>literal</think>"';
    final result = ChatTemplateEngine.parse(
      ChatFormat.lfm2.index,
      partial,
      tools: _tools,
      isPartial: true,
    );
    expect(result.content, 'Before');
    expect(result.reasoningContent, isNull);
    expect(result.toolCalls, isEmpty);
  });

  test(
    'hidden reasoning and tool choice none preserve separate controls',
    () async {
      const raw = '<think>Plan $_inner more.</think>Answer.';
      for (final parseTools in [false, true]) {
        final completion = await ChatCompletionStreamParser.parse(
          tokenStream: Stream.fromIterable(raw.split('')),
          templateResult: LlamaChatTemplateResult(
            prompt: '',
            format: ChatFormat.lfm2.index,
          ),
          parseToolCallsEnabled: parseTools,
          enableThinking: false,
          modelName: 'LFM2',
          completionId: 'hidden-reasoning',
          tools: _tools,
        ).collect();
        expect(completion.text, 'Answer.');
        expect(completion.thinking, isEmpty);
        expect(completion.toolCalls, isEmpty);
      }
    },
  );

  for (final city in [
    '<think>literal</think>',
    '</think>',
    '<think>',
    '<|tool_call_end|></think>',
    '<think><|tool_call_end|></think>',
  ]) {
    test('LFM quoted thought tags stay argument data $city', () async {
      final raw =
          '<|tool_call_start|>[weather(city="$city")]<|tool_call_end|>$_outer';
      final result = await ChatCompletionStreamParser.parse(
        tokenStream: Stream.fromIterable(raw.split('')),
        templateResult: LlamaChatTemplateResult(
          prompt: '',
          format: ChatFormat.lfm2.index,
        ),
        parseToolCallsEnabled: true,
        enableThinking: true,
        modelName: 'LFM2',
        completionId: 'literal-thinking',
        tools: _tools,
      ).collect();
      expect(result.thinking, isEmpty);
      expect(result.text, isEmpty);
      expect(result.toolCalls.map((c) => c.arguments['city']), [city, 'Rome']);
    });
  }

  test('split reasoning escapes wait for the following token', () async {
    const raw = r'<think>Plan\nline\rbackslash\</think>' + _outer;
    for (final size in [1, 2, 7, raw.length]) {
      final result = await ChatCompletionStreamParser.parse(
        tokenStream: Stream.fromIterable([
          for (var i = 0; i < raw.length; i += size)
            raw.substring(i, i + size < raw.length ? i + size : raw.length),
        ]),
        templateResult: LlamaChatTemplateResult(
          prompt: '',
          format: ChatFormat.lfm2.index,
        ),
        parseToolCallsEnabled: true,
        enableThinking: true,
        modelName: 'LFM2',
        completionId: 'reasoning-escapes',
        tools: _tools,
      ).collect();
      expect(result.thinking, 'Plan\nline\rbackslash\\');
      expect(result.toolCalls.single.arguments, {'city': 'Rome'});
    }
  });

  test('partial reasoning does not commit a pending escape prefix', () async {
    final result = await ChatCompletionStreamParser.parse(
      tokenStream: Stream.fromIterable([
        '<think>',
        ...'ABCDEFG'.split(''),
        r'\',
        'nline</think>',
        _outer,
      ]),
      templateResult: LlamaChatTemplateResult(
        prompt: '',
        format: ChatFormat.lfm2.index,
      ),
      parseToolCallsEnabled: true,
      enableThinking: true,
      modelName: 'LFM2',
      completionId: 'pending-escape',
      tools: _tools,
    ).collect();
    expect(result.thinking, 'ABCDEFG\nline');
    expect(result.toolCalls.single.arguments, {'city': 'Rome'});
  });

  test('Kimi retains its independent calls-inside-thoughts policy', () {
    const call =
        '<|tool_calls_section_begin|><|tool_call_begin|>functions.weather:0'
        '<|tool_call_argument_begin|>{"city":"Paris"}'
        '<|tool_call_end|><|tool_calls_section_end|>';
    final result = ChatTemplateEngine.parse(
      ChatFormat.kimiK2.index,
      '<think>Plan $call more.</think>Answer.',
      tools: _tools,
    );
    expect(result.toolCalls, hasLength(1));
    expect(result.reasoningContent, 'Plan  more.');
    expect(result.content, 'Answer.');
  });
}
