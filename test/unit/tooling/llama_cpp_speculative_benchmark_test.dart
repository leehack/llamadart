@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import '../../../tool/testing/llama_cpp_speculative_benchmark.dart'
    as speculative_benchmark;

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
      expect(result.stdout, contains('--ngram-cache-build-static-path <p>'));
      expect(result.stdout, contains('--ngram-cache-build-text <text>'));
    });

    test('builds llama.cpp static ngram cache bytes', () {
      final bytes = speculative_benchmark.buildLlamaCppStaticNgramCacheBytes(
        const [10, 20, 30, 40, 30, 40, 50],
      );
      final data = ByteData.sublistView(Uint8List.fromList(bytes));
      final words = [
        for (var offset = 0; offset < bytes.length; offset += 4)
          data.getInt32(offset, Endian.host),
      ];

      expect(bytes.length, 120);
      expect(words, [
        10,
        20,
        -1,
        -1,
        1,
        30,
        1,
        20,
        30,
        -1,
        -1,
        1,
        40,
        1,
        30,
        40,
        -1,
        -1,
        2,
        30,
        1,
        50,
        1,
        40,
        30,
        -1,
        -1,
        1,
        40,
        1,
      ]);
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

    test('rejects ngram cache build text without output path', () async {
      final result = await Process.run(Platform.resolvedExecutable, [
        '--disable-dart-dev',
        'tool/testing/llama_cpp_speculative_benchmark.dart',
        '--model',
        'missing.gguf',
        '--cases',
        'ngram-cache',
        '--ngram-cache-build-text',
        'alpha beta gamma',
      ]);

      expect(result.exitCode, isNot(0));
      expect(
        result.stderr,
        contains(
          '--ngram-cache-build-text requires '
          '--ngram-cache-build-static-path',
        ),
      );
    });

    test(
      'allows generated static cache path with equivalent absolute path',
      () async {
        final relativePath = 'relative-ngram-cache.bin';
        final absolutePath = '${Directory.current.path}/$relativePath';
        addTearDown(() async {
          final file = File(relativePath);
          if (await file.exists()) {
            await file.delete();
          }
        });

        final result = await Process.run(Platform.resolvedExecutable, [
          '--disable-dart-dev',
          'tool/testing/llama_cpp_speculative_benchmark.dart',
          '--model',
          'missing.gguf',
          '--cases',
          'ngram-cache',
          '--ngram-cache-static-path',
          relativePath,
          '--ngram-cache-build-static-path',
          absolutePath,
        ]);

        expect(result.exitCode, isNot(0));
        expect(
          result.stderr,
          isNot(contains('N-gram cache path does not exist')),
        );
        expect(
          result.stderr,
          isNot(contains('omit --ngram-cache-static-path')),
        );
      },
    );
  });
}
