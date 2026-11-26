@TestOn('vm')
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:mirrors';

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
  maxTokens: 24,
  penalty: 1,
  temp: 0,
  topK: 0,
  topP: 1,
  seed: 7,
  reusePromptPrefix: false,
);

const _sampled = GenerationParams(
  maxTokens: 24,
  penalty: 1,
  temp: 1,
  topK: 0,
  topP: 1,
  seed: 7,
  reusePromptPrefix: false,
);

const _eos = 0;

const _dynamicTemperatureWithMasking =
    'GenerationParams.dynatempRange cannot be combined with a grammar '
    '(including one from tools or responseFormat), a thinking budget, '
    'ignoreEos, model-suppressed tokens or a negative-infinity logitBias: '
    'llama.cpp can then select a masked token. Use a fixed temp or remove '
    'them.';
const _a = 100;

// With a +5 bias on 'a' the greedy token is 'a' (97), and 'b' (98) is the
// only other candidate above this threshold, so XTC swaps the two.
const _xtcOverBias = GenerationParams(
  maxTokens: 12,
  penalty: 1,
  temp: 0,
  topK: 0,
  topP: 1,
  seed: 7,
  reusePromptPrefix: false,
  logitBias: {_a: 5},
  xtcProbability: 1,
  xtcThreshold: 0.005,
);

const _forcedEndTag = [226, 150, 129, 98];

const _budget = ThinkingBudget(
  maxTokens: 1,
  startTag: 'a',
  endTag: 'b',
  forcedMessage: 'b',
);

