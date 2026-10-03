import 'dart:async';

import 'package:llamadart/llamadart.dart';
import 'package:test/test.dart';

import '../../../support/scripted_chat_engine.dart';

ToolDefinition _tool(String name, [ToolHandler? handler]) => ToolDefinition(
  name: name,
  description: 'The $name tool',
  parameters: [ToolParam.string('city')],
  handler: handler,
);

LlamaChatMessage _text(LlamaChatRole role, String text) =>
    LlamaChatMessage.fromText(role: role, text: text);

LlamaChatMessage _result(LlamaToolCallContent call, Object? result) =>
    LlamaChatMessage.withContent(
      role: LlamaChatRole.tool,
      content: [
        LlamaToolResultContent(id: call.id, name: call.name, result: result),
      ],
    );

List<LlamaChatRole> _roles(Iterable<LlamaChatMessage> messages) => [
  for (final message in messages) message.role,
];

/// A [ChatSession] subclass that mirrors the history it is given.
class _PersistingSession extends ChatSession {
  _PersistingSession(super.engine) : super(maxContextTokens: 0);

  final List<LlamaChatMessage> stored = [];
  int resets = 0;

  @override
  void addMessage(LlamaChatMessage message) {
    super.addMessage(message);
    stored.add(message);
  }

  @override
  void reset({bool keepSystemPrompt = true}) {
    resets += 1;
    super.reset(keepSystemPrompt: keepSystemPrompt);
  }
}

/// A [ChatSession] subclass that stores a copy of each added message.
class _CopyingSession extends ChatSession {
  _CopyingSession(super.engine) : super(maxContextTokens: 0);

  @override
  void addMessage(LlamaChatMessage message) => super.addMessage(
    LlamaChatMessage.withContent(role: message.role, content: message.parts),
  );
}

/// A `ChatSession` that only forwards its public members, and whose [reset]
/// drops the system prompt unless told otherwise.
class _DelegatingSession implements ChatSession {
  _DelegatingSession(this._inner);

  final ChatSession _inner;

  @override
  LlamaEngine get engine => _inner.engine;

  @override
  List<LlamaChatMessage> get history => _inner.history;

  @override
  bool get lastRequestFitContext => _inner.lastRequestFitContext;

  @override
  void addMessage(LlamaChatMessage message) => _inner.addMessage(message);

  @override
  void reset({bool keepSystemPrompt = false}) =>
      _inner.reset(keepSystemPrompt: keepSystemPrompt);

