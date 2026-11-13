@TestOn('vm')
library;

import 'dart:io';

import 'package:llamadart/src/core/models/chat/chat_message.dart';
import 'package:llamadart/src/core/models/chat/chat_role.dart';
import 'package:llamadart/src/core/models/chat/chat_template_result.dart';
import 'package:llamadart/src/core/models/inference/tool_choice.dart';
import 'package:llamadart/src/core/models/tools/tool_definition.dart';
import 'package:llamadart/src/core/models/tools/tool_param.dart';
import 'package:llamadart/src/core/template/chat_format.dart';
import 'package:llamadart/src/core/template/chat_template_engine.dart';
import 'package:llamadart/src/core/template/tool_call_grammar_utils.dart';
import 'package:test/test.dart';

import '../../../../support/gbnf_recognizer.dart';

final _tool = ToolDefinition(
  name: 'get_weather',
  description: 'Weather',
  parameters: [ToolParam.string('location', required: true)],
);

// The Granite 3.3 template with a generation prompt that opens a thought when
// `thinking` is set, as a custom template can.
final String _forcedOpenGranite =
    File(
      'test/fixtures/llama_cpp_templates/ibm-granite-granite-3.3-2B-Instruct.jinja',
    ).readAsStringSync().replaceFirst(
      "{{- '<|end_of_role|>' }}\n     {%- endif %}\n {%- endfor %}",
      "{{- '<|end_of_role|>' }}\n"
          "         {%- if thinking %}{{- '<think>' }}{%- endif %}\n"
          "     {%- endif %}\n {%- endfor %}",
    );

final String _officialGranite = File(
  'test/fixtures/llama_cpp_templates/ibm-granite-granite-3.3-2B-Instruct.jinja',
).readAsStringSync();

LlamaChatTemplateResult _render({
  List<ToolDefinition>? tools,
  ToolChoice toolChoice = ToolChoice.auto,
  String? templateSource,
  bool parallelToolCalls = false,
  Map<String, dynamic> chatTemplateKwargs = const {'thinking': true},
}) => ChatTemplateEngine.render(
  templateSource: templateSource ?? _forcedOpenGranite,
  messages: const [
    LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'Weather?'),
  ],
  metadata: const {},
  tools: tools,
  toolChoice: toolChoice,
  parallelToolCalls: parallelToolCalls,
  chatTemplateKwargs: chatTemplateKwargs,
);

const _call =
    '<|tool_call|>[{"name": "get_weather", "arguments": {"location": "Paris"}}]';

void main() {
  test('the fixture opens a Granite thought', () {
    final result = _render();
    expect(result.format, ChatFormat.granite.index);
    expect(result.thinkingForcedOpen, isTrue);
    expect(result.prompt, endsWith('<think>'));
  });

  test('a forced-open Granite prompt without tools has no grammar', () {
    expect(_render().grammar, isNull);
  });

  test('a required Granite call after a forced-open thought takes the '
      'thought first', () {
    final result = _render(tools: [_tool], toolChoice: ToolChoice.required);
    expect(result.grammarLazy, isFalse);
    expect(
      ToolCallGrammarUtils.takesForcedOpenThought(result.grammar!),
      isTrue,
    );
    final grammar = GbnfRecognizer(result.grammar!);
    expect(grammar.accepts('Plan.</think>\n$_call'), isTrue);
    expect(grammar.accepts('</think>$_call'), isTrue);
    expect(grammar.accepts('Plan.</think></think>$_call'), isFalse);
  });

  test('a lazy Granite call grammar after a forced-open thought starts at '
      'its trigger', () {
    final result = _render(tools: [_tool]);
    expect(result.grammarLazy, isTrue);
    expect(result.grammarTriggers.map((t) => t.value), ['<|tool_call|>']);
    expect(GbnfRecognizer(result.grammar!).accepts(_call), isTrue);
  });

  test('the official Granite template does not open a thought, so a required '
      'call grammar does not take one', () {
    final result = _render(
      templateSource: _officialGranite,
      tools: [_tool],
      toolChoice: ToolChoice.required,
      chatTemplateKwargs: const {},
    );
    expect(result.thinkingForcedOpen, isFalse);
    expect(
      ToolCallGrammarUtils.takesForcedOpenThought(result.grammar!),
      isFalse,
    );
    expect(GbnfRecognizer(result.grammar!).accepts(_call), isTrue);
  });

  test('Granite allows several calls in one array only with parallel calls', () {
    const two =
        '<|tool_call|>[{"name": "get_weather", "arguments": {"location": "Paris"}}, '
        '{"name": "get_weather", "arguments": {"location": "Rome"}}]';
    for (final parallel in [false, true]) {
      final result = _render(
        tools: [_tool],
        toolChoice: ToolChoice.required,
        parallelToolCalls: parallel,
      );
      expect(GbnfRecognizer(result.grammar!).accepts('</think>$two'), parallel);
    }
  });
}
