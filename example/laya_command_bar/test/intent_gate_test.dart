import 'package:flutter_test/flutter_test.dart';
import 'package:laya_command_bar_example/src/intent_gate.dart';
import 'package:laya_command_bar_example/src/intents.dart';

import 'support.dart';

void main() {
  test('stays plain until a reading reaches the enter confidence', () {
    final gate = IntentGate(enter: 0.6);
    expect(
      gate.update(readingOf(CommandIntent.event, 0.77, confidence: 0.57)),
      isNull,
    );
    expect(
      gate.update(readingOf(CommandIntent.event, 0.99, confidence: 0.6)),
      CommandIntent.event,
    );
  });

  test(
    'keeps the shown intent through weaker readings that still favor it',
    () {
      final gate = IntentGate(enter: 0.6, keep: 0.25)
        ..update(readingOf(CommandIntent.reminder, 0.97, confidence: 0.9));
      expect(
        gate.update(readingOf(CommandIntent.reminder, 0.38, confidence: 0.19)),
        CommandIntent.reminder,
      );
      expect(
        gate.update(
          readingOf(
            CommandIntent.ask,
            0.4,
            confidence: 0.2,
            others: {CommandIntent.reminder: 0.3},
          ),
        ),
        CommandIntent.reminder,
      );
    },
  );

  test('goes plain when a weak reading drops the shown intent below keep', () {
    final gate = IntentGate(enter: 0.6, keep: 0.25)
      ..update(readingOf(CommandIntent.reminder, 0.97, confidence: 0.9));
    expect(
      gate.update(
        readingOf(
          CommandIntent.ask,
          0.4,
          confidence: 0.16,
          others: {CommandIntent.reminder: 0.1},
        ),
      ),
      isNull,
    );
  });

  test('switches only to a confident new intent', () {
    final gate = IntentGate(enter: 0.6)
      ..update(readingOf(CommandIntent.calculate, 0.98, confidence: 0.93));
    expect(
      gate.update(readingOf(CommandIntent.search, 0.6, confidence: 0.61)),
      CommandIntent.search,
    );
  });

  test('a pin overrides readings until unpinned or cleared', () {
    final gate = IntentGate()..pin(CommandIntent.settings);
    expect(
      gate.update(readingOf(CommandIntent.ask, 0.99, confidence: 0.99)),
      CommandIntent.settings,
    );
    gate.pin(null);
    expect(gate.shown, CommandIntent.ask);
    gate
      ..pin(CommandIntent.task)
      ..clear();
    expect(gate.shown, isNull);
    expect(gate.pinned, isNull);
  });

  test('a text shorter than minWords reads as plain however sure', () {
    final gate = IntentGate(enter: 0.3, minWords: 2);
    expect(
      gate.update(readingOf(CommandIntent.calculate, 0.99, text: 'rem')),
      isNull,
    );
    expect(
      gate.update(readingOf(CommandIntent.reminder, 0.99, text: 'remind me')),
      CommandIntent.reminder,
    );
    expect(
      gate.update(readingOf(CommandIntent.reminder, 0.99, text: ' remind ')),
      isNull,
    );
  });

  test('forgetReadings drops the read intent but keeps the pin', () {
    final gate = IntentGate()
      ..update(readingOf(CommandIntent.event, 0.99))
      ..forgetReadings();
    expect(gate.shown, isNull);
    expect(
      gate.update(readingOf(CommandIntent.event, 0.5, confidence: 0.1)),
      isNull,
    );
    gate
      ..pin(CommandIntent.task)
      ..forgetReadings();
    expect(gate.shown, CommandIntent.task);
  });
}
