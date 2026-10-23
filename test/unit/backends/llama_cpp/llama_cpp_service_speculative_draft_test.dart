@TestOn('vm')
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:llamadart/src/backends/llama_cpp/bindings.dart';
import 'package:llamadart/src/backends/llama_cpp/exit_teardown_api.dart';
import 'package:llamadart/src/backends/llama_cpp/llama_cpp_service.dart';
import 'package:llamadart/src/core/exceptions.dart';
import 'package:llamadart/src/core/models/inference/generation_params.dart';
import 'package:llamadart/src/core/models/inference/model_params.dart';
import 'package:llamadart/src/core/models/model_source.dart';
import 'package:test/test.dart';

import '../../../support/synthetic_embedding_gguf.dart';

final _draft = ModelSource.path('draft.gguf');

GenerationParams _speculative(SpeculativeDecodingConfig config) =>
    GenerationParams(speculativeDecodingConfig: config);

Matcher _argumentError(String message) => throwsA(
  isA<LlamaArgumentException>()
      .having((error) => error.name, 'name', 'draftMicroBatchSize')
      .having((error) => error.message, 'message', contains(message)),
);

void main() {
  group('draftMicroBatchSize', () {
    final service = LlamaCppService();

    Object? resolve(SpeculativeDecodingConfig config) =>
        service.debugResolveSpeculativeNativeParamsForTesting(
          _speculative(config),
        )['draftMicroBatchSize'];

    test('reaches the native config of each draft-context strategy', () {
      for (final config in <SpeculativeDecodingConfig>[
        SpeculativeDecodingConfig.draftSimple(
          draftModel: _draft,
          draftMicroBatchSize: 8,
        ),
        SpeculativeDecodingConfig.draftEagle3(
          draftModel: _draft,
          draftMicroBatchSize: 8,
        ),
        const SpeculativeDecodingConfig.mtp(draftMicroBatchSize: 8),
        SpeculativeDecodingConfig.mixed(
          strategies: [
            SpeculativeDecodingStrategy.ngramMod,
            SpeculativeDecodingStrategy.draftSimple,
          ],
          draftModel: _draft,
          draftMicroBatchSize: 8,
        ),
      ]) {
        expect(resolve(config), 8, reason: '${config.effectiveStrategies}');
      }
      expect(
        resolve(SpeculativeDecodingConfig.draftSimple(draftModel: _draft)),
        isNull,
      );
    });

    test('rejects a value below one', () {
      for (final size in [0, -1]) {
        expect(
          () => resolve(
            SpeculativeDecodingConfig.draftSimple(
              draftModel: _draft,
              draftMicroBatchSize: size,
            ),
          ),
          _argumentError('must be at least 1'),
        );
      }
    });

    test('rejects n-gram strategies, which have no draft context', () {
      expect(
        () => resolve(
          const SpeculativeDecodingConfig.mixed(
            strategies: [
              SpeculativeDecodingStrategy.ngramMod,
              SpeculativeDecodingStrategy.ngramSimple,
            ],
            draftMicroBatchSize: 8,
          ),
        ),
        throwsA(
          isA<LlamaUnsupportedException>().having(
            (error) => error.message,
            'message',
            contains('creates no draft context'),
          ),
        ),
      );
    });

    test('needs a whole draft block for draft-dflash and draft-dspark', () {
      for (final strategy in [
        SpeculativeDecodingStrategy.draftDflash,
        SpeculativeDecodingStrategy.draftDspark,
      ]) {
        SpeculativeDecodingConfig config(int size) =>
            SpeculativeDecodingConfig.mixed(
              strategies: [strategy],
              draftModel: _draft,
              draftTokenMax: 4,
              draftMicroBatchSize: size,
            );

        expect(
          () => resolve(config(4)),
          _argumentError('at least draftTokenMax + 1 (5)'),
          reason: '$strategy',
        );
        expect(resolve(config(5)), 5, reason: '$strategy');
      }
      // The block holds the effective draft length, which a mixed n-gram
      // strategy can raise.
      expect(
        () => resolve(
          SpeculativeDecodingConfig.mixed(
            strategies: [
              SpeculativeDecodingStrategy.ngramSimple,
              SpeculativeDecodingStrategy.draftDflash,
            ],
            draftModel: _draft,
            draftTokenMax: 4,
            ngramSizeM: 16,
            draftMicroBatchSize: 5,
          ),
        ),
        _argumentError('(17)'),
      );
      expect(
        resolve(
          SpeculativeDecodingConfig.draftSimple(
            draftModel: _draft,
            draftTokenMax: 4,
            draftMicroBatchSize: 1,
          ),
        ),
        1,
      );
    });

    test("must fit the context's logical batch and context size", () {
      void validate(int? size, {required int batch, required int context}) =>
          service.debugValidateDraftMicroBatchSizeForTesting(
            _speculative(
              SpeculativeDecodingConfig.draftSimple(
                draftModel: _draft,
                draftMicroBatchSize: size,
              ),
            ),
            batchSize: batch,
            contextSize: context,
          );

      expect(() => validate(null, batch: 8, context: 8), returnsNormally);
      expect(() => validate(512, batch: 512, context: 2048), returnsNormally);
      expect(
        () => validate(513, batch: 512, context: 2048),
        _argumentError('logical batch size (512)'),
      );
      expect(
        () => validate(257, batch: 512, context: 256),
        _argumentError('logical batch size (256)'),
      );
    });
  });

  // Runs the real llama.cpp runtime on the CPU: a draft-simple session whose
  // synthetic draft model is the target's own file.
  group('draft context', () {
    late Directory dir;
    late LlamaCppService service;
    late int context;
    late List<int> draftMicroBatches;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('llamadart_draft_ubatch_');
      writeSyntheticLlamaGguf('${dir.path}/model.gguf');
      service = LlamaCppService(objectCalls: LlamaCppObjectCalls.upstream)
        ..initializeBackend();
      const params = ModelParams(
        gpuLayers: 0,
        contextSize: 64,
        batchSize: 64,
        microBatchSize: 32,
      );
      final model = service.loadModel('${dir.path}/model.gguf', params);
      context = service.createContext(model, params);
      draftMicroBatches = [];
      service.debugOnSpeculativeDraftContextForTesting = (draft) =>
          draftMicroBatches.add(llama_n_ubatch(draft));
    });

    tearDown(() {
      service.dispose();
      dir.deleteSync(recursive: true);
    });

    Future<List<int>> generate(int? draftMicroBatchSize) async {
      final cancel = calloc<Int8>();
      try {
        final bytes = <int>[];
        await for (final chunk in service.generate(
          context,
          'abababab',
          GenerationParams(
            maxTokens: 12,
            temp: 0,
            topK: 1,
            seed: 1,
            penalty: 1,
            speculativeDecodingConfig: SpeculativeDecodingConfig.draftSimple(
              draftModel: ModelSource.path('${dir.path}/model.gguf'),
              draftTokenMax: 4,
              draftMicroBatchSize: draftMicroBatchSize,
            ),
          ),
          cancel.address,
        )) {
          bytes.addAll(chunk);
        }
        return bytes;
      } finally {
        calloc.free(cancel);
      }
    }

    test('takes the draft micro-batch size, and the target size unset, '
        'with the same output', () async {
      final unset = await generate(null);
      final reduced = await generate(2);

      expect(draftMicroBatches, [32, 2]);
      expect(unset, isNotEmpty);
      expect(reduced, unset);
    });

    test("rejects a size above the context's logical batch before creating "
        'a session', () async {
      await expectLater(generate(65), _argumentError('(64)'));
      expect(draftMicroBatches, isEmpty);
    });
  });
}
