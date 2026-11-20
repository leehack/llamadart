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
  test('worker request carries copied budget ends and replay policy', () async {
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
    );
    final plan = ChatCompletionRequestPlanner.build(
      backend: _GrammarBackend(),
      templateResult: result,
      messages: messages,
      params: const GenerationParams(
        thinkingBudget: ThinkingBudget(maxTokens: 2),
      ),
      toolChoice: ToolChoice.auto,
      parallelToolCalls: false,
      tools: tools,
    );
    final port = ReceivePort();
    addTearDown(port.close);
    final request = GenerateRequest(
      1,
      result.prompt,
      plan.generationParams.copyWith(maxTokens: 20),
      0,
      port.sendPort,
    );
    final budget =
        await Isolate.run(() => request.params.thinkingBudget)
            as ResolvedThinkingBudget;
    expect(budget.naturalEndTags, ['\n</think>', '</think>', '<tool_call>']);
    expect(budget.grammarReplayEndIndex, 2);
    expect(budget.forcedMessage, '\n');
    expect(() => budget.naturalEndTags.add('bad'), throwsUnsupportedError);
  });
}

class _GrammarBackend
    implements LlamaBackend, BackendGrammarConstraintsSupport {
  @override
  bool get supportsGrammarConstraints => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
