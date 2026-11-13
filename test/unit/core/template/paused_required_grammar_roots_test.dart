@TestOn('vm')
library;

import 'dart:io';

import 'package:llamadart/src/core/models/chat/chat_message.dart';
import 'package:llamadart/src/core/models/chat/chat_role.dart';
import 'package:llamadart/src/core/models/inference/tool_choice.dart';
import 'package:llamadart/src/core/models/tools/tool_definition.dart';
import 'package:llamadart/src/core/models/tools/tool_param.dart';
import 'package:llamadart/src/core/template/chat_template_engine.dart';
import 'package:llamadart/src/core/template/tool_call_grammar_utils.dart';
import 'package:test/test.dart';

import '../../../support/gbnf_recognizer.dart';

final _tool = ToolDefinition(
  name: 'get_weather',
  description: 'Weather',
  parameters: [ToolParam.string('location', required: true)],
);

// A thinking budget pauses these required-call grammars through the thought,
// so they start on the reply after the end tag and must accept it.
const _repliesAfterThought = {
  'test/fixtures/llama_cpp_templates/inclusionai-ling-3.0-flash.jinja':
      '<tool_call>get_weather\n<arg_key>location</arg_key>\n'
      '<arg_value>Paris</arg_value>\n</tool_call>',
  'test/fixtures/templates/Qwen3_5-0_8B.jinja':
      '\n\n<tool_call>\n<function=get_weather>\n<parameter=location>\nParis\n'
      '</parameter>\n</function>\n</tool_call>',
};

void main() {
  for (final MapEntry(key: template, value: reply)
      in _repliesAfterThought.entries) {
    test('the paused $template required-call grammar accepts the reply after '
        'the thought', () {
      final result = ChatTemplateEngine.render(
        templateSource: File(template).readAsStringSync(),
        messages: const [
          LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'Weather?'),
        ],
        metadata: const {},
        tools: [_tool],
        toolChoice: ToolChoice.required,
      );
      expect(result.thinkingForcedOpen, isTrue);
      expect(result.grammarLazy, isFalse);
      expect(
        ToolCallGrammarUtils.keepsAppliedThroughThought(result.grammar!),
        isFalse,
      );
      expect(GbnfRecognizer(result.grammar!).accepts(reply), isTrue);
    });
  }
}
