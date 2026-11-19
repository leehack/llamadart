import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/core/engine/chat_completion_stream_parser.dart';
import 'package:test/test.dart';

const _prose = 'The weather looks clear.';
const _json = '{"name":"weather","arguments":{"city":"Seoul"}}';
const _archive =
    'Plan.</think><tool_call>\n'
    '{"name": "get_weather", "arguments": {"location": "Paris"}}\n'
    '</tool_call>';
const _native = '<|tool_call>call:weather{city:<|"|>Seoul<|"|>}<tool_call|>';
const _weather = ('weather', <String, String>{'city': 'Seoul'});
const _getWeather = ('get_weather', <String, String>{'location': 'Paris'});

final _tools = [
  ToolDefinition(
    name: 'weather',
    description: 'Weather',
    parameters: [ToolParam.string('city', required: true)],
  ),
  ToolDefinition(
    name: 'get_weather',
    description: 'Weather',
    parameters: [ToolParam.string('location', required: true)],
  ),
];

void main() {
  late String template;
  setUpAll(() async {
    const path = 'test/fixtures/templates/gemma-4-E2B-it.jinja';
    if (Uri.base.scheme == 'file') {
      template = await File(path).readAsString();
    } else {
      final response = await http.get(Uri.base.resolve('../../../../$path'));
      expect(response.statusCode, 200);
      template = utf8.decode(response.bodyBytes);
    }
  });

  LlamaChatTemplateResult render({bool tools = true}) =>
      ChatTemplateEngine.render(
        templateSource: template,
        messages: const [
          LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'Hi'),
        ],
        metadata: const {},
        tools: _tools,
        toolChoice: tools ? ToolChoice.auto : ToolChoice.none,
        parallelToolCalls: true,
      );

  for (final (label, raw, content, reasoning, calls, tools) in [
    ('bare JSON', _json, '', '', [_weather], true),
    ('prose before JSON', '$_prose $_json', '$_prose ', '', [_weather], true),
    (
      'archived Hermes wrapper',
      _archive,
      'Plan.</think>',
      '',
      [_getWeather],
      true,
    ),
    ('wrapped bare JSON', '```json\n$_json\n```', '', '', [_weather], true),
    (
      'prose before a fence',
      '$_prose\n```json\n$_json\n```',
      '$_prose\n',
      '',
      [_weather],
      true,
    ),
    (
      'literal text inside a fence before JSON',
      '```json\nResult: $_json\n```',
      '```json\nResult: ',
      '',
      [_weather],
      true,
    ),
    ('wrapped array', '$_prose [$_json]', '$_prose ', '', [_weather], true),
    (
      'parallel JSON',
      '$_prose $_json;$_json',
      '$_prose ',
      '',
      [_weather, _weather],
      true,
    ),
    (
      'ordinary JSON before a semicolon and a call',
      'Display {"forecast":"sun"}; then $_json',
      'Display {"forecast":"sun"}; then ',
      '',
      [_weather],
      true,
    ),
    (
      'native envelope after loose JSON',
      '$_prose $_json$_native Done. \n',
      '$_prose $_json Done. \n',
      '',
      [_weather],
      true,
    ),
    (
      'ordinary reply',
      _prose,
      _prose,
      '',
      <(String, Map<String, String>)>[],
      true,
    ),
    (
      'ordinary JSON',
      'Display {"forecast":"sun"}.',
      'Display {"forecast":"sun"}.',
      '',
      <(String, Map<String, String>)>[],
      true,
    ),
    (
      'malformed loose JSON',
      '$_prose {"name":',
      '$_prose {"name":',
      '',
      <(String, Map<String, String>)>[],
      true,
    ),
    (
      'thinking before loose JSON',
      '<|channel>thought\nPlan.<channel|>$_prose $_json',
      '$_prose ',
      'Plan.',
      [_weather],
      true,
    ),
    (
      'JSON with tools disabled',
      '$_prose $_json',
      '$_prose $_json',
      '',
      <(String, Map<String, String>)>[],
      false,
    ),
  ]) {
    test('Gemma 4 $label matches final parse at every split', () async {
      final rendered = render(tools: tools);
      expect(rendered.format, ChatFormat.gemma4.index);
      final parsed = ChatTemplateEngine.parseRendered(
        rendered,
        raw,
        parseToolCalls: tools,
        tools: _tools,
      );
      expect(parsed.content, content, reason: 'final content');
      expect(
        parsed.reasoningContent ?? '',
        reasoning,
        reason: 'final reasoning',
      );
      expect(
        parsed.toolCalls.map(_callValue),
        _expectedCalls(calls),
        reason: 'final calls',
      );
      await _expectStream(
        Stream.value(raw),
        rendered,
        content,
        reasoning,
        calls,
        tools,
        'whole',
      );
      await _expectStream(
        Stream.fromIterable(raw.split('')),
        rendered,
        content,
        reasoning,
        calls,
        tools,
        'character',
      );
      for (var first = 1; first < raw.length; first++) {
        await _expectStream(
          Stream.fromIterable([raw.substring(0, first), raw.substring(first)]),
          rendered,
          content,
          reasoning,
          calls,
          tools,
          'cut $first',
        );
        for (var second = first + 1; second < raw.length; second += 7) {
          await _expectStream(
            Stream.fromIterable([
              raw.substring(0, first),
              raw.substring(first, second),
              raw.substring(second),
            ]),
            rendered,
            content,
            reasoning,
            calls,
            tools,
            'cuts $first/$second',
          );
        }
      }
    });
  }

  test(
    'known prose and thinking arrive while the JSON suffix is pending',
    () async {
      final controller = StreamController<String>();
      final chunks = <LlamaCompletionChunk>[];
      final done = _stream(
        controller.stream,
        render(),
        true,
      ).forEach(chunks.add);
      try {
        controller.add('<|channel>thought\nPlan.<channel|>The');
        await pumpEventQueue();
        expect(_content(chunks), 'The');
        expect(
          chunks
              .map((chunk) => chunk.choices.single.delta.thinking ?? '')
              .join(),
          'Plan.',
        );

        for (final token in [
          ' weather',
          ' looks',
          ' clear.',
          ' ',
          '{',
          '"name"',
          ':"weather"',
          ',',
        ]) {
          controller.add(token);
        }
        await pumpEventQueue();
        expect(_content(chunks), _prose);
        expect(
          chunks.every((chunk) => chunk.choices.single.finishReason == null),
          isTrue,
        );
        expect(
          chunks.every(
            (chunk) => chunk.choices.single.delta.toolCalls?.isEmpty ?? true,
          ),
          isTrue,
        );
        controller.add('"arguments":{"city":"Seoul"}}');
      } finally {
        await controller.close();
        await done;
      }
      expect(_content(chunks), '$_prose ');
      expect(chunks.last.choices.single.finishReason, 'tool_calls');
    },
  );

  for (final paced in [false, true]) {
    test(
      'bare JSON is private on the ${paced ? "paced" : "immediate"} schedule',
      () async {
        Stream<String> tokens() async* {
          yield '{';
          yield '"name"';
          if (paced) {
            await Future<void>.delayed(const Duration(milliseconds: 60));
          }
          yield ':"weather",';
          yield '"arguments":{"city":"Seoul"}}';
        }

        await _expectStream(
          tokens(),
          render(),
          '',
          '',
          [_weather],
          true,
          'paced=$paced',
        );
      },
    );
  }

  test('completed ordinary JSON resumes visible output before EOF', () async {
    final controller = StreamController<String>();
    final chunks = <LlamaCompletionChunk>[];
    final done = _stream(controller.stream, render(), true).forEach(chunks.add);
    try {
      controller.add('Display {"forecast":"sun"}.');
      await pumpEventQueue();
      expect(_content(chunks), 'Display {"forecast":"sun"}.');
      expect(
        chunks.every((chunk) => chunk.choices.single.finishReason == null),
        isTrue,
      );
    } finally {
      await controller.close();
      await done;
    }
  });
}

