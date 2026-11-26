@TestOn('vm')
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/backends/llama_cpp/bindings.dart';
import 'package:llamadart/src/backends/llama_cpp/exit_teardown_api.dart';
import 'package:llamadart/src/backends/llama_cpp/llama_cpp_service.dart';
import 'package:test/test.dart';

import '../../../support/synthetic_embedding_gguf.dart';

const _modelParams = ModelParams(
  numberOfThreads: 2,
  numberOfThreadsBatch: 2,
  gpuLayers: 0,
  contextSize: 1024,
);

const _greedy = GenerationParams(
  maxTokens: 8,
  penalty: 1,
  temp: 0,
  topK: 0,
  topP: 1,
  seed: 7,
  reusePromptPrefix: false,
  grammar: 'root ::= "aa"',
);

const _a = 100;
const _b = 101;
const _nan = double.nan;
const _inf = double.infinity;

void main() {
  late LlamaCppService service;
  late int context;
  late int decodes;

  setUp(() {
    final dir = Directory.systemTemp.createTempSync(
      'llamadart_sampler_values_',
    );
    addTearDown(() => dir.deleteSync(recursive: true));
    decodes = 0;
    service = LlamaCppService(
      objectCalls: LlamaCppObjectCalls.untracked(
        decode: (ctx, batch) {
          decodes++;
          return llama_decode(ctx, batch);
        },
      ),
    )..initializeBackend();
    addTearDown(service.dispose);
    final path = writeSyntheticLlamaGguf(
      '${dir.path}/model.gguf',
      eosTokenId: 0,
    ).path;
    final model = service.loadModel(path, _modelParams);
    context = service.createContext(model, _modelParams);
  });

  Future<List<int>> generate(GenerationParams params) async {
    final cancel = calloc<Int8>();
    try {
      return await service
          .generate(context, 'ab', params, cancel.address)
          .expand((piece) => piece)
          .toList();
    } finally {
      calloc.free(cancel);
    }
  }

  for (final (name, field, params) in [
    ('NaN penalty', 'penalty', _greedy.copyWith(penalty: _nan)),
    ('infinite penalty', 'penalty', _greedy.copyWith(penalty: _inf)),
    ('zero penalty', 'penalty', _greedy.copyWith(penalty: 0)),
    ('negative penalty', 'penalty', _greedy.copyWith(penalty: -1)),
    ('penalty below limit', 'penalty', _greedy.copyWith(penalty: 0.0009)),
    ('penalty above limit', 'penalty', _greedy.copyWith(penalty: 101)),
    (
      'penalty that overflows a biased logit',
      'penalty',
      _greedy.copyWith(penalty: 1e35, logitBias: const {_a: -10000}),
    ),
    (
      'infinite presence penalty',
      'presencePenalty',
      _greedy.copyWith(presencePenalty: _inf),
    ),
    (
      'NaN presence penalty',
      'presencePenalty',
      _greedy.copyWith(presencePenalty: _nan),
    ),
    (
      'presence penalty above limit',
      'presencePenalty',
      _greedy.copyWith(presencePenalty: 101),
    ),
    (
      'presence penalty below limit',
      'presencePenalty',
      _greedy.copyWith(presencePenalty: -101),
    ),
    ('NaN temperature', 'temp', _greedy.copyWith(temp: _nan)),
    ('infinite temperature', 'temp', _greedy.copyWith(temp: _inf)),
    ('negative infinite temperature', 'temp', _greedy.copyWith(temp: -_inf)),
    ('denormal temperature', 'temp', _greedy.copyWith(temp: 1e-40)),
    (
      'tiny temperature with a bias',
      'temp',
      _greedy.copyWith(temp: 1e-35, logitBias: const {_a: 10000}),
    ),
    ('temperature above limit', 'temp', _greedy.copyWith(temp: 1e7)),
    ('NaN top-p', 'topP', _greedy.copyWith(topP: _nan)),
    ('infinite top-p', 'topP', _greedy.copyWith(topP: _inf)),
    ('NaN min-p', 'minP', _greedy.copyWith(minP: _nan)),
    ('infinite min-p', 'minP', _greedy.copyWith(minP: _inf)),
  ]) {
    test('rejects $name before decoding', () async {
      await expectLater(
        generate(params),
        throwsA(
          isA<LlamaArgumentException>().having((e) => e.name, 'name', field),
        ),
      );
      expect(decodes, 0);
    });
  }

  test('keeps the grammar for the documented extremes', () async {
    const bias = {_a: -10000.0, _b: 10000.0};
    for (final params in [
      _greedy,
      _greedy.copyWith(penalty: 100, logitBias: bias),
      _greedy.copyWith(penalty: 0.001, logitBias: bias),
      _greedy.copyWith(
        penalty: 100,
        presencePenalty: 100,
        frequencyPenalty: 100,
      ),
      _greedy.copyWith(presencePenalty: -100),
      _greedy.copyWith(temp: 1e-6, logitBias: {_a: 10000}),
      _greedy.copyWith(temp: 1e-6, penalty: 100, logitBias: bias),
      _greedy.copyWith(temp: 1e6, logitBias: bias),
      _greedy.copyWith(temp: -1),
      _greedy.copyWith(temp: 0.8),
    ]) {
      expect(await generate(params), [97, 97], reason: '$params');
    }
  });
}
