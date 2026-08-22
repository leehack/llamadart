@TestOn('vm')
@Tags(['local-only', 'e2e'])
library;

import 'dart:io';

import 'package:llamadart/src/core/models/tools/tool_definition.dart';
import 'package:llamadart/src/core/models/tools/tool_param.dart';
import 'package:llamadart/src/core/template/handlers/llama_cpp_specialized_handlers.dart';
import 'package:test/test.dart';

void main() {
  late String validator;

  setUpAll(() {
    validator = Platform.environment['LLAMA_CPP_GBNF_VALIDATOR'] ?? '';
    expect(
      validator,
      isNotEmpty,
      reason: 'Set LLAMA_CPP_GBNF_VALIDATOR to llama.cpp test-gbnf-validator.',
    );
    expect(File(validator).existsSync(), isTrue);
  });

  test('MiniMax M1 accepts quoted names and rejects invalid JSON names', () {
    final grammar = MinimaxM1Handler().buildGrammar([_schemaTool])!;
    _expectGrammar(
      validator,
      grammar,
      valid: [
        '<tool_calls>\n'
            '{"name":"inspect","arguments":'
            '{"code":"a]b","options":{},"items":[],"count":7,'
            '"active":true,"empty":null}}\n'
            '</tool_calls>',
      ],
      invalid: [
        '<tool_calls>\n'
            '{name:"inspect","arguments":'
            '{"code":"a","options":{},"items":[],"count":7,'
            '"active":true,"empty":null}}\n'
            '</tool_calls>',
        '<tool_calls>\n'
            '{"name":"unknown","arguments":'
            '{"code":"a","options":{},"items":[],"count":7,'
            '"active":true,"empty":null}}\n'
            '</tool_calls>',
        '<tool_calls>\n{"name":"inspect","arguments":\n</tool_calls>',
      ],
    );
  });

  test('Kimi K3 accepts escaped schema keys and rejects undeclared keys', () {
    final grammar = KimiK3Handler().buildGrammar([_kimiTool])!;
    const open = '<|open|>';
    const close = '<|close|>';
    const separator = '<|sep|>';
    _expectGrammar(
      validator,
      grammar,
      valid: [
        '$open'
            'tools$separator'
            '$open'
            'call tool="weather&amp;&quot;alerts"$separator'
            '$open'
            'argument key="city&amp;&quot;zone" type="string"$separator'
            'a<]b$close'
            'argument$separator'
            '$close'
            'call$separator'
            '$close'
            'tools$separator'
            '$close'
            'message$separator',
      ],
      invalid: [
        '$open'
            'tools$separator'
            '$open'
            'call tool="weather&amp;&quot;alerts"$separator'
            '$open'
            'argument key="city&\\"zone" type="string"$separator'
            'x$close'
            'argument$separator'
            '$close'
            'call$separator'
            '$close'
            'tools$separator'
            '$close'
            'message$separator',
        '$open'
            'tools$separator'
            '$open'
            'call tool="weather&amp;&quot;alerts"$separator'
            '$open'
            'argument key="unknown" type="string"$separator'
            'x$close'
            'argument$separator'
            '$close'
            'call$separator'
            '$close'
            'tools$separator'
            '$close'
            'message$separator',
      ],
    );
  });

  test('Kimi K3 compiles and accepts zero-parameter tools', () {
    final grammar = KimiK3Handler().buildGrammar([_zeroArgTool])!;
    const open = '<|open|>';
    const close = '<|close|>';
    const separator = '<|sep|>';
    _expectGrammar(
      validator,
      grammar,
      valid: [
        '$open'
            'tools$separator'
            '$open'
            'call tool="ping"$separator'
            '$close'
            'call$separator'
            '$close'
            'tools$separator'
            '$close'
            'message$separator',
      ],
      invalid: [
        '$open'
            'tools$separator'
            '$open'
            'call tool="ping"$separator'
            '$open'
            'argument key="unexpected" type="string"$separator'
            'value$close'
            'argument$separator'
            '$close'
            'call$separator'
            '$close'
            'tools$separator'
            '$close'
            'message$separator',
      ],
    );
  });

  test('XML attribute grammars round-trip escaped schema identities', () {
    const namespace = MinimaxM3Handler.namespace;
    _expectGrammar(
      validator,
      MinimaxM3Handler().buildGrammar([_attributeTool])!,
      valid: [
        '$namespace<tool_call>'
            '$namespace<invoke name="weather&amp;&quot;alerts">'
            '$namespace</invoke>'
            '$namespace</tool_call>',
      ],
      invalid: [
        '$namespace<tool_call>'
            '$namespace<invoke name="weather&"alerts">'
            '$namespace</invoke>'
            '$namespace</tool_call>',
        '$namespace<tool_call>'
            '$namespace<invoke name="weather&&quot;alerts">'
            '$namespace</invoke>'
            '$namespace</tool_call>',
        '$namespace<tool_call>'
            '$namespace<invoke name="weather&amp;amp;&quot;alerts">'
            '$namespace</invoke>'
            '$namespace</tool_call>',
      ],
    );

    const dsmlValid =
        '<｜DSML｜function_calls>'
        '<｜DSML｜invoke name="weather&amp;&quot;alerts">'
        '<｜DSML｜parameter name="city&amp;&quot;zone" string="true">Seoul'
        '</｜DSML｜parameter>'
        '</｜DSML｜invoke>'
        '</｜DSML｜function_calls>';
    _expectGrammar(
      validator,
      DeepseekV32Handler().buildGrammar([_escapedAttributeSchemaTool])!,
      valid: [dsmlValid],
      invalid: [
        dsmlValid.replaceFirst('&amp;&quot;', '&"'),
        dsmlValid.replaceFirst('&amp;&quot;', '&&quot;'),
        dsmlValid.replaceFirst('&amp;&quot;', '&bogus;&quot;'),
        dsmlValid.replaceFirst('&amp;&quot;', '&amp;amp;&quot;'),
      ],
    );

    const museValid =
        '<atem:function_calls>'
        '<atem:invoke name="weather&amp;&quot;alerts">'
        '<atem:parameter name="city&amp;&quot;zone">Seoul</atem:parameter>'
        '</atem:invoke>'
        '</atem:function_calls>';
    _expectGrammar(
      validator,
      MuseGlimmerHandler().buildGrammar([_escapedAttributeSchemaTool])!,
      valid: [museValid],
      invalid: [
        museValid.replaceFirst('&amp;&quot;', '&"'),
        museValid.replaceFirst('&amp;&quot;', '&&quot;'),
        museValid.replaceFirst('&amp;&quot;', '&bogus;&quot;'),
        museValid.replaceFirst('&amp;&quot;', '&amp;amp;&quot;'),
      ],
    );
    _expectGrammar(
      validator,
      MuseGlimmerHandler().buildRequiredGrammar([_escapedAttributeSchemaTool])!,
      valid: [' to=weather&"alerts<|message|>$museValid'],
      invalid: [
        ' to=weather<|message|>$museValid',
        ' to=other<|message|>$museValid',
        ' to= weather&"alerts <|message|>$museValid',
        ' to=weather&"alerts<|message|>'
            '${museValid.replaceFirst('</atem:function_calls>', '<atem:invoke name="weather&amp;&quot;alerts"></atem:invoke></atem:function_calls>')}',
      ],
    );
  });

  test('MiniMax M3 binds closing tags and preserves string delimiters', () {
    final grammar = MinimaxM3Handler().buildGrammar([
      _schemaTool,
      _zeroArgTool,
    ])!;
    const namespace = MinimaxM3Handler.namespace;
    _expectGrammar(
      validator,
      grammar,
      valid: [
        '$namespace<tool_call>'
            '$namespace<invoke name="inspect">'
            '$namespace<code>a]b$namespace</code>'
            '$namespace<options>$namespace</options>'
            '$namespace<items>$namespace</items>'
            '$namespace<count>7$namespace</count>'
            '$namespace<active>true$namespace</active>'
            '$namespace<empty>null$namespace</empty>'
            '$namespace</invoke>'
            '$namespace</tool_call>',
        '$namespace<tool_call>'
            '$namespace<invoke name="ping">'
            '$namespace</invoke>'
            '$namespace</tool_call>',
        '$namespace<tool_call>'
            '$namespace<invoke name="inspect">'
            '$namespace<code>a${namespace}literal$namespace</code>'
            '$namespace<options>$namespace</options>'
            '$namespace<items>$namespace</items>'
            '$namespace<count>7$namespace</count>'
            '$namespace<active>true$namespace</active>'
            '$namespace<empty>null$namespace</empty>'
            '$namespace</invoke>'
            '$namespace</tool_call>',
      ],
      invalid: [
        '$namespace<tool_call>'
            '$namespace<invoke name="inspect">'
            '$namespace<code>a$namespace</count>'
            '$namespace</invoke>'
            '$namespace</tool_call>',
        '$namespace<tool_call>'
            '$namespace<invoke name="inspect">'
            '$namespace<unknown>x$namespace</unknown>'
            '$namespace</invoke>'
            '$namespace</tool_call>',
        '$namespace<tool_call>'
            '$namespace<invoke name="inspect">'
            '$namespace<code>a$namespace</code>'
            '$namespace<options>$namespace</options>'
            '$namespace<items>$namespace</items>'
            '$namespace<count>oops$namespace</count>'
            '$namespace<active>true$namespace</active>'
            '$namespace<empty>null$namespace</empty>'
            '$namespace</invoke>'
            '$namespace</tool_call>',
      ],
    );
  });

  test('DeepSeek DSML enforces schema names types and delimiters', () {
    final grammar = DeepseekV32Handler().buildGrammar([_schemaTool])!;
    const start = '<｜DSML｜function_calls>';
    const end = '</｜DSML｜function_calls>';
    const invoke = '<｜DSML｜invoke name="inspect">';
    const closeInvoke = '</｜DSML｜invoke>';
    const valid =
        '$start\n$invoke\n'
        '<｜DSML｜parameter name="code" string="true">x < 5]'
        '</｜DSML｜parameter>\n'
        '<｜DSML｜parameter name="options" string="false">{}'
        '</｜DSML｜parameter>\n'
        '<｜DSML｜parameter name="items" string="false">[]'
        '</｜DSML｜parameter>\n'
        '<｜DSML｜parameter name="count" string="false">7'
        '</｜DSML｜parameter>\n'
        '<｜DSML｜parameter name="active" string="false">true'
        '</｜DSML｜parameter>\n'
        '<｜DSML｜parameter name="empty" string="false">null'
        '</｜DSML｜parameter>\n'
        '$closeInvoke\n$end';
    _expectGrammar(
      validator,
      grammar,
      valid: [valid],
      invalid: [
        valid.replaceFirst('name="code"', 'name="unknown"'),
        valid.replaceFirst('string="true"', 'string="false"'),
        valid.replaceFirst(
          '<｜DSML｜parameter name="count" string="false">7'
              '</｜DSML｜parameter>\n',
          '',
        ),
        valid.replaceFirst('>7</｜DSML｜parameter>', '>seven</｜DSML｜parameter>'),
      ],
    );
  });

  test(
    'Muse grammar enforces schema names types and delimiter-aware strings',
    () {
      final grammar = MuseGlimmerHandler().buildGrammar([_schemaTool])!;
      const valid =
          '<atem:function_calls>\n'
          '<atem:invoke name="inspect">\n'
          '<atem:parameter name="code">x < 5]</atem:parameter>\n'
          '<atem:parameter name="options">{}</atem:parameter>\n'
          '<atem:parameter name="items">[]</atem:parameter>\n'
          '<atem:parameter name="count">7</atem:parameter>\n'
          '<atem:parameter name="active">true</atem:parameter>\n'
          '<atem:parameter name="empty">null</atem:parameter>\n'
          '</atem:invoke>\n'
          '</atem:function_calls>';
      _expectGrammar(
        validator,
        grammar,
        valid: [valid],
        invalid: [
          valid.replaceFirst('name="code"', 'name="unknown"'),
          valid.replaceFirst(
            '<atem:parameter name="count">7</atem:parameter>\n',
            '',
          ),
          valid.replaceFirst('>7</atem:parameter>', '>seven</atem:parameter>'),
        ],
      );
    },
  );

  test('specialized grammars reject duplicate optional properties', () {
    const open = '<|open|>';
    const close = '<|close|>';
    const separator = '<|sep|>';
    _expectGrammar(
      validator,
      KimiK3Handler().buildGrammar([_optionalTool])!,
      valid: [
        '$open'
            'tools$separator'
            '$open'
            'call tool="lookup"$separator'
            '$open'
            'argument key="query" type="string"$separator'
            'weather$close'
            'argument$separator'
            '$open'
            'argument key="note" type="string"$separator'
            'metric$close'
            'argument$separator'
            '$close'
            'call$separator'
            '$close'
            'tools$separator'
            '$close'
            'message$separator',
      ],
      invalid: [
        '$open'
            'tools$separator'
            '$open'
            'call tool="lookup"$separator'
            '$open'
            'argument key="query" type="string"$separator'
            'weather$close'
            'argument$separator'
            '$open'
            'argument key="note" type="string"$separator'
            'metric$close'
            'argument$separator'
            '$open'
            'argument key="note" type="string"$separator'
            'duplicate$close'
            'argument$separator'
            '$close'
            'call$separator'
            '$close'
            'tools$separator'
            '$close'
            'message$separator',
      ],
    );

    const namespace = MinimaxM3Handler.namespace;
    const m3Valid =
        '$namespace<tool_call>'
        '$namespace<invoke name="lookup">'
        '$namespace<query>weather$namespace</query>'
        '$namespace<note>metric$namespace</note>'
        '$namespace</invoke>'
        '$namespace</tool_call>';
    _expectGrammar(
      validator,
      MinimaxM3Handler().buildGrammar([_optionalTool])!,
      valid: [m3Valid],
      invalid: [
        m3Valid.replaceFirst(
          '$namespace</invoke>',
          '$namespace<note>duplicate$namespace</note>$namespace</invoke>',
        ),
      ],
    );

    const dsmlValid =
        '<｜DSML｜function_calls>'
        '<｜DSML｜invoke name="lookup">'
        '<｜DSML｜parameter name="query" string="true">weather'
        '</｜DSML｜parameter>'
        '<｜DSML｜parameter name="note" string="true">metric'
        '</｜DSML｜parameter>'
        '</｜DSML｜invoke>'
        '</｜DSML｜function_calls>';
    _expectGrammar(
      validator,
      DeepseekV32Handler().buildGrammar([_optionalTool])!,
      valid: [dsmlValid],
      invalid: [
        dsmlValid.replaceFirst(
          '</｜DSML｜invoke>',
          '<｜DSML｜parameter name="note" string="true">duplicate'
              '</｜DSML｜parameter></｜DSML｜invoke>',
        ),
      ],
    );

    const museValid =
        '<atem:function_calls>'
        '<atem:invoke name="lookup">'
        '<atem:parameter name="query">weather</atem:parameter>'
        '<atem:parameter name="note">metric</atem:parameter>'
        '</atem:invoke>'
        '</atem:function_calls>';
    _expectGrammar(
      validator,
      MuseGlimmerHandler().buildGrammar([_optionalTool])!,
      valid: [museValid],
      invalid: [
        museValid.replaceFirst(
          '</atem:invoke>',
          '<atem:parameter name="note">duplicate</atem:parameter>'
              '</atem:invoke>',
        ),
      ],
    );
  });

  test('required grammars accept prefixes but still require a tool call', () {
    const kimiCall =
        '<|open|>tools<|sep|>'
        '<|open|>call tool="weather"<|sep|>'
        '<|open|>argument key="city" type="string"<|sep|>Seoul'
        '<|close|>argument<|sep|><|close|>call<|sep|>'
        '<|close|>tools<|sep|><|close|>message<|sep|>';
    _expectGrammar(
      validator,
      KimiK3Handler().buildRequiredGrammar([_weatherWithCityTool])!,
      valid: ['reasoning<|close|>think<|sep|>$kimiCall'],
      invalid: ['reasoning<|close|>think<|sep|>No tool'],
    );

    const namespace = MinimaxM3Handler.namespace;
    const m3Call =
        '$namespace<tool_call>'
        '$namespace<invoke name="ping">'
        '$namespace</invoke>'
        '$namespace</tool_call>';
    _expectGrammar(
      validator,
      MinimaxM3Handler().buildRequiredGrammar([_zeroArgTool])!,
      valid: ['<mm:think>reasoning</mm:think>$m3Call'],
      invalid: ['<mm:think>reasoning</mm:think>No tool'],
    );

    const dsmlCall =
        '<｜DSML｜function_calls>'
        '<｜DSML｜invoke name="weather">'
        '<｜DSML｜parameter name="city" string="true">Seoul'
        '</｜DSML｜parameter>'
        '</｜DSML｜invoke>'
        '</｜DSML｜function_calls>';
    _expectGrammar(
      validator,
      DeepseekV32Handler().buildRequiredGrammar([_weatherWithCityTool])!,
      valid: ['reasoning without a closing think tag$dsmlCall'],
      invalid: ['reasoning without a tool call'],
    );

    const museCall =
        ' to=weather<|message|><atem:function_calls>'
        '<atem:invoke name="weather">'
        '<atem:parameter name="city">Seoul</atem:parameter>'
        '</atem:invoke></atem:function_calls>';
    _expectGrammar(
      validator,
      MuseGlimmerHandler().buildRequiredGrammar([_weatherWithCityTool])!,
      valid: [
        ' to=self<|message|>reasoning<|eom|>'
            '<|start|>assistant$museCall',
      ],
      invalid: [' to=user<|message|>No tool<|eot|>'],
    );

    const lagunaCall =
        '\n<tool_call>weather\n'
        '<arg_key>city</arg_key>\n'
        '<arg_value>Seoul</arg_value>\n'
        '</tool_call>\n';
    _expectGrammar(
      validator,
      LagunaHandler().buildRequiredGrammar([_weatherWithCityTool])!,
      valid: ['reasoning</think>$lagunaCall'],
      invalid: ['reasoning</think>No tool'],
    );
  });
}

