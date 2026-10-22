import 'package:test/test.dart';
import 'package:llamadart/src/core/exceptions.dart';

void main() {
  test(
    'embedding overflow remains an inference error with optional exact count',
    () {
      final error = LlamaEmbeddingInputTooLongException(
        'too long',
        maxInputTokens: 64,
      );
      expect(error, isA<LlamaInferenceException>());
      expect(error.maxInputTokens, 64);
      expect(error.actualTokens, isNull);
      expect(
        LlamaEmbeddingInputTooLongException(
          'too long',
          maxInputTokens: 64,
          actualTokens: 65,
        ).actualTokens,
        65,
      );
    },
  );

  group('LlamaException Tests', () {
    test('LlamaModelException properties', () {
      final ex = LlamaModelException('Fail to load', 'err_code_1');
      expect(ex.message, 'Fail to load');
      expect(ex.details, 'err_code_1');
      expect(
        ex.toString(),
        contains('LlamaException: Fail to load (err_code_1)'),
      );
    });

    test('LlamaContextException properties', () {
      final ex = LlamaContextException('Context full');
      expect(ex.message, 'Context full');
      expect(ex.details, isNull);
      expect(ex.toString(), 'LlamaException: Context full');
    });
  });
}
