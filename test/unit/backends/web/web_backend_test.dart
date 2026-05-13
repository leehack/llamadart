@TestOn('browser')
library;

import 'package:llamadart/src/backends/backend.dart';
import 'package:llamadart/src/backends/web/web_backend.dart';
import 'package:llamadart/src/core/engine/engine.dart';
import 'package:llamadart/src/core/exceptions.dart';
import 'package:llamadart/src/core/models/config/log_level.dart';
import 'package:llamadart/src/core/models/inference/model_params.dart';
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
    expect((backend as WebAutoBackend).supportsStatePersistence, isFalse);
  });

  test('WebAutoBackend reports state support from injected delegate', () async {
    final backend = WebAutoBackend(webBackend: _NoStateBackend());
    final engine = LlamaEngine(backend);

    expect(backend.supportsStatePersistence, isFalse);
    expect(engine.supportsStatePersistence, isFalse);

    await engine.loadModel('/model.gguf');
    expect(engine.supportsStatePersistence, isFalse);
    await expectLater(
      () =>
          engine.stateSaveFile('/prompt-prefix.state', tokens: const <int>[1]),
      throwsA(
        isA<LlamaUnsupportedException>().having(
          (error) => error.message,
          'message',
          contains('v0.1.15'),
        ),
      ),
    );
  });
}

class _NoStateBackend implements LlamaBackend {
  @override
  bool get isReady => true;

  @override
  bool get supportsUrlLoading => true;

  @override
  Future<int> modelLoad(String path, ModelParams params) async => 1;

  @override
  Future<int> modelLoadFromUrl(
    String url,
    ModelParams params, {
    Function(double progress)? onProgress,
  }) async => 1;

  @override
  Future<int> contextCreate(int modelHandle, ModelParams params) async => 1;

  @override
  Future<void> contextFree(int contextHandle) async {}

  @override
  Future<void> modelFree(int modelHandle) async {}

  @override
  Future<void> setLogLevel(LlamaLogLevel level) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
