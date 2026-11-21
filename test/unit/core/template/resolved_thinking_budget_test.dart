@TestOn('vm')
library;

import 'dart:isolate';

import 'package:llamadart/backend.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/backends/llama_cpp/worker_messages.dart';
import 'package:llamadart/src/core/engine/chat_completion_request_planner.dart';
import 'package:llamadart/src/core/template/resolved_thinking_budget.dart';
import 'package:test/test.dart';

void main() {
  test('worker chooses replay from the carried request grammar', () async {
    const messages = [
      LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'Use a tool'),
    ];
    final tools = [
      ToolDefinition(name: 'inspect', description: 'Inspect', parameters: []),
    ];
    final result = ChatTemplateEngine.render(
      templateSource:
          '{# <tool_call><function=><parameter=><function><parameters> #}<think>\n',
      messages: messages,
      metadata: const {},
      tools: tools,
      toolChoice: ToolChoice.required,
    );
    final plan = ChatCompletionRequestPlanner.build(
      backend: _GrammarBackend(),
      templateResult: result,
      messages: messages,
      params: const GenerationParams(
        thinkingBudget: ThinkingBudget(maxTokens: 2),
      ),
      toolChoice: ToolChoice.required,
      parallelToolCalls: false,
      tools: tools,
    );
    final port = ReceivePort();
    addTearDown(port.close);
    final required = plan.generationParams;
    final rawLazy = required.copyWith(
      thinkingBudget: ChatTemplateEngine.resolveThinkingBudget(
        result.format,
        const ThinkingBudget(maxTokens: 2),
      ),
      grammarLazy: true,
      grammarTriggers: const [
        GenerationGrammarTrigger.typed(
          type: GrammarTriggerType.word,
          value: '<tool_call>',
        ),
      ],
    );
    for (final (params, expected) in [
      (rawLazy, 2),
      (required.copyWith(maxTokens: 20), 2),
      (required.copyWith(grammar: 'root ::= "{}"'), null),
      (required.copyWith(grammarRoot: 'answer'), null),
      (rawLazy.copyWith(grammarTriggers: const []), null),
    ]) {
      final request = GenerateRequest(
        1,
        result.prompt,
        params,
        0,
        port.sendPort,
      );
      final (budget, replay) = await Isolate.run(() {
        final params = request.params;
        final budget = params.thinkingBudget as ResolvedThinkingBudget;
        return (budget, budget.replayEndIndexFor(params));
      });
      expect(budget.naturalEndTags, ['\n</think>', '</think>', '<tool_call>']);
      expect(replay, expected);
      expect(budget.forcedMessage, '\n');
      expect(() => budget.naturalEndTags.add('bad'), throwsUnsupportedError);
    }
  });
}

class _GrammarBackend
    implements LlamaBackend, BackendGrammarConstraintsSupport {
  @override
  bool get supportsGrammarConstraints => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
