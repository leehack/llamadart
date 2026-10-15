@TestOn('vm')
@Tags(['local-only', 'e2e'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:llamadart/src/core/grammar/json_schema_converter.dart';
import 'package:llamadart/src/core/models/chat/chat_message.dart';
import 'package:llamadart/src/core/models/chat/chat_role.dart';
import 'package:llamadart/src/core/models/chat/content_part.dart';
import 'package:llamadart/src/core/models/inference/tool_choice.dart';
import 'package:llamadart/src/core/template/chat_format.dart';
import 'package:llamadart/src/core/template/chat_template_engine.dart';

import 'package:llamadart/src/core/models/tools/tool_definition.dart';
import 'package:llamadart/src/core/models/tools/tool_param.dart';
import 'package:llamadart/src/core/template/handlers/command_r7b_handler.dart';
import 'package:llamadart/src/core/template/handlers/gemma4_handler.dart';
import 'package:llamadart/src/core/template/handlers/glm45_handler.dart';
import 'package:llamadart/src/core/template/handlers/hermes_handler.dart';
import 'package:llamadart/src/core/template/handlers/mistral_handler.dart';
import 'package:llamadart/src/core/template/handlers/hunyuan_v3_handler.dart';
import 'package:llamadart/src/core/template/handlers/llama_cpp_specialized_handlers.dart';
import 'package:test/test.dart';

import '../../support/litert_qwen_content_fixture.dart';
import '../../support/llama_cpp_grammar_load.dart';
import '../../support/qwen35_tool_result_fixture.dart' as typed;
import '../../support/qwen_tool_schema_fixture.dart';
import '../../support/raw_tool_schema_fixture.dart';

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

  test('LiteRT Qwen normalized history preserves compiled JSON schema', () {
    for (final thinking in [true, false]) {
      final history = renderLiteRtQwenHistory(
        choice: ToolChoice.required,
        thinking: thinking,
      );
      expect(history.normalized, history.legacy);
      expect(history.normalized, contains(jsonEncode(qwenResultPayload)));
      expect(history.rendered.grammarLazy, isFalse);
      _expectGrammar(
        validator,
        history.rendered.grammar!,
        valid: [litertQwenEnvelope],
        invalid: [
          litertQwenEnvelope.replaceFirst('"inspect"', '"unknown"'),
          litertQwenEnvelope.replaceFirst('"code": "123"', '"code": 123'),
          litertQwenEnvelope.replaceFirst('"count": 7', '"count": "7"'),
          litertQwenEnvelope.replaceFirst('"active": true, ', ''),
          litertQwenEnvelope.replaceFirst('</tool_call>', ''),
          'No tool',
        ],
      );
    }
  });

  test('Qwen typed Map result history preserves compiled follow-up grammar', () {
    for (final thinking in [true, false]) {
      final rendered = typed.renderQwenResultHistory(thinking: thinking);
      expect(rendered.prompt, contains(jsonEncode(typed.qwenResultPayload)));
      expect(rendered.grammarLazy, isFalse);
      // Qwen's existing grammar constrains the XML envelope and declared names;
      // scalar typing is reconstructed by the output parser, tested separately.
      // Its grammar root begins at the tool envelope, not the thinking prefix.
      _expectGrammar(
        validator,
        rendered.grammar!,
        valid: [typed.qwenResultEnvelope],
        invalid: [
          typed.qwenResultEnvelope.replaceFirst(
            '<function=inspect>',
            '<function=unknown>',
          ),
          typed.qwenResultEnvelope.replaceFirst(
            '<parameter=count>',
            '<parameter=unknown>',
          ),
          typed.qwenResultEnvelope.replaceFirst('</tool_call>', ''),
          typed.qwenResultEnvelope.replaceFirst('</function>', ''),
          'No tool',
        ],
      );
    }
  });

  test('Qwen typed result history preserves compiled follow-up grammar', () {
    for (final thinking in [true, false]) {
      final rendered = renderQwenResultHistory(
        thinking: thinking,
        templateSource: File(qwenResultTemplatePath).readAsStringSync(),
      );
      expect(rendered.prompt, contains(jsonEncode(qwenResultPayload)));
      expect(rendered.grammarLazy, isFalse);
      final parsed = ChatTemplateEngine.parse(
        rendered.format,
        qwenResultEnvelope,
        tools: [qwenResultTool],
      );
      expect(parsed.toolCalls, hasLength(1));
      expect(
        jsonDecode(parsed.toolCalls.single.function!.arguments!),
        qwenResultPayload,
      );
      // Qwen's existing grammar constrains the XML envelope and declared names;
      // scalar typing is reconstructed by the output parser, tested separately.
      // Its grammar root begins at the tool envelope, not the thinking prefix.
      _expectGrammar(
        validator,
        rendered.grammar!,
        valid: [qwenResultEnvelope],
        invalid: [
          qwenResultEnvelope.replaceFirst(
            '<function=inspect>',
            '<function=unknown>',
          ),
          qwenResultEnvelope.replaceFirst(
            '<parameter=count>',
            '<parameter=unknown>',
          ),
          qwenResultEnvelope.replaceFirst('</tool_call>', ''),
          qwenResultEnvelope.replaceFirst('</function>', ''),
          'No tool',
        ],
      );
    }
  });

  test(
    'audio string-template rendering preserves compiled schema enforcement',
    () {
      final rendered = ChatTemplateEngine.render(
        templateSource:
            '{# ]<]minimax[>[ <tool_call> <invoke name= #}'
            '{{ messages[0].content }}{{ "<mm:think>" }}',
        messages: [
          LlamaChatMessage.withContent(
            role: LlamaChatRole.user,
            content: [
              const LlamaTextContent('inspect'),
              LlamaAudioContent(bytes: Uint8List.fromList([1, 2, 3])),
            ],
          ),
        ],
        metadata: const {},
        tools: [_schemaTool],
        toolChoice: ToolChoice.required,
      );
      expect(rendered.prompt, 'inspect<__media__><mm:think>');
      expect(rendered.grammarLazy, isFalse);
      const ns = MinimaxM3Handler.namespace;
      const valid =
          'reason</mm:think>$ns<tool_call>$ns<invoke name="inspect">'
          '$ns<code>123$ns</code>'
          '$ns<options>$ns</options>$ns<items>$ns</items>'
          '$ns<count>7$ns</count>$ns<active>true$ns</active>'
          '$ns<empty>null$ns</empty>$ns</invoke>$ns</tool_call>';
      _expectGrammar(
        validator,
        rendered.grammar!,
        valid: [valid],
        invalid: [
          valid.replaceFirst('name="inspect"', 'name="unknown"'),
          valid.replaceFirst('$ns<count>7$ns</count>', ''),
          valid.replaceFirst('$ns<count>7', '$ns<count>wrong'),
          valid.replaceFirst(
            '$ns</invoke>',
            '$ns<extra>x$ns</extra>$ns</invoke>',
          ),
          valid.replaceFirst('$ns</tool_call>', ''),
          'reason</mm:think>No tool',
        ],
      );
    },
  );

  test('Gemma 4 eager grammar enforces one exact schema-valid envelope', () {
    final grammar = Gemma4Handler().buildGrammar([
      _weatherWithCityTool,
      _zeroArgTool,
      _gemmaEscapedTool,
    ])!;
    final weatherCall = '<|tool_call>call:weather{"city":"Seoul"}<tool_call|>';
    final pingCall = '<|tool_call>call:ping{}<tool_call|>';
    final escapedRequiredArguments = <String, dynamic>{
      'a b': 'one',
      r'city&"zone\path': 'Montréal {north}',
    };
    final escapedOptionalArguments = <String, dynamic>{
      ...escapedRequiredArguments,
      'a-b': 'two',
    };
    String escapedCall(Map<String, dynamic> arguments) =>
        '<|tool_call>call:${_gemmaEscapedTool.name}'
        '${jsonEncode(arguments)}<tool_call|>';

    _expectGrammar(
      validator,
      grammar,
      valid: [
        weatherCall,
        pingCall,
        escapedCall(escapedRequiredArguments),
        escapedCall(escapedOptionalArguments),
      ],
      invalid: [
        'leading prose$weatherCall',
        '$weatherCall$pingCall',
        '<|tool_call>call:unknown{}<tool_call|>',
        '<|tool_call>call:weather{}<tool_call|>',
        '<|tool_call>call:weather{"city":7}<tool_call|>',
        '<|tool_call>call:weather{"city":"Seoul","extra":true}'
            '<tool_call|>',
        escapedCall(<String, dynamic>{'a b': 'one'}),
      ],
    );
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

  test('specialized and GLM rule names remain collision-free', () {
    const open = '<|open|>';
    const close = '<|close|>';
    const separator = '<|sep|>';
    _expectGrammar(
      validator,
      KimiK3Handler().buildGrammar([_collidingKeyTool])!,
      valid: [
        '$open'
            'tools$separator'
            '$open'
            'call tool="colliding"$separator'
            '$open'
            'argument key="a b" type="string"$separator'
            'first$close'
            'argument$separator'
            '$open'
            'argument key="a-b" type="string"$separator'
            'second$close'
            'argument$separator'
            '$close'
            'call$separator'
            '$close'
            'tools$separator'
            '$close'
            'message$separator',
      ],
      invalid: const [],
    );
    _expectGrammar(
      validator,
      Glm45Handler().buildGrammar([_collidingKeyTool])!,
      valid: const [
        '\n<tool_call>colliding\n'
            '<arg_key>a b</arg_key>\n'
            '<arg_value>first</arg_value>\n'
            '<arg_key>a-b</arg_key>\n'
            '<arg_value>second</arg_value>\n'
            '</tool_call>\n',
      ],
      invalid: const [],
    );
  });

  test('Command R7B, Hermes, and Hunyuan rule collisions compile', () {
    _expectGrammar(
      validator,
      CommandR7BHandler().buildGrammar(_collidingToolNames)!,
      valid: const [
        '<|START_ACTION|>'
            '[{"tool_name": "a b", "parameters": {}},'
            '{"tool_name": "a-b", "parameters": {}}]'
            '<|END_ACTION|>',
      ],
      invalid: const [
        '<|START_ACTION|>'
            '[{"tool_name": "a-u20-b", "parameters": {}}]'
            '<|END_ACTION|>',
      ],
    );

    _expectGrammar(
      validator,
      HermesHandler().buildGrammar(_collidingToolNames)!,
      valid: const [
        '<tool_call>{"name": "a b", "arguments": {}}</tool_call>'
            '<tool_call>{"name": "a-b", "arguments": {}}</tool_call>',
      ],
      invalid: const [
        '<tool_call>{"name": "a-u20-b", "arguments": {}}</tool_call>',
      ],
    );

    _expectGrammar(
      validator,
      HunyuanV3Handler().buildGrammar(_hunyuanCollisionTools)!,
      valid: const [
        '<tool_calls:opensource>\n'
            '<tool_call:opensource>a b<tool_sep:opensource>\n'
            '</tool_call:opensource>\n'
            '<tool_call:opensource>a-b<tool_sep:opensource>\n'
            '<arg_key:opensource>x y</arg_key:opensource>\n'
            '<arg_value:opensource>first</arg_value:opensource>\n'
            '<arg_key:opensource>x-y</arg_key:opensource>\n'
            '<arg_value:opensource>second</arg_value:opensource>\n'
            '</tool_call:opensource>\n'
            '</tool_calls:opensource>',
      ],
      invalid: const [
        '<tool_calls:opensource>\n'
            '<tool_call:opensource>a-b<tool_sep:opensource>\n'
            '<arg_key:opensource>x-u20-y</arg_key:opensource>\n'
            '<arg_value:opensource>first</arg_value:opensource>\n'
            '<arg_key:opensource>x-y</arg_key:opensource>\n'
            '<arg_value:opensource>second</arg_value:opensource>\n'
            '</tool_call:opensource>\n'
            '</tool_calls:opensource>',
      ],
    );
  });

  test('Command R7B and Hermes preserve escaped JSON wire identities', () {
    const toolName = 'quote"slash\\tool';
    const parameterName = 'quote"slash\\parameter';
    final tool = ToolDefinition(
      name: toolName,
      description: 'Escaped JSON identity coverage',
      parameters: [ToolParam.string(parameterName, required: true)],
      handler: (_) async => null,
    );
    final encodedTool = jsonEncode(toolName);
    final encodedParameter = jsonEncode(parameterName);
    final commandCall =
        '{"tool_name": $encodedTool, "parameters": '
        '{$encodedParameter: "value"}}';
    final hermesCall =
        '{"name": $encodedTool, "arguments": '
        '{$encodedParameter: "value"}}';

    _expectGrammar(
      validator,
      CommandR7BHandler().buildGrammar([tool])!,
      valid: ['<|START_ACTION|>[$commandCall]<|END_ACTION|>'],
      invalid: [
        '<|START_ACTION|>'
            '[{"tool_name": "quote\\"slash-tool", "parameters": '
            '{$encodedParameter: "value"}}]'
            '<|END_ACTION|>',
      ],
    );
    _expectGrammar(
      validator,
      HermesHandler().buildGrammar([tool])!,
      valid: ['<tool_call>$hermesCall</tool_call>'],
      invalid: [
        '<tool_call>'
            '{"name": "quote\\"slash-tool", "arguments": '
            '{$encodedParameter: "value"}}'
            '</tool_call>',
      ],
    );
  });

  test(
    'GLM accepts delimiter strings and rejects an invalid enum atomically',
    () {
      final grammar = Glm45Handler().buildGrammar([_glmEvidenceTool])!;
      const validCall =
          '<tool_call>inspect\n'
          '<arg_key>code</arg_key>\n'
          '<arg_value>x < 5</arg_value>\n'
          '<arg_key>city</arg_key>\n'
          '<arg_value>Seoul</arg_value>\n'
          '</tool_call>\n';
      const invalidEnumCall =
          '<tool_call>inspect\n'
          '<arg_key>code</arg_key>\n'
          '<arg_value>second</arg_value>\n'
          '<arg_key>city</arg_key>\n'
          '<arg_value>Rome</arg_value>\n'
          '</tool_call>\n';
      const protocolMarkers = [
        '<tool_call>',
        '</tool_call>',
        '<arg_key>',
        '</arg_key>',
        '<arg_value>',
        '</arg_value>',
      ];

      _expectGrammar(
        validator,
        grammar,
        valid: [
          validCall,
          '\n$validCall',
          for (final marker in protocolMarkers)
            validCall.replaceFirst(
              'x < 5',
              'before${marker.substring(0, marker.length - 1)}X after',
            ),
        ],
        invalid: [
          '$validCall$invalidEnumCall',
          for (final marker in protocolMarkers)
            validCall.replaceFirst('x < 5', 'before$marker after'),
        ],
      );
    },
  );

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

  test('specialized grammars accept optional properties in any order once', () {
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
            'argument key="detail" type="string"$separator'
            'verbose$close'
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
            'argument key="detail" type="string"$separator'
            'verbose$close'
            'argument$separator'
            '$open'
            'argument key="detail" type="string"$separator'
            'duplicate$close'
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
    );

    const namespace = MinimaxM3Handler.namespace;
    const m3Valid =
        '$namespace<tool_call>'
        '$namespace<invoke name="lookup">'
        '$namespace<query>weather$namespace</query>'
        '$namespace<detail>verbose$namespace</detail>'
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
          '$namespace<detail>duplicate$namespace</detail>$namespace</invoke>',
        ),
      ],
    );

    const dsmlValid =
        '<｜DSML｜function_calls>'
        '<｜DSML｜invoke name="lookup">'
        '<｜DSML｜parameter name="query" string="true">weather'
        '</｜DSML｜parameter>'
        '<｜DSML｜parameter name="detail" string="true">verbose'
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
          '<｜DSML｜parameter name="detail" string="true">duplicate'
              '</｜DSML｜parameter></｜DSML｜invoke>',
        ),
      ],
    );

    const museValid =
        '<atem:function_calls>'
        '<atem:invoke name="lookup">'
        '<atem:parameter name="query">weather</atem:parameter>'
        '<atem:parameter name="detail">verbose</atem:parameter>'
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
          '<atem:parameter name="detail">duplicate</atem:parameter>'
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

  test('LFM2.5 required tool choice compiles the LFM2 tool-call grammar', () {
    final rendered = ChatTemplateEngine.render(
      templateSource: File(
        'test/fixtures/templates/LFM2_5-1_2B-Thinking.jinja',
      ).readAsStringSync(),
      messages: const [
        LlamaChatMessage.fromText(
          role: LlamaChatRole.user,
          text: 'Weather in Seoul?',
        ),
      ],
      metadata: const {},
      tools: [_weatherWithCityTool],
      toolChoice: ToolChoice.required,
    );

    expect(rendered.format, ChatFormat.lfm2.index);
    expect(rendered.grammarLazy, isFalse);
    const call =
        '<|tool_call_start|>[{"name": "weather", '
        '"arguments": {"city": "Seoul"}, "id": "call_0"}]<|tool_call_end|>';
    _expectGrammar(
      validator,
      rendered.grammar!,
      valid: [call],
      invalid: [
        call.replaceFirst('"weather"', '"unknown"'),
        call.replaceFirst('"city"', '"town"'),
        call.replaceFirst('"Seoul"', '1'),
        call.replaceFirst('<|tool_call_end|>', ''),
        '{"tool_call": {"name": "weather", "arguments": {"city": "Seoul"}}}',
        'No tool',
      ],
    );
  });
  test(
    'canonical JSON schema grammar enforces nullable enums and containers',
    () {
      final tool = rawSchemaTool();
      final rendered = ChatTemplateEngine.render(
        templateSource: null,
        messages: const [
          LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'inspect'),
        ],
        metadata: const {},
        tools: [tool],
        toolChoice: ToolChoice.required,
        parallelToolCalls: true,
      );
      String envelope(Map<String, dynamic> args) => jsonEncode({
        'tool_call': {'name': 'inspect', 'arguments': args},
      });
      _expectGrammar(
        validator,
        rendered.grammar!,
        valid: [
          envelope(rawToolArguments),
          envelope({
            ...rawToolArguments,
            'code': '001',
            'mode': 1,
            'tags': ['a', 'b'],
          }),
        ],
        invalid: [
          envelope({...rawToolArguments, 'code': 42}),
          envelope({...rawToolArguments, 'mode': '2'}),
          envelope({...rawToolArguments, 'mode': 3}),
          envelope({...rawToolArguments, 'tags': []}),
          envelope({
            ...rawToolArguments,
            'tags': ['a', 'b', 'c'],
          }),
          envelope({
            ...rawToolArguments,
            'nested': {'active': 'true'},
          }),
          envelope({...rawToolArguments, 'extra': true}),
          envelope({...rawToolArguments}..remove('code')),
        ],
      );
    },
  );

  test('Hermes canonical alternatives bind both tags around every tool', () {
    final first = rawSchemaTool();
    final second = ToolDefinition.fromJsonSchema(
      name: 'other',
      description: 'Another tool',
      schema: first.toJsonSchema(),
    );
    final legacy = ToolDefinition(
      name: 'legacy',
      description: 'Legacy',
      parameters: [ToolParam.string('city', required: true)],
    );
    String call(String name, Map<String, dynamic> args) =>
        '<tool_call>${jsonEncode({'name': name, 'arguments': args})}</tool_call>';
    final a = call('inspect', rawToolArguments);
    final b = call('other', rawToolArguments);
    final c = call('legacy', {'city': 'Seoul'});
    for (final tools in [
      [first, second],
      [second, first],
      [first, legacy],
      [legacy, first],
    ]) {
      final other = tools.any((tool) => tool.name == 'legacy') ? c : b;
      _expectGrammar(
        validator,
        HermesHandler().buildGrammar(tools)!,
        valid: [a, other, '$a$other', '$other$a'],
        invalid: [
          a.replaceFirst('</tool_call>', ''),
          other.replaceFirst('<tool_call>', ''),
          a.replaceFirst('inspect', 'unknown'),
          '$a<tool_call>',
        ],
      );
    }
  });

  test('Hermes and Mistral compile canonical nullable nested constraints', () {
    final tool = rawSchemaTool();
    for (final hermes in [true, false]) {
      final grammar = hermes
          ? HermesHandler().buildGrammar([tool])!
          : MistralHandler().buildGrammar([tool])!;
      String output(Map<String, dynamic> args) => hermes
          ? '<tool_call>${jsonEncode({'name': 'inspect', 'arguments': args})}</tool_call>'
          : '[TOOL_CALLS]${jsonEncode([
              {'name': 'inspect', 'arguments': args, 'id': 'abcdefghi'},
            ])}';
      _expectGrammar(
        validator,
        grammar,
        valid: [
          output(rawToolArguments),
          output({...rawToolArguments, 'code': '001'}),
        ],
        invalid: [
          output({...rawToolArguments, 'mode': 3}),
          output({...rawToolArguments, 'tags': []}),
          output({
            ...rawToolArguments,
            'nested': {'active': 'true'},
          }),
          output({...rawToolArguments, 'code': 1}),
        ],
      );
    }
  });

  test(
    'canonical wire keys and annotation values are not schema references',
    () {
      for (final open in [true, false]) {
        final tool = ToolDefinition.fromJsonSchema(
          name: 'literal',
          description: 'Literal keys',
          schema: {
            'type': 'object',
            'properties': {
              r'$ref': {'type': 'integer'},
              '*': {'type': 'string'},
            },
            'required': [r'$ref', '*'],
            'additionalProperties': open,
            'default': {r'$ref': '#/missing'},
            'examples': [
              {r'$ref': '#/example'},
            ],
          },
        );
        final rendered = ChatTemplateEngine.render(
          templateSource: null,
          messages: const [],
          metadata: const {},
          tools: [tool],
          toolChoice: ToolChoice.required,
        );
        String output(Map<String, dynamic> args) => jsonEncode({
          'tool_call': {'name': 'literal', 'arguments': args},
        });
        _expectGrammar(
          validator,
          rendered.grammar!,
          valid: [
            output({r'$ref': 1, '*': 'yes'}),
            if (open) output({r'$ref': 1, '*': 'yes', 'extra': true}),
          ],
          invalid: [
            output({r'$ref': 1, 'other': 'yes'}),
            output({r'$ref': 1, '*': 2}),
            output({'*': 'yes'}),
          ],
        );
      }
    },
  );

  test('canonical scalar GLM and Hunyuan grammars enforce integer and null', () {
    final tool = rawScalarTool();
    const glm =
        '<tool_call>weather\n<arg_key>city</arg_key>\n<arg_value>Seoul</arg_value>\n<arg_key>count</arg_key>\n<arg_value>2</arg_value>\n<arg_key>nothing</arg_key>\n<arg_value>null</arg_value>\n</tool_call>';
    _expectGrammar(
      validator,
      Glm45Handler().buildGrammar([tool])!,
      valid: ['$glm\n'],
      invalid: [
        glm.replaceFirst('<arg_value>2', '<arg_value>2.5'),
        glm.replaceFirst('<arg_value>null', '<arg_value>true'),
      ],
    );
    const hunyuan =
        '<tool_calls>\n<tool_call>weather<tool_sep>\n<arg_key>city</arg_key>\n<arg_value>Seoul</arg_value>\n<arg_key>count</arg_key>\n<arg_value>2</arg_value>\n<arg_key>nothing</arg_key>\n<arg_value>null</arg_value>\n</tool_call>\n</tool_calls>';
    _expectGrammar(
      validator,
      HunyuanV3Handler().buildGrammar([tool])!,
      valid: [
        hunyuan.replaceAllMapped(
          RegExp(r'</?(?:tool_calls|tool_call|tool_sep|arg_key|arg_value)>'),
          (match) => match[0]!.replaceFirst('>', ':opensource>'),
        ),
      ],
      invalid: [
        hunyuan.replaceFirst('<arg_value>2', '<arg_value>2.5'),
        hunyuan.replaceFirst('<arg_value>null', '<arg_value>true'),
      ],
    );
  });

  test('open schema objects constrain declared optional properties', () {
    for (final open in [true, false]) {
      final tool = ToolDefinition.fromJsonSchema(
        name: 'weather',
        description: 'Weather',
        schema: {
          'type': 'object',
          'properties': {
            'city': {'type': 'string'},
            'count': {'type': 'integer'},
            'mode': {
              'enum': ['c', 'f'],
            },
          },
          'required': ['city'],
          if (!open) 'additionalProperties': false,
        },
      );
      String hermes(Map<String, dynamic> args) =>
          '<tool_call>${jsonEncode({'name': 'weather', 'arguments': args})}</tool_call>';
      String generic(Map<String, dynamic> args) => jsonEncode({
        'tool_call': {'name': 'weather', 'arguments': args},
      });
      final rendered = ChatTemplateEngine.render(
        templateSource: null,
        messages: const [],
        metadata: const {},
        tools: [tool],
        toolChoice: ToolChoice.required,
      );
      for (final (grammar, output) in [
        (HermesHandler().buildGrammar([tool])!, hermes),
        (rendered.grammar!, generic),
      ]) {
        _expectGrammar(
          validator,
          grammar,
          valid: [
            output({'city': 'Seoul'}),
            output({'city': 'Seoul', 'count': 3, 'mode': 'c'}),
            if (open) output({'city': 'Seoul', 'count': 3, 'extra': 'x'}),
            if (open) output({'city': 'Seoul', 'cit': 1, 'counter': 'x'}),
          ],
          invalid: [
            output({'city': 'Seoul', 'count': 'three'}),
            output({'city': 'Seoul', 'count': 1.5}),
            output({'city': 'Seoul', 'mode': 'zzz'}),
            output({'city': 1}),
            output({'count': 3}),
            output({
              'city': 'Seoul',
            }).replaceFirst('"Seoul"', '"Seoul","city":"dup"'),
            if (!open) output({'city': 'Seoul', 'extra': 'x'}),
          ],
        );
      }
    }
  });

  test('large open-object key sets load and exclude declared keys', () {
    for (final names in [...largeKeySets.values, overBudgetKeySet]) {
      final withinBudget = !identical(names, overBudgetKeySet);
      final schema = <String, dynamic>{
        'type': 'object',
        'properties': {
          for (final name in names) name: {'type': 'integer'},
        },
        'additionalProperties': true,
      };
      final first = jsonEncode(names.first);
      final duplicate = '{$first:1,$first:2}';
      for (final (grammar, output) in _openObjectGrammars(schema)) {
        _expectGrammar(
          validator,
          grammar,
          valid: [
            output('{$first:1}'),
            output('{$first:1,${jsonEncode('${names.first}x')}:"v"}'),
            output('{${jsonEncode(names.last)}:2,"zz-extra":true}'),
            // Beyond the budget, final validation checks declared keys.
            if (!withinBudget) ...[output(duplicate), output('{$first:"x"}')],
          ],
          invalid: [
            if (withinBudget) ...[output(duplicate), output('{$first:"x"}')],
            output('{$first:1,}'),
          ],
        );
      }
    }
  });

  test('closed objects with 1023 optional properties load', () {
    final schema = <String, dynamic>{
      'type': 'object',
      'properties': {
        for (final name in largeKeySets['1023 properties']!)
          name: {'type': 'integer'},
      },
      'additionalProperties': false,
    };
    for (final (grammar, output) in _openObjectGrammars(schema)) {
      _expectGrammar(
        validator,
        grammar,
        valid: [output('{"p5":1}'), output('{"p5":1,"p1022":2}')],
        invalid: [output('{"p5":1,"zz":1}'), output('{"p5":"x"}')],
      );
    }
  });

  test('open objects exclude non-BMP declared keys', () {
    final schema = <String, dynamic>{
      'type': 'object',
      'properties': {
        for (final name in ['é', 'éa', '😀', '😀b']) name: {'type': 'boolean'},
      },
      'additionalProperties': true,
    };
    for (final (grammar, output) in _openObjectGrammars(schema)) {
      _expectGrammar(
        validator,
        grammar,
        valid: [
          output('{"😀":true}'),
          output('{"😀c":1}'),
          output('{"éb":1}'),
          output('{"😀b":true,"😁":1}'),
        ],
        invalid: [output('{"😀":1}'), output('{"é":1}'), output('{"😀b":1}')],
      );
    }
  });

  test('maxItems 1999 loads for every minItems and item type', () {
    for (final item in boundedArrayItemSchemas) {
      final value = jsonEncode(boundedArrayItemValue(item));
      String items(int count) => '[${List.filled(count, value).join(',')}]';
      for (final minItems in [0, 1, 1999]) {
        final schema = <String, dynamic>{
          'type': 'object',
          'properties': {
            'list': {
              'type': 'array',
              'items': item,
              'minItems': minItems,
              'maxItems': 1999,
            },
          },
          'required': ['list'],
          'additionalProperties': false,
        };
        for (final (grammar, output) in _openObjectGrammars(schema)) {
          _expectGrammar(
            validator,
            grammar,
            valid: [
              if (minItems == 0) output('{"list":[]}'),
              if (minItems <= 1) output('{"list":${items(1)}}'),
              output('{"list":${items(1999)}}'),
            ],
            invalid: [
              output('{"list":${items(2000)}}'),
              if (minItems > 0) output('{"list":[]}'),
              if (minItems == 1999) output('{"list":${items(1998)}}'),
            ],
          );
        }
      }
    }
  });

  test('Hermes schema calls accept newlines inside the tool_call tags', () {
    final call = jsonEncode({'name': 'inspect', 'arguments': rawToolArguments});
    _expectGrammar(
      validator,
      HermesHandler().buildGrammar([rawSchemaTool()])!,
      valid: [
        '<tool_call>$call</tool_call>',
        '<tool_call>\n$call\n</tool_call>\n<tool_call>\n$call\n</tool_call>',
      ],
      invalid: ['$call</tool_call>', '<tool_call>\n$call\n'],
    );
  });

  test('legacy GLM integer parameters reject fractional values', () {
    final tool = ToolDefinition(
      name: 'weather',
      description: 'Weather',
      parameters: [ToolParam.integer('count', required: true)],
    );
    const call =
        '<tool_call>weather\n<arg_key>count</arg_key>\n<arg_value>15</arg_value>\n</tool_call>\n';
    _expectGrammar(
      validator,
      Glm45Handler().buildGrammar([tool])!,
      valid: [call],
      invalid: [call.replaceFirst('15', '1.5')],
    );
  });

  test('llama.cpp grammar repetition limit matches the schema bound', () {
    final directory = Directory.systemTemp.createTempSync('llamadart-gbnf-');
    addTearDown(() => directory.deleteSync(recursive: true));
    String run(int bound) {
      final grammar = File('${directory.path}/bound.gbnf')
        ..writeAsStringSync(
          JsonSchemaConverter.convert({'type': 'string', 'maxLength': bound}),
        );
      final input = File('${directory.path}/bound.txt')
        ..writeAsStringSync('"${'a' * bound}"');
      final result = Process.runSync(validator, [grammar.path, input.path]);
      return '${result.stdout}\n${result.stderr}';
    }

    expect(
      run(1999),
      contains('Input string is valid according to the grammar.'),
    );
    expect(run(2000), contains('failed to parse grammar'));
  });
}