void _expectGrammar(
  String validator,
  String grammar, {
  required List<String> valid,
  required List<String> invalid,
}) {
  final directory = Directory.systemTemp.createTempSync('llamadart-gbnf-');
  addTearDown(() => directory.deleteSync(recursive: true));
  final grammarFile = File('${directory.path}/grammar.gbnf')
    ..writeAsStringSync(grammar);
  for (final input in valid) {
    _validate(validator, grammarFile, input, expected: true);
  }
  for (final input in invalid) {
    _validate(validator, grammarFile, input, expected: false);
  }
}

void _validate(
  String validator,
  File grammar,
  String input, {
  required bool expected,
}) {
  final inputFile = File('${grammar.parent.path}/input.txt')
    ..writeAsStringSync(input);
  final result = Process.runSync(validator, [grammar.path, inputFile.path]);
  final output = '${result.stdout}\n${result.stderr}';
  expect(result.exitCode, 0, reason: output);
  expect(
    output.contains('Input string is valid according to the grammar.'),
    expected,
    reason: 'Input: $input\n$output\nGrammar:\n${grammar.readAsStringSync()}',
  );
}

final _schemaTool = ToolDefinition(
  name: 'inspect',
  description: 'Inspect typed values',
  parameters: [
    ToolParam.string('code', required: true),
    ToolParam.object('options', properties: const [], required: true),
    ToolParam.array(
      'items',
      itemType: ToolParam.string('item'),
      required: true,
    ),
    ToolParam.integer('count', required: true),
    ToolParam.boolean('active', required: true),
    ToolParam.nullType('empty', required: true),
  ],
  handler: (_) async => null,
);

final _zeroArgTool = ToolDefinition(
  name: 'ping',
  description: 'Ping',
  parameters: const [],
  handler: (_) async => null,
);

final _attributeTool = ToolDefinition(
  name: 'weather&"alerts',
  description: 'Weather alerts',
  parameters: const [],
  handler: (_) async => null,
);

final _escapedAttributeSchemaTool = ToolDefinition(
  name: 'weather&"alerts',
  description: 'Weather alerts',
  parameters: [ToolParam.string('city&"zone', required: true)],
  handler: (_) async => null,
);

final _weatherWithCityTool = ToolDefinition(
  name: 'weather',
  description: 'Weather',
  parameters: [ToolParam.string('city', required: true)],
  handler: (_) async => null,
);

final _optionalTool = ToolDefinition(
  name: 'lookup',
  description: 'Lookup',
  parameters: [
    ToolParam.string('query', required: true),
    ToolParam.string('note'),
  ],
  handler: (_) async => null,
);

final _kimiTool = ToolDefinition(
  name: 'weather&"alerts',
  description: 'Weather',
  parameters: [ToolParam.string('city&"zone', required: true)],
  handler: (_) async => null,
);
