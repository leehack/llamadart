import 'dart:async';

import 'package:llamadart/llamadart.dart';
import 'package:test/test.dart';

class _IdleBackend implements LlamaBackend {
  @override
  void cancelGeneration() {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

typedef _Reply = Stream<LlamaCompletionChunk> Function();

/// Answers each [create] call with the next scripted reply and records the
/// messages and tool choice it was given.
class _ScriptedEngine extends LlamaEngine {
  _ScriptedEngine() : super(_IdleBackend());

  final List<_Reply> replies = [];
  final List<List<LlamaChatMessage>> requests = [];
  final List<ToolChoice?> toolChoices = [];
  int promptTokens = 0;

  @override
  Stream<LlamaCompletionChunk> create(
    List<LlamaChatMessage> messages, {
    GenerationParams? params,
    List<ToolDefinition>? tools,
    ToolChoice? toolChoice,
    bool parallelToolCalls = false,
    bool enableThinking = true,
    Map<String, dynamic>? responseFormat,
    String? sourceLangCode,
    String? targetLangCode,
    Map<String, dynamic>? chatTemplateKwargs,
    DateTime? templateNow,
  }) {
    requests.add(List.of(messages));
    toolChoices.add(toolChoice);
    if (replies.isEmpty) fail('unexpected request ${requests.length}');
    return replies.removeAt(0)();
  }

  @override
  Future<LlamaChatTemplateResult> chatTemplate(
    List<LlamaChatMessage> messages, {
    bool addAssistant = true,
    @Deprecated('Use responseFormat.') Map<String, dynamic>? jsonSchema,
    List<ToolDefinition>? tools,
    ToolChoice toolChoice = ToolChoice.auto,
    bool parallelToolCalls = false,
    bool enableThinking = true,
    Map<String, dynamic>? responseFormat,
    String? customTemplate,
    String? sourceLangCode,
    String? targetLangCode,
    bool includeTokenCount = true,
    Map<String, dynamic>? chatTemplateKwargs,
    DateTime? templateNow,
  }) async => LlamaChatTemplateResult(prompt: '', tokenCount: promptTokens);
}

LlamaCompletionChunk _chunk({
  String? content,
  List<LlamaCompletionChunkToolCall>? toolCalls,
  String? finishReason,
}) => LlamaCompletionChunk(
  id: 'c',
  object: 'chat.completion.chunk',
  created: 1,
  model: 'm',
  choices: [
    LlamaCompletionChunkChoice(
      index: 0,
      delta: LlamaCompletionChunkDelta(content: content, toolCalls: toolCalls),
      finishReason: finishReason,
    ),
  ],
);

_Reply _answer(String text) =>
    () => Stream.fromIterable([_chunk(content: text, finishReason: 'stop')]);

_Reply _calls(List<(String id, String name, String arguments)> calls) =>
    () => Stream.fromIterable([
      _chunk(
        toolCalls: [
          for (final (index, (id, name, arguments)) in calls.indexed)
            LlamaCompletionChunkToolCall(
              index: index,
              id: id,
              type: 'function',
              function: LlamaCompletionChunkFunction(
                name: name,
                arguments: arguments,
              ),
            ),
        ],
        finishReason: 'tool_calls',
      ),
    ]);

ToolDefinition _tool(String name, [ToolHandler? handler]) => ToolDefinition(
  name: name,
  description: 'The $name tool',
  parameters: [ToolParam.string('city')],
  handler: handler,
);

List<LlamaToolResultContent> _toolResults(ChatSession session) => [
  for (final message in session.history)
    if (message.role == LlamaChatRole.tool)
      ...message.parts.whereType<LlamaToolResultContent>(),
];

void main() {
  late _ScriptedEngine engine;
  late ChatSession session;

  setUp(() {
    engine = _ScriptedEngine();
    session = ChatSession(engine, maxContextTokens: 0);
  });

  test('runs a handler and returns the final answer', () async {
    engine.replies
      ..add(_calls([('call_1', 'weather', '{"city":"Seoul"}')]))
      ..add(_answer('Sunny in Seoul.'));
    final added = <LlamaChatMessage>[];

    final result = await session.sendWithTools(
      'Weather?',
      tools: [
        _tool('weather', (params) async => {'city': params.getString('city')}),
      ],
      toolChoice: ToolChoice.required,
      onMessageAdded: added.add,
    );

    expect(result.stopReason, LlamaToolLoopStopReason.completed);
    expect(result.text, 'Sunny in Seoul.');
    expect(result.rounds, 1);
    expect(result.pendingToolCalls, isEmpty);
    expect(engine.toolChoices, [ToolChoice.required, null]);
    expect(session.history.map((message) => message.role), [
      LlamaChatRole.user,
      LlamaChatRole.assistant,
      LlamaChatRole.tool,
      LlamaChatRole.assistant,
    ]);
    expect(added.map((message) => message.role), [
      LlamaChatRole.user,
      LlamaChatRole.assistant,
      LlamaChatRole.tool,
      LlamaChatRole.assistant,
    ]);
    final toolResult = _toolResults(session).single;
    expect(toolResult.id, 'call_1');
    expect(toolResult.name, 'weather');
    expect(toolResult.result, {'city': 'Seoul'});
    // The second request continues the turn: no new user message.
    expect(engine.requests[1].last.role, LlamaChatRole.tool);
  });

  test('runs parallel calls concurrently and records them in order', () async {
    engine.replies
      ..add(
        _calls([('a', 'slow', '{"city":"A"}'), ('b', 'fast', '{"city":"B"}')]),
      )
      ..add(_answer('done'));
    final slowGate = Completer<void>();
    final started = <String>[];

    final result = await session.sendWithTools(
      'Both',
      tools: [
        _tool('slow', (params) async {
          started.add('slow');
          await slowGate.future;
          return 'slow:${params.getString('city')}';
        }),
        _tool('fast', (params) async {
          started.add('fast');
          slowGate.complete();
          return 'fast:${params.getString('city')}';
        }),
      ],
      parallelToolCalls: true,
    );

    expect(result.stopReason, LlamaToolLoopStopReason.completed);
    expect(started, ['slow', 'fast']);
    expect(_toolResults(session).map((result) => (result.id, result.result)), [
      ('a', 'slow:A'),
      ('b', 'fast:B'),
    ]);
  });

  test('stops at maxRounds with the calls left unrun', () async {
    engine.replies
      ..add(_calls([('1', 'weather', '{}')]))
      ..add(_calls([('2', 'weather', '{}')]));
    var runs = 0;

    final result = await session.sendWithTools(
      'Loop',
      tools: [_tool('weather', (_) async => runs += 1)],
      maxRounds: 1,
    );

    expect(result.stopReason, LlamaToolLoopStopReason.maxRounds);
    expect(result.rounds, 1);
    expect(runs, 1);
    expect(result.pendingToolCalls.single.id, '2');
    expect(engine.requests, hasLength(2));
    expect(session.history.last.role, LlamaChatRole.assistant);
  });

  test('maxRounds 0 returns the first calls unrun', () async {
    engine.replies.add(_calls([('1', 'weather', '{}')]));

    final result = await session.sendWithTools(
      'Loop',
      tools: [_tool('weather', (_) async => fail('ran'))],
      maxRounds: 0,
    );

    expect(result.stopReason, LlamaToolLoopStopReason.maxRounds);
    expect(result.rounds, 0);
    expect(result.pendingToolCalls.single.name, 'weather');
  });

  test('rejects a negative maxRounds before sending', () async {
    await expectLater(
      session.sendWithTools('Hi', tools: const [], maxRounds: -1),
      throwsA(
        isA<LlamaArgumentException>().having(
          (e) => e.name,
          'name',
          'maxRounds',
        ),
      ),
    );
    expect(engine.requests, isEmpty);
    expect(session.history, isEmpty);
  });

  group('a tool without a handler', () {
    test('surfaces the round and runs none of its calls', () async {
      engine.replies.add(
        _calls([('a', 'weather', '{}'), ('b', 'approve', '{"city":"X"}')]),
      );
      var ran = false;

      final result = await session.sendWithTools(
        'Do it',
        tools: [_tool('weather', (_) async => ran = true), _tool('approve')],
      );

      expect(result.stopReason, LlamaToolLoopStopReason.unhandledToolCalls);
      expect(ran, isFalse);
      expect(result.pendingToolCalls.map((call) => call.id), ['a', 'b']);
      expect(_toolResults(session), isEmpty);
    });

    test('continues after the caller adds the results', () async {
      engine.replies
        ..add(_calls([('a', 'approve', '{}')]))
        ..add(_answer('Approved.'));
      final tools = [_tool('approve')];

      final first = await session.sendWithTools('Approve', tools: tools);
      final call = first.pendingToolCalls.single;
      session.addMessage(
        LlamaChatMessage.withContent(
          role: LlamaChatRole.tool,
          content: [
            LlamaToolResultContent(id: call.id, name: call.name, result: 'ok'),
          ],
        ),
      );
      final second = await session.completeWithTools(const [], tools: tools);

      expect(second.stopReason, LlamaToolLoopStopReason.completed);
      expect(second.text, 'Approved.');
      expect(
        session.history.where((m) => m.role == LlamaChatRole.user),
        hasLength(1),
      );
    });

    test('runs onToolCall instead', () async {
      engine.replies
        ..add(_calls([('a', 'approve', '{"city":"X"}')]))
        ..add(_answer('ok'));
      final seen = <LlamaToolCallContent>[];

      final result = await session.sendWithTools(
        'Approve',
        tools: [_tool('approve')],
        onToolCall: (call) {
          seen.add(call);
          return 'approved ${call.arguments['city']}';
        },
      );

      expect(result.stopReason, LlamaToolLoopStopReason.completed);
      expect(seen.single.id, 'a');
      expect(_toolResults(session).single.result, 'approved X');
    });
  });

  group('tool errors', () {
    test('become the tool result by default', () async {
      engine.replies
        ..add(
          _calls([
            ('a', 'weather', '{}'),
            ('b', 'missing', '{}'),
            ('c', 'weather', '[1]'),
          ]),
        )
        ..add(_answer('sorry'));

      final result = await session.sendWithTools(
        'Weather',
        tools: [
          _tool('weather', (params) async => params.getRequiredString('city')),
        ],
      );

      expect(result.stopReason, LlamaToolLoopStopReason.completed);
      final results = _toolResults(session);
      expect(results.map((result) => result.id), ['a', 'b', 'c']);
      expect(results[0].result, {
        'error': contains('Required parameter "city" is missing'),
      });
      expect(results[1].result, {
        'error': 'The model called the unknown tool "missing".',
      });
      expect(results[2].result, {
        'error':
            'The arguments of the call to "weather" are not a JSON object.',
      });
    });

    test('onToolError maps the error', () async {
      engine.replies
        ..add(_calls([('a', 'weather', '{}')]))
        ..add(_answer('sorry'));
      final errors = <Object>[];

      await session.sendWithTools(
        'Weather',
        tools: [_tool('weather', (_) async => throw StateError('offline'))],
        onToolError: (call, error, stackTrace) {
          errors.add(error);
          return 'failed: ${call.name}';
        },
      );

      expect(errors.single, isA<StateError>());
      expect(_toolResults(session).single.result, 'failed: weather');
    });

    test('a rethrow from onToolError fails the loop', () async {
      engine.replies.add(_calls([('a', 'weather', '{}'), ('b', 'ok', '{}')]));
      var okFinished = false;

      await expectLater(
        session.sendWithTools(
          'Weather',
          tools: [
            _tool('weather', (_) async => throw StateError('offline')),
            _tool('ok', (_) async {
              await Future<void>.delayed(Duration.zero);
              okFinished = true;
              return 'fine';
            }),
          ],
          onToolError: (call, error, stackTrace) =>
              Error.throwWithStackTrace(error, stackTrace),
        ),
        throwsA(isA<StateError>()),
      );

      expect(okFinished, isTrue);
      expect(_toolResults(session), isEmpty);
      expect(
        session.history.last.parts.whereType<LlamaToolCallContent>(),
        hasLength(2),
      );
    });
  });

  test('does not run calls proposed from a trimmed prompt', () async {
    session = ChatSession(engine, maxContextTokens: 256);
    engine.promptTokens = 10000;
    engine.replies.add(_calls([('a', 'weather', '{}')]));

    final result = await session.sendWithTools(
      'Weather',
      tools: [_tool('weather', (_) async => fail('ran'))],
    );

    expect(session.lastRequestFitContext, isFalse);
    expect(result.stopReason, LlamaToolLoopStopReason.contextExceeded);
    expect(result.pendingToolCalls.single.id, 'a');
  });

  group('cancelGeneration', () {
    test('during a tool stops after recording its result', () async {
      engine.replies.add(_calls([('a', 'weather', '{}')]));

      final result = await session.sendWithTools(
        'Weather',
        tools: [
          _tool('weather', (_) async {
            engine.cancelGeneration();
            return 'sunny';
          }),
        ],
      );

      expect(result.stopReason, LlamaToolLoopStopReason.cancelled);
      expect(result.rounds, 1);
      expect(result.pendingToolCalls, isEmpty);
      expect(engine.requests, hasLength(1));
      expect(_toolResults(session).single.result, 'sunny');
    });

    test('during generation stops without running calls', () async {
      engine.replies.add(() async* {
        engine.cancelGeneration();
        yield* _calls([('a', 'weather', '{}')])();
      });

      final result = await session.sendWithTools(
        'Weather',
        tools: [_tool('weather', (_) async => fail('ran'))],
      );

      expect(result.stopReason, LlamaToolLoopStopReason.cancelled);
      expect(result.rounds, 0);
      expect(result.pendingToolCalls.single.id, 'a');
    });

    test('issued before the loop does not affect it', () async {
      engine.cancelGeneration();
      engine.replies.add(_answer('hi'));

      final result = await session.sendWithTools('Hi', tools: const []);

      expect(result.stopReason, LlamaToolLoopStopReason.completed);
      expect(result.text, 'hi');
    });
  });

  test('an error from create fails the loop', () async {
    engine.replies.add(() => Stream.error(LlamaInferenceException('boom')));

    await expectLater(
      session.sendWithTools('Hi', tools: const []),
      throwsA(isA<LlamaInferenceException>()),
    );
    expect(session.history, isEmpty);
  });

  test('completeWithTools sends media parts as the user turn', () async {
    engine.replies.add(_answer('A cat.'));

    final result = await session.completeWithTools([
      const LlamaTextContent('What is this?'),
      LlamaImageContent(url: 'https://example.com/cat.png'),
    ], tools: const []);

    expect(result.text, 'A cat.');
    expect(session.history.first.parts, hasLength(2));
  });
}
