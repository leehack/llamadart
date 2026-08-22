@TestOn('vm')
@Tags(['local-only', 'e2e'])
library;

import 'dart:io';

import 'package:llamadart/src/core/models/chat/chat_message.dart';
import 'package:llamadart/src/core/models/chat/chat_role.dart';
import 'package:llamadart/src/core/models/inference/tool_choice.dart';
import 'package:llamadart/src/core/models/tools/tool_definition.dart';
import 'package:llamadart/src/core/models/tools/tool_param.dart';
import 'package:llamadart/src/core/template/chat_template_engine.dart';
import 'package:llamadart/src/core/template/handlers/glm45_handler.dart';
import 'package:llamadart/src/core/template/handlers/llama_cpp_specialized_handlers.dart';
import 'package:test/test.dart';

void main() {
  const validator = '.dart_tool/llama_cpp_chat_tests/bin/test-gbnf-validator';
  final validatorFile = File(validator);

  setUpAll(() {
    expect(
      validatorFile.existsSync(),
      isTrue,
      reason:
          'Build the pinned upstream validator with '
          'tool/testing/run_llama_cpp_chat_tests.sh first.',
    );
  });

  test('accepts and rejects schema-exact specialized output shapes', () async {
    final cases = <_GrammarCase>[
      _GrammarCase(
        name: 'Kimi K3 escaped key and delimiter-aware string',
        grammar: KimiK3Handler().buildGrammar([_escapedTool])!,
        valid:
            '<|open|>tools<|sep|>'
            '<|open|>call tool="weather&amp;&quot;alerts"<|sep|>'
            '<|open|>argument key="city&amp;&quot;unit" type="string"<|sep|>'
            'x < 5<|close|>argument<|sep|>'
            '<|close|>call<|sep|><|close|>tools<|sep|>'
            '<|close|>message<|sep|>',
        invalid: [
          '<|open|>tools<|sep|>'
              '<|open|>call tool="weather&amp;&quot;alerts"<|sep|>'
              '<|open|>argument key="unknown" type="string"<|sep|>x'
              '<|close|>argument<|sep|><|close|>call<|sep|>'
              '<|close|>tools<|sep|><|close|>message<|sep|>',
        ],
      ),
      _GrammarCase(
        name: 'Kimi K3 required-first and flexible optional arguments',
        grammar: KimiK3Handler().buildGrammar([_orderedTool])!,
        valid:
            '<|open|>tools<|sep|>'
            '<|open|>call tool="ordered"<|sep|>'
            '<|open|>argument key="required_city" type="string"<|sep|>Seoul'
            '<|close|>argument<|sep|>'
            '<|open|>argument key="optional_last" type="string"<|sep|>C'
            '<|close|>argument<|sep|>'
            '<|open|>argument key="optional_first" type="string"<|sep|>A'
            '<|close|>argument<|sep|>'
            '<|close|>call<|sep|><|close|>tools<|sep|>'
            '<|close|>message<|sep|>',
        invalid: [
          '<|open|>tools<|sep|>'
              '<|open|>call tool="ordered"<|sep|>'
              '<|open|>argument key="optional_first" type="string"<|sep|>A'
              '<|close|>argument<|sep|>'
              '<|close|>call<|sep|><|close|>tools<|sep|>'
              '<|close|>message<|sep|>',
        ],
      ),
      _GrammarCase(
        name: 'Kimi K3 collision-free argument rule names',
        grammar: KimiK3Handler().buildGrammar([_collidingKeyTool])!,
        valid:
            '<|open|>tools<|sep|>'
            '<|open|>call tool="colliding"<|sep|>'
            '<|open|>argument key="a b" type="string"<|sep|>first'
            '<|close|>argument<|sep|>'
            '<|open|>argument key="a-b" type="string"<|sep|>second'
            '<|close|>argument<|sep|>'
            '<|close|>call<|sep|><|close|>tools<|sep|>'
            '<|close|>message<|sep|>',
        invalid: const [],
      ),
      _GrammarCase(
        name: 'MiniMax M1 quoted name',
        grammar: MinimaxM1Handler().buildGrammar([_weatherTool])!,
        valid:
            '<tool_calls>\n'
            '{"name":"weather","arguments":{"city":"Seoul"}}\n'
            '</tool_calls>',
        invalid: [
          '<tool_calls>\n'
              '{"name":weather,"arguments":{"city":"Seoul"}}\n'
              '</tool_calls>',
          '<tool_calls>\n'
              '{"name":"unknown","arguments":{"city":"Seoul"}}\n'
              '</tool_calls>',
        ],
      ),
      _GrammarCase(
        name: 'MiniMax M3 literal tag pairs and closing-bracket strings',
        grammar: MinimaxM3Handler().buildGrammar([_typedTool])!,
        valid:
            '${MinimaxM3Handler.namespace}<tool_call>\n'
            '${MinimaxM3Handler.namespace}<invoke name="typed">'
            '${MinimaxM3Handler.namespace}<code>x ] y'
            '${MinimaxM3Handler.namespace}</code>'
            '${MinimaxM3Handler.namespace}<options>'
            '${MinimaxM3Handler.namespace}</options>'
            '${MinimaxM3Handler.namespace}<items>'
            '${MinimaxM3Handler.namespace}</items>'
            '${MinimaxM3Handler.namespace}</invoke>\n'
            '${MinimaxM3Handler.namespace}</tool_call>',
        invalid: [
          '${MinimaxM3Handler.namespace}<tool_call>\n'
              '${MinimaxM3Handler.namespace}<invoke name="typed">'
              '${MinimaxM3Handler.namespace}<code>x'
              '${MinimaxM3Handler.namespace}</items>'
              '${MinimaxM3Handler.namespace}</invoke>\n'
              '${MinimaxM3Handler.namespace}</tool_call>',
        ],
      ),
      _GrammarCase(
        name: 'MiniMax M3 required-first and flexible optional arguments',
        grammar: MinimaxM3Handler().buildGrammar([_orderedTool])!,
        valid:
            '${MinimaxM3Handler.namespace}<tool_call>\n'
            '${MinimaxM3Handler.namespace}<invoke name="ordered">'
            '${MinimaxM3Handler.namespace}<required_city>Seoul'
            '${MinimaxM3Handler.namespace}</required_city>'
            '${MinimaxM3Handler.namespace}<optional_last>C'
            '${MinimaxM3Handler.namespace}</optional_last>'
            '${MinimaxM3Handler.namespace}<optional_first>A'
            '${MinimaxM3Handler.namespace}</optional_first>'
            '${MinimaxM3Handler.namespace}</invoke>\n'
            '${MinimaxM3Handler.namespace}</tool_call>',
        invalid: [
          '${MinimaxM3Handler.namespace}<tool_call>\n'
              '${MinimaxM3Handler.namespace}<invoke name="ordered">'
              '${MinimaxM3Handler.namespace}<optional_first>A'
              '${MinimaxM3Handler.namespace}</optional_first>'
              '${MinimaxM3Handler.namespace}</invoke>\n'
              '${MinimaxM3Handler.namespace}</tool_call>',
        ],
      ),
      _GrammarCase(
        name: 'MiniMax M3 zero-argument call',
        grammar: MinimaxM3Handler().buildGrammar([_pingTool])!,
        valid:
            '${MinimaxM3Handler.namespace}<tool_call>\n'
            '${MinimaxM3Handler.namespace}<invoke name="ping">'
            '${MinimaxM3Handler.namespace}</invoke>\n'
            '${MinimaxM3Handler.namespace}</tool_call>',
        invalid: [
          '${MinimaxM3Handler.namespace}<tool_call>\n'
              '${MinimaxM3Handler.namespace}<invoke name="ping">'
              '${MinimaxM3Handler.namespace}<unexpected>x'
              '${MinimaxM3Handler.namespace}</unexpected>'
              '${MinimaxM3Handler.namespace}</invoke>\n'
              '${MinimaxM3Handler.namespace}</tool_call>',
        ],
      ),
      _GrammarCase(
        name: 'DeepSeek V4 schema-directed DSML',
        grammar: DeepseekV4Handler().buildGrammar([_weatherTool])!,
        valid:
            '<｜DSML｜tool_calls>\n'
            '<｜DSML｜invoke name="weather">\n'
            '<｜DSML｜parameter name="city" string="true">x < 5'
            '</｜DSML｜parameter>\n'
            '</｜DSML｜invoke>\n'
            '</｜DSML｜tool_calls>',
        invalid: [
          '<｜DSML｜tool_calls>\n'
              '<｜DSML｜invoke name="weather">\n'
              '<｜DSML｜parameter name="city" string="false">"Seoul"'
              '</｜DSML｜parameter>\n'
              '</｜DSML｜invoke>\n'
              '</｜DSML｜tool_calls>',
        ],
      ),
      _GrammarCase(
        name: 'DeepSeek required-first and flexible optional parameters',
        grammar: DeepseekV4Handler().buildGrammar([_orderedTool])!,
        valid:
            '<｜DSML｜tool_calls>\n'
            '<｜DSML｜invoke name="ordered">\n'
            '<｜DSML｜parameter name="required_city" string="true">Seoul'
            '</｜DSML｜parameter>\n'
            '<｜DSML｜parameter name="optional_last" string="true">C'
            '</｜DSML｜parameter>\n'
            '<｜DSML｜parameter name="optional_first" string="true">A'
            '</｜DSML｜parameter>\n'
            '</｜DSML｜invoke>\n'
            '</｜DSML｜tool_calls>',
        invalid: [
          '<｜DSML｜tool_calls>\n'
              '<｜DSML｜invoke name="ordered">\n'
              '<｜DSML｜parameter name="optional_first" string="true">A'
              '</｜DSML｜parameter>\n'
              '</｜DSML｜invoke>\n'
              '</｜DSML｜tool_calls>',
        ],
      ),
      _GrammarCase(
        name: 'Muse Glimmer schema-directed ATEM',
        grammar: MuseGlimmerHandler().buildGrammar([_weatherTool])!,
        valid:
            '<atem:function_calls>\n'
            '<atem:invoke name="weather">\n'
            '<atem:parameter name="city">x < 5</atem:parameter>\n'
            '</atem:invoke>\n'
            '</atem:function_calls>',
        invalid: [
          '<atem:function_calls>\n'
              '<atem:invoke name="weather">\n'
              '<atem:parameter name="unknown">x</atem:parameter>\n'
              '</atem:invoke>\n'
              '</atem:function_calls>',
        ],
      ),
      _GrammarCase(
        name: 'Muse required-first and flexible optional parameters',
        grammar: MuseGlimmerHandler().buildGrammar([_orderedTool])!,
        valid:
            '<atem:function_calls>\n'
            '<atem:invoke name="ordered">\n'
            '<atem:parameter name="required_city">Seoul</atem:parameter>\n'
            '<atem:parameter name="optional_last">C</atem:parameter>\n'
            '<atem:parameter name="optional_first">A</atem:parameter>\n'
            '</atem:invoke>\n'
            '</atem:function_calls>',
        invalid: [
          '<atem:function_calls>\n'
              '<atem:invoke name="ordered">\n'
              '<atem:parameter name="optional_first">A</atem:parameter>\n'
              '</atem:invoke>\n'
              '</atem:function_calls>',
        ],
      ),
      _GrammarCase(
        name: 'Laguna delimiter-aware GLM arguments',
        grammar: Glm45Handler().buildGrammar([_weatherTool])!,
        valid:
            '<tool_call>weather\n'
            '<arg_key>city</arg_key>\n'
            '<arg_value>x < 5</arg_value>\n'
            '</tool_call>\n',
        invalid: [
          '<tool_call>weather\n'
              '<arg_key>unknown</arg_key>\n'
              '<arg_value>x</arg_value>\n'
              '</tool_call>\n',
        ],
      ),
      _GrammarCase(
        name: 'GLM collision-free argument rule names',
        grammar: Glm45Handler().buildGrammar([_collidingKeyTool])!,
        valid:
            '<tool_call>colliding\n'
            '<arg_key>a b</arg_key>\n'
            '<arg_value>first</arg_value>\n'
            '<arg_key>a-b</arg_key>\n'
            '<arg_value>second</arg_value>\n'
            '</tool_call>\n',
        invalid: const [],
      ),
    ];

    for (final grammarCase in cases) {
      await _expectGrammarMatch(
        validator: validator,
        name: grammarCase.name,
        grammar: grammarCase.grammar,
        input: grammarCase.valid,
        expected: true,
      );
      for (final invalid in grammarCase.invalid) {
        await _expectGrammarMatch(
          validator: validator,
          name: grammarCase.name,
          grammar: grammarCase.grammar,
          input: invalid,
          expected: false,
        );
      }
    }
  });

  test('required grammars accept prefixes but still require a tool', () async {
    const templateNames = [
      'Kimi-K3.jinja',
      'MiniMax-M3.jinja',
      'deepseek-ai-DeepSeek-V3.2.jinja',
      'deepseek-ai-DeepSeek-V4.jinja',
      'muse-glimmer.jinja',
      'poolside-Laguna-XS-2.1.jinja',
    ];
    for (final name in templateNames) {
      final source = File(
        '.dart_tool/llama_cpp/models/templates/$name',
      ).readAsStringSync();
      final rendered = ChatTemplateEngine.render(
        templateSource: source,
        messages: const [
          LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'weather?'),
        ],
        metadata: const {},
        tools: [_weatherTool],
        toolChoice: ToolChoice.required,
      );
      final toolOutput = _requiredOutputFor(name);
      await _expectGrammarMatch(
        validator: validator,
        name: '$name required prefix',
        grammar: rendered.grammar!,
        input: toolOutput,
        expected: true,
      );
      await _expectGrammarMatch(
        validator: validator,
        name: '$name required no-call rejection',
        grammar: rendered.grammar!,
        input: 'reasoning and final content only',
        expected: false,
      );
    }
  });
}

