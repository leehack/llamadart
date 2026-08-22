@TestOn('vm')
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/core/grammar/tool_grammar_generator.dart'
    as grammar;
import 'package:test/test.dart';

import '../../../test_helper.dart';

void main() {
  late File modelFile;
  late LlamaEngine engine;

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
  });

  tearDownAll(() => engine.dispose());

  test('native compiler accepts generated tool schema grammar', () async {
    final output = await _generate(
      engine,
      generatedGrammar,
      'Call the ping tool now.',
    );

    expect(
      jsonDecode(output),
      equals({
        'tool_call': {'name': 'ping', 'arguments': <String, dynamic>{}},
      }),
    );
  });

  test(
    'compiled grammar rejects a schema-invalid requested tool call',
    () async {
      const invalidRequestedOutput =
          '{"tool_call":{"name":"not_ping","arguments":{"extra":true}}}';
      final output = await _generate(
        engine,
        generatedGrammar,
        'Output exactly $invalidRequestedOutput',
      );

      expect(output, isNot(equals(invalidRequestedOutput)));
      expect(
        jsonDecode(output),
        equals({
          'tool_call': {'name': 'ping', 'arguments': <String, dynamic>{}},
        }),
      );
    },
  );

  test('native compiler rejects a broken generated grammar dependency', () {
    final invalidGrammar = generatedGrammar.replaceFirst(
      'root ::= ',
      'root ::= undefined-generated-rule ',
    );

    expect(
      invalidGrammar,
      isNot(equals(generatedGrammar)),
      reason: 'The adversarial mutation must modify the generated root rule.',
    );
    expectLater(
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
  });
}

Future<String> _generate(LlamaEngine engine, String grammar, String prompt) {
  return engine
      .create([
        LlamaChatMessage.fromText(role: LlamaChatRole.user, text: prompt),
      ], params: GenerationParams(grammar: grammar, maxTokens: 96, temp: 0))
      .map((chunk) => chunk.choices.first.delta.content ?? '')
      .join();
}
