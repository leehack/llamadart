@TestOn('vm')
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:llamadart/src/backends/llama_cpp/exit_teardown_api.dart';
import 'package:llamadart/src/backends/llama_cpp/llama_cpp_service.dart';
import 'package:llamadart/src/core/exceptions.dart';
import 'package:llamadart/src/core/models/inference/generation_params.dart';
import 'package:llamadart/src/core/models/inference/model_params.dart';
import 'package:test/test.dart';

import '../../../support/fake_mtmd.dart';
import '../../../support/synthetic_embedding_gguf.dart';

const _greedy = GenerationParams(maxTokens: 4, temp: 0, topK: 1, seed: 1);
const _imageText = 'abcdefgh';

// Runs the real llama.cpp runtime on the CPU with a stand-in projector whose
// non-causal image decode is a real non-causal llama_decode: one above
// n_ubatch aborts the process on llama.cpp's own assertion.
void main() {
  late Directory dir;
  late LlamaCppService service;
  late FakeMtmd mtmd;
  late int context;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('llamadart_media_ubatch_');
    writeSyntheticLlamaGguf('${dir.path}/model.gguf');
    File('${dir.path}/mmproj.gguf').writeAsStringSync('GGUF');
    service = LlamaCppService(objectCalls: LlamaCppObjectCalls.upstream)
      ..initializeBackend();
  });

  tearDown(() {
    service.dispose();
    mtmd.dispose();
    dir.deleteSync(recursive: true);
  });

  /// Loads the model with a projector whose one image has the 12 tokens of
  /// [_imageText] and a BOS.
  void load({
    required int batchSize,
    required int microBatchSize,
    FakeMtmdChunk chunk = FakeMtmdChunk.nonCausalImage,
    bool chunkEval = true,
  }) {
    final params = ModelParams(
      gpuLayers: 0,
      contextSize: 64,
      batchSize: batchSize,
      microBatchSize: microBatchSize,
    );
    final model = service.loadModel('${dir.path}/model.gguf', params);
    context = service.createContext(model, params);
    mtmd = FakeMtmd.install(
      service,
      tokens: service.tokenize(model, _imageText, true),
      chunkEval: chunkEval,
      chunk: chunk,
    );
    expect(mtmd.tokens, hasLength(12));
    service.createMultimodalContext(model, '${dir.path}/mmproj.gguf');
    mtmd.calls.clear();
  }

  Future<void> generate(String prompt, {bool image = false}) async {
    final cancel = calloc<Int8>();
    try {
      await service
          .generate(
            context,
            prompt,
            _greedy,
            cancel.address,
            parts: image ? mtmd.parts : null,
          )
          .drain<void>();
    } finally {
      calloc.free(cancel);
    }
  }

  Matcher aboveMicroBatch(int limit) => isA<LlamaInferenceException>().having(
    (error) => error.message,
    'message',
    'The image input has 12 tokens, but this projector decodes it in one '
        'pass of at most $limit tokens (n_ubatch). Raise '
        'ModelParams.microBatchSize and ModelParams.batchSize to at least '
        '12, or pass a smaller image if the projector sizes its output by '
        'the input.',
  );

  for (final (name, batchSize) in [
    ('below the batch', 16),
    ('equal to the batch', 8),
  ]) {
    test('a non-causal image above a micro-batch $name is a typed error '
        'before any evaluation, and the context still generates', () async {
      load(batchSize: batchSize, microBatchSize: 8);

      await expectLater(
        generate('<__media__>', image: true),
        throwsA(aboveMicroBatch(8)),
      );

      expect(mtmd.calls, ['mtmd_tokenize']);
      expect(mtmd.evaluations, 0);
      await generate('ab');
    });
  }

  test('a non-causal image of exactly the micro-batch is decoded in one '
      'pass', () async {
    load(batchSize: 16, microBatchSize: 12);

    await generate('<__media__>', image: true);

    expect(mtmd.calls, [
      'mtmd_tokenize',
      'mtmd_encode_chunk',
      'mtmd_helper_decode_image_chunk',
    ]);
    expect(mtmd.evaluations, 1);
  });

  test('a causal image above the micro-batch is decoded', () async {
    load(batchSize: 8, microBatchSize: 4, chunk: FakeMtmdChunk.causalImage);

    await generate('<__media__>', image: true);

    expect(mtmd.calls, [
      'mtmd_tokenize',
      'mtmd_encode_chunk',
      'mtmd_helper_decode_image_chunk',
    ]);
  });

  test('a runtime without the chunk-level functions evaluates the prompt '
      'unchecked', () async {
    load(batchSize: 8, microBatchSize: 8, chunkEval: false);

    await generate('<__media__>', image: true);

    expect(mtmd.calls, ['mtmd_tokenize', 'mtmd_helper_eval_chunks']);
  });
}
