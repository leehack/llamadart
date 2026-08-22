import 'dart:convert';

import 'package:llamadart/src/core/exceptions.dart';
import 'package:llamadart/src/core/models/tools/tool_definition.dart';
import 'package:llamadart/src/core/models/tools/tool_param.dart';
import 'package:llamadart/src/core/template/chat_format.dart';
import 'package:llamadart/src/core/template/chat_template_engine.dart';
import 'package:llamadart/src/core/template/handlers/llama_cpp_specialized_handlers.dart';
import 'package:test/test.dart';

void main() {
  group('Kimi K3', () {
    const call =
        '<|open|>response<|sep|>On it.<|close|>response<|sep|>'
        '<|open|>tools<|sep|>'
        '<|open|>call tool="weather&amp;alerts" index="1"<|sep|>'
        '<|open|>argument key="city" type="string"<|sep|>'
        ' New York <|close|>argument<|sep|>'
        '<|open|>argument key="days" type="number"<|sep|>'
        '2<|close|>argument<|sep|>'
        '<|close|>call<|sep|><|close|>tools<|sep|>'
        '<|close|>message<|sep|>';

    test('parses forced-open reasoning, content, and typed raw arguments', () {
      final parsed = ChatTemplateEngine.parse(
        ChatFormat.kimiK3.index,
        'check first<|close|>think<|sep|>$call',
        thinkingForcedOpen: true,
      );

      expect(parsed.reasoningContent, 'check first');
      expect(parsed.content, 'On it.');
      expect(parsed.toolCalls, hasLength(1));
      expect(parsed.toolCalls.single.function?.name, 'weather&alerts');
      expect(_arguments(parsed), {'city': ' New York ', 'days': 2});
    });

    test('parses a raw JSON argument block', () {
      const output =
          '<|open|>response<|sep|><|close|>response<|sep|>'
          '<|open|>tools<|sep|>'
          '<|open|>call tool="weather" index="1"<|sep|>'
          '<|open|>json type="object"<|sep|>{"city":"Seoul"}'
          '<|close|>json<|sep|><|close|>call<|sep|>'
          '<|close|>tools<|sep|><|close|>message<|sep|>';
      final parsed = KimiK3Handler().parse(output);
      expect(_arguments(parsed), {'city': 'Seoul'});
    });

    test('grammar permits the upstream raw JSON argument block', () {
      final grammar = KimiK3Handler().buildGrammar([_weatherTool])!;

      expect(grammar, contains('(kimi-empty-arguments | kimi-json-0)'));
      expect(grammar, contains(r'(" index=\"" [0-9]+ "\"")? "<|sep|>"'));
      expect(
        grammar,
        contains(r'"<|open|>json type=\"object\"<|sep|>" kimi-tool-0-json'),
      );
      expect(grammar, contains('kimi-tool-0-json ::= '));
    });

    test('grammar HTML-escapes tool names like the upstream XTML macro', () {
      final grammar = KimiK3Handler().buildGrammar([_attributeTool])!;

      expect(grammar, contains(r'call tool=\"weather&amp;&quot;alerts\"'));
      expect(grammar, isNot(contains(r'call tool=\"weather&\"alerts\"')));
    });

    test('grammar emits exact escaped schema keys and their declared type', () {
      final grammar = KimiK3Handler().buildGrammar([_escapedSchemaTool])!;

      expect(
        grammar,
        contains(r'argument key=\"city&amp;&quot;zone\" type=\"string\"'),
      );
      expect(grammar, isNot(contains('identifier ::=')));
    });

    test('zero-parameter grammar uses an explicit empty production', () {
      final grammar = KimiK3Handler().buildGrammar([_zeroArgTool])!;

      expect(grammar, contains('kimi-raw-0 ::= ""'));
      expect(grammar, isNot(contains(RegExp(r'kimi-raw-0 ::=\s*\n'))));
    });

    test('grammar rejects ambiguous or empty protocol identities', () {
      final duplicate = ToolDefinition(
        name: _weatherTool.name,
        description: 'Duplicate weather',
        parameters: [ToolParam.integer('days')],
        handler: (_) async => null,
      );
      final emptyTool = ToolDefinition(
        name: '',
        description: 'Empty name',
        parameters: const [],
        handler: (_) async => null,
      );
      final emptyParameter = ToolDefinition(
        name: 'empty_parameter',
        description: 'Empty parameter',
        parameters: [ToolParam.string('')],
        handler: (_) async => null,
      );

      for (final tools in [
        [_weatherTool, duplicate],
        [emptyTool],
        [emptyParameter],
      ]) {
        expect(
          () => KimiK3Handler().buildGrammar(tools),
          throwsA(isA<LlamaUnsupportedException>()),
        );
      }
    });

    test('production parse validates escaped Kimi names against schemas', () {
      const valid =
          '<|open|>tools<|sep|>'
          '<|open|>call tool="weather"<|sep|>'
          '<|open|>argument key="city&amp;&quot;zone" type="string"<|sep|>'
          '123<|close|>argument<|sep|><|close|>call<|sep|>'
          '<|close|>tools<|sep|><|close|>message<|sep|>';
      final parsed = ChatTemplateEngine.parse(
        ChatFormat.kimiK3.index,
        valid,
        tools: [_escapedSchemaTool],
      );

      expect(_arguments(parsed), {'city&"zone': '123'});

      final duplicate = valid.replaceFirst(
        '<|close|>argument<|sep|><|close|>call<|sep|>',
        '<|close|>argument<|sep|>'
            '<|open|>argument key="city&amp;&quot;zone" type="string"<|sep|>'
            'again<|close|>argument<|sep|><|close|>call<|sep|>',
      );

      for (final invalid in [
        valid.replaceFirst('tool="weather"', 'tool="unknown"'),
        valid.replaceFirst('tool="weather"', 'tool="weather" index="invalid"'),
        valid.replaceFirst('city&amp;&quot;zone', 'unknown'),
        valid.replaceFirst('city&amp;&quot;zone', 'city&&quot;zone'),
        valid.replaceFirst('city&amp;&quot;zone', 'city&bogus;&quot;zone'),
        valid.replaceFirst('city&amp;&quot;zone', 'city&amp;amp;&quot;zone'),
        valid.replaceFirst('type="string"', 'type="number"'),
        duplicate,
      ]) {
        final rejected = ChatTemplateEngine.parse(
          ChatFormat.kimiK3.index,
          invalid,
          tools: [_escapedSchemaTool],
        );
        expect(rejected.toolCalls, isEmpty);
        expect(rejected.content, contains('<|open|>tools<|sep|>'));
      }
    });

    test(
      'parses a tool call without the optional upstream index attribute',
      () {
        const output =
            '<|open|>tools<|sep|>'
            '<|open|>call tool="weather"<|sep|>'
            '<|open|>argument key="city" type="string"<|sep|>Seoul'
            '<|close|>argument<|sep|><|close|>call<|sep|>'
            '<|close|>tools<|sep|><|close|>message<|sep|>';

        final parsed = KimiK3Handler().parse(output);

        expect(parsed.content, isEmpty);
        expect(parsed.toolCalls.single.function?.name, 'weather');
        expect(_arguments(parsed), {'city': 'Seoul'});
      },
    );

    test('preserves trailing output when tool parsing is disabled', () {
      final parsed = KimiK3Handler().parse(call, parseToolCalls: false);

      expect(parsed.toolCalls, isEmpty);
      expect(parsed.content, startsWith('On it.'));
      expect(parsed.content, contains('<|open|>tools<|sep|>'));
      expect(
        parsed.content,
        contains('<|open|>call tool="weather&amp;alerts"'),
      );
    });

    test('preserves malformed tool markup instead of silently dropping it', () {
      const malformed =
          '<|open|>response<|sep|>On it.<|close|>response<|sep|>'
          '<|open|>tools<|sep|><|open|>call tool="weather" index="1"'
          '<|sep|><|open|>argument key="days" type="number"<|sep|>oops'
          '<|close|>argument<|sep|><|close|>call<|sep|>'
          '<|close|>tools<|sep|>';
      final parsed = KimiK3Handler().parse(malformed);
      expect(parsed.toolCalls, isEmpty);
      expect(parsed.content, contains('<|open|>tools<|sep|>'));
      expect(parsed.content, contains('On it.'));
    });
  });

  group('MiniMax M1', () {
    test('parses parallel newline-delimited calls and surrounding content', () {
      const output =
          'Checking.\n<tool_calls>\n'
          '{"name":"weather","arguments":{"city":"Seoul"}}\n'
          '{"name":"clock","arguments":{"tz":"UTC"}}\n'
          '</tool_calls>';
      final parsed = MinimaxM1Handler().parse(output);
      expect(parsed.content, 'Checking.');
      expect(parsed.toolCalls.map((call) => call.function?.name), [
        'weather',
        'clock',
      ]);
      expect(_arguments(parsed), {'city': 'Seoul'});
    });

    test('preserves malformed completed call envelopes', () {
      const output = '<tool_calls>\n{"name":"weather"\n</tool_calls>';
      final parsed = MinimaxM1Handler().parse(output);
      expect(parsed.toolCalls, isEmpty);
      expect(parsed.content, output);
    });

    test('keeps ordinary JSON-looking prose as content', () {
      const output = 'Example: {"name":"weather"}';
      expect(MinimaxM1Handler().parse(output).content, output);
    });

    test('grammar uses schema-aware JSON string and escape rules', () {
      final grammar = MinimaxM1Handler().buildGrammar([_weatherWithCityTool])!;
      final rootRule = grammar
          .split('\n')
          .singleWhere((line) => line.startsWith('root ::='));
      final callRule = grammar
          .split('\n')
          .singleWhere((line) => line.startsWith('tool-0-call ::='));

      expect(rootRule, contains('tool-call+'));
      expect(callRule, contains(' tool-0-arguments '));
      expect(grammar, contains('char ::= '));
      expect(grammar, contains(r'[^"\\\x7F\x00-\x1F]'));
      expect(grammar, contains(r'[\\] (["\\bfnrt] | "u"'));
      expect(grammar, isNot(contains('json-char ::=')));
    });

    test('grammar JSON-encodes the upstream tool-name value', () {
      final grammar = MinimaxM1Handler().buildGrammar([_weatherTool])!;
      final callRule = grammar
          .split('\n')
          .singleWhere((line) => line.startsWith('tool-0-call ::='));

      expect(callRule, contains(r'\"weather\"'));
      expect(callRule, isNot(contains(' space "weather" space')));
    });

    test('production parse rejects MiniMax M1 schema mismatches', () {
      const valid =
          '<tool_calls>\n'
          '{"name":"weather","arguments":{"city":"Seoul"}}\n'
          '</tool_calls>';
      final parsed = ChatTemplateEngine.parse(
        ChatFormat.minimaxM1.index,
        valid,
        tools: [_weatherWithCityTool],
      );
      expect(_arguments(parsed), {'city': 'Seoul'});

      for (final invalid in [
        valid.replaceFirst('"weather"', '"unknown"'),
        valid.replaceFirst('"city"', '"unknown"'),
        valid.replaceFirst('"Seoul"', '7'),
        valid.replaceFirst(
          '"name":"weather"',
          '"name":"weather","unexpected":true',
        ),
      ]) {
        final rejected = ChatTemplateEngine.parse(
          ChatFormat.minimaxM1.index,
          invalid,
          tools: [_weatherWithCityTool],
        );
        expect(rejected.toolCalls, isEmpty);
        expect(rejected.content, invalid);
      }
    });

    test('grammar and parse reject ambiguous MiniMax M1 tool schemas', () {
      const output =
          '<tool_calls>\n'
          '{"name":"weather","arguments":{}}\n'
          '</tool_calls>';
      final duplicate = ToolDefinition(
        name: 'weather',
        description: 'Duplicate weather tool',
        parameters: const [],
        handler: (_) async => null,
      );
      final empty = ToolDefinition(
        name: '',
        description: 'Empty tool identity',
        parameters: const [],
        handler: (_) async => null,
      );

      for (final tools in [
        [_weatherTool, duplicate],
        [empty],
      ]) {
        expect(
          () => MinimaxM1Handler().buildGrammar(tools),
          throwsA(isA<LlamaUnsupportedException>()),
        );
        expect(
          () => ChatTemplateEngine.parse(
            ChatFormat.minimaxM1.index,
            output,
            tools: tools,
          ),
          throwsA(isA<LlamaUnsupportedException>()),
        );
      }
    });
  });

  group('MiniMax M3', () {
    const ns = MinimaxM3Handler.namespace;

    test('parses reasoning and namespaced raw arguments', () {
      const output =
          '<mm:think>check</mm:think>'
          '$ns<tool_call>\n'
          '$ns<invoke name="weather">'
          '$ns<city> New York $ns</city>'
          '$ns<days>2$ns</days>'
          '$ns<options>$ns<units>metric$ns</units>'
          '$ns<alerts>$ns<item>true$ns</item>$ns<item>false$ns</item>'
          '$ns</alerts>$ns</options>'
          '$ns</invoke>\n$ns</tool_call>';
      final parsed = MinimaxM3Handler().parse(output);
      expect(parsed.reasoningContent, 'check');
      expect(parsed.content, isEmpty);
      expect(parsed.toolCalls.single.function?.name, 'weather');
      expect(_arguments(parsed), {
        'city': ' New York ',
        'days': 2,
        'options': {
          'units': 'metric',
          'alerts': [true, false],
        },
      });
    });

    test('preserves malformed namespace scopes', () {
      const output = '$ns<tool_call>$ns<invoke name="weather">broken';
      final parsed = MinimaxM3Handler().parse(output);
      expect(parsed.toolCalls, isEmpty);
      expect(parsed.content, output);
    });

    test('preserves literal namespace tokens outside a parsed tool scope', () {
      const output =
          'Before $ns literal\n'
          '$ns<tool_call>$ns<invoke name="weather">'
          '$ns<city>Seoul$ns</city>$ns</invoke>$ns</tool_call>'
          '\nAfter $ns literal';
      final parsed = MinimaxM3Handler().parse(output);

      expect(parsed.content, 'Before $ns literal\n\nAfter $ns literal');
      expect(_arguments(parsed), {'city': 'Seoul'});
    });

    test('keeps non-tool content after a disabled-thinking prefix', () {
      expect(MinimaxM3Handler().parse('</mm:think>Hello').content, 'Hello');
    });

    test('does not validate schemas when MiniMax M3 parsing is disabled', () {
      final duplicate = ToolDefinition(
        name: 'weather',
        description: 'Duplicate weather tool',
        parameters: const [],
        handler: (_) async => null,
      );
      const output = '$ns<tool_call>unparsed</tool_call>';

      final parsed = MinimaxM3Handler().parseWithTools(
        output,
        tools: [_weatherTool, duplicate],
        parseToolCalls: false,
      );

      expect(parsed.content, output);
      expect(parsed.toolCalls, isEmpty);
    });

    test('hides an incomplete invoke while streaming', () {
      const output =
          'Prelude$ns<tool_call>\n'
          '$ns<invoke name="weather">$ns<city>Seo';
      final parsed = MinimaxM3Handler().parse(output, isPartial: true);

      expect(parsed.content, 'Prelude');
      expect(parsed.toolCalls, isEmpty);
    });

    test('keeps completed calls before a partial invoke', () {
      const output =
          'Prelude$ns<tool_call>\n'
          '$ns<invoke name="weather">$ns<city>Seoul$ns</city>'
          '$ns</invoke>\n'
          '$ns<invoke name="clock">$ns<tz>UT';
      final parsed = MinimaxM3Handler().parse(output, isPartial: true);

      expect(parsed.content, 'Prelude');
      expect(parsed.toolCalls, hasLength(1));
      expect(parsed.toolCalls.single.function?.name, 'weather');
      expect(_arguments(parsed), {'city': 'Seoul'});
    });

    test('production parse accepts a zero-parameter invoke as empty args', () {
      const output =
          '$ns<tool_call>$ns<invoke name="ping">'
          '$ns</invoke>$ns</tool_call>';
      final parsed = ChatTemplateEngine.parse(
        ChatFormat.minimaxM3.index,
        output,
        tools: [_zeroArgTool],
      );

      expect(parsed.content, isEmpty);
      expect(parsed.toolCalls.single.function?.name, 'ping');
      expect(_arguments(parsed), isEmpty);
    });

    test('production parse preserves schema types and empty containers', () {
      const output =
          '$ns<tool_call>$ns<invoke name="inspect">'
          '$ns<code>123$ns</code>'
          '$ns<options>$ns</options>'
          '$ns<items>$ns</items>'
          '$ns<count>7$ns</count>'
          '$ns<active>true$ns</active>'
          '$ns<empty>null$ns</empty>'
          '$ns</invoke>$ns</tool_call>';
      final parsed = ChatTemplateEngine.parse(
        ChatFormat.minimaxM3.index,
        output,
        tools: [_schemaTool],
      );

      expect(_arguments(parsed), {
        'code': '123',
        'options': <String, dynamic>{},
        'items': <Object?>[],
        'count': 7,
        'active': true,
        'empty': null,
      });
    });

    test('production schema rejects unknown and mismatched arguments', () {
      const unknown =
          '$ns<tool_call>$ns<invoke name="inspect">'
          '$ns<unknown>x$ns</unknown>$ns</invoke>$ns</tool_call>';
      const mismatch =
          '$ns<tool_call>$ns<invoke name="inspect">'
          '$ns<code>x$ns</code>$ns<options>$ns</options>'
          '$ns<items>$ns</items>$ns<count>oops$ns</count>'
          '$ns<active>true$ns</active>$ns<empty>null$ns</empty>'
          '$ns</invoke>$ns</tool_call>';

      for (final output in [unknown, mismatch]) {
        final parsed = ChatTemplateEngine.parse(
          ChatFormat.minimaxM3.index,
          output,
          tools: [_schemaTool],
        );
        expect(parsed.toolCalls, isEmpty);
        expect(parsed.content, output);
      }
    });

    test('production schema rejects duplicate MiniMax M3 properties', () {
      const duplicateTopLevel =
          '$ns<tool_call>$ns<invoke name="inspect">'
          '$ns<code>first$ns</code>$ns<code>second$ns</code>'
          '$ns<options>$ns</options>$ns<items>$ns</items>'
          '$ns<count>7$ns</count>$ns<active>true$ns</active>'
          '$ns<empty>null$ns</empty>$ns</invoke>$ns</tool_call>';
      const duplicateNested =
          '$ns<tool_call>$ns<invoke name="weather">'
          '$ns<city>Seoul$ns</city>'
          '$ns<options>$ns<units>metric$ns</units>'
          '$ns<units>imperial$ns</units>$ns</options>'
          '$ns</invoke>$ns</tool_call>';

      for (final output in [duplicateTopLevel, duplicateNested]) {
        final parsed = ChatTemplateEngine.parse(
          ChatFormat.minimaxM3.index,
          output,
          tools: output == duplicateTopLevel
              ? [_schemaTool]
              : [_weatherNestedTool],
        );
        expect(parsed.toolCalls, isEmpty);
        expect(parsed.content, output);
      }
    });

    test('production schema rejects an unknown MiniMax M3 tool name', () {
      const output =
          '$ns<tool_call>$ns<invoke name="unknown">'
          '$ns</invoke>$ns</tool_call>';
      final parsed = ChatTemplateEngine.parse(
        ChatFormat.minimaxM3.index,
        output,
        tools: [_zeroArgTool],
      );

      expect(parsed.toolCalls, isEmpty);
      expect(parsed.content, output);
    });

    test('preserves namespace-like text inside MiniMax M3 strings', () {
      const output =
          '$ns<tool_call>$ns<invoke name="inspect">'
          '$ns<code>a${ns}literal$ns</code>'
          '$ns<options>$ns</options>$ns<items>$ns</items>'
          '$ns<count>7$ns</count>$ns<active>true$ns</active>'
          '$ns<empty>null$ns</empty>$ns</invoke>$ns</tool_call>';
      final parsed = ChatTemplateEngine.parse(
        ChatFormat.minimaxM3.index,
        output,
        tools: [_schemaTool],
      );

      expect(_arguments(parsed)['code'], 'a${ns}literal');
    });

    test('grammar binds literal closing tags and permits ] in strings', () {
      final grammar = MinimaxM3Handler().buildGrammar([_schemaTool])!;

      expect(grammar, contains('$ns<code>'));
      expect(grammar, contains('$ns</code>'));
      expect(grammar, isNot(contains('identifier ::=')));
      expect(grammar, isNot(contains(r'raw ::= [^]]*')));
    });

    test('round-trips escaped tool attributes and rejects unsafe tag keys', () {
      final grammar = MinimaxM3Handler().buildGrammar([_attributeTool])!;
      expect(grammar, contains(r'invoke name=\"weather&amp;&quot;alerts\"'));

      const output =
          '$ns<tool_call>$ns<invoke name="weather&amp;&quot;alerts">'
          '$ns</invoke>$ns</tool_call>';
      final parsed = ChatTemplateEngine.parse(
        ChatFormat.minimaxM3.index,
        output,
        tools: [_attributeTool],
      );
      expect(parsed.toolCalls.single.function?.name, 'weather&"alerts');

      for (final malformedName in [
        'weather&&quot;alerts',
        'weather&bogus;&quot;alerts',
        'weather&amp;amp;&quot;alerts',
      ]) {
        final malformed = output.replaceFirst(
          'weather&amp;&quot;alerts',
          malformedName,
        );
        final rejected = ChatTemplateEngine.parse(
          ChatFormat.minimaxM3.index,
          malformed,
          tools: [_attributeTool],
        );
        expect(rejected.toolCalls, isEmpty);
        expect(rejected.content, malformed);
      }

      expect(
        () => MinimaxM3Handler().buildGrammar([_escapedSchemaTool]),
        throwsA(
          isA<LlamaUnsupportedException>().having(
            (error) => error.message,
            'message',
            contains('cannot represent tool parameter "city&"zone"'),
          ),
        ),
      );
    });
  });

  group('DeepSeek V3.2 DSML', () {
    const actualUpstreamOutput =
        'Let me check the time</think>\n\n'
        '<｜DSML｜function_calls>\n'
        '<｜DSML｜invoke name="weather">\n'
        '<｜DSML｜parameter name="city" string="true">Tokyo'
        '</｜DSML｜parameter>\n'
        '</｜DSML｜invoke>\n'
        '</｜DSML｜function_calls>';

    test('parses the actual pinned-upstream function_calls emission', () {
      final parsed = DeepseekV32Handler().parse(
        actualUpstreamOutput,
        thinkingForcedOpen: true,
      );

      expect(parsed.reasoningContent, 'Let me check the time');
      expect(parsed.content, isEmpty);
      expect(parsed.toolCalls.single.function?.name, 'weather');
      expect(_arguments(parsed), {'city': 'Tokyo'});
    });

    test('uses the V3.2 envelope for grammar and lazy activation', () {
      final handler = DeepseekV32Handler();
      final grammar = handler.buildGrammar([_attributeTool])!;

      expect(handler.grammarTriggerValues, ['<｜DSML｜function_calls>']);
      expect(handler.preservedTokens, contains('<｜DSML｜function_calls>'));
      expect(
        grammar.split('\n').first,
        r'root ::= "<｜DSML｜function_calls>" dsml-space dsml-tool+ "</｜DSML｜function_calls>"',
      );
      expect(grammar, contains(r'invoke name=\"weather&amp;&quot;alerts\">'));
      expect(grammar, isNot(contains('identifier ::=')));
      expect(grammar, isNot(contains('<｜DSML｜tool_calls>')));
    });

    test('round-trips escaped DSML tool and parameter attributes', () {
      final grammar = DeepseekV32Handler().buildGrammar([
        _escapedAttributeSchemaTool,
      ])!;
      expect(grammar, contains(r'invoke name=\"weather&amp;&quot;alerts\"'));
      expect(grammar, contains(r'parameter name=\"city&amp;&quot;zone\"'));

      const output =
          '<｜DSML｜function_calls>'
          '<｜DSML｜invoke name="weather&amp;&quot;alerts">'
          '<｜DSML｜parameter name="city&amp;&quot;zone" string="true">Seoul'
          '</｜DSML｜parameter>'
          '</｜DSML｜invoke>'
          '</｜DSML｜function_calls>';
      final parsed = ChatTemplateEngine.parse(
        ChatFormat.deepseekV32.index,
        output,
        tools: [_escapedAttributeSchemaTool],
      );

      expect(parsed.toolCalls.single.function?.name, 'weather&"alerts');
      expect(_arguments(parsed), {'city&"zone': 'Seoul'});

      for (final malformed in [
        output.replaceFirst('weather&amp;&quot;alerts', 'weather&&quot;alerts'),
        output.replaceFirst(
          'weather&amp;&quot;alerts',
          'weather&bogus;&quot;alerts',
        ),
        output.replaceFirst(
          'weather&amp;&quot;alerts',
          'weather&amp;amp;&quot;alerts',
        ),
        output.replaceFirst('city&amp;&quot;zone', 'city&&quot;zone'),
        output.replaceFirst('city&amp;&quot;zone', 'city&bogus;&quot;zone'),
        output.replaceFirst('city&amp;&quot;zone', 'city&amp;amp;&quot;zone'),
      ]) {
        final rejected = ChatTemplateEngine.parse(
          ChatFormat.deepseekV32.index,
          malformed,
          tools: [_escapedAttributeSchemaTool],
        );
        expect(rejected.toolCalls, isEmpty);
        expect(rejected.content, malformed);
      }
    });

    test('forced-open reasoning terminates at the V3.2 envelope', () {
      const output =
          'Need the weather\n\n'
          '<｜DSML｜function_calls>\n'
          '<｜DSML｜invoke name="weather">\n'
          '<｜DSML｜parameter name="city" string="true">Seoul'
          '</｜DSML｜parameter>\n'
          '</｜DSML｜invoke>\n'
          '</｜DSML｜function_calls>';
      final parsed = ChatTemplateEngine.parse(
        ChatFormat.deepseekV32.index,
        output,
        tools: [_weatherWithCityTool],
        thinkingForcedOpen: true,
      );

      expect(parsed.reasoningContent, 'Need the weather');
      expect(parsed.content, isEmpty);
      expect(_arguments(parsed), {'city': 'Seoul'});
    });

    test('production parse enforces the V3.2 schema and string flag', () {
      const valid =
          '<｜DSML｜function_calls>\n'
          '<｜DSML｜invoke name="weather">\n'
          '<｜DSML｜parameter name="city" string="true">x < 5'
          '</｜DSML｜parameter>\n'
          '</｜DSML｜invoke>\n'
          '</｜DSML｜function_calls>';
      final parsed = ChatTemplateEngine.parse(
        ChatFormat.deepseekV32.index,
        valid,
        tools: [_weatherWithCityTool],
      );
      expect(_arguments(parsed), {'city': 'x < 5'});

      final duplicate = valid.replaceFirst(
        '</｜DSML｜parameter>',
        '</｜DSML｜parameter>\n'
            '<｜DSML｜parameter name="city" string="true">again'
            '</｜DSML｜parameter>',
      );
      for (final invalid in [
        valid.replaceFirst('name="weather"', 'name="unknown"'),
        valid.replaceFirst('name="city"', 'name="unknown"'),
        valid.replaceFirst('string="true"', 'string="false"'),
        duplicate,
      ]) {
        final rejected = ChatTemplateEngine.parse(
          ChatFormat.deepseekV32.index,
          invalid,
          tools: [_weatherWithCityTool],
        );
        expect(rejected.toolCalls, isEmpty);
        expect(rejected.content, contains('<｜DSML｜function_calls>'));
      }
    });

    test('preserves the protocol block when tool parsing is disabled', () {
      final parsed = DeepseekV32Handler().parse(
        actualUpstreamOutput,
        parseToolCalls: false,
        thinkingForcedOpen: true,
      );

      expect(parsed.reasoningContent, 'Let me check the time');
      expect(parsed.toolCalls, isEmpty);
      expect(parsed.content, startsWith('<｜DSML｜function_calls>'));
      expect(parsed.content, endsWith('</｜DSML｜function_calls>'));
    });

    test('preserves a forced-open protocol block when parsing is disabled', () {
      const output =
          'Need the weather\n\n'
          '<｜DSML｜function_calls>\n'
          '<｜DSML｜invoke name="weather">\n'
          '<｜DSML｜parameter name="city" string="true">Seoul'
          '</｜DSML｜parameter>\n'
          '</｜DSML｜invoke>\n'
          '</｜DSML｜function_calls>';
      final parsed = DeepseekV32Handler().parse(
        output,
        parseToolCalls: false,
        thinkingForcedOpen: true,
      );

      expect(parsed.reasoningContent, 'Need the weather');
      expect(parsed.toolCalls, isEmpty);
      expect(parsed.content, startsWith('<｜DSML｜function_calls>'));
      expect(parsed.content, endsWith('</｜DSML｜function_calls>'));
    });

    test('hides an incomplete function call while streaming', () {
      const output =
          'Prelude\n<｜DSML｜function_calls>\n'
          '<｜DSML｜invoke name="weather">\n'
          '<｜DSML｜parameter name="city" string="true">Seo';
      final parsed = DeepseekV32Handler().parse(output, isPartial: true);

      expect(parsed.content, 'Prelude');
      expect(parsed.toolCalls, isEmpty);
    });

    test('keeps completed calls before a partial second invoke', () {
      const output =
          '<｜DSML｜function_calls>\n'
          '<｜DSML｜invoke name="weather">\n'
          '<｜DSML｜parameter name="city" string="true">Seoul'
          '</｜DSML｜parameter>\n'
          '</｜DSML｜invoke>\n'
          '<｜DSML｜invoke name="clock">\n'
          '<｜DSML｜parameter name="tz" string="true">UT';
      final parsed = DeepseekV32Handler().parse(output, isPartial: true);

      expect(parsed.content, isEmpty);
      expect(parsed.toolCalls, hasLength(1));
      expect(parsed.toolCalls.single.function?.name, 'weather');
      expect(_arguments(parsed), {'city': 'Seoul'});
    });

    test('preserves a malformed completed payload', () {
      const output =
          '<｜DSML｜function_calls>\n'
          '<｜DSML｜invoke name="weather">\n'
          '<｜DSML｜parameter name="days" string="false">two'
          '</｜DSML｜parameter>\n'
          '</｜DSML｜invoke>\n'
          '</｜DSML｜function_calls>';
      final parsed = DeepseekV32Handler().parse(output);

      expect(parsed.toolCalls, isEmpty);
      expect(parsed.content, output);
    });

    test('preserves a truncated full output', () {
      const output =
          '<｜DSML｜function_calls>\n'
          '<｜DSML｜invoke name="weather">\n'
          '<｜DSML｜parameter name="city" string="true">Seoul'
          '</｜DSML｜parameter>\n'
          '</｜DSML｜invoke>';
      final parsed = DeepseekV32Handler().parse(output);

      expect(parsed.toolCalls, isEmpty);
      expect(parsed.content, output);
    });
  });

  group('DeepSeek V4 DSML', () {
    test('parses reasoning, raw strings, and JSON-typed values', () {
      const output =
          'reasoning</think>Done.\n\n'
          '<｜DSML｜tool_calls>\n'
          '<｜DSML｜invoke name="weather">\n'
          '<｜DSML｜parameter name="city" string="true"> New York '
          '</｜DSML｜parameter>\n'
          '<｜DSML｜parameter name="days" string="false">2'
          '</｜DSML｜parameter>\n'
          '</｜DSML｜invoke>\n'
          '</｜DSML｜tool_calls>';
      final parsed = DeepseekV4Handler().parse(
        output,
        thinkingForcedOpen: true,
      );
      expect(parsed.reasoningContent, 'reasoning');
      expect(parsed.content, 'Done.');
      expect(_arguments(parsed), {'city': ' New York ', 'days': 2});
    });

    test('preserves malformed non-string values', () {
      const output =
          '<｜DSML｜tool_calls>\n'
          '<｜DSML｜invoke name="weather">\n'
          '<｜DSML｜parameter name="days" string="false">two'
          '</｜DSML｜parameter>\n'
          '</｜DSML｜invoke>\n</｜DSML｜tool_calls>';
      final parsed = DeepseekV4Handler().parse(output);
      expect(parsed.toolCalls, isEmpty);
      expect(parsed.content, output);
    });

    test('keeps the V4 tool_calls grammar and trigger', () {
      final handler = DeepseekV4Handler();
      final grammar = handler.buildGrammar([_weatherTool])!;

      expect(handler.grammarTriggerValues, ['<｜DSML｜tool_calls>']);
      expect(
        grammar.split('\n').first,
        r'root ::= "<｜DSML｜tool_calls>" dsml-space dsml-tool+ "</｜DSML｜tool_calls>"',
      );
      expect(grammar, isNot(contains('<｜DSML｜function_calls>')));
    });
  });

  group('Muse Glimmer', () {
    const atem =
        '<atem:function_calls>\n'
        '<atem:invoke name="weather">\n'
        '<atem:parameter name="city"> New York </atem:parameter>\n'
        '</atem:invoke>\n'
        '</atem:function_calls>';

    test('separates reasoning, user content, and recipient tool channels', () {
      const output =
          ' to=self<|message|>check first<|eom|>'
          '<|start|>assistant to=user<|message|>On it.<|eom|>'
          '<|start|>assistant to=weather<|message|>$atem';
      final parsed = MuseGlimmerHandler().parse(output);
      expect(parsed.reasoningContent, 'check first');
      expect(parsed.content, 'On it.');
      expect(parsed.toolCalls.single.function?.name, 'weather');
      expect(_arguments(parsed), {'city': ' New York '});
    });

    test('round-trips escaped attributes and rejects reserved recipients', () {
      final grammar = MuseGlimmerHandler().buildGrammar([
        _escapedAttributeSchemaTool,
      ])!;
      expect(grammar, contains(r'invoke name=\"weather&amp;&quot;alerts\"'));
      expect(grammar, contains(r'parameter name=\"city&amp;&quot;zone\"'));

      const output =
          ' to=weather&"alerts<|message|>'
          '<atem:function_calls>'
          '<atem:invoke name="weather&amp;&quot;alerts">'
          '<atem:parameter name="city&amp;&quot;zone">Seoul</atem:parameter>'
          '</atem:invoke>'
          '</atem:function_calls><|eot|>';
      final parsed = ChatTemplateEngine.parse(
        ChatFormat.museGlimmer.index,
        output,
        tools: [_escapedAttributeSchemaTool],
      );
      expect(parsed.toolCalls.single.function?.name, 'weather&"alerts');
      expect(_arguments(parsed), {'city&"zone': 'Seoul'});

      for (final malformed in [
        output.replaceFirst('weather&amp;&quot;alerts', 'weather&&quot;alerts'),
        output.replaceFirst(
          'weather&amp;&quot;alerts',
          'weather&bogus;&quot;alerts',
        ),
        output.replaceFirst(
          'weather&amp;&quot;alerts',
          'weather&amp;amp;&quot;alerts',
        ),
        output.replaceFirst('city&amp;&quot;zone', 'city&&quot;zone'),
        output.replaceFirst('city&amp;&quot;zone', 'city&bogus;&quot;zone'),
        output.replaceFirst('city&amp;&quot;zone', 'city&amp;amp;&quot;zone'),
      ]) {
        final rejected = ChatTemplateEngine.parse(
          ChatFormat.museGlimmer.index,
          malformed,
          tools: [_escapedAttributeSchemaTool],
        );
        expect(rejected.toolCalls, isEmpty);
        expect(rejected.content, malformed.trim());
      }

      for (final reserved in ['self', 'user', ' leading', 'bad<route']) {
        final tool = ToolDefinition(
          name: reserved,
          description: 'Invalid Muse recipient',
          parameters: const [],
          handler: (_) async => null,
        );
        expect(
          () => MuseGlimmerHandler().buildGrammar([tool]),
          throwsA(isA<LlamaUnsupportedException>()),
        );
      }
    });

    test('requires one invoke matching the Muse recipient route', () {
      const valid =
          ' to=weather<|message|>'
          '<atem:function_calls>'
          '<atem:invoke name="weather"></atem:invoke>'
          '</atem:function_calls><|eot|>';
      final parsed = ChatTemplateEngine.parse(
        ChatFormat.museGlimmer.index,
        valid,
        tools: [_weatherTool],
      );
      expect(parsed.toolCalls.single.function?.name, 'weather');
      expect(parsed.content, isEmpty);

      for (final malformed in [
        valid.replaceFirst('to=weather', 'to=other'),
        valid.replaceFirst('to=weather', 'to= weather '),
        valid
            .replaceFirst('to=weather', 'to=other')
            .replaceFirst('name="weather"', 'name="other"'),
        valid.replaceFirst(
          '</atem:function_calls>',
          '<atem:invoke name="weather"></atem:invoke>'
              '</atem:function_calls>',
        ),
      ]) {
        final rejected = ChatTemplateEngine.parse(
          ChatFormat.museGlimmer.index,
          malformed,
          tools: [_weatherTool],
        );
        expect(rejected.toolCalls, isEmpty);
        expect(rejected.content, malformed.trim());
      }
    });

    test('does not parse quoted ATEM markup in the user channel', () {
      const output = ' to=user<|message|>Use this example:\n$atem<|eot|>';
      final parsed = MuseGlimmerHandler().parse(output);
      expect(parsed.toolCalls, isEmpty);
      expect(parsed.content, contains('<atem:function_calls>'));
    });

    test('does not validate schemas when Muse parsing is disabled', () {
      final duplicate = ToolDefinition(
        name: 'weather',
        description: 'Duplicate weather tool',
        parameters: const [],
        handler: (_) async => null,
      );
      const output = ' to=weather<|message|>$atem<|eot|>';

      final parsed = MuseGlimmerHandler().parseWithTools(
        output,
        tools: [_weatherTool, duplicate],
        parseToolCalls: false,
      );

      expect(parsed.content, atem);
      expect(parsed.toolCalls, isEmpty);
    });

    test('preserves malformed tool-channel markup as content', () {
      const output = ' to=weather<|message|><atem:function_calls>broken<|eot|>';
      final parsed = MuseGlimmerHandler().parse(output);
      expect(parsed.toolCalls, isEmpty);
      expect(parsed.content, output.trim());
    });

    test('rolls a truncated final Muse tool channel back verbatim', () {
      const output = 'Before. to=weather<|message|><atem:function_calls>broken';
      final parsed = MuseGlimmerHandler().parse(output);

      expect(parsed.toolCalls, isEmpty);
      expect(parsed.content, output);
    });

    test('hides an incomplete tool channel while streaming', () {
      const output =
          ' to=user<|message|>On it.<|eom|>'
          '<|start|>assistant to=weather<|message|>'
          '<atem:function_calls>\n<atem:invoke name="weather">\n'
          '<atem:parameter name="city">Seo';
      final parsed = MuseGlimmerHandler().parse(output, isPartial: true);

      expect(parsed.content, 'On it.');
      expect(parsed.toolCalls, isEmpty);
    });

    test('hides a partial Muse routing envelope before the message body', () {
      const output = 'Visible answer.<|start|>assistant to=weather<|mess';
      final parsed = MuseGlimmerHandler().parse(output, isPartial: true);

      expect(parsed.content, 'Visible answer.');
      expect(parsed.toolCalls, isEmpty);
    });

    test('preserves unmatched content around parsed Muse channels', () {
      const output =
          'Before.'
          ' to=user<|message|>User channel.<|eom|>'
          'Between.'
          '<|start|>assistant to=weather<|message|>$atem<|eot|>'
          'After.';
      final parsed = MuseGlimmerHandler().parse(output);

      expect(parsed.content, contains('Before.'));
      expect(parsed.content, contains('User channel.'));
      expect(parsed.content, contains('Between.'));
      expect(parsed.content, contains('After.'));
      expect(
        parsed.content.indexOf('Before.'),
        lessThan(parsed.content.indexOf('User channel.')),
      );
      expect(
        parsed.content.indexOf('User channel.'),
        lessThan(parsed.content.indexOf('Between.')),
      );
      expect(
        parsed.content.indexOf('Between.'),
        lessThan(parsed.content.indexOf('After.')),
      );
      expect(parsed.toolCalls.single.function?.name, 'weather');
    });

    test('restores an incomplete Muse route as final assistant content', () {
      const output = 'Visible.<|start|>assistant to=weather<|mess';
      final parsed = MuseGlimmerHandler().parse(output);

      expect(parsed.content, output);
      expect(parsed.toolCalls, isEmpty);
    });

    test('lazy grammar activates only at the ATEM tool-call envelope', () {
      final handler = MuseGlimmerHandler();
      final grammar = handler.buildGrammar([_weatherTool])!;

      expect(handler.grammarTriggerValues, ['<atem:function_calls>']);
      expect(
        grammar.split('\n').first,
        r'root ::= "<atem:function_calls>" muse-space muse-tool+ "</atem:function_calls>"',
      );
      expect(grammar, isNot(contains('identifier ::=')));
      expect(grammar.split('\n').first, isNot(contains(' to=')));
    });

    test('production parse preserves schema-directed Muse values', () {
      const output =
          ' to=inspect<|message|><atem:function_calls>'
          '<atem:invoke name="inspect">'
          '<atem:parameter name="code">123</atem:parameter>'
          '<atem:parameter name="options">{}</atem:parameter>'
          '<atem:parameter name="items">[]</atem:parameter>'
          '<atem:parameter name="count">7</atem:parameter>'
          '<atem:parameter name="active">true</atem:parameter>'
          '<atem:parameter name="empty">null</atem:parameter>'
          '</atem:invoke></atem:function_calls><|eot|>';
      final parsed = ChatTemplateEngine.parse(
        ChatFormat.museGlimmer.index,
        output,
        tools: [_schemaTool],
      );

      expect(_arguments(parsed), {
        'code': '123',
        'options': <String, dynamic>{},
        'items': <Object?>[],
        'count': 7,
        'active': true,
        'empty': null,
      });

      final duplicate = output.replaceFirst(
        '</atem:parameter><atem:parameter name="options">',
        '</atem:parameter>'
            '<atem:parameter name="code">again</atem:parameter>'
            '<atem:parameter name="options">',
      );
      final rejected = ChatTemplateEngine.parse(
        ChatFormat.museGlimmer.index,
        duplicate,
        tools: [_schemaTool],
      );
      expect(rejected.toolCalls, isEmpty);
      expect(rejected.content, contains('<atem:function_calls>'));
    });
  });

  group('Poolside Laguna', () {
    test('escapes the newline delimiter inside required GBNF classes', () {
      final grammar = LagunaHandler().buildRequiredGrammar([_schemaTool])!;

      expect(grammar, contains(r'[^\n<'));
      expect(grammar, isNot(contains('[^\n')));
    });

    test('parses reasoning and GLM-style tool calls with raw strings', () {
      const output =
          '<think>check</think>On it.\n'
          '<tool_call>weather\n'
          '<arg_key>city</arg_key>\n'
          '<arg_value> New York </arg_value>\n'
          '</tool_call>';
      final handler = LagunaHandler();
      final parsed = handler.parse(output);
      expect(parsed.reasoningContent, 'check');
      expect(parsed.content, 'On it.');
      expect(_arguments(parsed), {'city': 'New York'});
      expect(handler.additionalStops, contains('</assistant>'));
    });

    test('preserves malformed tool blocks as non-tool content', () {
      const output =
          '<tool_call>weather<arg_key>city</arg_key>Seoul</tool_call>';
      final parsed = LagunaHandler().parse(output);
      expect(parsed.toolCalls, isEmpty);
      expect(parsed.content, output);
    });

    test('hides an incomplete Laguna tool block while streaming', () {
      const output =
          'Visible answer.\n'
          '<tool_call>weather\n'
          '<arg_key>city</arg_key><arg_value>Seo';
      final parsed = LagunaHandler().parse(output, isPartial: true);

      expect(parsed.content, 'Visible answer.');
      expect(parsed.toolCalls, isEmpty);
    });

    test('keeps completed Laguna calls before an incomplete next call', () {
      const output =
          'Visible answer.\n'
          '<tool_call>weather\n'
          '<arg_key>city</arg_key><arg_value>Seoul</arg_value>\n'
          '</tool_call>\n'
          '<tool_call>weather\n<arg_key>city</arg_key><arg_value>Tor';
      final parsed = LagunaHandler().parse(output, isPartial: true);

      expect(parsed.content, 'Visible answer.');
      expect(parsed.toolCalls, hasLength(1));
      expect(_arguments(parsed), {'city': 'Seoul'});
    });

    test('hides a partial Laguna opening marker while streaming', () {
      const output = 'Visible answer.<tool_cal';
      final parsed = LagunaHandler().parse(output, isPartial: true);

      expect(parsed.content, 'Visible answer.');
      expect(parsed.toolCalls, isEmpty);
    });

    test('keeps incomplete Laguna markup when parsing is disabled', () {
      const output = 'Visible answer.<tool_call>weather';
      final parsed = LagunaHandler().parse(
        output,
        isPartial: true,
        parseToolCalls: false,
      );

      expect(parsed.content, output);
      expect(parsed.toolCalls, isEmpty);
    });

    test('production parse preserves schema-directed Laguna values', () {
      const output =
          '<tool_call>inspect\n'
          '<arg_key>code</arg_key><arg_value>123</arg_value>\n'
          '<arg_key>options</arg_key><arg_value>{}</arg_value>\n'
          '<arg_key>items</arg_key><arg_value>[]</arg_value>\n'
          '<arg_key>count</arg_key><arg_value>7</arg_value>\n'
          '<arg_key>active</arg_key><arg_value>true</arg_value>\n'
          '<arg_key>empty</arg_key><arg_value>null</arg_value>\n'
          '</tool_call>';
      final parsed = ChatTemplateEngine.parse(
        ChatFormat.laguna.index,
        output,
        tools: [_schemaTool],
      );

      expect(_arguments(parsed), {
        'code': '123',
        'options': <String, dynamic>{},
        'items': <Object?>[],
        'count': 7,
        'active': true,
        'empty': null,
      });
    });
  });

  test('specialized grammars reject nested duplicate parameter identities', () {
    final ambiguous = ToolDefinition(
      name: 'ambiguous',
      description: 'Ambiguous nested parameters',
      parameters: [
        ToolParam.object(
          'options',
          properties: [ToolParam.string('mode'), ToolParam.boolean('mode')],
        ),
      ],
      handler: (_) async => null,
    );
    final builders = <String? Function(List<ToolDefinition>?)>[
      KimiK3Handler().buildGrammar,
      MinimaxM3Handler().buildGrammar,
      DeepseekV32Handler().buildGrammar,
      MuseGlimmerHandler().buildGrammar,
    ];

    for (final buildGrammar in builders) {
      expect(
        () => buildGrammar([ambiguous]),
        throwsA(
          isA<LlamaUnsupportedException>().having(
            (error) => error.message,
            'message',
            allOf(contains('options'), contains('declared more than once')),
          ),
        ),
      );
    }
  });
}

