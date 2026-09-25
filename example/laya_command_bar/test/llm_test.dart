import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:laya_command_bar_example/src/intents.dart';
import 'package:laya_command_bar_example/src/llm.dart';

void main() {
  test('renormalizes the answer tokens in intent order', () async {
    final calls = <(String, List<int>)>[];
    final reader = LlmIntentReader(
      (prompt, candidates) async {
        calls.add((prompt, candidates));
        return [
          for (final intent in CommandIntent.values)
            intent == CommandIntent.reminder
                ? math.log(0.6)
                : intent == CommandIntent.event
                ? math.log(0.2)
                : math.log(0.001),
        ];
      },
      promptFor: (text) => '<$text>',
      answerTokens: [for (var i = 0; i < 8; i++) 100 + i],
    );

    final reading = await reader.read('nudge me at 3');

    expect(calls.single.$1, '<nudge me at 3>');
    expect(calls.single.$2, [100, 101, 102, 103, 104, 105, 106, 107]);
    expect(reading.top, CommandIntent.reminder);
    final total = 0.6 + 0.2 + 6 * 0.001;
    expect(
      reading.probabilityOf(CommandIntent.reminder),
      closeTo(0.6 / total, 1e-9),
    );
    expect(reading.confidence, closeTo(0.4 / total, 1e-9));
  });

  test('uses the current prompt after it changes', () async {
    final prompts = <String>[];
    final reader = LlmIntentReader(
      (prompt, candidates) async {
        prompts.add(prompt);
        return List.filled(candidates.length, -1);
      },
      promptFor: (text) => 'a $text',
      answerTokens: List.filled(8, 1),
    );

    await reader.read('x');
    reader.promptFor = (text) => 'b $text';
    final reading = await reader.read('x');

    expect(prompts, ['a x', 'b x']);
    expect(reading.confidence, 0);
  });

  test('instructions name every intent and example', () {
    final text = llmInstructions([(CommandIntent.task, 'wash the car')]);

    for (final intent in CommandIntent.values) {
      expect(text, contains('- ${intent.title}: '));
    }
    expect(text, contains('wash the car => Task'));
  });
}
