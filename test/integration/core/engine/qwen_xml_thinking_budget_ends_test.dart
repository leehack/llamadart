@TestOn('vm')
@Tags(['local-only'])
@Timeout(Duration(minutes: 10))
library;

import 'dart:io';

import 'package:llamadart/llamadart.dart';
import 'package:test/test.dart';

import '../../../support/qwen_xml_budget_tool_replay.dart';

const _rawPrompt =
    '<|im_start|>user\nCall get_weather for Seoul. '
    'Start immediately with the XML tool call.<|im_end|>\n'
    '<|im_start|>assistant\n<think>\n';
const _prefilled = '<tool_call>\n<function=get_weather>\n';
const _sentinel = 'BUDGET1949';
const _sampling = GenerationParams(
  maxTokens: 20,
  temp: 0,
  topK: 1,
  seed: 1,
  penalty: 1,
  reusePromptPrefix: false,
  preservedTokens: ['<think>', '</think>', '<tool_call>', '</tool_call>'],
);
const _messages = [
  LlamaChatMessage.fromText(
    role: LlamaChatRole.user,
    text: 'Call get_weather for Seoul.',
  ),
];

void main() {
  for (final (name, env, openerId, templateHasThought) in [
    ('Qwen3.5-0.8B Q4_K_M', 'LLAMADART_QWEN35_MODEL', 248058, true),
    (
      'Qwen3-Coder-30B-A3B-Instruct UD-IQ1_S',
      'LLAMADART_QWEN_CODER_MODEL',
      151657,
      false,
    ),
  ]) {
    final path = Platform.environment[env];
    test(
      '$name leaves a natural tool opener intact',
      skip: path == null ? 'Set $env to the specified GGUF.' : null,
      () async {
        final engine = LlamaEngine(LlamaBackend());
        addTearDown(engine.dispose);
        await engine.loadModel(
          path!,
          modelParams: const ModelParams(
            contextSize: 1024,
            gpuLayers: 0,
            preferredBackend: GpuBackend.cpu,
            numberOfThreads: 2,
            numberOfThreadsBatch: 2,
          ),
        );
        expect((await engine.getBackendName()).toUpperCase(), 'CPU');
        expect((await engine.capabilities).supportsThinkingBudget, isTrue);
        final metadata = await engine.getMetadata();
        expect(
          metadata['general.architecture'],
          templateHasThought ? 'qwen35' : 'qwen3moe',
        );
        expect(
          metadata['tokenizer.chat_template']!.contains('<think>'),
          templateHasThought,
        );
        final render = await engine.chatTemplate(
          _messages,
          enableThinking: true,
        );
        expect(render.format, ChatFormat.qwen3CoderXml.index);
        expect(render.thinkingForcedOpen, templateHasThought);

        final opener = await engine.tokenize('<tool_call>', addSpecial: false);
        expect(opener, [openerId]);
        final steered = _sampling.copyWith(
          grammar:
              'root ::= think-body !<[42]>*\nthink-body ::= <[$openerId]>\n',
        );
        ThinkingBudget budget(int maxTokens, {String forced = _sentinel}) =>
            ChatTemplateEngine.resolveThinkingBudget(
              render.format,
              ThinkingBudget(maxTokens: maxTokens, forcedMessage: forced),
            );
        Future<String> run(String prompt, GenerationParams params) =>
            engine.generate(prompt, params: params).join();
        final control = await run(_rawPrompt, steered);
        expect(control, startsWith('<tool_call>'));
        final afterGenerated = await run(
          _rawPrompt,
          steered.copyWith(thinkingBudget: budget(1)),
        );
        expect(afterGenerated, control);
        expect(afterGenerated, isNot(contains(_sentinel)));

        final prefilledPrompt = '$_rawPrompt$_prefilled';
        final prefilledControl = await run(prefilledPrompt, _sampling);
        expect(prefilledControl, isNotEmpty);
        final afterPrefill = await run(
          prefilledPrompt,
          _sampling.copyWith(thinkingBudget: budget(0)),
        );
        expect(afterPrefill, prefilledControl);
        expect(afterPrefill, isNot(contains(_sentinel)));

        final exhausted = await run(
          _rawPrompt,
          _sampling.copyWith(thinkingBudget: budget(0)),
        );
        expect(exhausted, startsWith('$_sentinel\n</think>'));
        final forcedOpener = await run(
          _rawPrompt,
          _sampling.copyWith(
            maxTokens: 3,
            thinkingBudget: budget(0, forced: '<tool_call>'),
          ),
        );
        expect(forcedOpener, '<tool_call>\n</think>');

        if (templateHasThought) {
          Future<String> chat(GenerationParams params) async =>
              (await engine
                      .create(_messages, params: params, enableThinking: true)
                      .toList())
                  .map((chunk) => chunk.choices.single.delta.content ?? '')
                  .join();
          final unbudgeted = await chat(steered);
          expect(unbudgeted, startsWith('<tool_call>'));
          final budgeted = await chat(
            steered.copyWith(
              thinkingBudget: const ThinkingBudget(
                maxTokens: 1,
                forcedMessage: _sentinel,
              ),
            ),
          );
          expect(budgeted, unbudgeted);
          expect(budgeted, isNot(contains(_sentinel)));
          await expectQwenXmlBudgetToolReplay(engine);
        }
      },
    );
  }
}
