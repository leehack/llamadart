import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:laya_command_bar_example/src/intent_runner.dart';
import 'package:laya_command_bar_example/src/intents.dart';

import 'support.dart';

void main() {
  late List<String> started;
  late List<Completer<IntentReading>> pending;
  late List<String> reported;
  late List<Object> errors;
  late IntentRunner runner;

  setUp(() {
    started = [];
    pending = [];
    reported = [];
    errors = [];
    runner = IntentRunner(
      (text) {
        started.add(text);
        final c = Completer<IntentReading>();
        pending.add(c);
        return c.future;
      },
      onReading: (r) => reported.add(r.text),
      onError: errors.add,
    );
  });

  tearDown(() async {
    for (final c in pending) {
      if (!c.isCompleted) c.complete(readingOf(CommandIntent.ask, 1));
    }
    await runner.dispose();
  });

  Future<void> finish(int i) async {
    pending[i].complete(readingOf(CommandIntent.ask, 1, text: started[i]));
    await pumpEventQueue();
  }

  test('runs one read at a time and then only the latest text', () async {
    runner
      ..submit('t')
      ..submit('te')
      ..submit('tex')
      ..submit('text');
    expect(started, ['t']);
    expect(runner.isBusy, isTrue);

    await finish(0);
    expect(reported, ['t']);
    expect(started, ['t', 'text']);
    expect(runner.skipped, 2);

    await finish(1);
    expect(reported, ['t', 'text']);
    expect(runner.isBusy, isFalse);
    expect(runner.reads, 2);
  });

  test('does not read the same text twice in a row', () async {
    runner.submit('same');
    await finish(0);
    runner.submit('same');
    expect(started, ['same']);
  });

  test('blank text drops the running read and the pending text', () async {
    runner
      ..submit('remind')
      ..submit('remind me')
      ..submit('  ');
    await finish(0);
    expect(reported, isEmpty);
    expect(started, ['remind']);
    expect(runner.isBusy, isFalse);

    runner.submit('remind');
    expect(started, ['remind', 'remind']);
  });

  test('reports a failed read and keeps going', () async {
    runner
      ..submit('a')
      ..submit('ab');
    pending[0].completeError(StateError('boom'));
    await pumpEventQueue();
    expect(errors.single, isStateError);
    await finish(1);
    expect(reported, ['ab']);
  });

  test(
    'dispose waits for the running read and reports nothing after',
    () async {
      runner.submit('a');
      var disposed = false;
      final done = runner.dispose().then((_) => disposed = true);
      await pumpEventQueue();
      expect(disposed, isFalse);
      await finish(0);
      await done;
      expect(reported, isEmpty);
    },
  );
}