String _requiredOutputFor(String templateName) {
  if (templateName == 'Kimi-K3.jinja') {
    return 'reasoning<|close|>think<|sep|>'
        '<|open|>response<|sep|>Checking.<|close|>response<|sep|>'
        '<|open|>tools<|sep|>'
        '<|open|>call tool="weather"<|sep|>'
        '<|open|>argument key="city" type="string"<|sep|>Seoul'
        '<|close|>argument<|sep|><|close|>call<|sep|>'
        '<|close|>tools<|sep|><|close|>message<|sep|>';
  }
  if (templateName == 'MiniMax-M3.jinja') {
    return '<mm:think>reasoning</mm:think>'
        '${MinimaxM3Handler.namespace}<tool_call>\n'
        '${MinimaxM3Handler.namespace}<invoke name="weather">'
        '${MinimaxM3Handler.namespace}<city>Seoul'
        '${MinimaxM3Handler.namespace}</city>'
        '${MinimaxM3Handler.namespace}</invoke>\n'
        '${MinimaxM3Handler.namespace}</tool_call>';
  }
  if (templateName.startsWith('deepseek-ai-DeepSeek-V3.2')) {
    return 'reasoning</think>Checking.\n'
        '<｜DSML｜function_calls>\n'
        '<｜DSML｜invoke name="weather">\n'
        '<｜DSML｜parameter name="city" string="true">Seoul'
        '</｜DSML｜parameter>\n'
        '</｜DSML｜invoke>\n'
        '</｜DSML｜function_calls>';
  }
  if (templateName.startsWith('deepseek-ai-DeepSeek-V4')) {
    return 'reasoning</think>Checking.\n'
        '<｜DSML｜tool_calls>\n'
        '<｜DSML｜invoke name="weather">\n'
        '<｜DSML｜parameter name="city" string="true">Seoul'
        '</｜DSML｜parameter>\n'
        '</｜DSML｜invoke>\n'
        '</｜DSML｜tool_calls>';
  }
  if (templateName == 'muse-glimmer.jinja') {
    return ' to=self<|message|>reasoning<|eom|>'
        '<|start|>assistant to=weather<|message|>'
        '<atem:function_calls>\n'
        '<atem:invoke name="weather">\n'
        '<atem:parameter name="city">Seoul</atem:parameter>\n'
        '</atem:invoke>\n'
        '</atem:function_calls>';
  }
  return '<think>reasoning</think>Checking.\n'
      '<tool_call>weather\n'
      '<arg_key>city</arg_key>\n'
      '<arg_value>Seoul</arg_value>\n'
      '</tool_call>\n';
}

