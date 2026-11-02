import 'dart:convert';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart/backend.dart';
import 'package:llamadart/src/core/engine/chat_completion_stream_parser.dart';
import 'package:test/test.dart';

const _opening = '<|tool_call_start|>';
const _closing = '<|tool_call_end|>';
const _routingTemplate =
    '{# <|tool_list_start|> <|tool_list_end|> <|tool_call_start|> #}'
    '{% for message in messages %}{{ message.content }}{% endfor %}';
final _tools = [
  ToolDefinition(
    name: 'weather',
    description: 'Weather',
    parameters: [ToolParam.string('city', required: true)],
    handler: (_) async => null,
  ),
];

LlamaChatTemplateResult _render(ToolChoice choice) => ChatTemplateEngine.render(
  templateSource: _routingTemplate,
  messages: const [
    LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'Weather?'),
  ],
  metadata: const {},
  tools: _tools,
  toolChoice: choice,
  parallelToolCalls: true,
);

String _envelope(String payload) => '$_opening$payload$_closing';

List<(String?, String?)> _calls(Iterable<LlamaCompletionChunkToolCall> calls) =>
    [for (final call in calls) (call.function?.name, call.function?.arguments)];

Future<void> _expectStream(
  String output,
  LlamaChatTemplateResult rendered, {
  bool tools = true,
}) async {
  expect(rendered.format, ChatFormat.lfm2.index);
  final parsed = ChatTemplateEngine.parseRendered(
    rendered,
    output,
    parseToolCalls: tools,
    tools: _tools,
  );
  final direct = ChatTemplateEngine.parse(
    rendered.format,
    output,
    parseToolCalls: tools,
    thinkingForcedOpen: rendered.thinkingForcedOpen,
    tools: _tools,
  );
  expect(direct.content, parsed.content);
  expect(direct.reasoningContent, parsed.reasoningContent);
  expect(_calls(direct.toolCalls), _calls(parsed.toolCalls));
  final partitions = [
    [output],
    output.split(''),
    for (var split = 1; split < output.length; split++)
      [output.substring(0, split), output.substring(split)],
  ];
  for (final tokens in partitions) {
    final chunks = await ChatCompletionStreamParser.parse(
      tokenStream: Stream.fromIterable(tokens),
      templateResult: rendered,
      parseToolCallsEnabled: tools,
      enableThinking: true,
      modelName: 'LFM2',
      completionId: 'quoted-delimiter',
      tools: _tools,
    ).toList();
    expect(
      chunks.map((c) => c.choices.single.delta.content ?? '').join(),
      parsed.content,
      reason: '$tokens',
    );
    expect(
      chunks.map((c) => c.choices.single.delta.thinking ?? '').join(),
      parsed.reasoningContent ?? '',
      reason: '$tokens',
    );
    expect(
      _calls(
        chunks.expand((c) => c.choices.single.delta.toolCalls ?? const []),
      ),
      _calls(parsed.toolCalls),
      reason: '$tokens',
    );
    expect(
      chunks.last.finishReason,
      parsed.hasToolCalls
          ? LlamaFinishReason.toolCalls
          : LlamaFinishReason.stop,
    );
  }
}

