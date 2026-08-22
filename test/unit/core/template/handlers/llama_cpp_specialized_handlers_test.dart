import 'dart:convert';

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

      expect(grammar, contains('kimi-0-json-block'));
      expect(grammar, contains(r'(" index=\"" [0-9]+ "\"")? "<|sep|>"'));
      expect(
        grammar,
        contains(r'"<|open|>json type=\"object\"<|sep|>" kimi-0-json-object'),
      );
    });

    test('grammar HTML-escapes tool names like the upstream XTML macro', () {
      final grammar = KimiK3Handler().buildGrammar([_attributeTool])!;

      expect(grammar, contains(r'tool=\"weather&amp;&quot;alerts\"'));
      expect(grammar, isNot(contains(r'tool=\"weather&\"alerts\"')));
    });

    test('grammar and parser round-trip escaped schema property names', () {
      final grammar = KimiK3Handler().buildGrammar([_escapedKeyTool])!;
      const output =
          '<|open|>tools<|sep|>'
          '<|open|>call tool="weather&amp;&quot;alerts"<|sep|>'
          '<|open|>argument key="city&amp;&quot;unit" type="string"<|sep|>'
          'x < 5<|close|>argument<|sep|>'
          '<|close|>call<|sep|><|close|>tools<|sep|>'
          '<|close|>message<|sep|>';

      expect(grammar, contains('key=\\"city&amp;&quot;unit\\"'));
      expect(grammar, isNot(contains('identifier ::=')));
      final parsed = ChatTemplateEngine.parse(
        ChatFormat.kimiK3.index,
        output,
        tools: [_escapedKeyTool],
      );
      expect(parsed.content, isEmpty);
      expect(parsed.toolCalls.single.function?.name, 'weather&"alerts');
      expect(_arguments(parsed), {'city&"unit': 'x < 5'});
    });

    test('schema-aware parsing rejects missing or undeclared arguments', () {
      const output =
          '<|open|>tools<|sep|>'
          '<|open|>call tool="weather"<|sep|>'
          '<|open|>argument key="unknown" type="string"<|sep|>x'
          '<|close|>argument<|sep|><|close|>call<|sep|>'
          '<|close|>tools<|sep|><|close|>message<|sep|>';
      final parsed = ChatTemplateEngine.parse(
        ChatFormat.kimiK3.index,
        output,
        tools: [_weatherWithCityTool],
      );
      expect(parsed.toolCalls, isEmpty);
      expect(parsed.content, contains('key="unknown"'));
    });

    test('preserves duplicate schema arguments as malformed content', () {
      const output =
          '<|open|>tools<|sep|>'
          '<|open|>call tool="weather"<|sep|>'
          '<|open|>argument key="city" type="string"<|sep|>Seoul'
          '<|close|>argument<|sep|>'
          '<|open|>argument key="city" type="string"<|sep|>Paris'
          '<|close|>argument<|sep|>'
          '<|close|>call<|sep|><|close|>tools<|sep|>'
          '<|close|>message<|sep|>';
      final parsed = ChatTemplateEngine.parse(
        ChatFormat.kimiK3.index,
        output,
        tools: [_weatherWithCityTool],
      );

      expect(parsed.toolCalls, isEmpty);
      expect(parsed.content, contains('<|open|>tools<|sep|>'));
      expect(parsed.content, contains('Seoul'));
      expect(parsed.content, contains('Paris'));
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

    test('suppresses a split tools marker while streaming', () {
      final parsed = KimiK3Handler().parse(
        '<|open|>response<|sep|>On it.<|close|>response<|sep|><|op',
        isPartial: true,
      );
      expect(parsed.content, 'On it.');
      expect(parsed.toolCalls, isEmpty);
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
      expect(callRule, contains(r'"\"weather\""'));
    });

    test('schema-aware parsing rejects unknown tool names', () {
      const output =
          '<tool_calls>\n'
          '{"name":"unknown","arguments":{"city":"Seoul"}}\n'
          '</tool_calls>';
      final parsed = ChatTemplateEngine.parse(
        ChatFormat.minimaxM1.index,
        output,
        tools: [_weatherWithCityTool],
      );
      expect(parsed.toolCalls, isEmpty);
      expect(parsed.content, output);
    });

    test('suppresses a split tool-call marker while streaming', () {
      final parsed = MinimaxM1Handler().parse('Prelude<tool_', isPartial: true);
      expect(parsed.content, 'Prelude');
      expect(parsed.toolCalls, isEmpty);
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

    test('hides an incomplete invoke while streaming', () {
      const output =
          'Prelude$ns<tool_call>\n'
          '$ns<invoke name="weather">$ns<city>Seo';
      final parsed = MinimaxM3Handler().parse(output, isPartial: true);

      expect(parsed.content, 'Prelude');
      expect(parsed.toolCalls, isEmpty);
    });

    test('suppresses a split namespace marker while streaming', () {
      final parsed = MinimaxM3Handler().parse(
        'Prelude${ns.substring(0, ns.length - 2)}',
        isPartial: true,
      );
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

    test('parses zero-argument calls with an empty object', () {
      const output =
          '$ns<tool_call>\n'
          '$ns<invoke name="ping">$ns</invoke>\n'
          '$ns</tool_call>';
      final parsed = ChatTemplateEngine.parse(
        ChatFormat.minimaxM3.index,
        output,
        tools: [_pingTool],
      );
      expect(parsed.content, isEmpty);
      expect(parsed.toolCalls.single.function?.name, 'ping');
      expect(_arguments(parsed), isEmpty);
    });

    test('reconstructs schema-directed scalars and empty containers', () {
      const output =
          '$ns<tool_call>\n'
          '$ns<invoke name="typed">'
          '$ns<code>123$ns</code>'
          '$ns<options>$ns</options>'
          '$ns<items>$ns</items>'
          '$ns</invoke>\n$ns</tool_call>';
      final parsed = ChatTemplateEngine.parse(
        ChatFormat.minimaxM3.index,
        output,
        tools: [_typedTool],
      );
      expect(_arguments(parsed), {'code': '123', 'options': {}, 'items': []});
    });

    test('schema grammar uses identical literal parameter tag pairs', () {
      final grammar = MinimaxM3Handler().buildGrammar([_typedTool])!;
      expect(grammar, contains('$ns<code>'));
      expect(grammar, contains('$ns</code>'));
      expect(grammar, isNot(contains('identifier ::=')));
      expect(grammar, contains('m3-0-arguments-code-text'));
    });

    test('preserves mismatched parameter closing tags', () {
      const output =
          '$ns<tool_call>$ns<invoke name="typed">'
          '$ns<code>123$ns</items>$ns</invoke>$ns</tool_call>';
      final parsed = ChatTemplateEngine.parse(
        ChatFormat.minimaxM3.index,
        output,
        tools: [_typedTool],
      );
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

    test('preserves duplicate DSML parameters as malformed content', () {
      const output =
          '<｜DSML｜tool_calls>\n'
          '<｜DSML｜invoke name="weather">\n'
          '<｜DSML｜parameter name="city" string="true">Seoul'
          '</｜DSML｜parameter>\n'
          '<｜DSML｜parameter name="city" string="true">Paris'
          '</｜DSML｜parameter>\n'
          '</｜DSML｜invoke>\n</｜DSML｜tool_calls>';
      final parsed = ChatTemplateEngine.parse(
        ChatFormat.deepseekV4.index,
        output,
        tools: [_weatherWithCityTool],
      );

      expect(parsed.toolCalls, isEmpty);
      expect(parsed.content, output);
    });

    test('parses the V3.2 function_calls envelope', () {
      const output =
          'check first'
          '<｜DSML｜function_calls>\n'
          '<｜DSML｜invoke name="weather">\n'
          '<｜DSML｜parameter name="city" string="true">x < 5'
          '</｜DSML｜parameter>\n'
          '</｜DSML｜invoke>\n'
          '</｜DSML｜function_calls>';
      final parsed = ChatTemplateEngine.parse(
        ChatFormat.deepseekV4.index,
        output,
        tools: [_weatherWithCityTool],
        thinkingForcedOpen: true,
      );
      expect(parsed.reasoningContent, 'check first');
      expect(parsed.content, isEmpty);
      expect(_arguments(parsed), {'city': 'x < 5'});
    });

    test('preserves malformed and finalized truncated V3.2 envelopes', () {
      const malformed =
          '<｜DSML｜function_calls>\n'
          '<｜DSML｜invoke name="weather">\n'
          '<｜DSML｜parameter name="city" string="true">Seoul'
          '</｜DSML｜parameter>\n'
          '</｜DSML｜tool_calls>';
      const truncated =
          '<｜DSML｜function_calls>\n'
          '<｜DSML｜invoke name="weather">\n'
          '<｜DSML｜parameter name="city" string="true">Seo';

      final malformedParsed = ChatTemplateEngine.parse(
        ChatFormat.deepseekV4.index,
        malformed,
        tools: [_weatherWithCityTool],
      );
      final finalizedTruncated = ChatTemplateEngine.parse(
        ChatFormat.deepseekV4.index,
        truncated,
        tools: [_weatherWithCityTool],
      );
      final partialTruncated = ChatTemplateEngine.parse(
        ChatFormat.deepseekV4.index,
        'reasoning$truncated',
        tools: [_weatherWithCityTool],
        thinkingForcedOpen: true,
        isPartial: true,
      );

      expect(malformedParsed.toolCalls, isEmpty);
      expect(malformedParsed.content, malformed);
      expect(finalizedTruncated.toolCalls, isEmpty);
      expect(finalizedTruncated.content, truncated);
      expect(partialTruncated.reasoningContent, 'reasoning');
      expect(partialTruncated.content, isEmpty);
      expect(partialTruncated.toolCalls, isEmpty);
    });

    test('preserves V3.2 markup when tool parsing is disabled', () {
      const output =
          '<｜DSML｜function_calls>\n'
          '<｜DSML｜invoke name="weather">\n'
          '<｜DSML｜parameter name="city" string="true">Seoul'
          '</｜DSML｜parameter>\n'
          '</｜DSML｜invoke>\n'
          '</｜DSML｜function_calls>';

      final parsed = DeepseekV4Handler().parse(output, parseToolCalls: false);

      expect(parsed.toolCalls, isEmpty);
      expect(parsed.content, output);
    });

    test('parses a V3.2 tool name containing regex metacharacters', () {
      const output =
          '<｜DSML｜function_calls>\n'
          '<｜DSML｜invoke name="weather.v2+alerts[0]">\n'
          '</｜DSML｜invoke>\n'
          '</｜DSML｜function_calls>';

      final parsed = ChatTemplateEngine.parse(
        ChatFormat.deepseekV4.index,
        output,
        tools: [_regexNameTool],
      );

      expect(parsed.content, isEmpty);
      expect(parsed.toolCalls.single.function?.name, 'weather.v2+alerts[0]');
      expect(_arguments(parsed), isEmpty);
    });

    test('DSML envelope ends forced-open thinking without a think close', () {
      const output =
          'reasoning'
          '<｜DSML｜tool_calls>\n'
          '<｜DSML｜invoke name="weather">\n'
          '<｜DSML｜parameter name="city" string="true">Seoul'
          '</｜DSML｜parameter>\n'
          '</｜DSML｜invoke>\n'
          '</｜DSML｜tool_calls>';
      final parsed = ChatTemplateEngine.parse(
        ChatFormat.deepseekV4.index,
        output,
        tools: [_weatherWithCityTool],
        thinkingForcedOpen: true,
      );
      expect(parsed.reasoningContent, 'reasoning');
      expect(_arguments(parsed), {'city': 'Seoul'});
    });

    test('suppresses a partial DSML envelope after forced reasoning', () {
      final parsed = ChatTemplateEngine.parse(
        ChatFormat.deepseekV4.index,
        'reasoning<｜DSML｜function_',
        tools: [_weatherWithCityTool],
        thinkingForcedOpen: true,
        isPartial: true,
      );
      expect(parsed.reasoningContent, 'reasoning');
      expect(parsed.content, isEmpty);
      expect(parsed.toolCalls, isEmpty);
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

    test('does not parse quoted ATEM markup in the user channel', () {
      const output = ' to=user<|message|>Use this example:\n$atem<|eot|>';
      final parsed = MuseGlimmerHandler().parse(output);
      expect(parsed.toolCalls, isEmpty);
      expect(parsed.content, contains('<atem:function_calls>'));
    });

    test('preserves malformed tool-channel markup as content', () {
      const output = ' to=weather<|message|><atem:function_calls>broken<|eot|>';
      final parsed = MuseGlimmerHandler().parse(output);
      expect(parsed.toolCalls, isEmpty);
      expect(parsed.content, contains('broken'));
    });

    test('preserves duplicate ATEM parameters as malformed content', () {
      const duplicateAtem =
          '<atem:function_calls>\n'
          '<atem:invoke name="weather">\n'
          '<atem:parameter name="city">Seoul</atem:parameter>\n'
          '<atem:parameter name="city">Paris</atem:parameter>\n'
          '</atem:invoke>\n'
          '</atem:function_calls>';
      const output = ' to=weather<|message|>$duplicateAtem<|eot|>';
      final parsed = ChatTemplateEngine.parse(
        ChatFormat.museGlimmer.index,
        output,
        tools: [_weatherWithCityTool],
      );

      expect(parsed.toolCalls, isEmpty);
      expect(parsed.content, contains(duplicateAtem));
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

    test('lazy grammar activates only at the ATEM tool-call envelope', () {
      final handler = MuseGlimmerHandler();
      final grammar = handler.buildGrammar([_weatherTool])!;

      expect(handler.grammarTriggerValues, ['<atem:function_calls>']);
      expect(
        grammar.split('\n').first,
        r'root ::= "<atem:function_calls>\n" invoke+ "</atem:function_calls>"',
      );
      expect(grammar.split('\n').first, isNot(contains(' to=')));
    });

    test('preserves unmatched surrounding content around channels', () {
      const output =
          'prefix<|start|>assistant to=user<|message|>Hello<|eot|>suffix';
      final parsed = MuseGlimmerHandler().parse(output);
      expect(parsed.content, 'prefixHellosuffix');
    });

    test('suppresses an incomplete routing prefix while streaming', () {
      for (final output in [
        'Prelude to=weather',
        'Prelude<|start|>assis',
        'Prelude<|start|>assistant to=wea',
      ]) {
        final parsed = MuseGlimmerHandler().parse(output, isPartial: true);
        expect(parsed.content, 'Prelude', reason: output);
      }
    });

    test('uses the schema to keep JSON-looking strings as strings', () {
      const output =
          ' to=typed<|message|><atem:function_calls>\n'
          '<atem:invoke name="typed">\n'
          '<atem:parameter name="code">123</atem:parameter>\n'
          '<atem:parameter name="options">{}</atem:parameter>\n'
          '<atem:parameter name="items">[]</atem:parameter>\n'
          '</atem:invoke>\n</atem:function_calls><|eot|>';
      final parsed = ChatTemplateEngine.parse(
        ChatFormat.museGlimmer.index,
        output,
        tools: [_typedTool],
      );
      expect(_arguments(parsed), {'code': '123', 'options': {}, 'items': []});
    });
  });

  group('Poolside Laguna', () {
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

    test('suppresses partial markup and restores it at finalization', () {
      const output =
          'Prelude<tool_call>weather<arg_key>city</arg_key>'
          '<arg_value>Seo';
      final partial = LagunaHandler().parse(output, isPartial: true);
      final complete = LagunaHandler().parse(output);
      expect(partial.content, 'Prelude');
      expect(complete.content, output);
    });

    test('suppresses a split tool marker while streaming', () {
      final parsed = LagunaHandler().parse('Prelude<tool_', isPartial: true);
      expect(parsed.content, 'Prelude');
      expect(parsed.toolCalls, isEmpty);
    });

    test('uses schema-directed values through the production parse path', () {
      const output =
          '<tool_call>typed\n'
          '<arg_key>code</arg_key>\n<arg_value>123</arg_value>\n'
          '<arg_key>options</arg_key>\n<arg_value>{}</arg_value>\n'
          '<arg_key>items</arg_key>\n<arg_value>[]</arg_value>\n'
          '</tool_call>';
      final parsed = ChatTemplateEngine.parse(
        ChatFormat.laguna.index,
        output,
        tools: [_typedTool],
      );
      expect(_arguments(parsed), {'code': '123', 'options': {}, 'items': []});
    });
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

final _attributeTool = ToolDefinition(
  name: 'weather&"alerts',
  description: 'Weather alerts',
  parameters: const [],
  handler: (_) async => null,
);

final _escapedKeyTool = ToolDefinition(
  name: 'weather&"alerts',
  description: 'Weather alerts',
  parameters: [ToolParam.string('city&"unit', required: true)],
  handler: (_) async => null,
);

final _pingTool = ToolDefinition(
  name: 'ping',
  description: 'Ping',
  parameters: const [],
  handler: (_) async => null,
);

final _regexNameTool = ToolDefinition(
  name: 'weather.v2+alerts[0]',
  description: 'Weather alerts',
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

Map<String, dynamic> _arguments(dynamic parsed) {
  return jsonDecode(parsed.toolCalls.first.function!.arguments!)
      as Map<String, dynamic>;
}
