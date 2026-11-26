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
  maxTokens: 48,
  penalty: 1,
  temp: 0,
  topK: 0,
  topP: 1,
  seed: 7,
  reusePromptPrefix: false,
);

const _vocabSize = 259;
const _eos = 0;
const _a = 100;
const _b = 101;
const _ban = double.negativeInfinity;
const _banWithGrammar =
    'GenerationParams.logitBias cannot ban tokens with a grammar (including '
    'one from tools or responseFormat). Use finite biases or remove the grammar.';

void main() {
  late LlamaCppService service;
  late String modelPath;
  late int model;
  late int context;
  late int decodes;

  setUp(() {
    final dir = Directory.systemTemp.createTempSync(
      'llamadart_sampler_controls_',
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
    modelPath = writeSyntheticLlamaGguf(
      '${dir.path}/model.gguf',
      eosTokenId: _eos,
    ).path;
    model = service.loadModel(modelPath, _modelParams);
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

  test('loaded llama.cpp reports the sampler controls', () {
    expect(service.generationCapabilities(model).samplerControls, {
      SamplerControl.frequencyPenalty,
      SamplerControl.penaltyLastN,
      SamplerControl.logitBias,
      SamplerControl.typicalP,
      SamplerControl.topNSigma,
      SamplerControl.xtc,
      SamplerControl.dynamicTemperature,
      SamplerControl.mirostat,
    });
  });

  test(
    'engine carries sampler controls and typed errors across the worker',
    () async {
      final engine = LlamaEngine(LlamaBackend());
      addTearDown(engine.dispose);
      await engine.loadModel(modelPath, modelParams: _modelParams);
      expect(
        (await engine.capabilities).samplerControls,
        service.generationCapabilities(model).samplerControls,
      );
      final params = _greedy.copyWith(
        maxTokens: 4,
        frequencyPenalty: 1,
        penaltyLastN: 0,
        logitBias: const {_a: 100},
      );
      expect(await engine.generate('ab', params: params).join(), 'aaaa');
      await expectLater(
        engine.generate(
          'ab',
          params: params.copyWith(logitBias: const {-1: 1}),
        ),
        emitsError(isA<LlamaArgumentException>()),
      );
    },
  );

  test('frequency penalty changes greedy generation', () async {
    expect(await generate(_greedy), List.filled(48, 98));
    final penalized = await generate(_greedy.copyWith(frequencyPenalty: 100));
    expect(penalized, hasLength(48));
    expect(penalized.toSet(), hasLength(48));
  });

  test(
    'zero disables penalties and two produces a period-three cycle',
    () async {
      expect(
        await generate(
          _greedy.copyWith(
            frequencyPenalty: 100,
            penalty: 2,
            presencePenalty: 100,
            penaltyLastN: 0,
          ),
        ),
        List.filled(48, 98),
      );
      final two = await generate(
        _greedy.copyWith(frequencyPenalty: 100, penaltyLastN: 2),
      );
      expect(two, hasLength(48));
      expect(
        two.skip(10),
        List.generate(38, (index) => const [9, 108, 117][index % 3]),
      );
    },
  );

  test('last N of -1 uses the full context', () async {
    final params = _greedy.copyWith(maxTokens: 120, frequencyPenalty: 100);
    final defaultWindow = await generate(params);
    expect(defaultWindow, hasLength(120));
    expect(defaultWindow.toSet(), hasLength(95));
    final fullWindow = await generate(params.copyWith(penaltyLastN: -1));
    expect(fullWindow, hasLength(120));
    expect(fullWindow.toSet(), hasLength(120));
  });

  test('large penalty windows clamp to context size before FFI', () async {
    final params = _greedy.copyWith(maxTokens: 120, frequencyPenalty: 100);
    final fullWindow = await generate(
      params.copyWith(penaltyLastN: service.getContextSize(context)),
    );
    expect(fullWindow, hasLength(120));
    expect(fullWindow.toSet(), hasLength(120));
    for (final lastN in [2147483648, 0x7fffffffffffffff]) {
      expect(await generate(params.copyWith(penaltyLastN: lastN)), fullWindow);
    }
  });

  test('logit bias can favor or ban a token', () async {
    expect(
      await generate(_greedy.copyWith(logitBias: const {_a: 100})),
      List.filled(48, 97),
    );
    final banned = await generate(
      _greedy.copyWith(logitBias: const {_b: _ban}),
    );
    expect(banned, hasLength(48));
    expect(banned, isNot(contains(98)));
  });

  test('ignoreEos still suppresses positively biased end tokens', () async {
    final params = _greedy.copyWith(logitBias: const {_eos: 100});
    expect(await generate(params), isEmpty);
    expect(
      await generate(params.copyWith(ignoreEos: true)),
      List.filled(48, 98),
    );
  });

  test(
    'rejects a bias that bans the whole vocabulary before decoding',
    () async {
      final params = _greedy.copyWith(
        logitBias: {for (var id = 0; id < _vocabSize; id++) id: _ban},
      );
      await expectLater(
        generate(params),
        throwsA(
          isA<LlamaArgumentException>().having(
            (e) => e.name,
            'name',
            'logitBias',
          ),
        ),
      );
      expect(decodes, 0);
    },
  );

  test('allows one unbanned token unless ignoreEos suppresses it', () async {
    final allButEos = _greedy.copyWith(
      logitBias: {
        for (var id = 0; id < _vocabSize; id++)
          if (id != _eos) id: _ban,
      },
    );
    await expectLater(
      generate(allButEos.copyWith(ignoreEos: true)),
      throwsA(
        isA<LlamaArgumentException>().having(
          (e) => e.name,
          'name',
          'logitBias',
        ),
      ),
    );
    expect(decodes, 0);

    final allButA = _greedy.copyWith(
      logitBias: {
        for (var id = 0; id < _vocabSize; id++)
          if (id != _a) id: _ban,
      },
    );
    expect(await generate(allButA), List.filled(48, 97));
  });

  for (final lazy in [false, true]) {
    test(
      'rejects token bans with ${lazy ? 'lazy' : 'eager'} grammar before decoding',
      () async {
        final params = _greedy.copyWith(
          grammar: 'root ::= "a"',
          grammarLazy: lazy,
          grammarTriggers: lazy
              ? const [
                  GenerationGrammarTrigger.typed(
                    type: GrammarTriggerType.word,
                    value: 'a',
                  ),
                ]
              : const [],
          logitBias: const {_a: _ban},
        );
        await expectLater(
          generate(params),
          throwsA(
            isA<LlamaUnsupportedException>().having(
              (e) => e.message,
              'message',
              _banWithGrammar,
            ),
          ),
        );
        expect(decodes, 0);
      },
    );
  }

  test('rejects token bans with a thinking budget before decoding', () async {
    final params = _greedy.copyWith(
      thinkingBudget: const ThinkingBudget(
        maxTokens: 1,
        startTag: 'a',
        endTag: 'b',
      ),
      logitBias: const {_a: _ban},
    );
    await expectLater(
      generate(params),
      throwsA(
        isA<LlamaUnsupportedException>().having(
          (e) => e.message,
          'message',
          contains('thinking budget'),
        ),
      ),
    );
    expect(decodes, 0);
  });

  test(
    'allows finite biases with a grammar for greedy and distribution sampling',
    () async {
      final params = _greedy.copyWith(
        grammar: 'root ::= "a"',
        logitBias: const {_a: -10000},
      );
      expect(await generate(params), [97]);
      expect(await generate(params.copyWith(temp: 0.8)), [97]);
    },
  );

  test('allows frequency penalty with a grammar', () async {
    final params = _greedy.copyWith(
      grammar: 'root ::= "aaaa"',
      frequencyPenalty: 100,
    );
    expect(await generate(params), [97, 97, 97, 97]);
  });

  for (final (name, field, params) in [
    (
      'negative window',
      'penaltyLastN',
      const GenerationParams(penaltyLastN: -2),
    ),
    (
      'frequency above limit',
      'frequencyPenalty',
      const GenerationParams(frequencyPenalty: 101),
    ),
    (
      'frequency below limit',
      'frequencyPenalty',
      const GenerationParams(frequencyPenalty: -101),
    ),
    (
      'infinite frequency',
      'frequencyPenalty',
      const GenerationParams(frequencyPenalty: double.infinity),
    ),
    (
      'NaN frequency',
      'frequencyPenalty',
      const GenerationParams(frequencyPenalty: double.nan),
    ),
    (
      'bias above limit',
      'logitBias',
      const GenerationParams(logitBias: {_a: 10001}),
    ),
    (
      'bias below limit',
      'logitBias',
      const GenerationParams(logitBias: {_a: -1e39}),
    ),
    (
      'infinite bias',
      'logitBias',
      const GenerationParams(logitBias: {_a: double.infinity}),
    ),
    (
      'NaN bias',
      'logitBias',
      const GenerationParams(logitBias: {_a: double.nan}),
    ),
    (
      'negative token ID',
      'logitBias',
      const GenerationParams(logitBias: {-1: 1}),
    ),
    (
      'out-of-vocabulary token ID',
      'logitBias',
      const GenerationParams(logitBias: {_vocabSize: 1}),
    ),
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
}
