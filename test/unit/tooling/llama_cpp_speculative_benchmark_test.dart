@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

void main() {
  group('llama_cpp_speculative_benchmark', () {
    test('documents flash-attention runtime option', () async {
      final result = await Process.run(Platform.resolvedExecutable, [
        '--disable-dart-dev',
        'tool/testing/llama_cpp_speculative_benchmark.dart',
        '--help',
      ]);

      expect(result.exitCode, 0);
      expect(result.stdout, contains('--flash-attention <mode>'));
      expect(result.stdout, contains('auto, enabled, disabled'));
    });

    test('lists all case aliases in invalid cases errors', () async {
      final result = await Process.run(Platform.resolvedExecutable, [
        '--disable-dart-dev',
        'tool/testing/llama_cpp_speculative_benchmark.dart',
        '--model',
        'missing.gguf',
        '--cases',
        'not-a-case',
      ]);

      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('all, draftless, ngram'));
    });

    test('rejects invalid flash-attention values', () async {
      final result = await Process.run(Platform.resolvedExecutable, [
        '--disable-dart-dev',
        'tool/testing/llama_cpp_speculative_benchmark.dart',
        '--model',
        'missing.gguf',
        '--flash-attention',
        'sometimes',
      ]);

      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('Invalid --flash-attention'));
      expect(result.stderr, contains('auto, enabled, disabled'));
    });
  });
}
