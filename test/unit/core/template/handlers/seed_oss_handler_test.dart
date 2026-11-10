import 'dart:convert';

import 'package:llamadart/src/core/models/chat/chat_message.dart';
import 'package:llamadart/src/core/models/chat/chat_role.dart';
import 'package:llamadart/src/core/models/tools/tool_definition.dart';
import 'package:llamadart/src/core/models/tools/tool_param.dart';
import 'package:llamadart/src/core/template/chat_format.dart';
import 'package:llamadart/src/core/template/chat_parse_result.dart';
import 'package:llamadart/src/core/template/handlers/seed_oss_handler.dart';
import 'package:llamadart/src/core/template/template_internal_metadata.dart';
import 'package:test/test.dart';

void main() {
  test('SeedOssHandler renders XML grammar and parses seed tool call', () {
    final handler = SeedOssHandler();
    final tools = [
      ToolDefinition(
        name: 'get_weather',
        description: 'Get weather',
        parameters: [ToolParam.string('city', required: true)],
        handler: _noop,
      ),
    ];

    final rendered = handler.render(
      templateSource: '{{ messages[0]["content"] }}',
      messages: const [
        LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'hello'),
      ],
      metadata: const {},
      tools: tools,
    );

    expect(handler.format, isA<ChatFormat>());
    expect(rendered.grammar, isNotNull);
    expect(rendered.grammarLazy, isTrue);
    expect(rendered.preservedTokens, contains('<seed:tool_call>'));
    expect(rendered.grammarTriggers.first.value, contains('<seed:tool_call>'));

    final parsed = handler.parse(
      '<seed:tool_call>\n<function=get_weather><parameter=city>"Seoul"</parameter></function></seed:tool_call>tail',
    );
    expect(parsed.content, equals('tail'));
    expect(parsed.toolCalls, hasLength(1));
    expect(parsed.toolCalls.first.function?.name, equals('get_weather'));
    expect(
      jsonDecode(parsed.toolCalls.first.function!.arguments!),
      containsPair('city', 'Seoul'),
    );
  });

  test('SeedOssHandler grammar repeats scopes only with parallel calls', () {
    final tools = [
      ToolDefinition(
        name: 'get_weather',
        description: 'Get weather',
        parameters: [ToolParam.string('city', required: true)],
        handler: _noop,
      ),
    ];
    for (final parallel in [true, false]) {
      final rendered = SeedOssHandler().render(
        templateSource: '{{ messages[0]["content"] }}',
        messages: const [
          LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'hello'),
        ],
        metadata: {internalParallelToolCallsMetadataKey: '$parallel'},
        tools: tools,
      );

      expect(
        rendered.grammar,
        contains(
          parallel
              ? 'root ::= tool-call-scope+\n'
              : 'root ::= tool-call-scope\n',
        ),
      );
      // As in llama.cpp, a call starts only at the line-broken scope.
      expect(rendered.grammarTriggers.map((trigger) => trigger.value), [
        '<seed:tool_call>\n',
      ]);
      expect(
        rendered.grammarTriggers.map((trigger) => trigger.type),
        everyElement(0),
      );
    }
  });

  test('SeedOssHandler.buildGrammar builds the default render grammar', () {
    final tools = [
      ToolDefinition(
        name: 'get_weather',
        description: 'Get weather',
        parameters: [ToolParam.string('city', required: true)],
        handler: _noop,
      ),
    ];
    final rendered = SeedOssHandler().render(
      templateSource: '{{ messages[0]["content"] }}',
      messages: const [
        LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'hello'),
      ],
      metadata: const {},
      tools: tools,
    );

    expect(rendered.grammar, contains('root ::= tool-call-scope\n'));
    expect(SeedOssHandler().buildGrammar(tools), rendered.grammar);
  });

  test('SeedOssHandler parses one call per <seed:tool_call> scope', () {
    String call(String city) =>
        '<seed:tool_call>\n<function=weather>\n'
        '<parameter=city>\n$city\n</parameter>\n'
        '</function>\n</seed:tool_call>';
    final parsed = SeedOssHandler().parse(
      '<seed:think>Plan</seed:think>\n${call('Paris')}\n${call('Rome')}'
      '${call('Tokyo')}',
    );

    expect(parsed.reasoningContent, 'Plan');
    expect(parsed.content, isEmpty);
    expect(
      [
        for (final call in parsed.toolCalls)
          (jsonDecode(call.function!.arguments!) as Map)['city'],
      ],
      ['\nParis\n', '\nRome\n', '\nTokyo\n'],
    );
  });

  // llama.cpp (`cd959bae9`) starts calls at the first `<seed:tool_call>`
  // followed by a line break; text before it is content (#1542).
  group('SeedOssHandler scope start tag', () {
    String call(String city, {String scopeStart = '<seed:tool_call>\n'}) =>
        '$scopeStart<function=get_weather>\n'
        '<parameter=location>\n$city\n</parameter>\n'
        '</function>\n</seed:tool_call>';
    List<Object?> cities(ChatParseResult parsed) => [
      for (final call in parsed.toolCalls)
        (jsonDecode(call.function!.arguments!) as Map)['location'],
    ];

    test('without a line break keeps the reply as content', () {
      for (final whitespace in ['', ' ', '\t', '\r\n', ' \n', '\t\n', '  ']) {
        final output = call('Paris', scopeStart: '<seed:tool_call>$whitespace');
        for (final forcedOpen in [false, true]) {
          final parsed = SeedOssHandler().parse(
            forcedOpen ? 'Plan</seed:think>\n$output' : output,
            thinkingForcedOpen: forcedOpen,
          );

          expect(parsed.toolCalls, isEmpty, reason: jsonEncode(whitespace));
          expect(parsed.content, output, reason: jsonEncode(whitespace));
        }
      }
    });

    test('calls start at the first scope with a line break', () {
      final compact = call('Paris', scopeStart: '<seed:tool_call>');
      for (final (output, content) in [
        ('$compact\n${call('Rome')}', compact),
        (
          'Use the <seed:tool_call> tag.\n${call('Rome')}',
          'Use the <seed:tool_call> tag.',
        ),
      ]) {
        final parsed = SeedOssHandler().parse(output);

        expect(cities(parsed), ['\nRome\n'], reason: output);
        expect(parsed.content, content, reason: output);
      }
    });

    test('a scope start tag in the thought does not decide the calls', () {
      for (final (output, forcedOpen) in [
        ('try <seed:tool_call><function=x></seed:think>', true),
        ('<seed:think>try <seed:tool_call><function=x></seed:think>', false),
      ]) {
        final parsed = SeedOssHandler().parse(
          '$output${call('Paris')}',
          thinkingForcedOpen: forcedOpen,
        );

        expect(parsed.reasoningContent, 'try <seed:tool_call><function=x>');
        expect(cities(parsed), ['\nParis\n'], reason: output);
        expect(parsed.content, isEmpty, reason: output);
      }
    });

    // llama.cpp fails the reply instead.
    test('a later scope without a line break stays content', () {
      for (final whitespace in ['', ' ']) {
        final later = call('Rome', scopeStart: '<seed:tool_call>$whitespace');
        final parsed = SeedOssHandler().parse('${call('Paris')}\n$later');

        expect(cities(parsed), ['\nParis\n'], reason: jsonEncode(whitespace));
        expect(parsed.content, later, reason: jsonEncode(whitespace));
      }
    });

    test('at the end of the output is content', () {
      final parsed = SeedOssHandler().parse('Checking <seed:tool_call>');

      expect(parsed.toolCalls, isEmpty);
      expect(parsed.content, 'Checking <seed:tool_call>');
    });

    test('with a leading line break parses a call, as llama.cpp does', () {
      for (final whitespace in ['\n\n', '\n ', '\n\t', '\n\r\n']) {
        final parsed = SeedOssHandler().parse(
          call('Paris', scopeStart: '<seed:tool_call>$whitespace'),
        );

        expect(cities(parsed), ['\nParis\n'], reason: jsonEncode(whitespace));
        expect(parsed.content, isEmpty, reason: jsonEncode(whitespace));
      }
    });
  });

  // Unlike llama.cpp, which fails the reply, the handler takes no tool
  // schemas, so it returns these as calls (#1542, #1531). The engine and the
  // stream parser reject them for `ToolDefinition.fromJsonSchema` tools.
  group('SeedOssHandler stays lenient where llama.cpp errors', () {
    String call(String city) =>
        '<seed:tool_call>\n<function=get_weather>\n'
        '<parameter=location>\n$city\n</parameter>\n'
        '</function>\n</seed:tool_call>';

    test('an unknown tool in a later scope is returned as a call', () {
      final output =
          '${call('Paris')}\n'
          '${call('Rome').replaceFirst('get_weather', 'not_a_tool')}';
      final parsed = SeedOssHandler().parse(output);

      expect(parsed.toolCalls.map((call) => call.function!.name), [
        'get_weather',
        'not_a_tool',
      ]);
      expect(parsed.content, isEmpty);
    });

    test('a call missing a required argument is returned as a call', () {
      final parsed = SeedOssHandler().parse(
        '<seed:tool_call>\n<function=get_weather>\n</function>\n'
        '</seed:tool_call>',
      );

      expect(parsed.toolCalls.map((call) => call.function!.name), [
        'get_weather',
      ]);
      expect(jsonDecode(parsed.toolCalls.single.function!.arguments!), isEmpty);
      expect(parsed.content, isEmpty);
    });
  });

  test('SeedOssHandler returns a forced-open thought as reasoning', () {
    const call =
        '<seed:tool_call>\n<function=weather><parameter=city>Paris'
        '</parameter></function></seed:tool_call>';
    for (final (output, reasoning, calls) in [
      ('Plan.', 'Plan.', 0),
      ('Plan. $call', 'Plan. $call', 0),
      ('Plan.</seed:think>\n$call', 'Plan.', 1),
    ]) {
      final parsed = SeedOssHandler().parse(output, thinkingForcedOpen: true);
      expect(parsed.content, isEmpty, reason: output);
      expect(parsed.reasoningContent, reasoning, reason: output);
      expect(parsed.toolCalls, hasLength(calls), reason: output);
    }
  });

  // Same rule as the model-opened thought pinned against llama.cpp
  // `cd959bae9` in closed_thought_upstream.json (`unfinished-end-tag`).
  test(
    'SeedOssHandler keeps a trailing partial end tag only once finished',
    () {
      const output = 'Plan</seed:thi';
      final handler = SeedOssHandler();
      expect(
        handler.parse(output, thinkingForcedOpen: true).reasoningContent,
        'Plan</seed:thi',
      );
      expect(
        handler
            .parse(output, thinkingForcedOpen: true, isPartial: true)
            .reasoningContent,
        'Plan',
      );
    },
  );
}

Future<Object?> _noop(_) async {
  return 'ok';
}
