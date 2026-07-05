@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

void main() {
  group('llama_cpp_speculative_benchmark', () {
    test('lists all case aliases in invalid cases errors', () async {
      final result = await Process.run(Platform.resolvedExecutable, [
        'run',
        'tool/testing/llama_cpp_speculative_benchmark.dart',
        '--model',
        'missing.gguf',
        '--cases',
        'not-a-case',
      ]);

      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('all, draftless, ngram'));
    });
  });
}