String _content(Iterable<LlamaCompletionChunk> chunks) =>
    chunks.map((chunk) => chunk.choices.single.delta.content ?? '').join();

List<Object?> _callValue(LlamaCompletionChunkToolCall call) => [
  call.index,
  call.type,
  call.function?.name,
  jsonDecode(call.function!.arguments!),
];

List<List<Object?>> _expectedCalls(List<(String, Map<String, String>)> calls) =>
    [
      for (final (index, (name, args)) in calls.indexed)
        [index, 'function', name, args],
    ];

Stream<LlamaCompletionChunk> _stream(
  Stream<String> tokens,
  LlamaChatTemplateResult rendered,
  bool tools,
) => ChatCompletionStreamParser.parse(
  tokenStream: tokens,
  templateResult: rendered,
  parseToolCallsEnabled: tools,
  enableThinking: true,
  modelName: 'gemma4',
  completionId: 'gemma4-loose-stream',
  tools: _tools,
);

Future<void> _expectStream(
  Stream<String> tokens,
  LlamaChatTemplateResult rendered,
  String content,
  String reasoning,
  List<(String, Map<String, String>)> calls,
  bool tools,
  String partition,
) async {
  var visible = '';
  var thought = '';
  var terminal = false;
  var deltaIndex = 0;
  await for (final chunk in _stream(tokens, rendered, tools)) {
    final choice = chunk.choices.single;
    final delta = choice.delta;
    final reason =
        '$partition, delta ${deltaIndex++}: ${jsonEncode([delta.content, delta.thinking])}';
    expect(terminal, isFalse, reason: reason);
    visible += delta.content ?? '';
    thought += delta.thinking ?? '';
    expect(content, startsWith(visible), reason: reason);
    expect(reasoning, startsWith(thought), reason: reason);
    final emitted = delta.toolCalls ?? const [];
    if (choice.finishReason == null) {
      expect(emitted, isEmpty, reason: reason);
    } else {
      terminal = true;
      expect(choice.finishReason, calls.isEmpty ? 'stop' : 'tool_calls');
      expect(emitted.map(_callValue), _expectedCalls(calls));
      expect(emitted.map((call) => call.id), [
        for (var i = 0; i < calls.length; i++) 'call_$i',
      ]);
    }
  }
  expect(terminal, isTrue, reason: partition);
  expect(visible, content, reason: partition);
  expect(thought, reasoning, reason: partition);
}
