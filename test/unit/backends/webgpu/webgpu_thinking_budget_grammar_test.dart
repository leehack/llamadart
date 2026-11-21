@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/backends/webgpu/webgpu_backend.dart';
import 'package:llamadart/src/core/engine/chat_completion_request_planner.dart';
import 'package:llamadart/src/core/template/tool_call_grammar_utils.dart';
import 'package:test/test.dart';

import '../../../support/fake_webgpu_feature_bridge.dart';

@JS('Error')
external JSObject _jsError(String message);

@JS('Promise.reject')
external JSPromise<JSAny?> _rejectPromise(JSAny? reason);

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
  const lingThought =
      'root ::= ling3-thought call\n'
      'ling3-thought ::= "</think>"\ncall ::= "x"\n';

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
      const GenerationParams(grammar: lingThought, thinkingBudget: budget),
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

  final xmlBudget = ChatTemplateEngine.resolveThinkingBudget(
    ChatFormat.qwen3CoderXml.index,
    const ThinkingBudget(maxTokens: 8),
  );
  final xmlWireBudget = <String, Object?>{
    ...paused,
    'forcedMessage': '\n',
    'naturalEndTags': ['\n</think>', '</think>', '<tool_call>'],
  };

  test('raw XML lazy grammar replays only its exact opener', () async {
    fake.completionCapabilities['thinkingBudgetMultiEnd'] = true;
    await load();
    for (final (grammar, grammarLazy, trigger, replay) in [
      ('root ::= "<tool_call>"', true, '<tool_call>', 2),
      ('root ::= "<tool_call>"', true, '</think>', null),
      ('root ::= "{}"', false, '<tool_call>', null),
      (null, false, null, null),
    ]) {
      await generate(
        GenerationParams(
          grammar: grammar,
          grammarLazy: grammarLazy,
          grammarTriggers: [
            if (trigger != null)
              GenerationGrammarTrigger.typed(
                type: GrammarTriggerType.word,
                value: trigger,
              ),
          ],
          thinkingBudget: xmlBudget,
        ),
      );
      expect(fake.completionOption('thinkingBudget'), {
        ...xmlWireBudget,
        if (replay != null) 'grammarReplayEndIndex': replay,
      });
    }
  });

  for (final value in <bool?>[null, false]) {
    test('requires the multi-end capability, received $value', () async {
      fake.completionCapabilities = {
        'thinkingBudget': true,
        'thinkingBudgetMultiEnd': ?value,
      };
      await load();
      expect((await engine.capabilities).supportsThinkingBudget, isTrue);
      await expectLater(
        generate(GenerationParams(thinkingBudget: xmlBudget)),
        throwsA(
          isA<LlamaUnsupportedException>().having(
            (error) => error.message,
            'message',
            allOf(contains('thinkingBudgetMultiEnd'), contains('v0.1.87+')),
          ),
        ),
      );
      expect(fake.completionCalls, 0);
      await generate(const GenerationParams(thinkingBudget: budget));
      expect(fake.completionOption('thinkingBudget'), paused);
    });
  }

  test('rejects a non-boolean multi-end capability', () async {
    fake.completionCapabilitiesResult = JSObject()
      ..['thinkingBudget'] = true.toJS
      ..['thinkingBudgetMultiEnd'] = 'true'.toJS;
    await load();
    await expectLater(
      generate(GenerationParams(thinkingBudget: xmlBudget)),
      throwsA(isA<LlamaUnsupportedException>()),
    );
    expect(fake.completionCalls, 0);
  });

  test('maps completion-time multi-end skew to typed unsupported', () async {
    fake.completionCapabilities = {
      'thinkingBudget': true,
      'thinkingBudgetMultiEnd': true,
    };
    fake.object['createCompletion'] =
        ((String prompt, JSObject options) => _rejectPromise(
          _jsError(
            'The loaded WebGPU core does not support CompletionOptions.thinkingBudget.naturalEndTags.',
          ),
        )).toJS;
    await load();
    await expectLater(
      generate(GenerationParams(thinkingBudget: xmlBudget)),
      throwsA(
        isA<LlamaUnsupportedException>().having(
          (error) => error.message,
          'message',
          allOf(contains('thinkingBudgetMultiEnd'), contains('v0.1.87+')),
        ),
      ),
    );
  });

  test('sends ordered natural ends and keeps singleton wire shape', () async {
    fake.completionCapabilities = {
      'thinkingBudget': true,
      'thinkingBudgetMultiEnd': true,
    };
    await load();
    await generate(GenerationParams(thinkingBudget: xmlBudget));
    expect(fake.completionOption('thinkingBudget'), xmlWireBudget);
    await expectLater(
      generate(GenerationParams(grammar: taking, thinkingBudget: xmlBudget)),
      throwsA(
        isA<LlamaUnsupportedException>().having(
          (error) => error.message,
          'message',
          contains('thinkingBudgetPauseGrammar'),
        ),
      ),
    );
    await generate(const GenerationParams(thinkingBudget: budget));
    expect(fake.completionOption('thinkingBudget'), paused);
  });

  for (final choice in [ToolChoice.auto, ToolChoice.required]) {
    test('sends the selected $choice XML grammar and its replay index', () async {
      const template =
          '{# <tool_call><function=><parameter=><function><parameters> #}<think>\n';
      const messages = [
        LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'Weather?'),
      ];
      const params = GenerationParams(
        thinkingBudget: ThinkingBudget(maxTokens: 8),
      );
      final tools = [
        ToolDefinition(
          name: 'get_weather',
          description: 'Look up the weather',
          parameters: [ToolParam.string('location', required: true)],
        ),
      ];
      fake.completionCapabilities['thinkingBudgetMultiEnd'] = true;
      fake.completionPieces = const [
        '<tool_call>\n<function=get_weather>\n<parameter=location>\n'
            'Seoul\n</parameter>\n</function>\n</tool_call>',
      ];
      await engine.loadModelFromUrl(
        'https://example.com/tiny.gguf',
        modelParams: const ModelParams(chatTemplate: template),
      );
      final chunks = await engine
          .create(
            messages,
            enableThinking: true,
            tools: tools,
            toolChoice: choice,
            params: params,
          )
          .toList();
      expect(chunks.last.choices.single.finishReason, 'tool_calls');
      expect(
        fake.completionOption('grammar'),
        contains('<function=get_weather>'),
      );
      expect(fake.completionOption('grammarLazy'), choice == ToolChoice.auto);
      expect(fake.completionOption('thinkingBudget'), {
        ...xmlWireBudget,
        'grammarReplayEndIndex': 2,
      });

      final plan = ChatCompletionRequestPlanner.build(
        backend: engine.backend,
        templateResult: ChatTemplateEngine.render(
          templateSource: template,
          messages: messages,
          metadata: const {},
          tools: tools,
          toolChoice: choice,
        ),
        messages: messages,
        tools: tools,
        toolChoice: choice,
        parallelToolCalls: false,
        params: params,
      );
      await generate(
        plan.generationParams.copyWith(
          grammar: 'root ::= "{}"',
          grammarLazy: false,
          grammarTriggers: const [],
        ),
      );
      expect(fake.completionOption('thinkingBudget'), xmlWireBudget);
    });
  }

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
                contains('think-body'),
                contains('seed-thought'),
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
