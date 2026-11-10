@TestOn('vm')
library;

import 'dart:io';

import 'package:llamadart/src/core/models/chat/chat_message.dart';
import 'package:llamadart/src/core/models/chat/chat_role.dart';
import 'package:llamadart/src/core/template/chat_format.dart';
import 'package:llamadart/src/core/template/chat_template_engine.dart';
import 'package:test/test.dart';

import '../../../support/gbnf_recognizer.dart';
import '../../../support/qwen3_coder_required_calls.dart';

void main() {
  // llama.cpp also starts it at `<function=get_weather>` for the Qwen3-Coder
  // template, which fails a reply that writes that tag as text.
  test('a lazy grammar starts only at `<tool_call>`', () {
    for (final (:template, :enableThinking, :bareFirstCall)
        in qwen3CoderRequiredTemplates) {
      final rendered = ChatTemplateEngine.render(
        templateSource: File(template).readAsStringSync(),
        messages: const [
          LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'hello'),
        ],
        metadata: const {},
        tools: [qwen3CoderRequiredTool],
        enableThinking: enableThinking,
      );
      expect(rendered.grammarLazy, isTrue);
      expect(rendered.grammarTriggers.map((trigger) => trigger.value), [
        '<tool_call>\n<function=',
      ], reason: template);
      final grammar = GbnfRecognizer(rendered.grammar!);
      const bareCall =
          '<function=get_weather>\n<parameter=location>\nParis\n'
          '</parameter>\n</function>\n</tool_call>';
      expect(grammar.accepts(bareCall), isFalse, reason: template);
      // The parse still takes a bare first call, as llama.cpp's does.
      expect(
        ChatTemplateEngine.parseRendered(
          rendered,
          'Text.\n$bareCall',
          tools: [qwen3CoderRequiredTool],
        ).toolCalls,
        hasLength(bareFirstCall ? 1 : 0),
        reason: template,
      );
      expect(grammar.accepts('<tool_call>\n$bareCall'), isTrue);
    }
  });

  test('Nemotron-3-Nano keeps its own required grammar', () {
    for (final enableThinking in [true, false]) {
      final rendered = renderQwen3CoderRequiredCall(
        'test/fixtures/llama_cpp_templates/'
        'NVIDIA-Nemotron-3-Nano-30B-A3B-BF16.jinja',
        enableThinking: enableThinking,
        parallelToolCalls: false,
      );
      expect(rendered.format, ChatFormat.pegConstructed.index);
      expect(rendered.grammarLazy, isFalse);
      expect(
        rendered.grammar,
        allOf(
          isNot(contains('text-before-calls')),
          isNot(contains('first-tool-call-scope')),
        ),
        reason: 'thinking $enableThinking',
      );
    }
  });

  group('required tool-call grammar takes what llama.cpp takes', () {
    for (final (:template, :enableThinking, :bareFirstCall)
        in qwen3CoderRequiredTemplates) {
      for (final parallel in [false, true]) {
        test('${template.split('/').last}, thinking $enableThinking, '
            'parallel $parallel', () {
          final rendered = renderQwen3CoderRequiredCall(
            template,
            enableThinking: enableThinking,
            parallelToolCalls: parallel,
          );
          expect(rendered.format, ChatFormat.qwen3CoderXml.index);
          expect(rendered.grammarLazy, isFalse);
          expect(rendered.grammarTriggers, isEmpty);
          final grammar = GbnfRecognizer(rendered.grammar!);
          final replies = qwen3CoderRequiredReplies(
            parallelToolCalls: parallel,
            bareFirstCall: bareFirstCall,
          );
          for (final output in replies.valid) {
            expect(grammar.accepts(output), isTrue, reason: output);
          }
          for (final output in replies.invalid) {
            expect(grammar.accepts(output), isFalse, reason: output);
          }

          final bare = ChatTemplateEngine.parseRendered(
            rendered,
            'Let me check.\n<function=get_weather>\n'
            '<parameter=location>\nParis\n</parameter>\n</function>\n'
            '</tool_call>',
            tools: [qwen3CoderRequiredTool],
          );
          expect(bare.toolCalls, hasLength(bareFirstCall ? 1 : 0));
        });
      }
    }
  });
}