/// Returns Hermes, generic required-tool and `responseFormat` grammars for an
/// object [schema], each with a function that wraps JSON arguments in the
/// grammar's output envelope.
List<(String, String Function(String))> _openObjectGrammars(
  Map<String, dynamic> schema,
) {
  final tool = ToolDefinition.fromJsonSchema(
    name: 'spec',
    description: 'Spec',
    schema: schema,
  );
  return [
    (
      HermesHandler().buildGrammar([tool])!,
      (args) => '<tool_call>{"name":"spec","arguments":$args}</tool_call>',
    ),
    (
      ChatTemplateEngine.render(
        templateSource: null,
        messages: const [],
        metadata: const {},
        tools: [tool],
        toolChoice: ToolChoice.required,
      ).grammar!,
      (args) => '{"tool_call":{"name":"spec","arguments":$args}}',
    ),
    (
      ChatTemplateEngine.render(
        templateSource: null,
        messages: const [],
        metadata: const {},
        responseFormat: {
          'type': 'json_schema',
          'json_schema': {'schema': schema},
        },
      ).grammar!,
      (args) => args,
    ),
  ];
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
  // The validator prints the rejected input byte by byte, which can split a
  // multi-byte UTF-8 character.
  const lenient = Utf8Codec(allowMalformed: true);
  final result = Process.runSync(
    validator,
    [grammar.path, inputFile.path],
    stdoutEncoding: lenient,
    stderrEncoding: lenient,
  );
  final text = '${result.stdout}\n${result.stderr}';
  expect(result.exitCode, 0, reason: text);
  expect(
    text.contains('Input string is valid according to the grammar.'),
    expected,
    reason: 'Input: $input\n$text\nGrammar:\n${grammar.readAsStringSync()}',
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
    ToolParam.string('detail'),
  ],
  handler: (_) async => null,
);

