import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:laya_command_bar_example/src/eval_cases.dart';
import 'package:laya_command_bar_example/src/example_bank.dart';
import 'package:laya_command_bar_example/src/intents.dart';

/// Bag-of-words vectors: texts that share words are similar.
Future<List<List<double>>> wordEmbedder(List<String> texts) async => [
  for (final text in texts)
    () {
      final v = List<double>.filled(64, 0);
      for (final w in text.toLowerCase().split(RegExp(r'\W+'))) {
        if (w.isNotEmpty) v[w.hashCode % 64] += 1;
      }
      final norm = math.sqrt(v.fold(0.0, (a, b) => a + b * b));
      return [for (final x in v) norm == 0 ? 0.0 : x / norm];
    }(),
];

void main() {
  test('reads a text as the intent of its most similar examples', () async {
    final bank = ExampleBank(wordEmbedder);
    await bank.addAll([
      (CommandIntent.task, 'buy milk'),
      (CommandIntent.task, 'buy eggs and bread'),
      (CommandIntent.message, 'text sam hello'),
      (CommandIntent.message, 'text mom later'),
    ]);
    final r = await bank.read('buy apples');
    expect(r.top, CommandIntent.task);
    final sorted = [...r.probabilities]..sort();
    expect(
      r.confidence,
      closeTo(sorted.last - sorted[sorted.length - 2], 1e-12),
    );
    expect(r.probabilities.reduce((a, b) => a + b), closeTo(1, 1e-9));
  });

  test('an added correction changes the next reading', () async {
    final bank = ExampleBank(wordEmbedder);
    await bank.addAll([
      (CommandIntent.ask, 'what is the weather'),
      (CommandIntent.task, 'buy milk'),
    ]);
    expect(
      (await bank.read('dark mode on')).top,
      isNot(CommandIntent.settings),
    );
    await bank.add(CommandIntent.settings, 'dark mode on');
    expect((await bank.read('dark mode on')).top, CommandIntent.settings);
    expect(bank.sizes[CommandIntent.settings], 1);
  });

  test('seed examples cover every intent and exclude the benchmark cases', () {
    String norm(String s) => s.toLowerCase().trim();
    final scored = {
      for (final (_, t) in [...evalCases, ...heldOutCases]) norm(t),
    };
    expect(
      [for (final (_, t) in seedExamples) norm(t)].where(scored.contains),
      isEmpty,
    );
    expect({
      for (final (i, _) in seedExamples) i,
    }, CommandIntent.values.toSet());
    expect(intentDescriptions.keys.toSet(), CommandIntent.values.toSet());
  });
}
