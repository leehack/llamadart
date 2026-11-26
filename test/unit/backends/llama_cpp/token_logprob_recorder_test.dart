@TestOn('vm')
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:llamadart/src/backends/llama_cpp/token_logprob_recorder.dart';
import 'package:test/test.dart';

void main() {
  group('topLogitTokens', () {
    test('returns the largest logits, largest first', () {
      final logits = Float32List.fromList([0.5, 3, -1, 2, 2.5]);
      expect(topLogitTokens(logits, 3), [1, 4, 3]);
    });

    test('keeps the lower id on a tie', () {
      final logits = Float32List.fromList([1, 2, 2, 2, 0]);
      expect(topLogitTokens(logits, 2), [1, 2]);
      expect(topLogitTokens(logits, 3), [1, 2, 3]);
    });

    test('returns every token for a k beyond the vocabulary', () {
      final logits = Float32List.fromList([1, 3, 2]);
      expect(topLogitTokens(logits, 10), [1, 2, 0]);
    });

    test('returns none for zero', () {
      expect(topLogitTokens(Float32List.fromList([1, 2]), 0), isEmpty);
    });

    test('agrees with a full sort over a larger vocabulary', () {
      final random = math.Random(3);
      final logits = Float32List.fromList([
        for (var i = 0; i < 5000; i++) random.nextDouble() * 20 - 10,
      ]);
      final expected = List<int>.generate(logits.length, (i) => i)
        ..sort((a, b) {
          final byLogit = logits[b].compareTo(logits[a]);
          return byLogit != 0 ? byLogit : a.compareTo(b);
        });
      expect(topLogitTokens(logits, 20), expected.take(20));
    });
  });

  group('logSumExp', () {
    test('normalizes a softmax', () {
      final logits = Float32List.fromList([1, 2, 3, -4]);
      final logSum = logSumExp(logits);
      final total = logits.fold<double>(
        0,
        (sum, logit) => sum + math.exp(logit - logSum),
      );
      expect(total, closeTo(1, 1e-9));
    });

    test('does not overflow on large logits', () {
      final logits = Float32List.fromList([1000, 1000]);
      expect(logSumExp(logits), closeTo(1000 + math.log(2), 1e-9));
    });
  });
}
