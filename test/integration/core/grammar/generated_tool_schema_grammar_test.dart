@TestOn('vm')
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/backends/llama_cpp/bindings.dart';
import 'package:llamadart/src/core/grammar/tool_grammar_generator.dart'
    as grammar;
import 'package:test/test.dart';

import '../../../test_helper.dart';

void main() {
  late File modelFile;
  late LlamaEngine engine;
  Pointer<llama_model>? nativeModel;

  final tool = ToolDefinition(
    name: 'ping',
    description: 'Return a deterministic ping tool call.',
    parameters: const [],
    handler: (_) async => null,
  );
  final generatedGrammar = grammar.ToolGrammarGenerator.generate([
    tool,
  ], toolChoice: grammar.ToolChoice.required)!.grammar;

  setUpAll(() async {
    modelFile = await TestHelper.getTestModel();
    engine = LlamaEngine(LlamaBackend());
    await engine.loadModel(
      modelFile.path,
      modelParams: const ModelParams(contextSize: 256),
    );
    final path = modelFile.path.toNativeUtf8();
    try {
      nativeModel = llama_model_load_from_file(
        path.cast<Char>(),
        llama_model_default_params(),
      );
    } finally {
      malloc.free(path);
    }
    expect(nativeModel, isNot(nullptr));
  });

  tearDownAll(() async {
    final loadedNativeModel = nativeModel;
    if (loadedNativeModel != null && loadedNativeModel != nullptr) {
      llama_model_free(loadedNativeModel);
    }
    await engine.dispose();
  });

  test('native compiler accepts generated tool schema grammar', () async {
    final output = await _generateThroughProductionTools(
      engine,
      tool,
      'Call the ping tool now.',
    );

    expect(
      output,
      equals({
        'name': 'ping',
        'arguments': <String, dynamic>{},
        'content': '',
        'finishReason': 'tool_calls',
      }),
    );
  });

  test(
    'compiled grammar rejects a schema-invalid requested tool call',
    () async {
      const invalidRequestedOutput =
          '{"tool_call":{"name":"not_ping","arguments":{"extra":true}}}';
      final output = await _generateThroughProductionTools(
        engine,
        tool,
        'Output exactly $invalidRequestedOutput',
      );

      expect(
        output,
        equals({
          'name': 'ping',
          'arguments': <String, dynamic>{},
          'content': '',
          'finishReason': 'tool_calls',
        }),
      );
    },
  );

  test('compiled grammar deterministically filters invalid candidates', () {
    expect(
      _compiledGrammarAccepts(
        nativeModel!,
        generatedGrammar,
        '{"tool_call":{"name":"ping","arguments":{}}}',
      ),
      isTrue,
    );
    expect(
      _compiledGrammarAccepts(
        nativeModel!,
        generatedGrammar,
        '{"tool_call":{"name":"not_ping","arguments":{"extra":true}}}',
      ),
      isFalse,
    );
  });

  test('compiled grammar rejects an incomplete valid prefix at EOG', () {
    expect(
      _compiledGrammarAccepts(
        nativeModel!,
        generatedGrammar,
        '{"tool_call":{"name":"ping","arguments":{}}',
      ),
      isFalse,
    );
  });

  test(
    'native compiler rejects a broken generated grammar dependency',
    () async {
      final invalidGrammar = generatedGrammar.replaceFirst(
        'root ::= ',
        'root ::= undefined-generated-rule ',
      );

      expect(
        invalidGrammar,
        isNot(equals(generatedGrammar)),
        reason: 'The adversarial mutation must modify the generated root rule.',
      );
      await expectLater(
        engine.create(
          const [
            LlamaChatMessage.fromText(
              role: LlamaChatRole.user,
              text: 'Call the ping tool now.',
            ),
          ],
          params: GenerationParams(
            grammar: invalidGrammar,
            maxTokens: 16,
            temp: 0,
          ),
        ).drain<void>(),
        throwsA(isA<LlamaInferenceException>()),
      );
    },
  );
}

bool _compiledGrammarAccepts(
  Pointer<llama_model> model,
  String generatedGrammar,
  String candidate,
) {
  final vocab = llama_model_get_vocab(model);
  final grammarPointer = generatedGrammar.toNativeUtf8();
  final rootPointer = 'root'.toNativeUtf8();
  final sampler = llama_sampler_init_grammar(
    vocab,
    grammarPointer.cast<Char>(),
    rootPointer.cast<Char>(),
  );
  malloc
    ..free(grammarPointer)
    ..free(rootPointer);
  expect(sampler, isNot(nullptr));

  final prefixedTokens = _tokenize(vocab, '\n$candidate');
  final prefixTokens = _tokenize(vocab, '\n');
  expect(prefixedTokens.take(prefixTokens.length), orderedEquals(prefixTokens));
  final candidateTokens = prefixedTokens.sublist(prefixTokens.length);
  final data = calloc<llama_token_data>(1);
  final array = calloc<llama_token_data_array>();
  try {
    array.ref
      ..data = data
      ..size = 1
      ..selected = -1
      ..sorted = false;
    for (final token in candidateTokens) {
      data.ref
        ..id = token
        ..logit = 0
        ..p = 0;
      llama_sampler_apply(sampler, array);
      if (data.ref.logit == double.negativeInfinity) return false;
      llama_sampler_accept(sampler, token);
    }
    final eog = llama_vocab_eos(vocab);
    expect(
      llama_vocab_is_eog(vocab, eog),
      isTrue,
      reason:
          'The test model EOS token must be a valid end-of-generation token.',
    );
    data.ref
      ..id = eog
      ..logit = 0
      ..p = 0;
    llama_sampler_apply(sampler, array);
    return data.ref.logit.isFinite;
  } finally {
    calloc
      ..free(data)
      ..free(array);
    llama_sampler_free(sampler);
  }
}

List<int> _tokenize(Pointer<llama_vocab> vocab, String value) {
  final text = value.toNativeUtf8();
  try {
    final required = -llama_tokenize(
      vocab,
      text.cast<Char>(),
      text.length,
      nullptr,
      0,
      false,
      true,
    );
    final tokens = calloc<llama_token>(required);
    try {
      expect(
        llama_tokenize(
          vocab,
          text.cast<Char>(),
          text.length,
          tokens,
          required,
          false,
          true,
        ),
        required,
      );
      return [for (var index = 0; index < required; index++) tokens[index]];
    } finally {
      calloc.free(tokens);
    }
  } finally {
    malloc.free(text);
  }
}

Future<Map<String, dynamic>> _generateThroughProductionTools(
  LlamaEngine engine,
  ToolDefinition tool,
  String prompt,
) async {
  final chunks = await engine
      .create(
        [LlamaChatMessage.fromText(role: LlamaChatRole.user, text: prompt)],
        tools: [tool],
        toolChoice: ToolChoice.required,
        params: const GenerationParams(maxTokens: 96, temp: 0),
      )
      .toList();
  final calls = chunks
      .expand((chunk) => chunk.choices.first.delta.toolCalls ?? const [])
      .toList();
  expect(calls, hasLength(1));
  final call = calls.single;

  return {
    'name': call.function?.name,
    'arguments': jsonDecode(call.function?.arguments ?? 'null'),
    'content': chunks
        .map((chunk) => chunk.choices.first.delta.content ?? '')
        .join(),
    'finishReason': chunks.last.choices.first.finishReason,
  };
}