Future<void> _expectGrammarMatch({
  required String validator,
  required String name,
  required String grammar,
  required String input,
  required bool expected,
}) async {
  final directory = await Directory.systemTemp.createTemp(
    'llamadart-specialized-grammar-',
  );
  addTearDown(() => directory.delete(recursive: true));
  final grammarFile = File('${directory.path}/grammar.gbnf');
  final inputFile = File('${directory.path}/input.txt');
  await grammarFile.writeAsString(grammar);
  await inputFile.writeAsString(input);
  final result = await Process.run(validator, [
    grammarFile.path,
    inputFile.path,
  ]);
  final output = '${result.stdout}\n${result.stderr}';
  expect(result.exitCode, 0, reason: '$name\n$output');
  expect(
    output.contains('Input string is valid according to the grammar.'),
    expected,
    reason: '$name\n$output\nGrammar:\n$grammar\nInput:\n$input',
  );
}

class _GrammarCase {
  const _GrammarCase({
    required this.name,
    required this.grammar,
    required this.valid,
    required this.invalid,
  });

  final String name;
  final String grammar;
  final String valid;
  final List<String> invalid;
}

final _weatherTool = ToolDefinition(
  name: 'weather',
  description: 'Weather',
  parameters: [ToolParam.string('city', required: true)],
  handler: (_) async => null,
);

final _escapedTool = ToolDefinition(
  name: 'weather&"alerts',
  description: 'Weather',
  parameters: [ToolParam.string('city&"unit', required: true)],
  handler: (_) async => null,
);

final _orderedTool = ToolDefinition(
  name: 'ordered',
  description: 'Ordering coverage',
  parameters: [
    ToolParam.string('optional_first'),
    ToolParam.string('required_city', required: true),
    ToolParam.string('optional_last'),
  ],
  handler: (_) async => null,
);

final _pingTool = ToolDefinition(
  name: 'ping',
  description: 'Ping',
  parameters: const [],
  handler: (_) async => null,
);

final _typedTool = ToolDefinition(
  name: 'typed',
  description: 'Typed values',
  parameters: [
    ToolParam.string('code', required: true),
    ToolParam.object('options', properties: const [], required: true),
    ToolParam.array(
      'items',
      itemType: ToolParam.string('item'),
      required: true,
    ),
  ],
  handler: (_) async => null,
);

final _collidingKeyTool = ToolDefinition(
  name: 'colliding',
  description: 'Collision coverage',
  parameters: [
    ToolParam.string('a b', required: true),
    ToolParam.string('a-b', required: true),
  ],
  handler: (_) async => null,
);
