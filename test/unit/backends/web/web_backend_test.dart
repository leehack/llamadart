@TestOn('browser')
library;

import 'package:llamadart/src/backends/backend.dart';
import 'package:llamadart/src/backends/web/web_backend.dart';
import 'package:llamadart/src/core/engine/engine.dart';
import 'package:test/test.dart';

void main() {
  test('createBackend returns WebAutoBackend', () {
    final backend = createBackend();

    expect(backend, isA<LlamaBackend>());
    expect(backend, isA<WebAutoBackend>());
    expect(backend, isA<BackendEmbeddings>());
    expect(backend, isA<BackendBatchEmbeddings>());
    expect(backend, isA<BackendStatePersistence>());
    expect(backend, isA<BackendStatePersistenceSupport>());
    expect((backend as WebAutoBackend).supportsStatePersistence, isTrue);
  });

  test('WebAutoBackend reports state support from injected delegate', () {
    final backend = WebAutoBackend(webBackend: _NoStateBackend());
    final engine = LlamaEngine(backend);

    expect(backend.supportsStatePersistence, isFalse);
    expect(engine.supportsStatePersistence, isFalse);
  });
}

class _NoStateBackend implements LlamaBackend {
  @override
  bool get isReady => false;

  @override
  bool get supportsUrlLoading => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
