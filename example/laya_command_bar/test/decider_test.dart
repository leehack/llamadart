import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:laya_command_bar_example/src/decider.dart';
import 'package:laya_command_bar_example/src/intents.dart';

void main() {
  test('the prompt is decider\'s plain layout', () {
    expect(
      deciderPrompt('buy milk'),
      'Context:\nbuy milk\n\n'
      'Question: What does the user want to do with this text typed into '
      'the app?\n'
      'Options:\n'
      '(A) search: find or look up something the user already has\n'
      '(B) task: add a to-do item\n'
      '(C) event: schedule a meeting or calendar event\n'
      '(D) reminder: be reminded or alerted later, or set a timer\n'
      '(E) message: send a message, text or email to a person\n'
      '(F) calculate: do math or convert units or currencies\n'
      '(G) ask: a general question for the assistant to answer\n'
      '(H) settings: change an app setting or preference\n'
      'Answer: (',
    );
  });

  test('softmaxes the letters over the temperature in intent order', () async {
    final calls = <(String, List<int>)>[];
    final reader = DeciderIntentReader(
      (prompt, candidates) async {
        calls.add((prompt, candidates));
        return [
          for (final intent in CommandIntent.values)
            intent == CommandIntent.reminder ? 0.0 : -2.0,
        ];
      },
      letterTokens: [for (var i = 0; i < 8; i++) 32 + i],
      temperature: 2,
    );

    final reading = await reader.read('nudge me at 3');

    expect(calls.single.$1, deciderPrompt('nudge me at 3'));
    expect(calls.single.$2, [32, 33, 34, 35, 36, 37, 38, 39]);
    expect(reading.top, CommandIntent.reminder);
    final other = math.exp(-1);
    final top = 1 / (1 + 7 * other);
    expect(reading.probabilityOf(CommandIntent.reminder), closeTo(top, 1e-9));
    expect(
      reading.probabilityOf(CommandIntent.task),
      closeTo(other * top, 1e-9),
    );
    expect(reading.confidence, closeTo(top, 1e-9));
  });
}
