import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart_validation/llamadart_validation.dart';
import 'package:test/test.dart';

import '../../../test/unit/core/engine/multimodal_embeddings_test.dart';

class _CancellableBackend extends ContentBackend {
  @override
  void cancelGeneration() {
    super.cancelGeneration();
    failure = LlamaInferenceException('Content embedding cancelled');
    gate?.complete();
  }
}

void main() {
  late Directory files;
  setUp(() {
    files = Directory.systemTemp.createTempSync('embedding-adapter-');
    for (final name in ['model.gguf', 'projector.gguf']) {
      File('${files.path}/$name').writeAsBytesSync([0, 0, 0, 0]);
    }
  });
  tearDown(() => files.deleteSync(recursive: true));
  final profile = ValidationProfile.fromJson(
    jsonDecode(
          File('assets/profiles/embedding-gguf-cpu.json').readAsStringSync(),
        )
        as Map<String, dynamic>,
  );
  for (final after in [false, true]) {
    test(
      'public adapter observes cancellation dispatch=$after and allows reuse',
      () async {
        final backend = _CancellableBackend();
        final engine = PublicEmbeddingValidationEngine(
          projector: '${files.path}/projector.gguf',
          backend: backend,
        );
        addTearDown(engine.dispose);
        await engine.load('${files.path}/model.gguf', profile);
        backend.gate = Completer<void>();
        final input = LlamaEmbeddingInput([const LlamaTextContent('text')]);
        expect(
          backend.lastMultimodalProjectorPath,
          '${files.path}/projector.gguf',
        );
        final result = await engine.cancelEmbedding(
          input,
          afterDispatch: after,
        );
        expect(result['precondition_met'], isTrue);
        expect(result['dispatch_observed'], after);
        expect(result['cancelled'], isTrue);
        expect(result['error_type'], 'LlamaInferenceException');
        expect(backend.received.length, after ? 4 : 0);
        backend.failure = null;
        backend.gate = null;
        expect(await engine.embedContent(input, normalize: false), [1.0]);
        expect(backend.normalized, isFalse);
        expect(await engine.embedContentBatch([input, input]), [
          [1.0],
          [1.0],
        ]);
        expect((await engine.embeddingCapabilities()).image, isTrue);
      },
    );
  }
  test(
    'already completed work cannot pass after-dispatch cancellation',
    () async {
      final backend = ContentBackend();
      final engine = PublicEmbeddingValidationEngine(
        projector: '${files.path}/projector.gguf',
        backend: backend,
      );
      addTearDown(engine.dispose);
      await engine.load('${files.path}/model.gguf', profile);
      expect(
        backend.lastMultimodalProjectorPath,
        '${files.path}/projector.gguf',
      );
      final result = await engine.cancelEmbedding(
        LlamaEmbeddingInput([const LlamaTextContent('text')]),
        afterDispatch: true,
      );
      expect(result['precondition_met'], isFalse);
      expect(result['cancelled'], isFalse);
    },
  );
}
