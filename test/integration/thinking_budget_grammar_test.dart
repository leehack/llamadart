@TestOn('vm')
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/core/template/tool_call_grammar_utils.dart';
import 'package:test/test.dart';

import '../test_helper.dart';

void main() {
  late LlamaBackend backend;
  late int model;
  late int context;

  setUpAll(() async {
    backend = LlamaBackend();
    final file = await TestHelper.getTestModel();
    const params = ModelParams(
      contextSize: 512,
      gpuLayers: 0,
      preferredBackend: GpuBackend.cpu,
      numberOfThreads: 2,
      numberOfThreadsBatch: 2,
    );
    model = await backend.modelLoad(file.path, params);
    context = await backend.contextCreate(model, params);
  });
  tearDownAll(() async {
    await backend.contextFree(context);
    await backend.modelFree(model);
    await backend.dispose();
  });

  // The budget opens on the prompt only where the start tag tokenizes as it
  // does alone, which for this SentencePiece vocabulary is after a space.
  const prompt = 'Once upon a time <think>';

  Future<String> run(String grammar, int budget) async {
    final chunks = await backend
        .generate(
          context,
          prompt,
          GenerationParams(
            maxTokens: 48,
            temp: 0,
            seed: 1,
            penalty: 1,
            grammar: grammar,
            thinkingBudget: ThinkingBudget(
              maxTokens: budget,
              startTag: '<think>',
              endTag: '</think>',
            ),
          ),
        )
        .toList();
    return utf8.decode(chunks.expand((chunk) => chunk).toList());
  }

  test('a grammar that takes the thought constrains the reply after a spent '
      'thinking budget', () async {
    final grammar = ToolCallGrammarUtils.afterForcedOpenThought(
      'root ::= "ok"\n',
      '</think>',
    );

    expect(await run(grammar, 0), matches(RegExp(r'^ </think>\s*ok$')));
    expect(
      await run(grammar, 3),
      matches(RegExp(r'^.+ </think>\s*ok$', dotAll: true)),
    );
  });

  test('a caller grammar waits for the budgeted thought to close', () async {
    expect(await run('root ::= "ok"', 0), ' </think>ok');
    expect(
      await run('root ::= "ok"', 3),
      matches(RegExp(r'^.+ </think>ok$', dotAll: true)),
    );
  });

  // The `<s>` token is the one start tag this vocabulary produces under a
  // grammar exactly as the budget sampler tokenizes it, as the model opens the
  // thought itself.
  test('a grammar that models the thought it opens stays applied through a '
      'spent thinking budget', () async {
    const grammar = r'''
root ::= seed-thought "ok"
seed-thought ::= "<s>" thought-text " done"
thought-text ::= [^d]*
''';

    for (final budget in [1, 3]) {
      final chunks = await backend
          .generate(
            context,
            'Once upon a time',
            GenerationParams(
              maxTokens: 48,
              temp: 0,
              seed: 1,
              penalty: 1,
              grammar: grammar,
              thinkingBudget: ThinkingBudget(
                maxTokens: budget,
                startTag: '<s>',
                endTag: ' done',
              ),
            ),
          )
          .toList();

      expect(
        utf8.decode(chunks.expand((chunk) => chunk).toList()),
        endsWith(' doneok'),
        reason: 'budget $budget',
      );
    }
  });
}
