import 'dart:math' as math;

import 'package:llamadart/llamadart.dart';
import 'package:test/test.dart';

void main() {
  test('decodes token bytes, replacing a partial character', () {
    final whole = LlamaTokenLogprob(
      token: 1,
      bytes: const [0xEC, 0x95, 0x88],
      logprob: 0,
    );
    final partial = LlamaTokenLogprob(
      token: 2,
      bytes: const [0xEC, 0x95],
      logprob: 0,
    );

    expect(whole.text, '안');
    expect(partial.text, '�');
  });

  test('derives probability from the log-probability', () {
    final token = LlamaTokenLogprob(
      token: 1,
      bytes: const [],
      logprob: math.log(0.25),
    );

    expect(token.probability, closeTo(0.25, 1e-12));
  });

  test('copies its lists', () {
    final bytes = [65];
    final candidates = [LlamaTokenLogprob(token: 1, bytes: bytes, logprob: 0)];
    final token = candidates.first;
    final scores = LlamaNextTokenScores(
      candidates: candidates,
      top: candidates,
      promptTokens: 1,
    );
    bytes.add(66);
    candidates.clear();

    expect(token.bytes, [65]);
    expect(scores.candidates, [token]);
    expect(scores.top, [token]);
    expect(() => scores.top.add(token), throwsUnsupportedError);
  });

  group('LlamaGeneratedTokenLogprobs', () {
    final sampled = LlamaTokenLogprob(
      token: 7,
      bytes: const [0xC3],
      logprob: -0.5,
    );
    final alternative = LlamaTokenLogprob(
      token: 9,
      bytes: const [0x61],
      logprob: -1.5,
    );

    test('copies its alternatives', () {
      final top = [alternative];
      final entry = LlamaGeneratedTokenLogprobs(sampled: sampled, top: top);
      top.clear();

      expect(entry.top, [alternative]);
      expect(() => entry.top.add(alternative), throwsUnsupportedError);
    });

    test('writes an OpenAI content entry and reads it back', () {
      final entry = LlamaGeneratedTokenLogprobs(
        sampled: sampled,
        top: [alternative],
      );
      final json = entry.toJson();

      expect(json, {
        'token': '�',
        'id': 7,
        'logprob': -0.5,
        'bytes': [0xC3],
        'top_logprobs': [
          {
            'token': 'a',
            'id': 9,
            'logprob': -1.5,
            'bytes': [0x61],
          },
        ],
      });
      final decoded = LlamaGeneratedTokenLogprobs.fromJson(json);
      expect(decoded.sampled.token, 7);
      expect(decoded.sampled.bytes, [0xC3]);
      expect(decoded.sampled.logprob, -0.5);
      expect(decoded.top.single.token, 9);
      expect(decoded.top.single.logprob, -1.5);
    });

    test('writes a ruled-out token as -9999, which JSON can hold', () {
      final impossible = LlamaTokenLogprob(
        token: 1,
        bytes: const [],
        logprob: double.negativeInfinity,
      );

      expect(impossible.toJson()['logprob'], -9999.0);
    });
  });
}
