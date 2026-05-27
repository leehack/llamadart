import 'package:llamadart/src/backends/backend.dart';
import 'package:test/test.dart';

void main() {
  test('LlamaBackend interface is available', () {
    expect(LlamaBackend, isNotNull);
  });

  test('BackendEmbeddings capability interface is available', () {
    expect(BackendEmbeddings, isNotNull);
  });

  test('BackendEmbeddingsSupport capability interface is available', () {
    expect(BackendEmbeddingsSupport, isNotNull);
  });

  test('BackendBatchEmbeddings capability interface is available', () {
    expect(BackendBatchEmbeddings, isNotNull);
  });

  test('BackendStatePersistence capability interface is available', () {
    expect(BackendStatePersistence, isNotNull);
  });

  group('StateLoadResult', () {
    test('exposes the recovered token sequence', () {
      const result = StateLoadResult(tokens: [1, 2, 3]);
      expect(result.tokens, [1, 2, 3]);
    });

    test('accepts an empty token list', () {
      const result = StateLoadResult(tokens: []);
      expect(result.tokens, isEmpty);
    });
  });
}
