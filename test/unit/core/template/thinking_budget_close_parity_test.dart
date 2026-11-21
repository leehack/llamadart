@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:llamadart/src/backends/backend.dart';
import 'package:llamadart/src/core/engine/chat_completion_request_planner.dart';
import 'package:llamadart/src/core/models/chat/chat_message.dart';
import 'package:llamadart/src/core/models/chat/chat_role.dart';
import 'package:llamadart/src/core/models/chat/chat_template_result.dart';
import 'package:llamadart/src/core/models/inference/generation_params.dart';
import 'package:llamadart/src/core/models/inference/tool_choice.dart';
import 'package:llamadart/src/core/template/chat_format.dart';
import 'package:llamadart/src/core/template/chat_template_engine.dart';
import 'package:llamadart/src/core/template/resolved_thinking_budget.dart';
import 'package:test/test.dart';

void main() {
  final fixture =
      jsonDecode(
            File(
              'test/fixtures/thinking_budget_close_upstream.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;

  for (final entry in (fixture['templates'] as List).cast<Map>()) {
    final path = entry['template'] as String;
    test('closes the thought of $path as llama.cpp does', () {
      final result = ChatTemplateEngine.render(
        templateSource: File(path).readAsStringSync(),
        messages: _messages,
        metadata: const {'general.name': 'Generic test model'},
      );
      final budget = _planBudget(result);

      expect(_naturalEnds(budget), entry['thinking_end_tags']);
      expect(
        '${budget.forcedMessage ?? ''}${budget.endTag}',
        (entry['thinking_end_tags'] as List).first,
      );
      expect(budget.startTag, entry['thinking_start_tag']);
    });
  }
  test('the actual plain Qwen3-Coder template retains one end', () {
    final result = ChatTemplateEngine.render(
      templateSource: File(
        'test/fixtures/llama_cpp_templates/Qwen3-Coder.jinja',
      ).readAsStringSync(),
      messages: _messages,
      metadata: const {'general.name': 'Qwen3.5'},
    );
    expect(result.format, ChatFormat.qwen3CoderXml.index);
    expect(result.thinkingForcedOpen, isFalse);
    final budget = _planBudget(result);
    expect(_naturalEnds(budget), ['</think>']);
    expect(budget.forcedMessage, '\n');
  });
}

const _messages = [
  LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'hello'),
];

ThinkingBudget _planBudget(LlamaChatTemplateResult result) =>
    ChatCompletionRequestPlanner.build(
      backend: _PromptBackend(),
      templateResult: result,
      messages: _messages,
      params: const GenerationParams(
        thinkingBudget: ThinkingBudget(maxTokens: 4),
      ),
      toolChoice: ToolChoice.auto,
      parallelToolCalls: false,
    ).generationParams.thinkingBudget!;

List<String> _naturalEnds(ThinkingBudget budget) =>
    budget is ResolvedThinkingBudget ? budget.naturalEndTags : [budget.endTag!];

class _PromptBackend implements LlamaBackend, BackendGrammarConstraintsSupport {
  @override
  bool get supportsGrammarConstraints => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