void main() {
  test('auto singleton trailing comma preserves one quoted argument', () async {
    final rendered = _render(ToolChoice.auto);
    const city = 'Seoul"), weather(city=';
    final output = _envelope("[weather(city='$city'), \n ]");
    final parsed = ChatTemplateEngine.parseRendered(
      rendered,
      output,
      tools: _tools,
    );
    expect(parsed.toolCalls, hasLength(1));
    expect(jsonDecode(parsed.toolCalls.single.function!.arguments!), {
      'city': city,
    });
    await _expectStream(output, rendered);
  });

  test(
    'public engine preserves calls before a later explicit thought',
    () async {
      const call = '<|tool_call_start|>[weather(city="Rome")]<|tool_call_end|>';
      final engine = LlamaEngine(
        _RawLfm2Backend(
          '$call<think>Thought</think>Answer.',
          template: '$_routingTemplate<think>',
        ),
      );
      addTearDown(engine.dispose);
      await engine.loadModel('LFM2-fixture.gguf');
      final completion = await engine.create(const [
        LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'Weather?'),
      ], tools: _tools).collect();
      expect(completion.thinking, 'Thought');
      expect(completion.text, 'Answer.');
      expect(completion.toolCalls, hasLength(1));
      expect(completion.toolCalls.single.arguments, {'city': 'Rome'});
    },
  );
  test('public engine keeps thought calls out of executable output', () async {
    const inner = '<|tool_call_start|>[weather(city="Paris")]<|tool_call_end|>';
    const outer = '<|tool_call_start|>[weather(city="Rome")]<|tool_call_end|>';
    final engine = LlamaEngine(
      _RawLfm2Backend('<think>Plan $inner more.</think>$outer'),
    );
    addTearDown(engine.dispose);
    await engine.loadModel('LFM2-fixture.gguf');
    final completion = await engine
        .create(
          const [
            LlamaChatMessage.fromText(
              role: LlamaChatRole.user,
              text: 'Weather?',
            ),
          ],
          tools: _tools,
          parallelToolCalls: true,
        )
        .collect();
    expect(completion.thinking, 'Plan $inner more.');
    expect(completion.text, isEmpty);
    expect(completion.toolCalls, hasLength(1));
    expect(completion.toolCalls.single.arguments, {'city': 'Rome'});
  });
  for (final choice in [ToolChoice.auto, ToolChoice.required]) {
    final rendered = _render(choice);
    for (final quote in ['"', "'"]) {
      for (final city in [
        'ordinary',
        'a${_closing}b',
        '$_closing$_closing',
        'Montréal $_closing 東京',
        '$_opening literal $_closing',
      ]) {
        final payload = '[weather(city=$quote$city$quote)]';
        test('${choice.name} Python $quote preserves $city', () async {
          final output = 'Before${_envelope(payload)}After';
          final parsed = ChatTemplateEngine.parseRendered(
            rendered,
            output,
            tools: _tools,
          );
          expect(parsed.content, 'BeforeAfter');
          expect(parsed.toolCalls, hasLength(1));
          expect(jsonDecode(parsed.toolCalls.single.function!.arguments!), {
            'city': city,
          });
          await _expectStream(output, rendered);
          await _expectStream(output, rendered, tools: false);
        });
      }
    }
    for (final city in [
      'a${_closing}b',
      'a"$_closing\\b',
      "apostrophe's $_closing",
    ]) {
      test('${choice.name} JSON quoted marker $city', () async {
        final payload = jsonEncode([
          {
            'name': 'weather',
            'arguments': {'city': city},
          },
        ]);
        final output = 'Before${_envelope(payload)}After';
        final parsed = ChatTemplateEngine.parseRendered(
          rendered,
          output,
          tools: _tools,
        );
        expect(parsed.content, 'BeforeAfter');
        expect(jsonDecode(parsed.toolCalls.single.function!.arguments!), {
          'city': city,
        });
        await _expectStream(output, rendered);
        await _expectStream(output, rendered, tools: false);
      });
    }
    test('${choice.name} keeps later calls and visible text', () async {
      final output =
          'Before${_envelope('[weather(city="a${_closing}b"), weather(city="Rome")]')}'
          'Between${_envelope('[weather(city="Seoul")]')}After';
      final parsed = ChatTemplateEngine.parseRendered(
        rendered,
        output,
        tools: _tools,
      );
      expect(parsed.content, 'BeforeBetweenAfter');
      expect(
        parsed.toolCalls
            .map((c) => jsonDecode(c.function!.arguments!)['city'])
            .toList(),
        ['a${_closing}b', 'Rome', 'Seoul'],
      );
      expect(parsed.toolCalls.map((c) => c.index), [0, 1, 2]);
      await _expectStream(output, rendered);
    });
    for (final payload in [
      '[weather(city="a${_closing}b")]',
      '[{"name":"weather","arguments":{"city":"a${_closing}b"}}]',
    ]) {
      test(
        '${choice.name} public engine uses the same delimiter: $payload',
        () async {
          final output = 'Before${_envelope(payload)}After';
          final backend = _RawLfm2Backend(output);
          final engine = LlamaEngine(backend);
          addTearDown(engine.dispose);
          await engine.loadModel('LFM2-fixture.gguf');
          final completion = await engine
              .create(
                const [
                  LlamaChatMessage.fromText(
                    role: LlamaChatRole.user,
                    text: 'Weather?',
                  ),
                ],
                tools: _tools,
                toolChoice: choice,
                parallelToolCalls: true,
                enableThinking: false,
              )
              .collect();
          expect(backend.promptPenaltyCalls, choice == ToolChoice.auto ? 1 : 0);
          expect(completion.text, 'BeforeAfter');
          expect(completion.toolCalls, hasLength(1));
          expect(completion.toolCalls.single.arguments, {
            'city': 'a${_closing}b',
          });
          expect(completion.finishReason, LlamaFinishReason.toolCalls);
        },
      );
    }
  }

  for (final output in [
    'Before$_opening[weather(city="a${_closing}b")]',
    'Before$_opening[weather(city="unterminated)]${_closing}After',
    'Before$_opening[weather(city=\')]${_closing}After',
    'Before${_opening}nonsense "a${_closing}b"$_closing After',
    '$_opening[weather(city="unterminated)]$_closing'
        '$_opening[weather(city="Seoul")]$_closing',
    "$_opening[weather(city='unterminated)]$_closing"
        "$_opening[weather(city='Seoul')]$_closing",
  ]) {
    test(
      'malformed/truncated input streams its final parse: $output',
      () async {
        await _expectStream(output, _render(ToolChoice.auto));
        await _expectStream(output, _render(ToolChoice.none), tools: false);
      },
    );
  }
}

