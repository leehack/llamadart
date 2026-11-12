@TestOn('browser')
library;

import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/backends/webgpu/webgpu_backend.dart';
import 'package:llamadart/src/core/template/tool_call_grammar_utils.dart';
import 'package:test/test.dart';

import '../../../support/fake_webgpu_feature_bridge.dart';

void main() {
  late FakeFeatureBridge fake;
  late LlamaEngine engine;

  setUp(() {
    fake = FakeFeatureBridge()
      ..completionCapabilities = {
        'thinkingBudget': true,
        'thinkingBudgetPauseGrammar': true,
        'lazyGrammar': true,
      };
    engine = LlamaEngine(
      WebGpuLlamaBackend(bridgeFactory: ([_]) => fake.bridge),
    );
    addTearDown(engine.dispose);
  });

  Future<void> load() =>
      engine.loadModelFromUrl('https://example.com/tiny.gguf');
  Future<void> generate(GenerationParams params) =>
      engine.generate('Once <think>', params: params).drain<void>();
  final taking = ToolCallGrammarUtils.afterForcedOpenThought(
    'root ::= "ok"\n',
    '</think>',
  );
  const budget = ThinkingBudget(
    maxTokens: 8,
    startTag: '<think>',
    endTag: '</think>',
  );
  const paused = <String, Object?>{
    'maxTokens': 8,
    'startTag': '<think>',
    'endTag': '</think>',
    'forcedMessage': '',
  };

  const seedThought = 'root ::= seed-thought call\ncall ::= "x"\n';

  test('keeps a grammar that takes or models the thought applied', () async {
    await load();
    for (final grammar in [taking, seedThought]) {
      await generate(
        GenerationParams(grammar: grammar, thinkingBudget: budget),
      );
      expect(fake.completionOption('thinkingBudget'), {
        ...paused,
        'pauseGrammar': false,
      });
    }
  });

  test('leaves every other grammar paused', () async {
    await load();
    for (final params in [
      const GenerationParams(thinkingBudget: budget),
      const GenerationParams(grammar: 'root ::= "ok"', thinkingBudget: budget),
      GenerationParams(
        grammar: taking,
        grammarLazy: true,
        grammarTriggers: const [
          GenerationGrammarTrigger.typed(
            type: GrammarTriggerType.word,
            value: 'a',
          ),
        ],
        thinkingBudget: budget,
      ),
    ]) {
      await generate(params);
      expect(fake.completionOption('thinkingBudget'), paused);
    }
  });

  test(
    'rejects a kept-applied grammar on assets that would pause it',
    () async {
      fake.completionCapabilities = {'thinkingBudget': true};
      await load();
      for (final grammar in [taking, seedThought]) {
        await expectLater(
          generate(GenerationParams(grammar: grammar, thinkingBudget: budget)),
          throwsA(
            isA<LlamaUnsupportedException>().having(
              (error) => error.message,
              'message',
              allOf(
                contains('thinkingBudgetPauseGrammar'),
                contains('v0.1.84+'),
              ),
            ),
          ),
        );
      }
      expect(fake.completionCalls, 0);
      await generate(
        const GenerationParams(
          grammar: 'root ::= "ok"',
          thinkingBudget: budget,
        ),
      );
      expect(fake.completionOption('thinkingBudget'), paused);
      await generate(GenerationParams(grammar: taking));
      expect(fake.completionOption('thinkingBudget'), isNull);
    },
  );
}
