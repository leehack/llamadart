@TestOn('vm')
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
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

const _dry = GenerationParams(
  maxTokens: 24,
  penalty: 1,
  temp: 0,
  topK: 0,
  topP: 1,
  seed: 7,
  reusePromptPrefix: false,
  dryMultiplier: 0.8,
);

const _b = 98;
const _eos = 0;

const _dryWithMasking =
    'GenerationParams.dryMultiplier cannot be combined with a grammar '
    '(including one from tools or responseFormat) or a thinking budget: the '
    'penalty can leave no valid candidate. Remove them or set dryMultiplier '
    'to 0.';

// Byte tokens of the synthetic vocabulary start at id 3; '\n' (id 13) is a
// default sequence breaker and ids 10-12 and 14 are not.
const _breaker = 13;

void main() {
  late LlamaCppService service;
  late String modelPath;
  late int model;
  late int context;
  late int decodes;
  late Pointer<llama_vocab> vocab;

  setUp(() {
    final dir = Directory.systemTemp.createTempSync('llamadart_sampler_dry_');
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
    final models = _field<Map<Object?, Object?>>(service, '_models');
    vocab = llama_model_get_vocab(
      reflect(models[model]).getField(#pointer).reflectee
          as Pointer<llama_model>,
    );
  });

  Future<List<int>> generate(
    GenerationParams params, {
    String prompt = 'ab',
  }) async {
    final cancel = calloc<Int8>();
    try {
      return await service
          .generate(context, prompt, params, cancel.address)
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
    final sampler =
        _invoke<Pointer<llama_sampler>>(service, '_initializeSampler', [
          params,
          vocab,
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
        ]);
    try {
      return List.generate(
        llama_sampler_chain_n(sampler),
        (index) => llama_sampler_name(
          llama_sampler_chain_get(sampler, index),
        ).cast<Utf8>().toDartString(),
      );
    } finally {
      _invoke<void>(service, '_freeSamplerChain', [sampler]);
    }
  }

  // Applies a DRY sampler that has accepted [history] to [candidates] tokens
  // with equal logits and returns the logits it leaves.
  List<double> penalties(
    GenerationParams params,
    List<int> history, {
    int nCtx = 1024,
    int candidates = 20,
  }) {
    final sampler = _invoke<Pointer<llama_sampler>>(
      service,
      '_initDrySampler',
      [params, vocab, nCtx],
    );
    final data = calloc<llama_token_data>(candidates);
    final array = calloc<llama_token_data_array>();
    try {
      for (final token in history) {
        llama_sampler_accept(sampler, token);
      }
      for (var i = 0; i < candidates; i++) {
        data[i]
          ..id = i
          ..logit = 0;
      }
      array.ref
        ..data = data
        ..size = candidates
        ..selected = -1
        ..sorted = false;
      llama_sampler_apply(sampler, array);
      return [for (var i = 0; i < candidates; i++) data[i].logit];
    } finally {
      calloc.free(array);
      calloc.free(data);
      llama_sampler_free(sampler);
    }
  }

  double penaltyOf(
    GenerationParams params,
    List<int> history,
    int token, {
    int nCtx = 1024,
  }) => penalties(params, history, nCtx: nCtx)[token];

  group('sampler chain', () {
    const defaultNames = ['penalties', 'top-k', 'top-p', 'temp', 'dist'];

    test('DRY is absent by default and while dryMultiplier is 0', () {
      expect(chainNames(const GenerationParams()), defaultNames);
      expect(
        chainNames(
          const GenerationParams().copyWith(
            dryBase: 0.5,
            dryAllowedLength: -3,
            dryPenaltyLastN: 0,
            drySequenceBreakers: const [''],
          ),
        ),
        defaultNames,
      );
    });

    for (final (label, params, suppressed, names) in [
      (
        'DRY runs after the penalties and before top-k',
        const GenerationParams(dryMultiplier: 0.8),
        const <int>[],
        ['penalties', 'dry', 'top-k', 'top-p', 'temp', 'dist'],
      ),
      (
        'DRY runs after bias, penalties and suppression',
        const GenerationParams(dryMultiplier: 0.8, logitBias: {3: 1}),
        const [4],
        ['logit-bias', 'penalties', 'logit-bias', 'dry', 'top-k', 'top-p'],
      ),
      (
        'DRY runs before top-n-sigma',
        const GenerationParams(dryMultiplier: 0.8, topNSigma: 1),
        const <int>[],
        ['penalties', 'dry', 'top-n-sigma', 'top-k', 'top-p', 'temp', 'dist'],
      ),
      (
        'DRY runs before temperature with Mirostat',
        const GenerationParams(dryMultiplier: 0.8, mirostat: 2),
        const <int>[],
        ['penalties', 'dry', 'temp', 'mirostat-v2'],
      ),
    ]) {
      test(label, () {
        expect(chainNames(params, suppressed).take(names.length), names);
      });
    }
  });

  group('native penalty', () {
    const params = GenerationParams(dryMultiplier: 0.8, dryAllowedLength: 2);
    // A suffix of five tokens (10 11 12 10 11) recurs earlier and was followed
    // by 12.
    const repeated = [10, 11, 12, 10, 11, 12, 10, 11];

    double expected(double multiplier, double base, int exponent) =>
        -multiplier * math.pow(base, exponent);

    test('subtracts multiplier * base ^ (length - allowed) from the token', () {
      final logits = penalties(params, repeated);
      expect(logits[12], closeTo(expected(0.8, 1.75, 3), 1e-4));
      expect([
        for (var i = 0; i < logits.length; i++)
          if (i != 12) logits[i],
      ], everyElement(0));
    });

    test('applies the multiplier, base and allowed length', () {
      expect(
        penaltyOf(params.copyWith(dryMultiplier: 2), repeated, 12),
        closeTo(expected(2, 1.75, 3), 1e-4),
      );
      expect(
        penaltyOf(params.copyWith(dryBase: 2), repeated, 12),
        closeTo(expected(0.8, 2, 3), 1e-4),
      );
      expect(
        penaltyOf(params.copyWith(dryAllowedLength: 1), repeated, 12),
        closeTo(expected(0.8, 1.75, 4), 1e-4),
      );
      expect(penaltyOf(params.copyWith(dryAllowedLength: 6), repeated, 12), 0);
    });

    test('scans only the last dryPenaltyLastN tokens', () {
      // History 10 11 12 10 11, token 12 would extend a two-token repeat.
      const history = [10, 11, 12, 10, 11];
      final base = params.copyWith(dryAllowedLength: 1);
      expect(
        penaltyOf(base.copyWith(dryPenaltyLastN: 5), history, 12),
        closeTo(expected(0.8, 1.75, 1), 1e-4),
      );
      expect(
        penaltyOf(base.copyWith(dryPenaltyLastN: 4), history, 12),
        closeTo(expected(0.8, 1.75, 0), 1e-4),
      );
      expect(penaltyOf(base.copyWith(dryPenaltyLastN: 3), history, 12), 0);
    });

    test('caps dryPenaltyLastN at the context size', () {
      const history = [10, 11, 12, 10, 11];
      final base = params.copyWith(
        dryAllowedLength: 1,
        dryPenaltyLastN: 100000,
      );
      expect(
        penaltyOf(base, history, 12, nCtx: 4),
        closeTo(expected(0.8, 1.75, 0), 1e-4),
      );
      expect(penaltyOf(base, history, 12, nCtx: 3), 0);
      expect(
        penaltyOf(base, history, 12),
        closeTo(expected(0.8, 1.75, 1), 1e-4),
      );
    });

    test('a sequence breaker limits the repeated length', () {
      // 10 11 \n 12 14 10 11 \n 12: without the breaker 14 extends a repeat
      // of four tokens, with it only the one after the breaker counts.
      const history = [10, 11, _breaker, 12, 14, 10, 11, _breaker, 12];
      final base = params.copyWith(dryAllowedLength: 0);
      expect(
        penaltyOf(base, history, 14),
        closeTo(expected(0.8, 1.75, 1), 1e-4),
      );
      for (final breakers in [
        const <String>[],
        const ['x'],
        ['é', 'x'],
      ]) {
        expect(
          penaltyOf(base.copyWith(drySequenceBreakers: breakers), history, 14),
          closeTo(expected(0.8, 1.75, 4), 1e-4),
          reason: '$breakers',
        );
      }
      for (final breakers in [
        const ['\n'],
        const ['x', '\n'],
        const ['\n', 'x'],
        const ['x', 'y', 'z', '\n', 'w'],
      ]) {
        expect(
          penaltyOf(base.copyWith(drySequenceBreakers: breakers), history, 14),
          closeTo(expected(0.8, 1.75, 1), 1e-4),
          reason: '$breakers',
        );
      }
    });

    test('a single-token breaker is never penalized', () {
      const history = [_breaker, _breaker, _breaker, _breaker, _breaker];
      expect(penaltyOf(params, history, _breaker), 0);
      expect(penaltyOf(params, [10, 10, 10, 10, 10], 10), lessThan(0));
      expect(
        penaltyOf(
          params.copyWith(drySequenceBreakers: const ['x']),
          history,
          _breaker,
        ),
        lessThan(0),
      );
    });

    test('accepts the longest and the most breakers', () {
      final breakers = [
        for (var i = 0; i < 64; i++) 'breaker-${i.toString().padLeft(3, '0')}',
      ];
      expect(
        penaltyOf(params.copyWith(drySequenceBreakers: breakers), repeated, 12),
        closeTo(expected(0.8, 1.75, 3), 1e-4),
      );
      final longest = 'x' * 40;
      final multiByte = 'é' * 20;
      expect(
        penaltyOf(
          params.copyWith(drySequenceBreakers: [longest, multiByte]),
          repeated,
          12,
        ),
        closeTo(expected(0.8, 1.75, 3), 1e-4),
      );
    });

    test(
      'a large penalty can set a repeated token logit to negative infinity',
      () {
        final logits = penalties(
          params.copyWith(dryMultiplier: 100, dryBase: 100),
          List.filled(200, 10),
        );
        expect(logits[10], double.negativeInfinity);
        expect(logits.where((logit) => logit.isNaN), isEmpty);
      },
    );
  });

  group('behavior', () {
    int longestRun(List<int> tokens) {
      var longest = 0;
      var run = 0;
      for (var i = 0; i < tokens.length; i++) {
        run = i > 0 && tokens[i] == tokens[i - 1] ? run + 1 : 1;
        longest = math.max(longest, run);
      }
      return longest;
    }

    test('suppresses a repetition loop', () async {
      final baseline = await generate(_greedy);
      expect(baseline, List.filled(24, _b));

      final suppressed = await generate(_dry);
      expect(suppressed, isNot(baseline));
      expect(longestRun(suppressed), lessThanOrEqualTo(2));
      expect(await generate(_dry), suppressed);

      for (final allowed in [0, 4, 8]) {
        final output = await generate(_dry.copyWith(dryAllowedLength: allowed));
        expect(longestRun(output), lessThanOrEqualTo(math.max(allowed, 1)));
      }
    });

    test('a DRY multiplier of 0.1 breaks a repetition loop', () async {
      final baseline = await generate(_greedy);
      expect(baseline, List.filled(_greedy.maxTokens, _b));
      final output = await generate(_dry.copyWith(dryMultiplier: 0.1));
      expect(output, isNotEmpty);
      expect(output, isNot(baseline));
    });

    test(
      'leaves output unchanged when no repeat exceeds the allowance',
      () async {
        expect(
          await generate(_dry.copyWith(dryAllowedLength: 30)),
          List.filled(24, _b),
        );
      },
    );

    test('a sequence breaker exempts its token', () async {
      expect(
        await generate(_dry.copyWith(drySequenceBreakers: const ['b'])),
        List.filled(24, _b),
      );
      expect(
        await generate(_dry.copyWith(drySequenceBreakers: const [])),
        isNot(List.filled(24, _b)),
      );
    });

    test('counts the prompt as repetition history', () async {
      const prompt = 'bbbbbbbbbbbb';
      expect((await generate(_greedy, prompt: prompt)).first, _b);
      final output = await generate(_dry, prompt: prompt);
      expect(output.isEmpty || output.first != _b, true);
    });

    test('disabled DRY ignores the other fields', () async {
      final baseline = await generate(_sampled);
      expect(
        await generate(
          _sampled.copyWith(
            dryMultiplier: 0,
            dryBase: double.nan,
            dryAllowedLength: -3,
            dryPenaltyLastN: 0,
            drySequenceBreakers: const [''],
          ),
        ),
        baseline,
      );
    });

    test('works with sampling and with Mirostat', () async {
      for (final params in [
        _sampled.copyWith(dryAllowedLength: 0),
        _sampled.copyWith(dryAllowedLength: 0, mirostat: 2),
      ]) {
        final without = params.copyWith(dryMultiplier: 0);
        final output = await generate(params.copyWith(dryMultiplier: 5));
        expect(output, isNotEmpty);
        expect(await generate(params.copyWith(dryMultiplier: 5)), output);
        expect(output, isNot(await generate(without)));
      }
    });

    test('accepts a context-sized dryPenaltyLastN', () async {
      final output = await generate(_dry.copyWith(dryPenaltyLastN: 0x7fffffff));
      expect(longestRun(output), lessThanOrEqualTo(2));
    });

    test('engine carries DRY and typed errors across the worker', () async {
      final engine = LlamaEngine(LlamaBackend());
      addTearDown(engine.dispose);
      await engine.loadModel(modelPath, modelParams: _modelParams);
      expect(
        (await engine.capabilities).samplerControls,
        contains(SamplerControl.dry),
      );
      final text = await engine.generate('ab', params: _dry).join();
      expect(text, startsWith('bb'));
      expect(text, isNot(contains('bbb')));
      await expectLater(
        engine.generate('ab', params: _dry.copyWith(dryBase: 0.5)),
        emitsError(isA<LlamaArgumentException>()),
      );
    });
  });

  group('masked candidates', () {
    const abGrammar = 'root ::= "a"+';
    const budget = ThinkingBudget(
      maxTokens: 1,
      startTag: 'a',
      endTag: 'b',
      forcedMessage: 'b',
    );

    for (final (label, params) in [
      ('a grammar', _dry.copyWith(grammar: abGrammar)),
      (
        'a lazy grammar',
        _dry.copyWith(
          grammar: abGrammar,
          grammarLazy: true,
          grammarTriggers: const [
            GenerationGrammarTrigger.typed(
              type: GrammarTriggerType.word,
              value: 'a',
            ),
          ],
        ),
      ),
      ('a thinking budget', _dry.copyWith(thinkingBudget: budget)),
    ]) {
      test('rejects $label before decoding', () async {
        await expectLater(
          generate(params),
          throwsA(
            isA<LlamaUnsupportedException>().having(
              (e) => e.message,
              'message',
              _dryWithMasking,
            ),
          ),
        );
        expect(decodes, 0);
      });
    }

    // Without the refusal this aborts the process: the penalty overflows
    // float32, no candidate is left and the grammar sees an invalid token
    // ("Unexpected empty grammar stack").
    test('rejects an overflowing penalty on a long grammar', () async {
      await expectLater(
        generate(
          _dry.copyWith(
            maxTokens: 40,
            grammar: 'root ::= "a"{40}',
            dryMultiplier: 100,
            dryBase: 100,
            dryAllowedLength: 0,
          ),
        ),
        throwsA(isA<LlamaUnsupportedException>()),
      );
      expect(decodes, 0);
    });

    test('allows a grammar while DRY is disabled', () async {
      expect(
        await generate(
          _dry.copyWith(dryMultiplier: 0, grammar: 'root ::= "a"'),
        ),
        [97],
      );
    });

    test('allows banned tokens and ignoreEos', () async {
      expect(
        await generate(
          _dry.copyWith(logitBias: const {101: double.negativeInfinity}),
        ),
        isNotEmpty,
      );
      expect(
        await generate(_dry.copyWith(ignoreEos: true, maxTokens: 6)),
        hasLength(6),
      );
    });

    const bToken = _b + 3;
    const vocabSize = 259;
    Map<int, double> banAllBut(Set<int> kept) => {
      for (var id = 0; id < vocabSize; id++)
        if (!kept.contains(id)) id: double.negativeInfinity,
    };

    final overflow = _sampled.copyWith(
      maxTokens: 60,
      dryMultiplier: 100,
      dryBase: 100,
      dryAllowedLength: 0,
      logitBias: banAllBut({bToken}),
    );
    for (final (name, params) in [
      ('dist', overflow),
      ('Mirostat 1', overflow.copyWith(mirostat: 1)),
      ('Mirostat 2', overflow.copyWith(mirostat: 2)),
      ('greedy', overflow.copyWith(temp: 0)),
      (
        'dist with ignoreEos',
        overflow.copyWith(
          dryMultiplier: 1,
          dryBase: 10,
          dryPenaltyLastN: 39,
          temp: 0.1,
          ignoreEos: true,
          logitBias: banAllBut({bToken, _eos}),
        ),
      ),
      (
        'dist with overflow after temperature scaling',
        overflow.copyWith(
          dryMultiplier: 1,
          dryBase: 10,
          dryPenaltyLastN: 39,
          temp: 0.1,
        ),
      ),
    ]) {
      test('rejects DRY that can exhaust an allow-list with $name', () async {
        await expectLater(
          generate(params),
          throwsA(
            isA<LlamaArgumentException>().having(
              (e) => e.name,
              'name',
              'dryMultiplier',
            ),
          ),
        );
        expect(decodes, 0);
      });
    }

    test(
      'checks a model-defined allow-list without explicit token bans',
      () async {
        final path = writeSyntheticLlamaGguf(
          '$modelPath.suppressed.gguf',
          eosTokenId: _eos,
          int32ArrayMetadata: {
            'tokenizer.ggml.suppress_tokens': banAllBut({bToken}).keys.toList(),
          },
        ).path;
        context = service.createContext(
          service.loadModel(path, _modelParams),
          _modelParams,
        );
        await expectLater(
          generate(overflow.copyWith(logitBias: const {})),
          throwsA(isA<LlamaArgumentException>()),
        );
        expect(decodes, 0);
      },
    );

    test('accepts a bounded DRY penalty with a one-token allow-list', () async {
      expect(
        await generate(
          _sampled.copyWith(dryMultiplier: 0.8, logitBias: banAllBut({bToken})),
        ),
        List.filled(_sampled.maxTokens, _b),
      );
      expect(
        await generate(
          overflow.copyWith(dryMultiplier: 1, dryBase: 10, dryPenaltyLastN: 39),
        ),
        List.filled(overflow.maxTokens, _b),
      );
    });

    test('accepts large DRY penalties when enough tokens remain', () async {
      final output = await generate(
        overflow.copyWith(
          ignoreEos: true,
          logitBias: const {bToken: double.negativeInfinity},
        ),
      );
      expect(output, isNotEmpty);
      expect(output, isNot(contains(_b)));
    });

    test('accepts a long DRY window with a sparse token mask', () async {
      final params = _sampled.copyWith(dryMultiplier: 0.8, temp: 0.8);
      await generate(
        params.copyWith(
          dryPenaltyLastN: 420,
          logitBias: const {258: double.negativeInfinity},
        ),
      );
      final output = await generate(
        params.copyWith(dryPenaltyLastN: 1024, ignoreEos: true),
      );
      expect(output, isNotEmpty);
    });

    test('rejects a DRY window that can overflow two continuations', () async {
      final params = overflow.copyWith(
        dryBase: 10,
        dryPenaltyLastN: 76,
        logitBias: banAllBut({97 + 3, bToken}),
      );
      // The suffix matches twice inside the first run, followed by 'a' and 'b'.
      final prompt = '${'a' * 38}b${'a' * 37}';
      await expectLater(
        generate(params, prompt: prompt),
        throwsA(
          isA<LlamaArgumentException>().having(
            (error) => error.name,
            'name',
            'dryMultiplier',
          ),
        ),
      );
      expect(decodes, 0);
    });
  });

  group('validation', () {
    test('validates allowed length against the actual context cap', () async {
      context = service.createContext(
        model,
        _modelParams.copyWith(contextSize: 32),
      );
      expect(service.getContextSize(context), 256);
      final params = _dry.copyWith(dryPenaltyLastN: 300, dryAllowedLength: 256);
      await expectLater(
        generate(params),
        throwsA(
          isA<LlamaArgumentException>()
              .having((error) => error.name, 'name', 'dryAllowedLength')
              .having((error) => error.message, 'message', contains('256')),
        ),
      );
      expect(decodes, 0);
      expect(
        await generate(params.copyWith(dryAllowedLength: 255)),
        List.filled(params.maxTokens, _b),
      );
      expect(
        await generate(params.copyWith(dryMultiplier: 0)),
        List.filled(params.maxTokens, _b),
      );
    });

    final tooLong = 'x' * 41;
    final tooLongMultiByte = 'é' * 21;
    for (final (name, field, params) in [
      (
        'NaN dryMultiplier',
        'dryMultiplier',
        _dry.copyWith(dryMultiplier: double.nan),
      ),
      (
        'infinite dryMultiplier',
        'dryMultiplier',
        _dry.copyWith(dryMultiplier: double.infinity),
      ),
      (
        'negative dryMultiplier',
        'dryMultiplier',
        _dry.copyWith(dryMultiplier: -0.8),
      ),
      (
        'dryMultiplier above 100',
        'dryMultiplier',
        _dry.copyWith(dryMultiplier: 100.5),
      ),
      (
        'dryMultiplier that rounds to zero',
        'dryMultiplier',
        _dry.copyWith(dryMultiplier: 1e-46),
      ),
      ('NaN dryBase', 'dryBase', _dry.copyWith(dryBase: double.nan)),
      ('dryBase below one', 'dryBase', _dry.copyWith(dryBase: 0.99)),
      ('zero dryBase', 'dryBase', _dry.copyWith(dryBase: 0)),
      ('dryBase above 100', 'dryBase', _dry.copyWith(dryBase: 101)),
      ('infinite dryBase', 'dryBase', _dry.copyWith(dryBase: double.infinity)),
      (
        'negative dryAllowedLength',
        'dryAllowedLength',
        _dry.copyWith(dryAllowedLength: -1),
      ),
      (
        'dryAllowedLength above int32',
        'dryAllowedLength',
        _dry.copyWith(dryAllowedLength: 0x80000000),
      ),
      (
        'dryAllowedLength equal to dryPenaltyLastN',
        'dryAllowedLength',
        _dry.copyWith(dryAllowedLength: 64),
      ),
      (
        'dryAllowedLength above dryPenaltyLastN',
        'dryAllowedLength',
        _dry.copyWith(dryAllowedLength: 100),
      ),
      (
        'zero dryPenaltyLastN',
        'dryPenaltyLastN',
        _dry.copyWith(dryPenaltyLastN: 0),
      ),
      (
        'negative dryPenaltyLastN',
        'dryPenaltyLastN',
        _dry.copyWith(dryPenaltyLastN: -1),
      ),
      (
        'dryPenaltyLastN above int32',
        'dryPenaltyLastN',
        _dry.copyWith(dryPenaltyLastN: 0x80000000),
      ),
      (
        'an empty breaker',
        'drySequenceBreakers',
        _dry.copyWith(drySequenceBreakers: const ['x', '']),
      ),
      (
        'a breaker over 40 bytes',
        'drySequenceBreakers',
        _dry.copyWith(drySequenceBreakers: [tooLong]),
      ),
      (
        'a multi-byte breaker over 40 bytes',
        'drySequenceBreakers',
        _dry.copyWith(drySequenceBreakers: [tooLongMultiByte]),
      ),
      (
        'a breaker with a NUL character',
        'drySequenceBreakers',
        _dry.copyWith(drySequenceBreakers: const ['a\u0000b']),
      ),
      (
        'a breaker with an unpaired surrogate',
        'drySequenceBreakers',
        _dry.copyWith(drySequenceBreakers: ['a${String.fromCharCode(0xd800)}']),
      ),
      (
        'more than 64 distinct breakers',
        'drySequenceBreakers',
        _dry.copyWith(
          drySequenceBreakers: [for (var i = 0; i < 65; i++) 'b$i'],
        ),
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

    test('accepts duplicate breakers beyond the distinct limit', () async {
      expect(
        await generate(
          _dry.copyWith(
            drySequenceBreakers: [for (var i = 0; i < 200; i++) 'b${i % 64}'],
          ),
        ),
        isNotEmpty,
      );
    });

    test('accepts the documented bounds', () async {
      for (final params in [
        _dry.copyWith(dryMultiplier: 100, dryBase: 100),
        _dry.copyWith(dryMultiplier: 100.000001, dryBase: 100.000001),
        _dry.copyWith(dryBase: 0.99999999),
        _dry.copyWith(dryMultiplier: 1e-6, dryBase: 1),
        _dry.copyWith(dryAllowedLength: 0, dryPenaltyLastN: 1),
        _dry.copyWith(
          dryAllowedLength: service.getContextSize(context) - 1,
          dryPenaltyLastN: 0x7fffffff,
        ),
      ]) {
        expect(await generate(params), isNotEmpty);
      }
    });
  });
}

T _field<T>(LlamaCppService service, String name) {
  final owner = reflectClass(LlamaCppService).owner as LibraryMirror;
  return reflect(
        service,
      ).getField(MirrorSystem.getSymbol(name, owner)).reflectee
      as T;
}

T _invoke<T>(
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
