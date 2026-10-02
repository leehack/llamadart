@TestOn('vm')
library;

import 'dart:io';

import 'package:llamadart/llamadart.dart';
import 'package:test/test.dart';

import '../../../support/scripted_chat_engine.dart';

/// Templates that reject a user turn unless every earlier user turn has an
/// assistant reply without tool calls.
const _strictTemplates = <String>[
  'test/fixtures/templates/Ministral-3-3B-Reasoning.jinja',
  'test/fixtures/llama_cpp_templates/mistralai-Ministral-3-14B-Reasoning-2512.jinja',
];

ToolDefinition _tool(String name, [ToolHandler? handler]) => ToolDefinition(
  name: name,
  description: 'The $name tool',
  parameters: [ToolParam.string('city')],
  handler: handler,
);

void main() {
  for (final path in _strictTemplates) {
    group(path.split('/').last, () {
      late ScriptedChatEngine engine;
      late ChatSession session;

      setUp(() {
        final source = File(path).readAsStringSync();
        engine = ScriptedChatEngine()
          ..onRequest = (messages, tools) => ChatTemplateEngine.render(
            templateSource: source,
            messages: messages,
            metadata: const {},
            tools: tools,
          );
        session = ChatSession(engine, maxContextTokens: 0);
      });

      Future<void> expectNextTurnRenders() async {
        engine.replies.add(scriptedAnswer('4'));
        final next = await session.send('And 2 + 2?');
        expect(next.text, '4');
      }

      final weather = _tool('weather', (_) async => 'sunny');

      test('completed', () async {
        engine.replies
          ..add(scriptedCalls([('call00001', 'weather', '{}')]))
          ..add(scriptedAnswer('Sunny.'));
        final result = await session.sendWithTools('Hi', tools: [weather]);
        expect(result.stopReason, LlamaToolLoopStopReason.completed);
        await expectNextTurnRenders();
      });

      for (final maxRounds in [0, 1]) {
        test('maxRounds $maxRounds', () async {
          engine.replies.addAll([
            for (var round = 0; round <= maxRounds; round++)
              scriptedCalls([('call0000$round', 'weather', '{}')]),
          ]);
          final result = await session.sendWithTools(
            'Hi',
            tools: [weather],
            maxRounds: maxRounds,
          );
          expect(result.stopReason, LlamaToolLoopStopReason.maxRounds);
          await expectNextTurnRenders();
        });
      }

      test('contextExceeded', () async {
        session = ChatSession(engine, maxContextTokens: 256);
        engine
          ..promptTokens = 10000
          ..replies.add(scriptedCalls([('call00001', 'weather', '{}')]));
        final result = await session.sendWithTools('Hi', tools: [weather]);
        expect(result.stopReason, LlamaToolLoopStopReason.contextExceeded);
        engine.promptTokens = 0;
        await expectNextTurnRenders();
      });

      test('unhandledToolCalls, after the app answers the calls', () async {
        engine.replies
          ..add(scriptedCalls([('call00001', 'approve', '{}')]))
          ..add(scriptedAnswer('Approved.'));
        final tools = [_tool('approve')];
        final result = await session.sendWithTools('Hi', tools: tools);
        expect(result.stopReason, LlamaToolLoopStopReason.unhandledToolCalls);

        final call = result.pendingToolCalls.single;
        session.addMessage(
          LlamaChatMessage.withContent(
            role: LlamaChatRole.tool,
            content: [
              LlamaToolResultContent(
                id: call.id,
                name: call.name,
                result: 'denied',
              ),
            ],
          ),
        );
        final answered = await session.completeWithTools(
          const [],
          tools: tools,
        );
        expect(answered.stopReason, LlamaToolLoopStopReason.completed);
        await expectNextTurnRenders();
      });

      test('cancelled during a tool', () async {
        engine.replies.add(scriptedCalls([('call00001', 'weather', '{}')]));
        final result = await session.sendWithTools(
          'Hi',
          tools: [
            _tool('weather', (_) async {
              engine.cancelGeneration();
              return 'sunny';
            }),
          ],
        );
        expect(result.stopReason, LlamaToolLoopStopReason.cancelled);
        await expectNextTurnRenders();
      });

      test('cancelled before the next reply starts', () async {
        engine.replies
          ..add(scriptedCalls([('call00001', 'weather', '{}')]))
          ..add(() async* {
            engine.cancelGeneration();
          });
        final result = await session.sendWithTools('Hi', tools: [weather]);
        expect(result.stopReason, LlamaToolLoopStopReason.cancelled);
        await expectNextTurnRenders();
      });

      test('cancelled while generating calls', () async {
        engine.replies.add(() async* {
          engine.cancelGeneration();
          yield* scriptedCalls([('call00001', 'weather', '{}')])();
        });
        final result = await session.sendWithTools('Hi', tools: [weather]);
        expect(result.stopReason, LlamaToolLoopStopReason.cancelled);
        await expectNextTurnRenders();
      });

      test('cancelled during the answer', () async {
        engine.replies
          ..add(scriptedCalls([('call00001', 'weather', '{}')]))
          ..add(() async* {
            yield scriptedChunk(content: 'Sun');
            engine.cancelGeneration();
          });
        final result = await session.sendWithTools('Hi', tools: [weather]);
        expect(result.stopReason, LlamaToolLoopStopReason.cancelled);
        expect(session.history.last.content, 'Sun');
        await expectNextTurnRenders();
      });

      test('a rethrow from onToolError', () async {
        engine.replies.add(scriptedCalls([('call00001', 'weather', '{}')]));
        await expectLater(
          session.sendWithTools(
            'Hi',
            tools: [_tool('weather', (_) async => throw StateError('down'))],
            onToolError: (call, error, stackTrace) =>
                Error.throwWithStackTrace(error, stackTrace),
          ),
          throwsStateError,
        );
        await expectNextTurnRenders();
      });

      test('an error in a later round', () async {
        engine.replies
          ..add(scriptedCalls([('call00001', 'weather', '{}')]))
          ..add(() => Stream.error(LlamaInferenceException('boom')));
        await expectLater(
          session.sendWithTools('Hi', tools: [weather]),
          throwsA(isA<LlamaInferenceException>()),
        );
        await expectNextTurnRenders();
      });
    });
  }
}
