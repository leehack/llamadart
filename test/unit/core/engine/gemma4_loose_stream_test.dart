import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/core/engine/chat_completion_stream_parser.dart';
import 'package:test/test.dart';

import '../../../integration/core/engine/tool_calling_integration_test.dart';

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

class _GemmaBackend extends MockLlamaBackend {
  _GemmaBackend(this.template);

  final String template;

  @override
  Future<Map<String, String>> modelMetadata(int modelHandle) async => {
    'tokenizer.chat_template': template,
  };
}

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

  LlamaChatTemplateResult render({
    bool tools = true,
    bool parallelToolCalls = true,
  }) => ChatTemplateEngine.render(
    templateSource: template,
    messages: const [
      LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'Hi'),
    ],
    metadata: const {},
    tools: _tools,
    toolChoice: tools ? ToolChoice.auto : ToolChoice.none,
    parallelToolCalls: parallelToolCalls,
  );

  const oslo = '{"name":"weather","arguments":{"city":"Oslo"}}';
  const paris = '{"name":"weather","arguments":{"city":"Paris"}}';
  for (final explanation in [
    'would retrieve the current weather information.',
    'is my call',
  ]) {
    test('ChatSession leaves "$explanation" as text without dispatch', () async {
      final output = 'get_weather(location="Paris") $explanation';
      final backend = _GemmaBackend(template)
        ..queueResponse(output.split(''))
        ..queueResponse(['Done.']);
      final engine = LlamaEngine(backend);
      addTearDown(engine.dispose);
      await engine.loadModel('mock.gguf');
      var invocations = 0;
      final result = await ChatSession(engine, maxContextTokens: 0).sendWithTools(
        'Do not call any tool. Explain what get_weather(location="Paris") does.',
        tools: [
          ToolDefinition(
            name: 'get_weather',
            description: 'Weather',
            parameters: [ToolParam.string('location', required: true)],
            handler: (_) async {
              invocations++;
              return 'sunny';
            },
          ),
        ],
        toolChoice: ToolChoice.auto,
        enableThinking: false,
      );
      expect(invocations, 0);
      expect(result.stopReason, LlamaToolLoopStopReason.completed);
      expect(result.text, output);
    });
  }

  for (final (label, raw, cities) in [
    ('closed wrapper', '<tool_call>$oslo;$paris</tool_call>', ['Oslo']),
    ('unclosed wrapper', '<tool_call>$oslo;$paris', ['Oslo']),
    ('unwrapped continuation', '$oslo;$paris', ['Oslo', 'Paris']),
    ('native call', _native, ['Seoul']),
    (
      'native call after function-like prose',
      'weather(city="A") then later visible text $_native',
      ['Seoul'],
    ),
    (
      'function-like prose with another parenthetical',
      'weather(city="A") is a lesson (see below)',
      <String>[],
    ),
    ('unterminated call', 'weather(city="A)', <String>[]),
  ]) {
    test('Gemma 4 ChatSession dispatches expected calls for $label', () async {
      final backend = _GemmaBackend(template)
        ..queueResponse(raw.split(''))
        ..queueResponse(['Done.']);
      final engine = LlamaEngine(backend);
      addTearDown(engine.dispose);
      await engine.loadModel('mock.gguf');
      final invocations = <String>[];
      final result = await ChatSession(engine, maxContextTokens: 0)
          .sendWithTools(
            'Weather?',
            tools: [
              ToolDefinition(
                name: 'weather',
                description: 'Weather',
                parameters: [ToolParam.string('city', required: true)],
                handler: (params) async {
                  invocations.add(params.getRequiredString('city'));
                  return 'sunny';
                },
              ),
            ],
            toolChoice: ToolChoice.auto,
            parallelToolCalls: false,
            enableThinking: false,
          );
      expect(result.stopReason, LlamaToolLoopStopReason.completed);
      expect(invocations, cities);
    });
  }

  for (final (label, raw, content, reasoning, calls, tools) in [
    ('bare JSON', _json, '', '', [_weather], true),
    ('indented bare JSON', '\n  $_json', '', '', [_weather], true),
    ('prose before JSON', '$_prose $_json', '$_prose ', '', [_weather], true),
    (
      'indented prose before JSON',
      '\n\n$_prose $_json',
      '\n\n$_prose ',
      '',
      [_weather],
      true,
    ),
    (
      'archived Hermes wrapper',
      _archive,
      'Plan.</think>',
      '',
      [_getWeather],
      true,
    ),
    (
      'archived Hermes wrapper with trailing text',
      '$_archive\nDone.',
      'Plan.</think>\nDone.',
      '',
      [_getWeather],
      true,
    ),
    (
      'fenced bare JSON stays text',
      '```json\n$_json\n```',
      '```json\n$_json\n```',
      '',
      <(String, Map<String, String>)>[],
      true,
    ),
    (
      'prose before fenced JSON stays text',
      '$_prose\n```json\n$_json\n```',
      '$_prose\n```json\n$_json\n```',
      '',
      <(String, Map<String, String>)>[],
      true,
    ),
    (
      'tilde fenced JSON stays text',
      '$_prose\n~~~json\n$_json\n~~~\nDone.',
      '$_prose\n~~~json\n$_json\n~~~\nDone.',
      '',
      <(String, Map<String, String>)>[],
      true,
    ),
    (
      'literal text inside a fence before JSON stays text',
      '```json\nResult: $_json\n```',
      '```json\nResult: $_json\n```',
      '',
      <(String, Map<String, String>)>[],
      true,
    ),
    (
      'inline-backtick JSON stays text',
      'Run `$_json` now.',
      'Run `$_json` now.',
      '',
      <(String, Map<String, String>)>[],
      true,
    ),
    (
      'multi-backtick inline JSON stays text',
      'Run ``$_json`` now.',
      'Run ``$_json`` now.',
      '',
      <(String, Map<String, String>)>[],
      true,
    ),
    (
      'multiline inline-backtick JSON stays text',
      'Run `{\n"name":"weather","arguments":{"city":"Seoul"}\n}` now.',
      'Run `{\n"name":"weather","arguments":{"city":"Seoul"}\n}` now.',
      '',
      <(String, Map<String, String>)>[],
      true,
    ),
    (
      'inline-backtick span before declared loose call',
      'Use `foo` then $_json',
      'Use `foo` then ',
      '',
      [_weather],
      true,
    ),
    (
      'undeclared loose JSON name stays text',
      '$_prose {"name":"other","arguments":{"city":"Seoul"}}',
      '$_prose {"name":"other","arguments":{"city":"Seoul"}}',
      '',
      <(String, Map<String, String>)>[],
      true,
    ),
    (
      'schema JSON stays text',
      'Schema: {"type":"object","properties":{"city":{"type":"string"}}}',
      'Schema: {"type":"object","properties":{"city":{"type":"string"}}}',
      '',
      <(String, Map<String, String>)>[],
      true,
    ),
    (
      'schema JSON with nested declared name stays text',
      'Schema: {"type":"object","properties":{"sub":$_json}}',
      'Schema: {"type":"object","properties":{"sub":$_json}}',
      '',
      <(String, Map<String, String>)>[],
      true,
    ),
    (
      'declared call with trailing text',
      '$_prose $_json Then I will summarize.',
      '$_prose Then I will summarize.',
      '',
      [_weather],
      true,
    ),
    (
      'declared call without horizontal whitespace at junction',
      'Ok${_json}Done',
      'OkDone',
      '',
      [_weather],
      true,
    ),
    (
      'unpaired closing tag after bare call',
      '$_json</tool_call> Done',
      ' Done',
      '',
      [_weather],
      true,
    ),
    (
      'unpaired closing tag with prose around call',
      '$_prose $_json</tool_call> Done',
      '$_prose Done',
      '',
      [_weather],
      true,
    ),
    (
      'unpaired closing tag before call stays visible',
      '$_prose </tool_call> $_json',
      '$_prose </tool_call> ',
      '',
      [_weather],
      true,
    ),
    (
      'truncated closing tag after bare call',
      '$_prose $_json</tool_',
      '$_prose ',
      '',
      [_weather],
      true,
    ),
    (
      'trailing semicolon after loose call',
      '$_prose $_json;',
      '$_prose ',
      '',
      [_weather],
      true,
    ),
    (
      'semicolon separator before prose',
      '$_prose $_json; then done',
      '$_prose then done',
      '',
      [_weather],
      true,
    ),
    (
      'leading call with semicolon separator before prose',
      '$_json; then done',
      'then done',
      '',
      [_weather],
      true,
    ),
    (
      'semicolon separator before newline',
      '$_prose $_json;\nDone',
      '$_prose \nDone',
      '',
      [_weather],
      true,
    ),
    (
      'non-call JSON before declared call',
      'Use {"a":1} like this. $_json',
      'Use {"a":1} like this. ',
      '',
      [_weather],
      true,
    ),
    ('wrapped array', '$_prose [$_json]', '$_prose ', '', [_weather], true),
    (
      'parallel array calls',
      '$_prose [$_json,{"name":"get_weather","arguments":{"location":"Paris"}}]',
      '$_prose ',
      '',
      [_weather, _getWeather],
      true,
    ),
    (
      'parallel JSON',
      '$_prose $_json;$_json',
      '$_prose ',
      '',
      [_weather, _weather],
      true,
    ),
    (
      'parallel JSON with trailing text',
      '$_prose $_json; $_json; bye',
      '$_prose bye',
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
      'loose JSON recovered after a malformed native envelope',
      'Pre <|tool_call>call:f{a:<|"|>x<tool_call|>$_json',
      'Pre ',
      '',
      [_weather],
      true,
    ),
    (
      'undeclared loose JSON after a malformed native envelope stays text',
      'Pre <|tool_call>call:f{a:<|"|>x<tool_call|>'
          '{"name":"rm","arguments":{"path":"/"}}',
      'Pre {"name":"rm","arguments":{"path":"/"}}',
      '',
      <(String, Map<String, String>)>[],
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
      'semicolon before closing tag',
      '$_prose $_json;</tool_call> Done',
      '$_prose Done',
      '',
      [_weather],
      true,
    ),
    (
      'semicolon inside unclosed tool_call tag',
      '$_prose <tool_call>$_json; Done',
      '$_prose Done',
      '',
      [_weather],
      true,
    ),
    (
      'semicolon after closed tool_call tag stays',
      '$_prose <tool_call>$_json</tool_call>; Done',
      '$_prose ; Done',
      '',
      [_weather],
      true,
    ),
    (
      'CR before semicolon stays',
      '$_prose $_json\r; then',
      '$_prose \r; then',
      '',
      [_weather],
      true,
    ),
    (
      'trailing spaces after bare call keep junction space',
      '$_prose $_json  ',
      '$_prose ',
      '',
      [_weather],
      true,
    ),
    (
      'leading spaces before call with trailing prose',
      '  $_json  Done',
      ' Done',
      '',
      [_weather],
      true,
    ),
    (
      'declared function syntax',
      'weather(city="Seoul")',
      '',
      '',
      [_weather],
      true,
    ),
    (
      'declared function syntax with trailing prose',
      'weather(city="Seoul") is a lesson (see below)',
      'weather(city="Seoul") is a lesson (see below)',
      '',
      <(String, Map<String, String>)>[],
      true,
    ),
    (
      'declared function call strips a trailing separator and closing tag',
      'weather(city="Seoul"); </tool_call> ',
      '',
      '',
      [_weather],
      true,
    ),
    (
      'parenthetical after a declared tool name stays text',
      'weather (humidity) means relative humidity.',
      'weather (humidity) means relative humidity.',
      '',
      <(String, Map<String, String>)>[],
      true,
    ),
    (
      'indented declared function syntax',
      '\n  weather(city="Seoul")',
      '',
      '',
      [_weather],
      true,
    ),
    (
      'undeclared function syntax stays text',
      'rm(path="/")',
      'rm(path="/")',
      '',
      <(String, Map<String, String>)>[],
      true,
    ),
    (
      'undeclared dotted function syntax stays text',
      'os.system(cmd="ls")',
      'os.system(cmd="ls")',
      '',
      <(String, Map<String, String>)>[],
      true,
    ),
    (
      'function syntax with tools disabled stays text',
      'weather(city="Seoul")',
      'weather(city="Seoul")',
      '',
      <(String, Map<String, String>)>[],
      false,
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

  final code = StringBuffer('Here is the class:\n```js\nclass Store {\n')
    ..writeln('  constructor() { this.items = {}; }');
  for (var i = 0; i < 40; i++) {
    code.writeln('  method$i(x) {\n    return x + $i;\n  }');
  }
  code.write('}\n```\nThat is the full store implementation.');
  final prose = List.filled(400, 'word').join(' ');
  for (final (label, raw) in [
    ('JavaScript class', code.toString()),
    ('brace emoticon', 'Smile :-{ $prose'),
    ('brace key', 'Press the { key. $prose'),
    ('invalid array', 'Display this; [true, plain text. $prose'),
  ]) {
    test('Gemma 4 $label keeps streaming before EOF', () async {
      final rendered = render();
      final controller = StreamController<String>();
      final content = StringBuffer();
      final done = _stream(controller.stream, rendered, true).forEach((chunk) {
        final choice = chunk.choices.single;
        content.write(choice.delta.content ?? '');
        expect(choice.delta.toolCalls ?? const [], isEmpty);
      });
      var maxHeld = 0;
      try {
        for (var start = 0; start < raw.length; start += 4) {
          final end = (start + 4).clamp(0, raw.length);
          controller.add(raw.substring(start, end));
          await pumpEventQueue(times: 2);
          final held = end - content.length;
          if (held > maxHeld) maxHeld = held;
          expect(raw, startsWith(content.toString()));
        }
        // Includes the existing periodic snapshot interval, measured in bytes
        // of scripted input rather than wall time.
        expect(maxHeld, lessThanOrEqualTo(48));
      } finally {
        await controller.close();
        await done;
      }
      final parsed = ChatTemplateEngine.parseRendered(
        rendered,
        raw,
        tools: _tools,
      );
      expect(parsed.toolCalls, isEmpty);
      expect(parsed.content, raw);
      expect(content.toString(), raw);
    });
  }

  test('partial JSON releases at the first impossible token', () {
    final rendered = render();
    for (final (maybe, impossible) in [
      ('{ ', 'k'),
      ('{\n  ', 'c'),
      ('["item", ', 'p'),
      ('{"name":"weather" ', '!'),
      ('{"name":"weather","arguments":{"count":1e+', 'x'),
      ('{"name":"weather","arguments":{"ready":tr', 'x'),
      (r'{"name":"weather","arguments":{"city":"a\u12', 'x'),
      ('{"name":"weather","arguments":{}', '!'),
      ('{"name":"weather","arguments":{"city":"a', '\n'),
      (r'{"name":"weather","arguments":{"city":"a\', 'q'),
      ('[1', 'x'),
      ('{"name"', 'x'),
    ]) {
      const prose = 'Before; ';
      final pending = ChatTemplateEngine.parseRendered(
        rendered,
        '$prose$maybe',
        isPartial: true,
        tools: _tools,
      );
      expect(pending.content, prose, reason: maybe);
      final rejected = ChatTemplateEngine.parseRendered(
        rendered,
        '$prose$maybe$impossible',
        isPartial: true,
        tools: _tools,
      );
      expect(rejected.content, '$prose$maybe$impossible', reason: maybe);
    }
  });

  test('valid loose JSON remains held through strings, scalars and escapes', () {
    final rendered = render();
    const raw =
        r'{"name":weather,"arguments":{"a":[true,false,null,-1.2e+3,"\u2601","\n","a;b"]}}';
    const prose = 'Before ';
    for (var cut = 1; cut < raw.length; cut++) {
      final parsed = ChatTemplateEngine.parseRendered(
        rendered,
        '$prose${raw.substring(0, cut)}',
        isPartial: true,
        tools: _tools,
      );
      expect(parsed.content, prose, reason: 'cut $cut');
    }
    final parsed = ChatTemplateEngine.parseRendered(
      rendered,
      '$prose$raw',
      tools: _tools,
    );
    expect(parsed.content, prose);
    expect(parsed.toolCalls.single.function?.name, 'weather');
  });

  test('a recovered inner object stays private in an open array', () async {
    final rendered = render();
    const prefix = '[null,$_json';
    final partial = ChatTemplateEngine.parseRendered(
      rendered,
      prefix,
      isPartial: true,
      tools: _tools,
    );
    expect(partial.toolCalls.single.index, 0);
    expect(partial.content, isEmpty);
    final raw = '$prefix]';
    final complete = ChatTemplateEngine.parseRendered(
      rendered,
      raw,
      tools: _tools,
    );
    expect(complete.toolCalls.single.index, 1);
    final chunks = await _stream(
      Stream.fromIterable([prefix, ']']),
      rendered,
      true,
    ).toList();
    expect(_content(chunks), isEmpty);
    expect(chunks.last.choices.single.delta.toolCalls!.single.index, 1);
  });

  test('streaming releases undeclared name and schema JSON before }', () async {
    for (final (label, prefix, tail) in [
      (
        'undeclared name',
        'Try {"name":"other"',
        ',"arguments":{"city":"Seoul","extra":"long"}}',
      ),
      (
        'schema JSON',
        'Schema: {"type":"object"',
        ',"properties":{"city":{"type":"string"}}}',
      ),
    ]) {
      final controller = StreamController<String>();
      final chunks = <LlamaCompletionChunk>[];
      final done = _stream(
        controller.stream,
        render(),
        true,
      ).forEach(chunks.add);
      try {
        for (final token in prefix.split('')) {
          controller.add(token);
        }
        // Trigger a signal-driven partial parse without closing the object.
        await Future<void>.delayed(const Duration(milliseconds: 30));
        controller.add(',');
        await pumpEventQueue(times: 4);
        expect(_content(chunks), '$prefix,', reason: label);
        controller.add(tail.substring(1));
      } finally {
        await controller.close();
        await done;
      }
      expect(_content(chunks), '$prefix$tail', reason: label);
      expect(chunks.last.choices.single.finishReason, 'stop', reason: label);
    }
  });

  test(
    'streaming releases fenced and inline-backtick JSON before EOF',
    () async {
      final fencedController = StreamController<String>();
      final fencedChunks = <LlamaCompletionChunk>[];
      final fencedDone = _stream(
        fencedController.stream,
        render(),
        true,
      ).forEach(fencedChunks.add);
      try {
        for (final token in ['Look:\n```json\n', '{"name":"weather",']) {
          fencedController.add(token);
        }
        await Future<void>.delayed(const Duration(milliseconds: 30));
        fencedController.add('"city"');
        await pumpEventQueue(times: 4);
        expect(
          _content(fencedChunks),
          'Look:\n```json\n{"name":"weather","city"',
        );
        fencedController.add('}\n```');
      } finally {
        await fencedController.close();
        await fencedDone;
      }
      expect(
        _content(fencedChunks),
        'Look:\n```json\n{"name":"weather","city"}\n```',
      );
      expect(fencedChunks.last.choices.single.finishReason, 'stop');

      final inlineController = StreamController<String>();
      final inlineChunks = <LlamaCompletionChunk>[];
      final inlineDone = _stream(
        inlineController.stream,
        render(),
        true,
      ).forEach(inlineChunks.add);
      try {
        for (final token in [
          'Run `',
          '{"name":"weather",',
          '"arguments":{"city":"Seoul"}}',
          '`',
        ]) {
          inlineController.add(token);
        }
        await pumpEventQueue(times: 4);
        expect(_content(inlineChunks), 'Run `');

        for (final token in [
          ' ',
          'next',
          ' ',
          'step',
          ' ',
          'now',
          ' ',
          'ok.',
        ]) {
          inlineController.add(token);
        }
        await pumpEventQueue(times: 4);
        expect(_content(inlineChunks), 'Run `$_json` next step');
      } finally {
        await inlineController.close();
        await inlineDone;
      }
      expect(_content(inlineChunks), 'Run `$_json` next step now ok.');
      expect(inlineChunks.last.choices.single.finishReason, 'stop');
    },
  );

  test(
    'streaming holds trailing text after a declared loose call until EOF',
    () async {
      final controller = StreamController<String>();
      final chunks = <LlamaCompletionChunk>[];
      final done = _stream(
        controller.stream,
        render(),
        true,
      ).forEach(chunks.add);
      try {
        controller.add('$_prose $_json');
        await pumpEventQueue(times: 4);
        expect(_content(chunks), _prose);

        for (final token in [
          ' Then',
          ' I',
          ' will',
          ' soon',
          ' explain',
          ' all',
          ' of',
          ' it.',
        ]) {
          controller.add(token);
        }
        await pumpEventQueue(times: 4);
        expect(_content(chunks), _prose);
        expect(
          chunks.every((chunk) => chunk.choices.single.finishReason == null),
          isTrue,
        );
      } finally {
        await controller.close();
        await done;
      }
      expect(_content(chunks), '$_prose Then I will soon explain all of it.');
      expect(chunks.last.choices.single.finishReason, 'tool_calls');
      expect(
        chunks.last.choices.single.delta.toolCalls!.single.function?.name,
        'weather',
      );
    },
  );

  const nativeBody = '<|tool_call>call:weather{city:<|"|>Seoul<|"|>}';
  const functionProse = 'weather(city="A") then later visible text ';
  for (final parallel in [false, true]) {
    for (final (termination, cancelled, limit) in [
      ('EOF', false, false),
      ('cancellation', true, false),
      ('token limit', false, true),
      ('cancellation at the token limit', true, true),
    ]) {
      test(
        'native call after function-like prose at $termination (parallel: $parallel)',
        () async {
          final rendered = render(parallelToolCalls: parallel);
          const raw = '$functionProse$_native';
          final parsed = ChatTemplateEngine.parseRendered(
            rendered,
            raw,
            tools: _tools,
          );
          expect(parsed.content, functionProse);
          expect(parsed.toolCalls.map(_callValue), _expectedCalls([_weather]));
          await _expectStream(
            Stream.fromIterable(raw.split('')),
            rendered,
            functionProse,
            '',
            [_weather],
            true,
            termination,
            cancelled: cancelled,
            stoppedAtLimit: limit,
          );
        },
      );
    }

    for (final (label, prefix, live, fallbackContent) in [
      ('standalone function', 'weather(city="A")', '', ''),
      (
        'indented function with residue',
        '\n\t weather(city="A"); </tool_call>\t ',
        '',
        '',
      ),
      (
        'loose JSON with preamble and wrapper',
        'Intro:\t <tool_call>{"name":"weather","arguments":{"city":"A"}}; </tool_call>\t then later visible text ',
        'Intro:',
        'Intro: then later visible text ',
      ),
    ]) {
      test(
        '$label restores literal text only when native wins (parallel: $parallel)',
        () async {
          final rendered = render(parallelToolCalls: parallel);
          for (final nativeWins in [false, true]) {
            final controller = StreamController<String>();
            final chunks = <LlamaCompletionChunk>[];
            final done = _stream(
              controller.stream,
              rendered,
              true,
            ).forEach(chunks.add);
            try {
              controller.add(prefix);
              await pumpEventQueue(times: 4);
              expect(_content(chunks), live);
              expect(
                chunks.expand(
                  (chunk) => chunk.choices.single.delta.toolCalls ?? [],
                ),
                isEmpty,
              );
              if (nativeWins) {
                await Future<void>.delayed(const Duration(milliseconds: 30));
                controller.add(nativeBody);
                for (var i = 0; i < 8; i++) {
                  controller.add(' ');
                }
                await pumpEventQueue(times: 4);
                expect(_content(chunks), prefix.trimRight());
                expect(
                  chunks.expand(
                    (chunk) => chunk.choices.single.delta.toolCalls ?? [],
                  ),
                  isEmpty,
                );
                controller.add('<tool_call|>');
              }
            } finally {
              await controller.close();
              await done;
            }
            expect(_content(chunks), nativeWins ? prefix : fallbackContent);
            final terminal = chunks.last.choices.single;
            expect(terminal.finishReason, 'tool_calls');
            expect(
              terminal.delta.toolCalls!.map(_callValue),
              _expectedCalls([
                nativeWins ? _weather : ('weather', {'city': 'A'}),
              ]),
            );
          }
        },
      );
    }
  }

  test(
    'cancel and length limit strip trailing semicolon and truncated closing tag',
    () async {
      final rendered = render();
      for (final (label, tokens, expectedContent) in [
        ('bare truncated close tag', ['$_json</tool_'], ''),
        ('wrapped truncated close tag', ['<tool_call>$_json', '</tool_'], ''),
        (
          'prose with truncated close tag',
          ['$_prose $_json', '</tool_'],
          '$_prose ',
        ),
        ('prose with trailing semicolon', ['$_prose $_json', ';'], '$_prose '),
        ('bare trailing semicolon', [_json, '; '], ''),
        (
          'prose with semicolon and truncated close tag',
          ['$_prose $_json', ';', '</tool_'],
          '$_prose ',
        ),
        (
          'wrapped unclosed semicolon',
          ['$_prose <tool_call>$_json', '; '],
          '$_prose ',
        ),
      ]) {
        for (final atLimit in [false, true]) {
          final chunks = await ChatCompletionStreamParser.parse(
            tokenStream: Stream.fromIterable(tokens),
            templateResult: rendered,
            parseToolCallsEnabled: true,
            enableThinking: true,
            modelName: 'gemma4',
            completionId: 'gemma4-residue-$label-$atLimit',
            tools: _tools,
            cancelled: () => !atLimit,
            stoppedAtLimit: () => atLimit,
          ).toList();
          expect(
            _content(chunks),
            expectedContent,
            reason: '$label (limit=$atLimit)',
          );
          expect(
            chunks.last.choices.single.finishReason,
            atLimit ? 'length' : 'tool_calls',
            reason: '$label (limit=$atLimit)',
          );
        }
      }
    },
  );

  test(
    'streaming releases an impossible function argument list early',
    () async {
      const impossible = 'weather (humidity)';
      final tokens = [
        'weather',
        ' (humidity)',
        ' means ',
        ...List.filled(128, 'another word of prose '),
      ];
      final raw = tokens.join();
      final rendered = render();
      var charactersRead = 0;
      int? firstVisibleAt;
      final chunks = <LlamaCompletionChunk>[];

      Stream<String> source() async* {
        for (final token in tokens) {
          charactersRead += token.length;
          yield token;
        }
      }

      await for (final chunk in _stream(source(), rendered, true)) {
        if ((chunk.choices.single.delta.content ?? '').isNotEmpty) {
          firstVisibleAt ??= charactersRead;
        }
        chunks.add(chunk);
      }
      expect(firstVisibleAt, lessThanOrEqualTo(impossible.length + 4 * 22));
      expect(_content(chunks), raw);
      expect(
        _content(chunks),
        ChatTemplateEngine.parseRendered(rendered, raw, tools: _tools).content,
      );
      expect(chunks.last.choices.single.finishReason, 'stop');
    },
  );

  for (final atLimit in [false, true]) {
    test(
      'unterminated quoted function argument at ${atLimit ? 'limit' : 'cancel'} stays text',
      () async {
        const raw = 'weather(city="A)';
        final chunks = await ChatCompletionStreamParser.parse(
          tokenStream: Stream.fromIterable(raw.split('')),
          templateResult: render(),
          parseToolCallsEnabled: true,
          enableThinking: true,
          modelName: 'gemma4',
          completionId: 'gemma4-unterminated-function',
          tools: _tools,
          cancelled: () => !atLimit,
          stoppedAtLimit: () => atLimit,
        ).toList();
        expect(_content(chunks), raw);
        expect(chunks.last.choices.single.delta.toolCalls, isNull);
        expect(
          chunks.last.choices.single.finishReason,
          atLimit ? 'length' : 'stop',
        );
      },
    );
  }

  test(
    'function-call syntax matches final parse at every prefix and cancel/limit',
    () async {
      final rendered = render();
      for (final (label, raw, tools) in [
        ('declared', 'weather(city="Seoul")', _tools),
        ('unclosed nested argument', 'weather(city=lookup(a', _tools),
        ('closed nested argument', 'weather(city=lookup(a))', _tools),
        ('function followed by prose', functionProse, _tools),
        ('undeclared', 'rm(path="/")', _tools),
        ('undeclared dotted', 'os.system(cmd="ls")', _tools),
        ('shared-prefix undeclared', 'get_other(location="Paris")', _tools),
        ('prose starting with tool name', 'weather is sunny today.', _tools),
        ('no tools', 'weather(city="Seoul")', const <ToolDefinition>[]),
      ]) {
        final finalParsed = ChatTemplateEngine.parseRendered(
          rendered,
          raw,
          tools: tools,
        );
        for (var i = 1; i <= raw.length; i++) {
          final prefix = raw.substring(0, i);
          final partial = ChatTemplateEngine.parseRendered(
            rendered,
            prefix,
            isPartial: true,
            tools: tools,
          );
          expect(
            finalParsed.content,
            startsWith(partial.content.trimRight()),
            reason: '$label @$i',
          );

          final expectedPrefixFinal = ChatTemplateEngine.parseRendered(
            rendered,
            prefix,
            tools: tools,
          );
          for (final atLimit in [false, true]) {
            for (final charwise in [true, false]) {
              final chunks = await ChatCompletionStreamParser.parse(
                tokenStream: Stream.fromIterable(
                  charwise ? prefix.split('') : [prefix],
                ),
                templateResult: rendered,
                parseToolCallsEnabled: true,
                enableThinking: true,
                modelName: 'gemma4',
                completionId: 'gemma4-func-$label-$i-$atLimit-$charwise',
                tools: tools,
                cancelled: () => !atLimit,
                stoppedAtLimit: () => atLimit,
              ).toList();
              expect(
                _content(chunks),
                expectedPrefixFinal.content,
                reason: '$label @$i limit=$atLimit charwise=$charwise',
              );
            }
          }
        }
      }
    },
  );

  test(
    'streaming releases undeclared function-call names once name fails to match',
    () async {
      final rendered = render();
      for (final (label, prefix, tail, tools) in [
        ('undeclared', 'rm(', 'path="/")', _tools),
        ('shared-prefix', 'get_o', 'ther(location="Paris")', _tools),
        ('boundary mismatch', 'get(', 'location="Paris")', _tools),
        ('prose after name', 'weather i', 's clear today.', _tools),
        ('no tools', 'weather(', 'city="Seoul")', const <ToolDefinition>[]),
      ]) {
        final controller = StreamController<String>();
        final chunks = <LlamaCompletionChunk>[];
        final done = ChatCompletionStreamParser.parse(
          tokenStream: controller.stream,
          templateResult: rendered,
          parseToolCallsEnabled: true,
          enableThinking: true,
          modelName: 'gemma4',
          completionId: 'gemma4-func-release-$label',
          tools: tools,
        ).forEach(chunks.add);
        try {
          for (final token
              in prefix.substring(0, prefix.length - 1).split('')) {
            controller.add(token);
          }
          await Future<void>.delayed(const Duration(milliseconds: 30));
          controller.add(prefix[prefix.length - 1]);
          await pumpEventQueue(times: 4);
          expect(_content(chunks), prefix, reason: label);
          controller.add(tail);
        } finally {
          await controller.close();
          await done;
        }
        expect(_content(chunks), '$prefix$tail', reason: label);
        expect(chunks.last.choices.single.finishReason, 'stop', reason: label);
      }

      final declaredController = StreamController<String>();
      final declaredChunks = <LlamaCompletionChunk>[];
      final declaredDone = _stream(
        declaredController.stream,
        rendered,
        true,
      ).forEach(declaredChunks.add);
      try {
        for (final token in 'weather(city="Seoul"'.split('')) {
          declaredController.add(token);
        }
        await pumpEventQueue(times: 4);
        expect(_content(declaredChunks), isEmpty);
        declaredController.add(')');
      } finally {
        await declaredController.close();
        await declaredDone;
      }
      expect(_content(declaredChunks), isEmpty);
      expect(declaredChunks.last.choices.single.finishReason, 'tool_calls');
      expect(
        declaredChunks
            .last
            .choices
            .single
            .delta
            .toolCalls!
            .single
            .function
            ?.name,
        'weather',
      );
    },
  );
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
  bool tools, {
  bool cancelled = false,
  bool stoppedAtLimit = false,
}) => ChatCompletionStreamParser.parse(
  tokenStream: tokens,
  templateResult: rendered,
  parseToolCallsEnabled: tools,
  enableThinking: true,
  modelName: 'gemma4',
  completionId: 'gemma4-loose-stream',
  tools: _tools,
  cancelled: () => cancelled,
  stoppedAtLimit: () => stoppedAtLimit,
);

Future<void> _expectStream(
  Stream<String> tokens,
  LlamaChatTemplateResult rendered,
  String content,
  String reasoning,
  List<(String, Map<String, String>)> calls,
  bool tools,
  String partition, {
  bool cancelled = false,
  bool stoppedAtLimit = false,
}) async {
  var visible = '';
  var thought = '';
  var terminal = false;
  var deltaIndex = 0;
  final expectedCalls = stoppedAtLimit
      ? _expectedCalls([])
      : _expectedCalls(calls);
  await for (final chunk in _stream(
    tokens,
    rendered,
    tools,
    cancelled: cancelled,
    stoppedAtLimit: stoppedAtLimit,
  )) {
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
      expect(
        choice.finishReason,
        stoppedAtLimit
            ? 'length'
            : calls.isEmpty
            ? 'stop'
            : 'tool_calls',
      );
      expect(emitted.map(_callValue), expectedCalls);
      expect(emitted.map((call) => call.id), [
        for (var i = 0; i < expectedCalls.length; i++) 'call_$i',
      ]);
    }
  }
  expect(terminal, isTrue, reason: partition);
  expect(visible, content, reason: partition);
  expect(thought, reasoning, reason: partition);
}