final _weatherTool = ToolDefinition(
  name: 'weather',
  description: 'Weather',
  parameters: const [],
  handler: (_) async => null,
);

final _weatherWithCityTool = ToolDefinition(
  name: 'weather',
  description: 'Weather',
  parameters: [ToolParam.string('city', required: true)],
  handler: (_) async => null,
);

final _weatherNestedTool = ToolDefinition(
  name: 'weather',
  description: 'Weather with options',
  parameters: [
    ToolParam.string('city', required: true),
    ToolParam.object(
      'options',
      properties: [ToolParam.string('units', required: true)],
      required: true,
    ),
  ],
  handler: (_) async => null,
);

final _attributeTool = ToolDefinition(
  name: 'weather&"alerts',
  description: 'Weather alerts',
  parameters: const [],
  handler: (_) async => null,
);

final _escapedSchemaTool = ToolDefinition(
  name: 'weather',
  description: 'Weather',
  parameters: [ToolParam.string('city&"zone', required: true)],
  handler: (_) async => null,
);

final _escapedAttributeSchemaTool = ToolDefinition(
  name: 'weather&"alerts',
  description: 'Weather alerts',
  parameters: [ToolParam.string('city&"zone', required: true)],
  handler: (_) async => null,
);

final _zeroArgTool = ToolDefinition(
  name: 'ping',
  description: 'Ping',
  parameters: const [],
  handler: (_) async => null,
);

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

Map<String, dynamic> _arguments(dynamic parsed) {
  return jsonDecode(parsed.toolCalls.first.function!.arguments!)
      as Map<String, dynamic>;
}
