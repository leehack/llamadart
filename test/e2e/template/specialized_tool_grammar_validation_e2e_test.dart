@TestOn('vm')
@Tags(['local-only', 'e2e'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:llamadart/src/core/exceptions.dart';
import 'package:llamadart/src/core/grammar/json_schema_converter.dart';
import 'package:llamadart/src/core/grammar/llama_cpp_grammar_limits.dart';
import 'package:llamadart/src/core/models/chat/chat_message.dart';
import 'package:llamadart/src/core/models/chat/chat_role.dart';
import 'package:llamadart/src/core/models/chat/content_part.dart';
import 'package:llamadart/src/core/models/inference/tool_choice.dart';
import 'package:llamadart/src/core/template/response_format.dart';
import 'package:llamadart/src/core/template/chat_format.dart';
import 'package:llamadart/src/core/template/chat_template_engine.dart';
import 'package:llamadart/src/core/template/template_internal_metadata.dart';

import 'package:llamadart/src/core/models/tools/tool_definition.dart';
import 'package:llamadart/src/core/models/tools/tool_param.dart';
import 'package:llamadart/src/core/template/handlers/command_r7b_handler.dart';
import 'package:llamadart/src/core/template/handlers/gemma4_handler.dart';
import 'package:llamadart/src/core/template/handlers/gpt_oss_handler.dart';
import 'package:llamadart/src/core/template/handlers/glm45_handler.dart';
import 'package:llamadart/src/core/template/handlers/hermes_handler.dart';
import 'package:llamadart/src/core/template/handlers/llama3_handler.dart';
import 'package:llamadart/src/core/template/handlers/mistral_handler.dart';
import 'package:llamadart/src/core/template/handlers/hunyuan_v3_handler.dart';
import 'package:llamadart/src/core/template/handlers/llama_cpp_specialized_handlers.dart';
import 'package:test/test.dart';

import '../../support/litert_qwen_content_fixture.dart';
import '../../support/llama_cpp_grammar_load.dart';
import '../../support/pydantic_audit_schemas.dart';
import '../../support/upstream_integer_bound_grammars.dart';
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

  test('negative maximum grammars reject leading-zero JSON integers', () {
    for (final bounds in <Map<String, dynamic>>[
      {'exclusiveMaximum': 0},
      {'maximum': -1},
      {'maximum': -5},
      {'maximum': -25},
    ]) {
      _expectGrammar(
        validator,
        responseFormatGrammar({'type': 'integer', ...bounds}),
        valid: ['-25', '-100', '-1234'],
        invalid: ['-00', '-01', '-012', '-025', '-00100', '0', '1'],
      );
    }
  });

  test('bare bounded arrays compile with unrestricted JSON items', () {
    _expectGrammar(
      validator,
      responseFormatGrammar({'type': 'array', 'minItems': 1, 'maxItems': 2}),
      valid: ['[1]', '["s",null]', '[{}]', '[[true]]'],
      invalid: ['[]', '[1,2,3]'],
    );
  });

  test(
    'audit lossy upstream integer suffixes are rejected before generation',
    () {
      // v0.7.0 drops zero padding when recursing into a one-sided suffix.
      _expectGrammar(
        validator,
        JsonSchemaConverter.convert({'type': 'integer', 'minimum': 100}),
        valid: ['10', '100'],
        invalid: ['9'],
      );
      for (final schema in <Map<String, dynamic>>[
        {'type': 'integer', 'minimum': 100},
        {'type': 'integer', 'minimum': 101},
        {'type': 'integer', 'minimum': 1205},
        {'type': 'integer', 'maximum': -100},
        {'type': 'integer', 'maximum': -201},
      ]) {
        expect(
          () => responseFormatGrammar(schema),
          throwsA(
            isA<LlamaUnsupportedException>().having(
              (e) => e.message,
              'path',
              contains(r'$'),
            ),
          ),
        );
      }
    },
  );

  test('audit integer grammar expressions preserve scoped upstream parity', () {
    // Keep upstream fixtures intact: these two expose the leading-zero defect
    // corrected for negative maxima, so their intentional divergence is explicit.
    const correctedRoot = r'("-" ([1] [0-9]{1,15} | [2-9] [0-9]{0,15}))';
    const correctedRoots = {
      'maximum-1.2': correctedRoot,
      'exclusiveMaximum-1': correctedRoot,
    };
    final fixtures =
        jsonDecode(upstreamIntegerBoundGrammars) as Map<String, dynamic>;
    for (final entry in fixtures.entries) {
      final row = entry.value as Map<String, dynamic>;
      final grammar = responseFormatGrammar(
        row['schema'] as Map<String, dynamic>,
      );
      expect(
        grammar.split('\n').first,
        'root ::= ${correctedRoots[entry.key] ?? row['root']} space',
        reason: entry.key,
      );
    }
  });

  test(
    'audit formats and integer bounds match compiled upstream constraints',
    () {
      for (final (format, valid, invalid) in [
        ('uuid', '"12345678-1234-ABCD-abcd-123456789abc"', '"bad"'),
        ('date', '"2026-10-16"', '"2026-13-16"'),
        ('time', '"23:59:59.123+02:30"', '"24:00:00Z"'),
        ('date-time', '"2026-10-16T00:00:00Z"', '"2026-10-16 00:00:00Z"'),
      ]) {
        _expectGrammar(
          validator,
          responseFormatGrammar({'type': 'string', 'format': format}),
          valid: [valid],
          invalid: [invalid, '3'],
        );
      }
      for (final (min, max) in <(int?, int?)>[
        (-150, -101),
        (-99, -1),
        (-12, 12),
        (0, 0),
        (8, 16),
        (20, 350),
        (123, 567),
        (101, 599),
        (0, 99),
        (0, 100),
        (50, 50),
        (null, -12),
        (null, 0),
        (null, 123),
        (-12, null),
        (0, null),
        (1, null),
        (5, null),
        (12, null),
        (99, null),
        (123, null),
        (250, null),
        (999999999999999, null),
        (1111111111111111, null),
        (null, -1111111111111111),
        (9007199254740990, 9007199254740991),
        (-9007199254740991, -9007199254740990),
        (-9007199254740991, 9007199254740991),
        (-9007199254740991, null),
        (null, 9007199254740991),
      ]) {
        final schema = <String, dynamic>{
          'type': 'integer',
          'minimum': ?min,
          'maximum': ?max,
        };
        _expectGrammar(
          validator,
          responseFormatGrammar(schema),
          valid: [
            if (min != null) '$min',
            if (max != null) '$max',
            if ((min ?? -1) <= 0 && (max ?? 1) >= 0) '0',
          ],
          invalid: [
            if (min != null) '${min - 1}',
            if (max != null) '${max + 1}',
            '1.2',
            '"3"',
          ],
        );
      }
      for (final (keyword, bound, valid, invalid)
          in <(String, num, String, String)>[
            ('minimum', 1.2, '2', '1'),
            ('maximum', -1.2, '-2', '-1'),
            ('exclusiveMinimum', -1.2, '-1', '-2'),
            ('exclusiveMaximum', 1.2, '1', '2'),
            ('exclusiveMinimum', 1, '2', '1'),
            ('exclusiveMaximum', -1, '-2', '-1'),
          ]) {
        _expectGrammar(
          validator,
          responseFormatGrammar({'type': 'integer', keyword: bound}),
          valid: [valid],
          invalid: [invalid],
        );
      }
    },
  );

  test(
    'audit tuples, discriminators and allOf compile on the production path',
    () {
      for (final key in ['items', 'prefixItems']) {
        _expectGrammar(
          validator,
          responseFormatGrammar({
            'type': 'array',
            key: [
              {'type': 'integer'},
              {'type': 'string'},
            ],
            'minItems': 2,
            'maxItems': 2,
          }),
          valid: ['[1,"s"]'],
          invalid: ['[]', '[1]', '[1,"s",2]', '["s","s"]'],
        );
        _expectGrammar(
          validator,
          responseFormatGrammar({'type': 'array', key: []}),
          valid: ['[]'],
          invalid: ['[1]'],
        );
      }
      _expectGrammar(
        validator,
        responseFormatGrammar({
          'allOf': [
            {
              'enum': ['a', 'b'],
            },
            {
              'enum': ['b', 'c'],
            },
          ],
        }),
        valid: ['"b"'],
        invalid: ['"a"', '"c"', '{}'],
      );
      _expectGrammar(
        validator,
        responseFormatGrammar({
          'allOf': [
            {
              'properties': {
                's': {'type': 'string'},
              },
              'required': ['s'],
            },
            {
              'properties': {
                'n': {'type': 'integer'},
              },
              'required': ['n'],
            },
          ],
        }),
        valid: ['{"s":"a","n":1}'],
        invalid: ['{"s":1,"n":1}', '{"s":"a"}', '{"s":"a","n":1,"extra":true}'],
      );
      final corpus = jsonDecode(pydanticAuditSchemas) as Map<String, dynamic>;
      _expectGrammar(
        validator,
        responseFormatGrammar(
          corpus['pydantic_discriminator'] as Map<String, dynamic>,
        ),
        valid: ['{"pet":{"pet_type":"cat","meows":1}}'],
        invalid: [
          '{"pet":{"pet_type":"bird","meows":1}}',
          '{"pet":{"pet_type":"cat","meows":"s"}}',
        ],
      );
    },
  );

  test(
    'strict response schemas compile annotation-only values and patterns',
    () {
      _expectGrammar(
        validator,
        responseFormatGrammar({'description': 'Any value'}),
        valid: ['null', 'true', '3', '"text"', '[]', '{}'],
        invalid: ['undefined', '{', '[1,]', '"unterminated'],
      );
      _expectGrammar(
        validator,
        responseFormatGrammar({'type': 'string', 'pattern': r'^[a-z]{2,4}$'}),
        valid: ['"ab"', '"abcd"'],
        invalid: ['"A"', '"abcde"', '3'],
      );
      _expectGrammar(
        validator,
        responseFormatGrammar({}),
        valid: ['{}', '{"x":null}'],
        invalid: ['null', '[]', '3'],
      );
      _expectGrammar(
        validator,
        responseFormatGrammar({
          'allOf': [
            {'description': 'Base'},
            {
              'type': 'object',
              'properties': {
                'ok': {'type': 'boolean'},
              },
            },
          ],
        }),
        valid: ['{"ok":true}', '{ "ok": false }'],
        invalid: ['{}', '{"ok":1}', '{"ok":true,"x":1}', 'true'],
      );
    },
  );

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

  test('GPT-OSS grammar accepts routed frames and rejects invalid arguments', () {
    final grammar = GptOssHandler().buildGrammar([_weatherWithCityTool])!;
    const call =
        '<|start|>assistant to=functions.weather<|channel|>commentary'
        '<|message|>{"city":"Paris"}<|end|>';
    _expectGrammar(
      validator,
      grammar,
      valid: [
        call,
        call.replaceFirst('commentary', 'analysis'),
        call.replaceFirst('<|start|>assistant', ''),
        '<|channel|>analysis to=functions.weather<|message|>{"city":"Paris"}<|end|>',
      ],
      invalid: [
        'Let me check.\n$call',
        call.replaceFirst('functions.weather', 'functions.unknown'),
        call.replaceFirst('{"city":"Paris"}', '{}'),
        call.replaceFirst('{"city":"Paris"}', '{"city":7}'),
        call.replaceFirst('<|end|>', ''),
        call
            .replaceFirst('<|start|>assistant', '')
            .replaceFirst('functions.weather', 'functions.unknown'),
        call
            .replaceFirst('<|start|>assistant', '')
            .replaceFirst('{"city":"Paris"}', '{"city":7}'),
      ],
    );
  });

  test('Llama 3 grammar accepts one call and rejects invalid envelopes', () {
    final grammar = Llama3Handler().buildGrammar([_weatherWithCityTool])!;
    const call = '{"name": "weather", "parameters": {"city": "Paris"}}';
    _expectGrammar(
      validator,
      grammar,
      valid: [call],
      invalid: [
        'Let me check.\n$call',
        call.replaceFirst('weather', 'unknown'),
        call.replaceFirst('{"city": "Paris"}', '{}'),
        call.replaceFirst('"Paris"', '7'),
        call.replaceFirst('"parameters"', '"arguments"'),
        call.substring(0, call.length - 1),
      ],
    );
  });

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

  test('GLM grammars accept compact GLM-4.7 and newline GLM-4.6 layouts', () {
    const compact =
        '<tool_call>weather'
        '<arg_key>city</arg_key><arg_value>Paris, France</arg_value>'
        '<arg_key>days</arg_key><arg_value>3</arg_value>'
        '</tool_call>';
    const newline =
        '<tool_call>weather\n'
        '<arg_key>city</arg_key>\n<arg_value>Paris, France</arg_value>\n'
        '<arg_key>days</arg_key>\n<arg_value>3</arg_value>\n'
        '</tool_call>\n';
    _expectGrammar(
      validator,
      Glm45Handler().buildGrammar([_glmLayoutTool])!,
      valid: [
        compact,
        newline,
        '\n$newline',
        '$compact$compact',
        '$newline$compact',
        '<tool_call>weather<arg_key>city</arg_key>'
            '<arg_value>Paris</arg_value></tool_call>',
      ],
      invalid: [
        compact.replaceFirst('</arg_key><arg_value>', '</arg_key> <arg_value>'),
        newline.replaceFirst('</arg_key>\n', '</arg_key>\n\n'),
        '<tool_call>weather</tool_call>',
        '${compact}Done.',
        compact.replaceFirst('>3<', '>3.5<'),
        '<tool_call>weather<arg_key>unit</arg_key>'
            '<arg_value>C</arg_value></tool_call>',
      ],
    );

    const lagunaCall =
        '<tool_call>weather'
        '<arg_key>city</arg_key><arg_value>Seoul</arg_value>'
        '</tool_call>';
    _expectGrammar(
      validator,
      LagunaHandler().buildRequiredGrammar([_weatherWithCityTool])!,
      valid: [
        'reasoning</think>$lagunaCall',
        'reasoning</think>Let me check.$lagunaCall',
      ],
      invalid: ['reasoning</think>$lagunaCall Done.'],
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

  test('required grammars end a forced-open thought before the calls', () {
    const seoul = '{"city": "Seoul"}';
    // EXAONE MoE gets no valid call: its grammar does not quote the tool name.
    for (final (format, call) in [
      (
        ChatFormat.deepseekV3,
        '<｜tool▁calls▁begin｜><｜tool▁call▁begin｜>weather<｜tool▁sep｜>'
            '$seoul<｜tool▁call▁end｜><｜tool▁calls▁end｜>',
      ),
      (
        ChatFormat.hermes,
        '<tool_call>{"name": "weather", "arguments": $seoul}</tool_call>',
      ),
      (
        ChatFormat.seedOss,
        '<seed:tool_call><function=weather><parameter=city>Seoul'
            '</parameter></function></seed:tool_call>',
      ),
      (
        ChatFormat.minimaxM2,
        '<minimax:tool_call>\n<invoke name="weather">\n'
            '<parameter name="city">Seoul</parameter>\n</invoke>\n'
            '</minimax:tool_call>',
      ),
      (
        ChatFormat.apriel15,
        '<tool_calls>[{"name": "weather", "arguments": $seoul}]</tool_calls>',
      ),
      (ChatFormat.exaoneMoe, null),
    ]) {
      final handler = ChatTemplateEngine.handlerFor(format);
      final rendered = handler.render(
        templateSource:
            '{{ messages[0]["content"] }}${handler.thinkingStartTag}\n',
        messages: const [
          LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'hi'),
        ],
        metadata: {internalToolChoiceMetadataKey: ToolChoice.required.name},
        tools: [_weatherWithCityTool],
      );
      expect(rendered.thinkingForcedOpen, isTrue, reason: '$format');
      final end = handler.thinkingEndTag;
      const exaoneCall = '<tool_call>{"name": "weather", "arguments": {}}';
      _expectGrammar(
        validator,
        rendered.grammar!,
        valid: [
          if (call != null) ...[
            '$end$call',
            'Plan <${end.substring(0, end.length - 1)}.$end\n\n$call',
          ],
        ],
        invalid: [
          call ?? exaoneCall,
          'Plan.$end\nNo tool',
          'Plan.',
          if (call != null) 'Plan.$end more $end$call',
        ],
      );
    }
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

  test('three open objects sharing escape rules keep their key rules', () {
    for (final label in ['21 distinct 20-character names', '1023 properties']) {
      final names = largeKeySets[label]!;
      final first = jsonEncode(names.first);
      final grammar = responseFormatGrammar({
        'type': 'object',
        'properties': {
          for (var i = 0; i < 3; i++)
            'o$i': {
              'type': 'object',
              'properties': {
                for (final name in names) name: {'type': 'integer'},
              },
              'additionalProperties': true,
            },
        },
      });
      _expectGrammar(
        validator,
        grammar,
        valid: ['{"o2":{$first:5,"zz-extra":"v"}}'],
        invalid: ['{"o2":{$first:1,$first:2}}', '{"o2":{$first:"x"}}'],
      );
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

  test('open objects exclude escaped spellings of declared keys', () {
    final schema = <String, dynamic>{
      'type': 'object',
      'properties': {
        'city': {'type': 'string'},
        'ci': {'type': 'boolean'},
        'é': {'type': 'null'},
        '😀': {'type': 'null'},
      },
      'additionalProperties': true,
    };
    for (final (grammar, output) in _openObjectGrammars(schema)) {
      _expectGrammar(
        validator,
        grammar,
        valid: [
          output('{"city":"x"}'),
          output(r'{"\u0043ity":1}'),
          output(r'{"cit\u0065":1}'),
          output(r'{"x\u0063":1}'),
          output(r'{"ci":true,"\u0062":1}'),
          output(r'{"\u00E8":1}'),
          output('{"😁":1}'),
        ],
        invalid: [
          output(r'{"\u0063ity":"x"}'),
          output(r'{"ci\u0074y":"x"}'),
          output(r'{"c\u0069":true}'),
          output(r'{"\u00E9":null}'),
          output(r'{"\ud83d\ude00":null}'),
        ],
      );
    }
  });

  test('Hermes required calls may follow forced-open reasoning', () {
    final template = File(
      'test/fixtures/llama_cpp_templates/Qwen-QwQ-32B.jinja',
    ).readAsStringSync();
    final legacy = ToolDefinition(
      name: 'inspect',
      description: 'Inspect',
      parameters: [ToolParam.string('code', required: true)],
      handler: (_) async => null,
    );
    for (final (tool, call) in [
      (
        rawSchemaTool(),
        '<tool_call>\n'
            '${jsonEncode({'name': 'inspect', 'arguments': rawToolArguments})}'
            '\n</tool_call>',
      ),
      (
        legacy,
        '<tool_call>{"name": "inspect", "arguments": {"code": "x"}}</tool_call>',
      ),
    ]) {
      final rendered = ChatTemplateEngine.render(
        templateSource: template,
        messages: [
          LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'hi'),
        ],
        metadata: const {},
        tools: [tool],
        toolChoice: ToolChoice.required,
      );
      expect(rendered.thinkingForcedOpen, isTrue);
      expect(rendered.grammarLazy, isFalse);
      _expectGrammar(
        validator,
        rendered.grammar!,
        valid: [
          'Need to inspect.\n</think>\n\n$call',
          '</think>$call',
          'Maybe <tool_call> or </thin, <think> too.</think>\n$call',
        ],
        invalid: [
          call,
          'Need to inspect.\n</think>\n\nDone.',
          'a</think>b</think>$call',
          'Need to inspect.\n</think>\n\n$call trailing',
        ],
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

  test('tool schema bounds of 2000 load and enforce every bound', () {
    for (final item in [null, ...boundedArrayItemSchemas]) {
      final suffix = item == null ? 'Length' : 'Items';
      String value(int count) => item == null
          ? jsonEncode('a' * count)
          : jsonEncode(List.filled(count, boundedArrayItemValue(item)));
      for (final bounds in <Map<String, int>>[
        {'min$suffix': 2000},
        {'max$suffix': 2000},
        for (final minimum in [0, 1, 1999, 2000])
          {'min$suffix': minimum, 'max$suffix': 2000},
      ]) {
        final minimum = bounds['min$suffix'] ?? 0;
        final maximum = bounds['max$suffix'];
        final schema = <String, dynamic>{
          'type': 'object',
          'properties': {
            'x': {
              'type': item == null ? 'string' : 'array',
              'items': ?item,
              ...bounds,
            },
          },
          'required': ['x'],
          'additionalProperties': false,
        };
        final tool = ToolDefinition.fromJsonSchema(
          name: 'spec',
          description: 'Spec',
          schema: schema,
        );
        final grammars = [
          ..._openObjectGrammars(schema),
          (
            MistralHandler().buildGrammar([tool])!,
            (String args) =>
                '[TOOL_CALLS][{"name":"spec","arguments":$args,"id":"123456789"}]',
          ),
        ];
        for (final (grammar, output) in grammars) {
          _expectGrammar(
            validator,
            grammar,
            valid: [
              output('{"x":${value(2000)}}'),
              if (minimum < 2000) output('{"x":${value(minimum)}}'),
              if (maximum == null) output('{"x":${value(2001)}}'),
            ],
            invalid: [
              if (minimum > 0) output('{"x":${value(minimum - 1)}}'),
              if (maximum != null) output('{"x":${value(2001)}}'),
              output('{}'),
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

  test('grammar limit check agrees with llama.cpp on Hermes tool counts', () {
    for (final (count, loads) in [(1997, true), (1998, false)]) {
      final tools = [
        for (var i = 0; i < count; i++)
          ToolDefinition.fromJsonSchema(
            name: 'tool_$i',
            description: 'Tool $i',
            schema: const {
              'type': 'object',
              'properties': {
                'a': {'type': 'string'},
              },
              'required': ['a'],
            },
          ),
      ];
      final grammar = HermesHandler().buildGrammar(tools)!;
      final last = count - 1;
      if (loads) {
        expect(() => checkTemplateGrammarLimits(grammar), returnsNormally);
        _expectGrammar(
          validator,
          grammar,
          valid: [
            '<tool_call>{"name":"tool_$last","arguments":{"a":"x"}}</tool_call>',
          ],
          invalid: [
            '<tool_call>{"name":"tool_$count","arguments":{"a":"x"}}</tool_call>',
            '<tool_call>{"name":"tool_0","arguments":{"a":1}}</tool_call>',
          ],
        );
      } else {
        expect(
          () => checkTemplateGrammarLimits(grammar),
          throwsA(isA<LlamaUnsupportedException>()),
        );
        expect(_load(validator, grammar, ''), contains('failed to parse'));
      }
    }
  });

  test('raw schemas reject repetition bounds that llama.cpp drops', () {
    const schema = {'type': 'string', 'maxLength': 2001};
    final grammar = JsonSchemaConverter.convert(schema);
    expect(
      () => responseFormatGrammar(schema),
      throwsA(
        isA<LlamaUnsupportedException>().having(
          (error) => error.message,
          'path',
          contains(r'$.maxLength'),
        ),
      ),
    );
    expect(
      _load(validator, grammar, '"${'a' * 2500}"'),
      contains('Input string is valid according to the grammar.'),
    );
    expect(() => checkTemplateGrammarLimits(grammar), returnsNormally);
  });

  test('enforceable responseFormat schemas compile and constrain output', () {
    String render(Map<String, dynamic> schema) {
      final grammar = ChatTemplateEngine.render(
        templateSource: null,
        messages: const [],
        metadata: const {},
        responseFormat: {
          'type': 'json_schema',
          'json_schema': {'schema': schema},
        },
      ).grammar!;
      checkTemplateGrammarLimits(grammar);
      return grammar;
    }

    _expectGrammar(
      validator,
      render(const {
        'type': 'object',
        'properties': {
          'id': {'type': 'string', 'pattern': r'^[a-z]{2}-[0-9]{3}$'},
          'tags': {
            'type': 'array',
            'items': {'type': 'string', 'maxLength': 3},
            'maxItems': 2,
          },
        },
        'required': ['id'],
        'additionalProperties': false,
        'x-vendor': {'minimum': 1},
      }),
      valid: ['{"id":"ab-123"}', '{"id":"zz-000","tags":["a","bcd"]}'],
      invalid: [
        '{"id":"ab-12"}',
        '{"id":"AB-123"}',
        '{"id":"ab-123","tags":["abcd"]}',
        '{"id":"ab-123","tags":["a","b","c"]}',
        '{"id":"ab-123","extra":1}',
      ],
    );

    Map<String, dynamic> schema = {'type': 'integer'};
    for (var i = 0; i < 127; i++) {
      schema = {'type': 'array', 'items': schema};
    }
    _expectGrammar(
      validator,
      render(schema),
      valid: ['${'[' * 127}7${']' * 127}'],
      invalid: ['${'[' * 127}"7"${']' * 127}', '${'[' * 126}7${']' * 126}'],
    );
    // 0.14 bounds validation walks before recursion, including schema nesting.
    expect(
      () => render({'type': 'array', 'items': schema}),
      throwsA(
        isA<LlamaUnsupportedException>().having(
          (error) => error.message,
          'limit',
          contains('128'),
        ),
      ),
    );
  });

  test('llama.cpp grammar repetition limit matches the schema bound', () {
    final directory = Directory.systemTemp.createTempSync('llamadart-gbnf-');
    addTearDown(() => directory.deleteSync(recursive: true));
    String run(Map<String, dynamic> schema, int length) {
      final grammar = JsonSchemaConverter.convert(schema);
      final grammarFile = File('${directory.path}/bound.gbnf')
        ..writeAsStringSync(grammar);
      final input = File('${directory.path}/bound.txt')
        ..writeAsStringSync('"${'a' * length}"');
      final result = Process.runSync(validator, [grammarFile.path, input.path]);
      return '${result.stdout}\n${result.stderr}';
    }

    const maxLength = {'type': 'string', 'maxLength': 2000};
    expect(
      () => checkTemplateGrammarLimits(JsonSchemaConverter.convert(maxLength)),
      returnsNormally,
    );
    expect(
      run(maxLength, 2000),
      contains('Input string is valid according to the grammar.'),
    );
    expect(run(maxLength, 2001), isNot(contains('failed to parse grammar')));
    expect(
      run(maxLength, 2001),
      isNot(contains('Input string is valid according to the grammar.')),
    );

    const minLength = {'type': 'string', 'minLength': 2001};
    expect(
      () => checkTemplateGrammarLimits(JsonSchemaConverter.convert(minLength)),
      throwsA(isA<LlamaUnsupportedException>()),
    );
    expect(run(minLength, 2001), contains('failed to parse grammar'));
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

/// Runs [validator] on [grammar] and [input] and returns its output.
String _load(String validator, String grammar, String input) {
  final directory = Directory.systemTemp.createTempSync('llamadart-gbnf-');
  addTearDown(() => directory.deleteSync(recursive: true));
  final grammarFile = File('${directory.path}/grammar.gbnf')
    ..writeAsStringSync(grammar);
  final inputFile = File('${directory.path}/input.txt')
    ..writeAsStringSync(input);
  final result = Process.runSync(validator, [grammarFile.path, inputFile.path]);
  return '${result.stdout}\n${result.stderr}';
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

final _glmLayoutTool = ToolDefinition(
  name: 'weather',
  description: 'Weather',
  parameters: [
    ToolParam.string('city', required: true),
    ToolParam.integer('days'),
  ],
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