final _gemmaEscapedTool = ToolDefinition(
  name: r'weather&"alerts\route|primary',
  description: 'Gemma escaped identity and collision coverage',
  parameters: [
    ToolParam.string('a b', required: true),
    ToolParam.string('a-b'),
    ToolParam.string(r'city&"zone\path', required: true),
  ],
  handler: (_) async => null,
);

final _kimiTool = ToolDefinition(
  name: 'weather&"alerts',
  description: 'Weather',
  parameters: [ToolParam.string('city&"zone', required: true)],
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

final _collidingToolNames = <ToolDefinition>[
  ToolDefinition(
    name: 'a b',
    description: 'Spaced tool name',
    parameters: const [],
    handler: (_) async => null,
  ),
  ToolDefinition(
    name: 'a-b',
    description: 'Dashed tool name',
    parameters: const [],
    handler: (_) async => null,
  ),
];

final _hunyuanCollisionTools = <ToolDefinition>[
  _collidingToolNames.first,
  ToolDefinition(
    name: 'a-b',
    description: 'Tool and parameter collision coverage',
    parameters: [
      ToolParam.string('x y', required: true),
      ToolParam.string('x-y', required: true),
    ],
    handler: (_) async => null,
  ),
];

final _glmEvidenceTool = ToolDefinition(
  name: 'inspect',
  description: 'GLM donor evidence',
  parameters: [
    ToolParam.string('code', required: true),
    ToolParam.enumType(
      'city',
      values: const ['Seoul', 'Paris'],
      required: true,
    ),
  ],
  handler: (_) async => null,
);
