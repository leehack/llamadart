import 'package:flutter_test/flutter_test.dart';
import 'package:genkit/genkit.dart';
import 'package:genkit_llamadart_dartpad_example/playground_controller.dart';

void main() {
  test('reported output tokens over 2000 ms are 10.0 tokens per second', () {
    expect(formatStats(20, 2000), '20 tok · 10.0 tok/s');
  });

  test('unreported output tokens produce neither a count nor a rate', () {
    expect(formatStats(null, 2000), isEmpty);
  });

  test('missing or zero latency preserves the count without a rate', () {
    expect(formatStats(20, null), '20 tok');
    expect(formatStats(20, 0), '20 tok');
  });

  test('formatLoadElapsed formats seconds and minutes cleanly', () {
    expect(formatLoadElapsed(Duration.zero), '0s');
    expect(formatLoadElapsed(const Duration(seconds: 5)), '5s');
    expect(formatLoadElapsed(const Duration(seconds: 59)), '59s');
    expect(formatLoadElapsed(const Duration(seconds: 60)), '1m 00s');
    expect(formatLoadElapsed(const Duration(seconds: 84)), '1m 24s');
  });

  test('trimLocalHistory keeps newest pairs within budget in order', () {
    const turns = [
      ChatTurn(Role.user, 'u0-12345'),
      ChatTurn(Role.model, 'a0-12345'),
      ChatTurn(Role.user, 'u1-12345'),
      ChatTurn(Role.model, 'a1-12345'),
      ChatTurn(Role.user, 'u2-12345'),
      ChatTurn(Role.model, 'a2-12345'),
    ];

    final allFit = trimLocalHistory(turns, maxChars: 100);
    expect(allFit.omittedPairs, 0);
    expect(allFit.turns.map((t) => t.text), [
      'u0-12345',
      'a0-12345',
      'u1-12345',
      'a1-12345',
      'u2-12345',
      'a2-12345',
    ]);

    final twoFit = trimLocalHistory(turns, maxChars: 32);
    expect(twoFit.omittedPairs, 1);
    expect(twoFit.turns.map((t) => t.text), [
      'u1-12345',
      'a1-12345',
      'u2-12345',
      'a2-12345',
    ]);

    final noneFit = trimLocalHistory(turns, maxChars: 10);
    expect(noneFit.omittedPairs, 3);
    expect(noneFit.turns, isEmpty);
  });
}