  @override
  Stream<LlamaCompletionChunk> create(
    List<LlamaContentPart> parts, {
    GenerationParams? params,
    List<ToolDefinition>? tools,
    ToolChoice? toolChoice,
    bool parallelToolCalls = false,
    bool enableThinking = true,
    Map<String, dynamic>? responseFormat,
    Map<String, dynamic>? chatTemplateKwargs,
    void Function(LlamaChatMessage message)? onMessageAdded,
    bool continuesPreviousTurn = false,
  }) => _inner.create(
    parts,
    params: params,
    tools: tools,
    toolChoice: toolChoice,
    parallelToolCalls: parallelToolCalls,
    enableThinking: enableThinking,
    responseFormat: responseFormat,
    chatTemplateKwargs: chatTemplateKwargs,
    onMessageAdded: onMessageAdded,
    continuesPreviousTurn: continuesPreviousTurn,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

List<LlamaToolResultContent> _toolResults(ChatSession session) => [
  for (final message in session.history)
    if (message.role == LlamaChatRole.tool)
      ...message.parts.whereType<LlamaToolResultContent>(),
];

void main() {
  late ScriptedChatEngine engine;
  late ChatSession session;

  setUp(() {
    engine = ScriptedChatEngine();
    session = ChatSession(engine, maxContextTokens: 0);
  });

  test('runs a handler and returns the final answer', () async {
    engine.replies
      ..add(scriptedCalls([('call_1', 'weather', '{"city":"Seoul"}')]))
      ..add(scriptedAnswer('Sunny in Seoul.'));
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
        scriptedCalls([
          ('a', 'slow', '{"city":"A"}'),
          ('b', 'fast', '{"city":"B"}'),
        ]),
      )
      ..add(scriptedAnswer('done'));
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
      ..add(scriptedCalls([('1', 'weather', '{}')]))
      ..add(scriptedCalls([('2', 'weather', '{}')]));
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
    expect(result.rolledBack, isTrue);
    expect(session.history, isEmpty);
    expect(_roles(result.messages), [
      LlamaChatRole.user,
      LlamaChatRole.assistant,
      LlamaChatRole.tool,
      LlamaChatRole.assistant,
    ]);
  });

  test('a rolled-back turn keeps earlier turns and can be resumed', () async {
    final earlier = [
      _text(LlamaChatRole.user, 'Hi'),
      _text(LlamaChatRole.assistant, 'Hello'),
    ];
    earlier.forEach(session.addMessage);
    engine.replies
      ..add(scriptedCalls([('1', 'weather', '{}')]))
      ..add(scriptedAnswer('Sunny.'));
    final tools = [_tool('weather', (_) async => fail('ran'))];

    final stopped = await session.sendWithTools(
      'Weather',
      tools: tools,
      maxRounds: 0,
    );

    expect(stopped.stopReason, LlamaToolLoopStopReason.maxRounds);
    expect(session.history, orderedEquals(earlier));

    stopped.messages.forEach(session.addMessage);
    session.addMessage(_result(stopped.pendingToolCalls.single, 'sunny'));
    final resumed = await session.completeWithTools(const [], tools: tools);

    expect(resumed.stopReason, LlamaToolLoopStopReason.completed);
    expect(resumed.rolledBack, isFalse);
    expect(resumed.text, 'Sunny.');
    expect(_roles(session.history), [
      LlamaChatRole.user,
      LlamaChatRole.assistant,
      LlamaChatRole.user,
      LlamaChatRole.assistant,
      LlamaChatRole.tool,
      LlamaChatRole.assistant,
    ]);
    expect(resumed.messages, orderedEquals(session.history.skip(2)));
  });

  group('a continuation', () {
    final earlier = [
      _text(LlamaChatRole.user, 'Hi'),
      _text(LlamaChatRole.assistant, 'Hello'),
    ];

    Future<List<LlamaChatMessage>> openTurn(List<ToolDefinition> tools) async {
      earlier.forEach(session.addMessage);
      engine.replies.add(scriptedCalls([('1', 'approve', '{}')]));
      final first = await session.sendWithTools('Delete it', tools: tools);
      expect(first.stopReason, LlamaToolLoopStopReason.unhandledToolCalls);
      expect(first.rolledBack, isFalse);
      session.addMessage(_result(first.pendingToolCalls.single, 'approved'));
      return session.history.skip(2).toList();
    }

    test('that stops early rolls back the whole open turn', () async {
      final tools = [_tool('approve'), _tool('weather', (_) async => 'x')];
      final open = await openTurn(tools);
      engine.replies.add(scriptedCalls([('2', 'weather', '{}')]));

      final result = await session.completeWithTools(
        const [],
        tools: tools,
        maxRounds: 0,
      );

      expect(result.stopReason, LlamaToolLoopStopReason.maxRounds);
      expect(result.rolledBack, isTrue);
      expect(session.history, orderedEquals(earlier));
      expect(result.messages.take(3), orderedEquals(open));
      expect(_roles(result.messages), [
        LlamaChatRole.user,
        LlamaChatRole.assistant,
        LlamaChatRole.tool,
        LlamaChatRole.assistant,
      ]);
    });

    test('that throws rolls back the whole open turn', () async {
      final tools = [_tool('approve')];
      await openTurn(tools);
      engine.replies.add(() => Stream.error(LlamaInferenceException('boom')));

      await expectLater(
        session.completeWithTools(const [], tools: tools),
        throwsA(isA<LlamaInferenceException>()),
      );
      expect(session.history, orderedEquals(earlier));
    });

    test('includes user-role continuations of the open turn', () async {
      final call = LlamaToolCallContent(
        id: '1',
        name: 'approve',
        arguments: const {},
        rawJson: '{}',
      );
      earlier.forEach(session.addMessage);
      session
        ..addMessage(_text(LlamaChatRole.user, 'Delete it'))
        ..addMessage(
          LlamaChatMessage.withContent(
            role: LlamaChatRole.assistant,
            content: [call],
          ),
        )
        ..addMessage(
          const LlamaChatMessage.fromText(
            role: LlamaChatRole.user,
            text: 'approved',
            continuesPreviousTurn: true,
          ),
        );
      engine.replies.add(scriptedCalls([('2', 'weather', '{}')]));

      final result = await session.completeWithTools(
        const [],
        tools: [_tool('weather', (_) async => 'x')],
        maxRounds: 0,
      );

      expect(result.rolledBack, isTrue);
      expect(session.history, orderedEquals(earlier));
      expect(result.messages, hasLength(4));
    });

    test('keeps an earlier turn that shares a const message', () async {
      const question = LlamaChatMessage.fromText(
        role: LlamaChatRole.user,
        text: 'Delete it',
      );
      const answer = LlamaChatMessage.fromText(
        role: LlamaChatRole.assistant,
        text: 'Done.',
      );
      final call = LlamaToolCallContent(
        id: '1',
        name: 'approve',
        arguments: const {},
        rawJson: '{}',
      );
      session
        ..addMessage(question)
        ..addMessage(answer)
        ..addMessage(question)
        ..addMessage(
          LlamaChatMessage.withContent(
            role: LlamaChatRole.assistant,
            content: [call],
          ),
        )
        ..addMessage(_result(call, 'approved'));
      engine.replies.add(scriptedCalls([('2', 'weather', '{}')]));

      await session.completeWithTools(
        const [],
        tools: [_tool('weather', (_) async => 'x')],
        maxRounds: 0,
      );

      expect(session.history, orderedEquals([question, answer]));
    });

    test('of an answered turn rolls back only its own messages', () async {
      earlier.forEach(session.addMessage);
      engine.replies.add(scriptedCalls([('1', 'weather', '{}')]));

      final result = await session.completeWithTools(
        const [],
        tools: [_tool('weather', (_) async => 'x')],
        maxRounds: 0,
      );

      expect(result.rolledBack, isTrue);
      expect(session.history, orderedEquals(earlier));
      expect(_roles(result.messages), [LlamaChatRole.assistant]);
    });
  });

  test('a rollback keeps a turn another caller completed meanwhile', () async {
    engine.replies
      ..add(scriptedCalls([('1', 'weather', '{}')]))
      ..add(scriptedAnswer('Side answer'))
      ..add(scriptedCalls([('2', 'weather', '{}')]));
    var runs = 0;

    final result = await session.sendWithTools(
      'Weather',
      maxRounds: 1,
      tools: [
        _tool('weather', (_) async {
          runs += 1;
          if (runs == 1) await session.send('Side question');
          return 'sunny';
        }),
      ],
    );

    expect(result.stopReason, LlamaToolLoopStopReason.maxRounds);
    expect(session.history.map((message) => message.content), [
      'Side question',
      'Side answer',
    ]);
  });

  test('maxRounds 0 returns the first calls unrun', () async {
    engine.replies.add(scriptedCalls([('1', 'weather', '{}')]));

    final result = await session.sendWithTools(
      'Loop',
      tools: [_tool('weather', (_) async => fail('ran'))],
      maxRounds: 0,
    );

    expect(result.stopReason, LlamaToolLoopStopReason.maxRounds);
    expect(result.rounds, 0);
    expect(result.pendingToolCalls.single.name, 'weather');
    expect(session.history, isEmpty);
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
        scriptedCalls([
          ('a', 'weather', '{}'),
          ('b', 'approve', '{"city":"X"}'),
        ]),
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
      expect(_roles(session.history), [
        LlamaChatRole.user,
        LlamaChatRole.assistant,
      ]);
      expect(
        session.history.last.parts.whereType<LlamaToolCallContent>(),
        hasLength(2),
      );
    });

    test('continues after the caller adds the results', () async {
      engine.replies
        ..add(scriptedCalls([('a', 'approve', '{}')]))
        ..add(scriptedAnswer('Approved.'));
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
        ..add(scriptedCalls([('a', 'approve', '{"city":"X"}')]))
        ..add(scriptedAnswer('ok'));
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

    test('onToolCall does not replace a handler', () async {
      engine.replies
        ..add(scriptedCalls([('a', 'weather', '{"city":"X"}')]))
        ..add(scriptedAnswer('ok'));

      await session.sendWithTools(
        'Weather',
        tools: [_tool('weather', (_) async => 'from handler')],
        onToolCall: (call) => fail('onToolCall ran'),
      );

      expect(_toolResults(session).single.result, 'from handler');
    });

    test('onToolCall runs a call to an unknown tool', () async {
      engine.replies
        ..add(scriptedCalls([('a', 'missing', '{"city":"X"}')]))
        ..add(scriptedAnswer('ok'));
      final seen = <String>[];

      final result = await session.sendWithTools(
        'Weather',
        tools: [_tool('weather', (_) async => fail('handler ran'))],
        onToolCall: (call) {
          seen.add(call.name);
          return 'from onToolCall';
        },
      );

      expect(result.stopReason, LlamaToolLoopStopReason.completed);
      expect(seen, ['missing']);
      expect(_toolResults(session).single.result, 'from onToolCall');
    });
  });

  group('tool errors', () {
    test('become the tool result by default', () async {
      engine.replies
        ..add(
          scriptedCalls([
            ('a', 'weather', '{}'),
            ('b', 'missing', '{}'),
            ('c', 'weather', '[1]'),
          ]),
        )
        ..add(scriptedAnswer('sorry'));

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
        ..add(scriptedCalls([('a', 'weather', '{}')]))
        ..add(scriptedAnswer('sorry'));
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
      engine.replies.add(
        scriptedCalls([('a', 'weather', '{}'), ('b', 'ok', '{}')]),
      );
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
      expect(session.history, isEmpty);
    });
  });

  test('does not run calls proposed from a trimmed prompt', () async {
    session = ChatSession(engine, maxContextTokens: 256);
    engine.promptTokens = 10000;
    engine.replies.add(scriptedCalls([('a', 'weather', '{}')]));

    final result = await session.sendWithTools(
      'Weather',
      tools: [_tool('weather', (_) async => fail('ran'))],
    );

    expect(session.lastRequestFitContext, isFalse);
    expect(result.stopReason, LlamaToolLoopStopReason.contextExceeded);
    expect(result.pendingToolCalls.single.id, 'a');
    expect(session.history, isEmpty);
  });

  test('a rollback leaves turns trimmed for context dropped', () async {
    session = ChatSession(engine, maxContextTokens: 256);
    final note = _text(LlamaChatRole.system, 'note');
    [
      _text(LlamaChatRole.user, 'Hi'),
      _text(LlamaChatRole.assistant, 'Hello'),
    ].forEach(session.addMessage);
    engine.promptTokens = 10000;
    engine.replies.add(scriptedCalls([('a', 'weather', '{}')]));

    final result = await session.sendWithTools(
      'Weather',
      tools: [_tool('weather', (_) async => fail('ran'))],
      onMessageAdded: (message) {
        if (message.role == LlamaChatRole.user) session.addMessage(note);
      },
    );

    expect(result.stopReason, LlamaToolLoopStopReason.contextExceeded);
    expect(engine.requests.single.first.content, 'Weather');
    expect(session.history, orderedEquals([note]));
  });

  group('a reset during the loop', () {
    final oldQuestion = _text(LlamaChatRole.user, 'OLD secret question');
    final oldAnswer = _text(LlamaChatRole.assistant, 'OLD secret answer');

    setUp(() {
      session = ChatSession(engine, maxContextTokens: 256);
      session
        ..addMessage(oldQuestion)
        ..addMessage(oldAnswer);
      // The old turn no longer fits, so the first request trims it.
      engine.countFor = (messages) =>
          messages.any((message) => identical(message, oldQuestion))
          ? 10000
          : 10;
    });

    List<String?> contents() => [
      for (final message in session.history) message.content,
    ];

    test('during a tool, then maxRounds, keeps the new chat', () async {
      final fresh = _text(LlamaChatRole.user, 'New chat');
      engine.replies
        ..add(scriptedCalls([('a', 'weather', '{}')]))
        ..add(scriptedCalls([('b', 'weather', '{}')]));
      var runs = 0;

      final result = await session.sendWithTools(
        'Weather',
        maxRounds: 1,
        tools: [
          _tool('weather', (_) async {
            runs += 1;
            if (runs == 1) {
              session
                ..reset()
                ..addMessage(fresh);
            }
            return 'sunny';
          }),
        ],
      );

      expect(result.rolledBack, isTrue);
      expect(session.history, orderedEquals([fresh]));
    });

    test('during the next request, then an error, stays empty', () async {
      engine.replies
        ..add(scriptedCalls([('a', 'weather', '{}')]))
        ..add(() async* {
          session.reset();
          throw LlamaInferenceException('boom');
        });

      await expectLater(
        session.sendWithTools(
          'Weather',
          tools: [_tool('weather', (_) async => 'sunny')],
        ),
        throwsA(isA<LlamaInferenceException>()),
      );
      expect(contents(), isEmpty);
    });

    for (final during in ['a tool', 'the next request']) {
      test('with a cancel during $during stays empty', () async {
        void newChat() {
          engine.cancelGeneration();
          session.reset();
        }

        engine.replies.add(scriptedCalls([('a', 'weather', '{}')]));
        if (during == 'the next request') {
          engine.replies.add(() async* {
            newChat();
            yield scriptedChunk(content: '', finishReason: 'stop');
          });
        }

        final result = await session.sendWithTools(
          'Weather',
          tools: [
            _tool('weather', (_) async {
              if (during == 'a tool') newChat();
              return 'sunny';
            }),
          ],
        );

        expect(result.stopReason, LlamaToolLoopStopReason.cancelled);
        expect(contents(), isNot(contains(oldQuestion.content)));
        expect(contents(), isNot(contains(oldAnswer.content)));
        if (during == 'a tool') expect(contents(), isEmpty);
      });
    }
  });

  group('cancelGeneration', () {
    test('during a tool rolls the turn back and returns its results', () async {
      engine.replies.add(scriptedCalls([('a', 'weather', '{}')]));

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
      expect(session.history, isEmpty);
      final results = result.messages
          .expand((message) => message.parts)
          .whereType<LlamaToolResultContent>();
      expect(results.single.result, 'sunny');
    });

    test('keeps a partial answer as the turn reply', () async {
      engine.replies
        ..add(scriptedCalls([('a', 'weather', '{}')]))
        ..add(() async* {
          yield scriptedChunk(content: 'Sunny');
          engine.cancelGeneration();
        });

      final result = await session.sendWithTools(
        'Weather',
        tools: [_tool('weather', (_) async => 'sunny')],
      );

      expect(result.stopReason, LlamaToolLoopStopReason.cancelled);
      expect(result.rolledBack, isFalse);
      expect(result.text, 'Sunny');
      expect(_roles(session.history), [
        LlamaChatRole.user,
        LlamaChatRole.assistant,
        LlamaChatRole.tool,
        LlamaChatRole.assistant,
      ]);
      expect(session.history.last.content, 'Sunny');
    });

    test('reported as a stream error keeps a partial answer', () async {
      engine.replies
        ..add(scriptedCalls([('a', 'weather', '{}')]))
        ..add(() async* {
          yield scriptedChunk(content: 'Sun');
          engine.cancelGeneration();
          throw LlamaInferenceException('aborted');
        });

      final result = await session.sendWithTools(
        'Weather',
        tools: [_tool('weather', (_) async => 'sunny')],
      );

      expect(result.stopReason, LlamaToolLoopStopReason.cancelled);
      expect(result.rolledBack, isFalse);
      expect(result.text, 'Sun');
      expect(session.history.last.content, 'Sun');
    });

    test('does not hide an error from onMessageAdded', () async {
      engine.replies.add(() async* {
        yield scriptedChunk(content: 'partial');
        engine.cancelGeneration();
      });

      await expectLater(
        session.sendWithTools(
          'Hi',
          tools: const [],
          onMessageAdded: (message) {
            if (message.role == LlamaChatRole.assistant) {
              throw StateError('persisting failed');
            }
          },
        ),
        throwsStateError,
      );
      expect(session.history, isEmpty);
    });

    test('after a stream error does not hide that error', () async {
      engine.replies.add(() async* {
        yield scriptedChunk(content: 'partial');
        throw LlamaInferenceException('boom');
      });

      await expectLater(
        session.sendWithTools(
          'Hi',
          tools: const [],
          onMessageAdded: (message) {
            if (message.role == LlamaChatRole.assistant) {
              engine.cancelGeneration();
            }
          },
        ),
        throwsA(isA<LlamaInferenceException>()),
      );
      expect(session.history, isEmpty);
    });

    test('reported as a stream error before a reply rolls back', () async {
      engine.replies
        ..add(scriptedCalls([('a', 'weather', '{}')]))
        ..add(() async* {
          engine.cancelGeneration();
          throw LlamaInferenceException('aborted');
        });

      final result = await session.sendWithTools(
        'Weather',
        tools: [_tool('weather', (_) async => 'sunny')],
      );

      expect(result.stopReason, LlamaToolLoopStopReason.cancelled);
      expect(result.rolledBack, isTrue);
      expect(session.history, isEmpty);
    });

    test(
      'reported as a stream error before the first reply rolls back',
      () async {
        engine.replies.add(() async* {
          engine.cancelGeneration();
          throw LlamaInferenceException('aborted');
        });

        final result = await session.sendWithTools('Hi', tools: const []);

        expect(result.stopReason, LlamaToolLoopStopReason.cancelled);
        expect(result.rolledBack, isTrue);
        expect(session.history, isEmpty);
      },
    );

    test('before the next reply starts rolls the turn back', () async {
      engine.replies
        ..add(scriptedCalls([('a', 'weather', '{}')]))
        ..add(() async* {
          engine.cancelGeneration();
        });

      final result = await session.sendWithTools(
        'Weather',
        tools: [_tool('weather', (_) async => 'sunny')],
      );

      expect(result.stopReason, LlamaToolLoopStopReason.cancelled);
      expect(result.rounds, 1);
      expect(session.history, isEmpty);
    });

    test('after an app reset removes only the loop messages', () async {
      final kept = _text(LlamaChatRole.user, 'Kept');
      engine.replies.add(scriptedCalls([('a', 'weather', '{}')]));

      await session.sendWithTools(
        'Weather',
        tools: [
          _tool('weather', (_) async {
            session
              ..reset()
              ..addMessage(kept);
            engine.cancelGeneration();
            return 'sunny';
          }),
        ],
      );

      expect(session.history, orderedEquals([kept]));
    });

    test('after an app reset during generation keeps the reset', () async {
      [
        _text(LlamaChatRole.user, 'Hi'),
        _text(LlamaChatRole.assistant, 'Hello'),
      ].forEach(session.addMessage);
      engine.replies.add(() async* {
        session.reset();
        engine.cancelGeneration();
        yield* scriptedCalls([('a', 'weather', '{}')])();
      });

      await session.sendWithTools(
        'Weather',
        tools: [_tool('weather', (_) async => fail('ran'))],
      );

      expect(session.history, isEmpty);
    });

    test('during generation stops without running calls', () async {
      engine.replies.add(() async* {
        engine.cancelGeneration();
        yield* scriptedCalls([('a', 'weather', '{}')])();
      });

      final result = await session.sendWithTools(
        'Weather',
        tools: [_tool('weather', (_) async => fail('ran'))],
      );

      expect(result.stopReason, LlamaToolLoopStopReason.cancelled);
      expect(result.rounds, 0);
      expect(result.pendingToolCalls.single.id, 'a');
      expect(session.history, isEmpty);
    });

    test('issued before the loop does not affect it', () async {
      engine.cancelGeneration();
      engine.replies.add(scriptedAnswer('hi'));

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

  test('an error in a later round rolls the turn back', () async {
    engine.replies
      ..add(scriptedCalls([('a', 'weather', '{}')]))
      ..add(() async* {
        yield scriptedChunk(content: 'Sun');
        throw LlamaInferenceException('boom');
      });
    final added = <LlamaChatMessage>[];

    await expectLater(
      session.sendWithTools(
        'Weather',
        tools: [_tool('weather', (_) async => 'sunny')],
        onMessageAdded: added.add,
      ),
      throwsA(isA<LlamaInferenceException>()),
    );
    expect(session.history, isEmpty);
    expect(_roles(added), [
      LlamaChatRole.user,
      LlamaChatRole.assistant,
      LlamaChatRole.tool,
      LlamaChatRole.assistant,
    ]);
  });

  test(
    'a rollback does not replay a subclass\'s addMessage or reset',
    () async {
      final persisting = _PersistingSession(engine);
      [
        _text(LlamaChatRole.user, 'Hi'),
        _text(LlamaChatRole.assistant, 'Hello'),
      ].forEach(persisting.addMessage);
      engine.replies.add(scriptedCalls([('a', 'weather', '{}')]));

      final result = await persisting.sendWithTools(
        'Weather',
        tools: [_tool('weather', (_) async => fail('ran'))],
        maxRounds: 0,
      );

      expect(result.rolledBack, isTrue);
      expect(persisting.history, hasLength(2));
      expect(persisting.stored, hasLength(2));
      expect(persisting.resets, 0);
    },
  );

  test('a rollback removes the copies a subclass stored', () async {
    final copying = _CopyingSession(engine);
    engine.replies.add(scriptedCalls([('a', 'weather', '{}')]));

    final result = await copying.sendWithTools(
      'Weather',
      tools: [
        _tool('weather', (_) async {
          engine.cancelGeneration();
          return 'sunny';
        }),
      ],
    );

    expect(result.rolledBack, isTrue);
    expect(copying.history, isEmpty);
  });

  test('runs on a class that implements ChatSession', () async {
    engine.replies
      ..add(scriptedCalls([('a', 'weather', '{}')]))
      ..add(scriptedCalls([('b', 'weather', '{}')]));
    session.systemPrompt = 'Be brief.';
    final delegate = _DelegatingSession(session);

    final result = await delegate.sendWithTools(
      'Weather',
      tools: [_tool('weather', (_) async => 'sunny')],
      maxRounds: 1,
    );

    expect(result.stopReason, LlamaToolLoopStopReason.maxRounds);
    expect(session.history, isEmpty);
    expect(session.systemPrompt, 'Be brief.');
  });

  test('completeWithTools sends media parts as the user turn', () async {
    engine.replies.add(scriptedAnswer('A cat.'));

    final result = await session.completeWithTools([
      const LlamaTextContent('What is this?'),
      LlamaImageContent(url: 'https://example.com/cat.png'),
    ], tools: const []);

    expect(result.text, 'A cat.');
    expect(session.history.first.parts, hasLength(2));
  });
}