void main() {
  late LlamaCppService service;
  late String modelPath;
  late int model;
  late int context;
  late int decodes;

  setUp(() {
    final dir = Directory.systemTemp.createTempSync(
      'llamadart_sampler_shapes_',
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

  Future<List<int>> generate(GenerationParams params, [int? ctx]) async {
    final cancel = calloc<Int8>();
    try {
      return await service
          .generate(ctx ?? context, 'ab', params, cancel.address)
          .expand((piece) => piece)
          .toList();
    } finally {
      calloc.free(cancel);
    }
  }

  List<String> chainNames(
    GenerationParams params, [
    List<int> suppressed = const [],
  ]) {
    final sampler = _invokePrivateForTesting<Pointer<llama_sampler>>(
      service,
      '_initializeSampler',
      [
        params,
        nullptr,
        259,
        1024,
        suppressed,
        nullptr,
        nullptr,
        null,
        null,
        null,
        0,
        nullptr,
        false,
      ],
    );
    try {
      return List.generate(
        llama_sampler_chain_n(sampler),
        (index) => llama_sampler_name(
          llama_sampler_chain_get(sampler, index),
        ).cast<Utf8>().toDartString(),
      );
    } finally {
      _invokePrivateForTesting<void>(service, '_freeSamplerChain', [sampler]);
    }
  }

  test('loaded llama.cpp reports every sampler control', () {
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

  group('sampler chain', () {
    const defaultNames = ['penalties', 'top-k', 'top-p', 'temp', 'dist'];

    test('defaults and explicit default values keep the default chain', () {
      const defaults = GenerationParams();
      expect(chainNames(defaults), defaultNames);
      expect(
        chainNames(
          defaults.copyWith(
            typicalP: 1,
            topNSigma: -1,
            xtcProbability: 0,
            xtcThreshold: 0.1,
            dynatempRange: 0,
            dynatempExponent: 1,
            mirostat: 0,
            mirostatTau: 5,
            mirostatEta: 0.1,
          ),
        ),
        defaultNames,
      );
    });

    for (final (label, params, names) in [
      (
        'top-n-sigma runs before top-k',
        const GenerationParams(topNSigma: 1),
        ['penalties', 'top-n-sigma', 'top-k', 'top-p', 'temp', 'dist'],
      ),
      (
        'typical runs between top-k and top-p',
        const GenerationParams(typicalP: 0.5),
        ['penalties', 'top-k', 'typical', 'top-p', 'temp', 'dist'],
      ),
      (
        'xtc runs after min-p and before temperature',
        const GenerationParams(
          minP: 0.05,
          xtcProbability: 0.5,
          xtcThreshold: 0.2,
        ),
        ['penalties', 'top-k', 'top-p', 'min-p', 'xtc', 'temp', 'dist'],
      ),
      (
        'dynamic temperature replaces temp',
        const GenerationParams(dynatempRange: 0.5),
        ['penalties', 'top-k', 'top-p', 'temp-ext', 'dist'],
      ),
      (
        'greedy keeps xtc before the final greedy sampler',
        const GenerationParams(temp: 0, xtcProbability: 1),
        ['penalties', 'top-k', 'top-p', 'xtc', 'temp', 'greedy'],
      ),
      (
        'every sampler together',
        const GenerationParams(
          logitBias: {3: 1},
          topNSigma: 2,
          typicalP: 0.9,
          minP: 0.05,
          xtcProbability: 0.3,
          dynatempRange: 0.4,
          dynatempExponent: 2,
        ),
        [
          'logit-bias',
          'penalties',
          'top-n-sigma',
          'top-k',
          'typical',
          'top-p',
          'min-p',
          'xtc',
          'temp-ext',
          'dist',
        ],
      ),
    ]) {
      test(label, () => expect(chainNames(params), names));
    }

    test('mirostat replaces everything after penalties and suppression', () {
      const tuned = GenerationParams(topK: 5, topP: 0.5, minP: 0.2);
      expect(chainNames(tuned.copyWith(mirostat: 1)), [
        'penalties',
        'temp',
        'mirostat',
      ]);
      expect(chainNames(tuned.copyWith(mirostat: 2)), [
        'penalties',
        'temp',
        'mirostat-v2',
      ]);
      expect(
        chainNames(tuned.copyWith(mirostat: 2, logitBias: const {3: 1}), [4]),
        ['logit-bias', 'penalties', 'logit-bias', 'temp', 'mirostat-v2'],
      );
    });
  });

  group('behavior', () {
    test('default-valued controls leave generation unchanged', () async {
      final baseline = await generate(_sampled);
      expect(
        await generate(
          _sampled.copyWith(
            typicalP: 1,
            topNSigma: -1,
            xtcProbability: 0,
            xtcThreshold: 0.1,
            dynatempRange: 0,
            dynatempExponent: 1,
            mirostat: 0,
            mirostatTau: 5,
            mirostatEta: 0.1,
          ),
        ),
        baseline,
      );
    });

    test('typical-P filters the distribution deterministically', () async {
      final baseline = await generate(_sampled);
      final typical = await generate(_sampled.copyWith(typicalP: 0.01));
      expect(typical, isNot(baseline));
      expect(await generate(_sampled.copyWith(typicalP: 0.01)), typical);
      expect(await generate(_sampled.copyWith(typicalP: 0.5)), isNot(typical));
    });

    test('typical-P keeps at least one candidate and no more', () async {
      final tight = _sampled.copyWith(typicalP: 1e-6);
      final first = await generate(tight);
      expect(first, isNotEmpty);
      expect(await generate(tight.copyWith(seed: 11)), first);
      expect(await generate(tight.copyWith(seed: 13)), first);
    });

    test(
      'top-n-sigma narrows high temperature sampling to the top token',
      () async {
        const hot = GenerationParams(
          maxTokens: 24,
          penalty: 1,
          temp: 3,
          topK: 0,
          topP: 1,
          seed: 7,
          reusePromptPrefix: false,
        );
        expect(await generate(hot), isNot(List.filled(24, 98)));
        expect(
          await generate(hot.copyWith(topNSigma: 1e-6)),
          List.filled(24, 98),
        );
      },
    );

    test('xtc swaps the top two candidates when it triggers', () async {
      expect(
        await generate(
          _xtcOverBias.copyWith(xtcProbability: 0, xtcThreshold: 0.1),
        ),
        List.filled(12, 97),
      );
      expect(await generate(_xtcOverBias), List.filled(12, 98));
    });

    test('xtc may remove the top of a two-candidate set', () async {
      expect(
        await generate(_xtcOverBias.copyWith(topK: 2)),
        List.filled(12, 98),
      );
    });

    test('xtc and mirostat use the request seed', () async {
      final half = _xtcOverBias.copyWith(xtcProbability: 0.5);
      final first = await generate(half);
      expect(first.toSet(), {97, 98});
      expect(await generate(half), first);
      expect(await generate(half.copyWith(seed: 11)), isNot(first));

      for (final mode in [1, 2]) {
        final params = _sampled.copyWith(mirostat: mode);
        final output = await generate(params);
        expect(await generate(params), output);
        expect(await generate(params.copyWith(seed: 11)), isNot(output));
      }
    });

    test('dynamic temperature differs from fixed temperature', () async {
      final fixed = await generate(_sampled);
      final dynamic = await generate(_sampled.copyWith(dynatempRange: 0.9));
      expect(dynamic, isNot(fixed));
      expect(await generate(_sampled.copyWith(dynatempRange: 0.9)), dynamic);
      expect(
        await generate(_sampled.copyWith(dynatempRange: 0.3)),
        isNot(dynamic),
      );
      expect(
        await generate(
          _sampled.copyWith(dynatempRange: 0.9, dynatempExponent: 3),
        ),
        isNot(dynamic),
      );
    });

    test('dynamic temperature applies the request temperature', () async {
      final params = _sampled.copyWith(dynatempRange: 0.3);
      final outputs = {
        for (final temp in [0.5, 1.0, 1.5])
          temp: (await generate(params.copyWith(temp: temp))).join(','),
      };
      expect(outputs.values.toSet(), hasLength(3));
    });

    test('dynamic temperature at the floor stays valid', () async {
      const confident = GenerationParams(
        maxTokens: 12,
        penalty: 1,
        temp: 1,
        topK: 0,
        topP: 1,
        seed: 7,
        reusePromptPrefix: false,
        logitBias: {_a: 10000},
        dynatempRange: 0.98,
        dynatempExponent: 3,
      );
      expect(await generate(confident), List.filled(12, 97));
      expect(
        await generate(
          confident.copyWith(topK: 40, topP: 0.9, logitBias: const {_a: 90}),
        ),
        List.filled(12, 97),
      );
    });

    test('mirostat versions, tau and eta change generation', () async {
      final v1 = await generate(_sampled.copyWith(mirostat: 1));
      final v2 = await generate(_sampled.copyWith(mirostat: 2));
      expect(v1, isNotEmpty);
      expect(v2, isNotEmpty);
      expect(v1, isNot(v2));
      expect(v1, isNot(await generate(_sampled)));
      for (final mode in [1, 2]) {
        final tuned = _sampled.copyWith(mirostat: mode);
        expect(
          await generate(tuned.copyWith(mirostatTau: 1)),
          List.filled(24, 98),
        );
        final loose = await generate(tuned.copyWith(mirostatTau: 8));
        expect(loose.where((token) => token == 98), hasLength(lessThan(3)));
        expect(
          await generate(tuned.copyWith(mirostatTau: 2, mirostatEta: 0.5)),
          isNot(
            await generate(tuned.copyWith(mirostatTau: 2, mirostatEta: 0.1)),
          ),
        );
      }
    });

    test('mirostat applies the request temperature', () async {
      for (final mode in [1, 2]) {
        final params = _sampled.copyWith(mirostat: mode);
        expect(
          await generate(params.copyWith(temp: 0.5)),
          isNot(await generate(params)),
        );
      }
    });

    test('mirostat ignores top-k, top-p and min-p', () async {
      final plain = await generate(_sampled.copyWith(mirostat: 2));
      expect(
        await generate(
          _sampled.copyWith(mirostat: 2, topK: 1, topP: 0.1, minP: 0.5),
        ),
        plain,
      );
    });

    test(
      'engine carries the controls and typed errors across the worker',
      () async {
        final engine = LlamaEngine(LlamaBackend());
        addTearDown(engine.dispose);
        await engine.loadModel(modelPath, modelParams: _modelParams);
        expect(
          (await engine.capabilities).samplerControls,
          service.generationCapabilities(model).samplerControls,
        );
        expect(
          await engine.generate('ab', params: _xtcOverBias).join(),
          'b' * 12,
        );
        await expectLater(
          engine.generate('ab', params: _greedy.copyWith(typicalP: 0)),
          emitsError(isA<LlamaArgumentException>()),
        );
      },
    );
  });

  group('with a single-token grammar', () {
    final grammar = _greedy.copyWith(grammar: 'root ::= "a"');
    for (final (label, params) in [
      ('typical-P', const GenerationParams(typicalP: 0.3)),
      ('top-n-sigma', const GenerationParams(topNSigma: 1)),
      ('xtc', const GenerationParams(xtcProbability: 1)),
      (
        'xtc at a low threshold',
        const GenerationParams(xtcProbability: 1, xtcThreshold: 0.005),
      ),
      ('mirostat 1', const GenerationParams(mirostat: 1)),
      ('mirostat 2', const GenerationParams(mirostat: 2)),
    ]) {
      for (final temp in [0.0, 0.8]) {
        if (temp == 0 && params.mirostat != 0) {
          continue;
        }
        test('$label keeps the only valid token at temp $temp', () async {
          final request = grammar.copyWith(
            temp: temp,
            typicalP: params.typicalP,
            topNSigma: params.topNSigma,
            xtcProbability: params.xtcProbability,
            xtcThreshold: params.xtcThreshold,
            mirostat: params.mirostat,
          );
          expect(await generate(request), [97]);
        });
      }
    }
  });

  group('with a thinking budget', () {
    final budgeted = _greedy.copyWith(maxTokens: 8, thinkingBudget: _budget);
    for (final (label, params) in [
      ('typical-P', const GenerationParams(temp: 0.8, typicalP: 0.3)),
      ('top-n-sigma', const GenerationParams(temp: 0.8, topNSigma: 1)),
      ('xtc', const GenerationParams(temp: 0.8, xtcProbability: 1)),
      ('mirostat 1', const GenerationParams(temp: 0.8, mirostat: 1)),
      ('mirostat 2', const GenerationParams(temp: 0.8, mirostat: 2)),
    ]) {
      test('$label still lets the budget force its end tag', () async {
        final output = await generate(
          budgeted.copyWith(
            temp: params.temp,
            typicalP: params.typicalP,
            topNSigma: params.topNSigma,
            xtcProbability: params.xtcProbability,
            mirostat: params.mirostat,
          ),
        );
        expect(output.join(','), contains(_forcedEndTag.join(',')));
      });
    }
  });

  group('dynamic temperature with masked candidates', () {
    const masked = _dynamicTemperatureWithMasking;
    final dynamic = _sampled.copyWith(dynatempRange: 0.5);
    for (final (label, params) in [
      ('a grammar', dynamic.copyWith(grammar: 'root ::= "a"')),
      (
        'a lazy grammar',
        dynamic.copyWith(
          grammar: 'root ::= "a"',
          grammarLazy: true,
          grammarTriggers: const [
            GenerationGrammarTrigger.typed(
              type: GrammarTriggerType.word,
              value: 'a',
            ),
          ],
        ),
      ),
      ('a thinking budget', dynamic.copyWith(thinkingBudget: _budget)),
      ('ignoreEos', dynamic.copyWith(ignoreEos: true)),
      (
        'a banned token',
        dynamic.copyWith(logitBias: const {_a: double.negativeInfinity}),
      ),
    ]) {
      test('rejects $label before decoding', () async {
        await expectLater(
          generate(params),
          throwsA(
            isA<LlamaUnsupportedException>().having(
              (e) => e.message,
              'message',
              masked,
            ),
          ),
        );
        expect(decodes, 0);
      });
    }

    test('rejects model-suppressed tokens before decoding', () async {
      final dir = Directory.systemTemp.createTempSync(
        'llamadart_sampler_suppressed_',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = writeSyntheticLlamaGguf(
        '${dir.path}/suppressed.gguf',
        eosTokenId: _eos,
        int32ArrayMetadata: {
          'tokenizer.ggml.suppress_tokens': [_a + 1],
        },
      ).path;
      final suppressed = service.createContext(
        service.loadModel(path, _modelParams),
        _modelParams,
      );
      expect(
        await generate(_sampled.copyWith(maxTokens: 4), suppressed),
        isNotEmpty,
      );
      decodes = 0;
      await expectLater(
        generate(dynamic, suppressed),
        throwsA(
          isA<LlamaUnsupportedException>().having(
            (e) => e.message,
            'message',
            masked,
          ),
        ),
      );
      expect(decodes, 0);
    });

    test('allows finite biases', () async {
      expect(
        await generate(dynamic.copyWith(logitBias: const {_a: -10000})),
        isNotEmpty,
      );
    });

    // Reproductions of the denormal-temperature and float32-overflow aborts.
    const abGrammar = 'root ::= ("a" | "b")+';
    for (final (label, params, unsupported) in [
      (
        'range equal to temp with a grammar',
        _sampled.copyWith(
          maxTokens: 12,
          grammar: abGrammar,
          dynatempRange: 1,
          logitBias: const {_a: 90},
        ),
        false,
      ),
      (
        'range equal to temp with a grammar and top-k',
        _sampled.copyWith(
          maxTokens: 12,
          topK: 40,
          grammar: abGrammar,
          dynatempRange: 1,
          dynatempExponent: 2,
          logitBias: const {_a: 50},
        ),
        false,
      ),
      (
        'range equal to temp with a banned token',
        _sampled.copyWith(
          maxTokens: 12,
          dynatempRange: 1,
          dynatempExponent: 3,
          logitBias: const {_a: 40, 130: double.negativeInfinity},
        ),
        false,
      ),
      (
        'a safe range with a grammar and a confident bias',
        _sampled.copyWith(
          maxTokens: 12,
          grammar: abGrammar,
          dynatempRange: 0.5,
          logitBias: const {_a: 90},
        ),
        true,
      ),
      (
        'a range beyond float32 with a grammar',
        _sampled.copyWith(
          maxTokens: 12,
          grammar: abGrammar,
          dynatempRange: 1e39,
        ),
        false,
      ),
      (
        'a threshold that rounds to zero with a grammar',
        _sampled.copyWith(
          maxTokens: 12,
          grammar: abGrammar,
          xtcProbability: 1,
          xtcThreshold: 1e-46,
        ),
        false,
      ),
    ]) {
      test('rejects $label before decoding', () async {
        await expectLater(
          generate(params),
          throwsA(
            unsupported
                ? isA<LlamaUnsupportedException>()
                : isA<LlamaArgumentException>(),
          ),
        );
        expect(decodes, 0);
      });
    }
  });

  group('validation', () {
    for (final (name, field, params) in [
      (
        'NaN typicalP',
        'typicalP',
        const GenerationParams(typicalP: double.nan),
      ),
      ('zero typicalP', 'typicalP', const GenerationParams(typicalP: 0)),
      ('negative typicalP', 'typicalP', const GenerationParams(typicalP: -0.5)),
      ('typicalP above one', 'typicalP', const GenerationParams(typicalP: 1.5)),
      (
        'NaN topNSigma',
        'topNSigma',
        const GenerationParams(topNSigma: double.nan),
      ),
      ('zero topNSigma', 'topNSigma', const GenerationParams(topNSigma: 0)),
      (
        'topNSigma below -1',
        'topNSigma',
        const GenerationParams(topNSigma: -2),
      ),
      (
        'infinite topNSigma',
        'topNSigma',
        const GenerationParams(topNSigma: double.infinity),
      ),
      (
        'NaN xtcProbability',
        'xtcProbability',
        const GenerationParams(xtcProbability: double.nan),
      ),
      (
        'negative xtcProbability',
        'xtcProbability',
        const GenerationParams(xtcProbability: -0.1),
      ),
      (
        'xtcProbability above one',
        'xtcProbability',
        const GenerationParams(xtcProbability: 1.1),
      ),
      (
        'NaN xtcThreshold',
        'xtcThreshold',
        const GenerationParams(xtcThreshold: double.nan),
      ),
      (
        'zero xtcThreshold',
        'xtcThreshold',
        const GenerationParams(xtcProbability: 1, xtcThreshold: 0),
      ),
      (
        'xtcThreshold above 0.5',
        'xtcThreshold',
        const GenerationParams(xtcProbability: 1, xtcThreshold: 0.6),
      ),
      (
        'xtcThreshold without xtcProbability',
        'xtcThreshold',
        const GenerationParams(xtcThreshold: 0.2),
      ),
      (
        'NaN dynatempRange',
        'dynatempRange',
        const GenerationParams(dynatempRange: double.nan),
      ),
      (
        'negative dynatempRange',
        'dynatempRange',
        const GenerationParams(dynatempRange: -0.1),
      ),
      (
        'infinite dynatempRange',
        'dynatempRange',
        const GenerationParams(dynatempRange: double.infinity),
      ),
      (
        'dynatempRange with zero temp',
        'dynatempRange',
        const GenerationParams(temp: 0, dynatempRange: 0.5),
      ),
      (
        'zero dynatempExponent',
        'dynatempExponent',
        const GenerationParams(dynatempRange: 0.5, dynatempExponent: 0),
      ),
      (
        'infinite dynatempExponent',
        'dynatempExponent',
        const GenerationParams(
          dynatempRange: 0.5,
          dynatempExponent: double.infinity,
        ),
      ),
      (
        'NaN dynatempExponent',
        'dynatempExponent',
        const GenerationParams(dynatempExponent: double.nan),
      ),
      (
        'dynatempExponent without dynatempRange',
        'dynatempExponent',
        const GenerationParams(dynatempExponent: 2),
      ),
      (
        'dynatempRange equal to temp',
        'dynatempRange',
        const GenerationParams(temp: 1, dynatempRange: 1),
      ),
      (
        'dynatempRange leaving a lowest temperature under the floor',
        'dynatempRange',
        const GenerationParams(temp: 0.5, dynatempRange: 0.495),
      ),
      (
        'dynatempRange whose float32 lowest temperature is under the floor',
        'dynatempRange',
        const GenerationParams(temp: 1, dynatempRange: 0.99),
      ),
      (
        'dynatempRange beyond float32',
        'dynatempRange',
        const GenerationParams(temp: 1, dynatempRange: 1e39),
      ),
      (
        'dynatempRange that rounds to zero',
        'dynatempRange',
        const GenerationParams(temp: 1, dynatempRange: 1e-46),
      ),
      (
        'dynatempExponent beyond float32',
        'dynatempExponent',
        const GenerationParams(dynatempRange: 0.5, dynatempExponent: 1e39),
      ),
      (
        'dynatempExponent that rounds to zero',
        'dynatempExponent',
        const GenerationParams(dynatempRange: 0.5, dynatempExponent: 1e-46),
      ),
      (
        'xtcThreshold that rounds to zero',
        'xtcThreshold',
        const GenerationParams(xtcProbability: 1, xtcThreshold: 1e-46),
      ),
      (
        'xtcThreshold beyond float32',
        'xtcThreshold',
        const GenerationParams(xtcProbability: 1, xtcThreshold: 1e39),
      ),
      (
        'xtcProbability that rounds to zero',
        'xtcProbability',
        const GenerationParams(xtcProbability: 1e-46),
      ),
      (
        'typicalP that rounds to zero',
        'typicalP',
        const GenerationParams(typicalP: 1e-46),
      ),
      (
        'topNSigma that rounds to zero',
        'topNSigma',
        const GenerationParams(topNSigma: 1e-46),
      ),
      (
        'topNSigma beyond float32',
        'topNSigma',
        const GenerationParams(topNSigma: 1e39),
      ),
      (
        'mirostatTau that rounds to zero',
        'mirostatTau',
        const GenerationParams(mirostat: 2, mirostatTau: 1e-46),
      ),
      (
        'mirostatTau beyond float32',
        'mirostatTau',
        const GenerationParams(mirostat: 2, mirostatTau: 1e39),
      ),
      (
        'mirostatEta that rounds to zero',
        'mirostatEta',
        const GenerationParams(mirostat: 1, mirostatEta: 1e-46),
      ),
      (
        'mirostatEta beyond float32',
        'mirostatEta',
        const GenerationParams(mirostat: 1, mirostatEta: 1e39),
      ),
      ('mirostat mode 3', 'mirostat', const GenerationParams(mirostat: 3)),
      (
        'negative mirostat mode',
        'mirostat',
        const GenerationParams(mirostat: -1),
      ),
      (
        'zero mirostatTau',
        'mirostatTau',
        const GenerationParams(mirostat: 1, mirostatTau: 0),
      ),
      (
        'NaN mirostatTau',
        'mirostatTau',
        const GenerationParams(mirostat: 1, mirostatTau: double.nan),
      ),
      (
        'infinite mirostatTau',
        'mirostatTau',
        const GenerationParams(mirostat: 2, mirostatTau: double.infinity),
      ),
      (
        'zero mirostatEta',
        'mirostatEta',
        const GenerationParams(mirostat: 1, mirostatEta: 0),
      ),
      (
        'negative mirostatEta',
        'mirostatEta',
        const GenerationParams(mirostat: 2, mirostatEta: -0.1),
      ),
      (
        'mirostatTau without mirostat',
        'mirostat',
        const GenerationParams(mirostatTau: 4),
      ),
      (
        'mirostatEta without mirostat',
        'mirostat',
        const GenerationParams(mirostatEta: 0.2),
      ),
      (
        'mirostat with zero temp',
        'mirostat',
        const GenerationParams(temp: 0, mirostat: 2),
      ),
      (
        'mirostat with typicalP',
        'mirostat',
        const GenerationParams(mirostat: 2, typicalP: 0.5),
      ),
      (
        'mirostat with topNSigma',
        'mirostat',
        const GenerationParams(mirostat: 2, topNSigma: 1),
      ),
      (
        'mirostat with xtc',
        'mirostat',
        const GenerationParams(mirostat: 1, xtcProbability: 0.5),
      ),
      (
        'mirostat with dynamic temperature',
        'mirostat',
        const GenerationParams(mirostat: 1, dynatempRange: 0.5),
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
  });
}

T _invokePrivateForTesting<T>(
  LlamaCppService service,
  String member,
  List<Object?> positionalArguments,
) {
  final owner = reflectClass(LlamaCppService).owner as LibraryMirror;
  return reflect(service)
          .invoke(MirrorSystem.getSymbol(member, owner), positionalArguments)
          .reflectee
      as T;
}
