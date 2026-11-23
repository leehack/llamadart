@TestOn('vm')
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:llamadart/src/backends/backend.dart';
import 'package:llamadart/src/backends/llama_cpp/bindings.dart';
import 'package:llamadart/src/backends/llama_cpp/exit_teardown_api.dart';
import 'package:llamadart/src/backends/llama_cpp/llama_cpp_service.dart';
import 'package:llamadart/src/core/exceptions.dart';
import 'package:llamadart/src/core/models/inference/generation_params.dart';
import 'package:llamadart/src/core/models/inference/model_params.dart';
import 'package:test/test.dart';

import '../../../support/synthetic_embedding_gguf.dart';

const _params = ModelParams(
  numberOfThreads: 2,
  numberOfThreadsBatch: 2,
  gpuLayers: 0,
  contextSize: 1024,
);

// The synthetic vocabulary is `<unk>`, `<s>`, `</s>` and 256 byte tokens.
// EOS is `</s>` (2); the EOT and EOM ids name two byte tokens, so llama.cpp
// counts three end-of-generation tokens.
const _eos = 2;
const _eot = 10;
const _eom = 11;

// Near-uniform sampling over 259 tokens with random weights: without the
// bias one of the three end-of-generation tokens comes up long before 400
// tokens for this seed.
const _uniform = GenerationParams(
  maxTokens: 400,
  temp: 1000,
  topK: 0,
  topP: 1,
  penalty: 1,
  seed: 7,
  reusePromptPrefix: false,
);

void main() {
  late Directory dir;
  late LlamaCppService service;
  late int model;
  late int context;
  late int decodes;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('llamadart_ignore_eos_');
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
    model = service.loadModel(
      writeSyntheticLlamaGguf(
        '${dir.path}/model.gguf',
        uint32Metadata: const {
          'tokenizer.ggml.eot_token_id': _eot,
          'tokenizer.ggml.eom_token_id': _eom,
        },
      ).path,
      _params,
    );
    context = service.createContext(model, _params);
  });

  Future<(BackendGenerationLimit?, int)> generate(
    GenerationParams params,
  ) async {
    final cancel = calloc<Int8>();
    BackendGenerationLimit? limit;
    try {
      await service
          .generate(
            context,
            'ab',
            params,
            cancel.address,
            onLimit: (value) => limit = value,
          )
          .drain<void>();
    } finally {
      calloc.free(cancel);
    }
    return (limit, service.getPerformanceContext(context)!.evalTokens);
  }

  test('suppresses every end-of-generation token, read at load', () {
    expect(
      service.debugSuppressedTokensForTesting(model, ignoreEos: true),
      unorderedEquals(const <int>[_eos, _eot, _eom]),
    );
    expect(
      service.debugSuppressedTokensForTesting(model, ignoreEos: false),
      isEmpty,
    );
  });

  test('runs to maxTokens where sampling would otherwise end', () async {
    final (limit, tokens) = await generate(_uniform);
    expect(limit, isNull, reason: 'an end-of-generation token was sampled');
    expect(tokens, lessThan(_uniform.maxTokens));

    final (ignoredLimit, ignoredTokens) = await generate(
      _uniform.copyWith(ignoreEos: true),
    );
    expect(ignoredLimit, BackendGenerationLimit.maxTokens);
    expect(ignoredTokens, _uniform.maxTokens);
  });

  for (final (name, params) in [
    ('grammar', _uniform.copyWith(ignoreEos: true, grammar: 'root ::= "a"')),
    (
      'lazy grammar',
      _uniform.copyWith(
        ignoreEos: true,
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
  ]) {
    test('refuses a $name before any decode', () async {
      final cancel = calloc<Int8>();
      addTearDown(() => calloc.free(cancel));
      await expectLater(
        service.generate(context, 'ab', params, cancel.address),
        emitsError(
          isA<LlamaUnsupportedException>().having(
            (error) => error.message,
            'message',
            contains('ignoreEos'),
          ),
        ),
      );
      expect(decodes, 0);
    });
  }

  test('takes an empty grammar as none, as llama.cpp does', () async {
    final (limit, tokens) = await generate(
      _uniform.copyWith(maxTokens: 8, ignoreEos: true, grammar: ''),
    );
    expect(limit, BackendGenerationLimit.maxTokens);
    expect(tokens, 8);
  });
}
