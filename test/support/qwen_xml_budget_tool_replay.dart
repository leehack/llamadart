import 'dart:convert';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/core/engine/chat_completion_request_planner.dart';
import 'package:test/test.dart';

/// Checks raw and planned XML grammar replay against a real Qwen3.5 opener.
Future<void> expectQwenXmlBudgetToolReplay(LlamaEngine engine) async {
  const prompt =
      '<|im_start|>user\nWrite an XML tool call to get_weather for Seoul. '
      'The response must start with <tool_call>.<|im_end|>\n'
      '<|im_start|>assistant\n<think>\nExample:\n';
  const messages = [
    LlamaChatMessage.fromText(
      role: LlamaChatRole.user,
      text: 'Call get_weather for Seoul.',
    ),
  ];
  final tools = [
    ToolDefinition(
      name: 'get_weather',
      description: 'Look up weather for a city.',
      parameters: [
        ToolParam.enumType('location', values: ['Seoul'], required: true),
      ],
    ),
  ];
  const sampling = GenerationParams(
    maxTokens: 96,
    temp: 0,
    topK: 1,
    seed: 1,
    penalty: 1,
    reusePromptPrefix: false,
    preservedTokens: ['<think>', '</think>', '<tool_call>', '</tool_call>'],
  );
  const budget = ThinkingBudget(maxTokens: 1, forcedMessage: 'BUDGET1949');
  final metadata = await engine.getMetadata();
  expect(
    await engine
        .generate(prompt, params: sampling.copyWith(maxTokens: 1))
        .join(),
    '<tool_call>',
    reason: 'The prefilling fixture must naturally generate the opener first',
  );
  for (final choice in [ToolChoice.auto, ToolChoice.required]) {
    final rendered = ChatTemplateEngine.render(
      templateSource: metadata['tokenizer.chat_template'],
      metadata: metadata,
      messages: messages,
      tools: tools,
      toolChoice: choice,
    );
    expect(rendered.format, ChatFormat.qwen3CoderXml.index);
    expect(rendered.thinkingForcedOpen, isTrue);
    final plan = ChatCompletionRequestPlanner.build(
      backend: engine.backend,
      templateResult: rendered,
      messages: messages,
      tools: tools,
      toolChoice: choice,
      parallelToolCalls: false,
      params: sampling.copyWith(thinkingBudget: budget),
    );
    final raw = await engine
        .generate(prompt, params: plan.generationParams)
        .join();
    void expectToolCall(String output) {
      expect(output, startsWith('<tool_call>\n<function=get_weather>'));
      expect('<tool_call>'.allMatches(output), hasLength(1));
      expect(output, isNot(contains('BUDGET1949')));
      final call = ChatTemplateEngine.parseRendered(
        rendered,
        output,
        tools: tools,
      ).toolCalls.single.function!;
      expect(call.name, 'get_weather');
      expect(jsonDecode(call.arguments!), {'location': 'Seoul'});
    }

    expectToolCall(raw);
    if (choice == ToolChoice.auto) {
      final fromFormat = await engine
          .generate(
            prompt,
            params: plan.generationParams.copyWith(
              thinkingBudget: ChatTemplateEngine.resolveThinkingBudget(
                rendered.format,
                budget,
              ),
            ),
          )
          .join();
      expect(fromFormat, raw);
      expectToolCall(fromFormat);
    }

    // A structurally valid envelope alone must never produce a tool call.
    final undeclared = raw.replaceFirst('get_weather', 'undeclared');
    expect(
      ChatTemplateEngine.parseRendered(
        rendered,
        undeclared,
        tools: tools,
      ).toolCalls,
      isEmpty,
    );
  }
}