// This parser fixture replays retained bytes; it does not qualify inference.
class _RawLfm2Backend implements LlamaBackend, BackendPromptPenaltyGeneration {
  _RawLfm2Backend(this.output, {this.template = _routingTemplate});
  final String output;
  final String template;
  int promptPenaltyCalls = 0;

  @override
  bool get supportsPromptPenaltiesWithGrammar => true;

  @override
  Stream<List<int>> generateWithPromptPenalties(
    int contextHandle,
    String prompt,
    GenerationParams params, {
    String? mediaMarker,
    List<LlamaContentPart>? parts,
  }) {
    promptPenaltyCalls++;
    return generate(contextHandle, prompt, params, parts: parts);
  }

  @override
  bool get supportsUrlLoading => false;
  @override
  Future<int> modelLoad(String path, ModelParams params) async => 1;
  @override
  Future<int> contextCreate(int modelHandle, ModelParams params) async => 1;
  @override
  Future<int> getContextSize(int contextHandle) async => 2048;
  @override
  Future<void> modelFree(int modelHandle) async {}
  @override
  Future<void> contextFree(int contextHandle) async {}
  @override
  Future<void> dispose() async {}
  @override
  Future<void> setLogLevel(LlamaLogLevel level) async {}
  @override
  Future<String> getBackendName() async => 'RawLfm2';
  @override
  Future<Map<String, String>> modelMetadata(int modelHandle) async => {
    'tokenizer.chat_template': template,
  };
  @override
  Future<List<int>> tokenize(
    int modelHandle,
    String text, {
    bool addSpecial = true,
  }) async => [1];
  @override
  Stream<List<int>> generate(
    int contextHandle,
    String prompt,
    GenerationParams params, {
    List<LlamaContentPart>? parts,
  }) async* {
    for (final character in output.split('')) {
      yield utf8.encode(character);
    }
  }

  @override
  void cancelGeneration() {}
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
