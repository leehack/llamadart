import 'dart:convert';

import 'package:llamadart/src/core/models/chat/chat_message.dart';
import 'package:llamadart/src/core/models/chat/chat_role.dart';
import 'package:llamadart/src/core/models/chat/chat_template_result.dart';
import 'package:llamadart/src/core/models/inference/tool_choice.dart';
import 'package:llamadart/src/core/models/tools/tool_definition.dart';
import 'package:llamadart/src/core/models/tools/tool_param.dart';
import 'package:llamadart/src/core/template/chat_format.dart';
import 'package:llamadart/src/core/template/chat_parse_result.dart';
import 'package:llamadart/src/core/template/handlers/lfm2_handler.dart';
import 'package:llamadart/src/core/template/template_internal_metadata.dart';
import 'package:test/test.dart';

void main() {
  // Outputs and values of llama.cpp 620d2225 tests/test-chat.cpp
  // test_lfm2_parser. Its <think> cases are out of scope because this format
  // deliberately parses calls inside thoughts, and its \n and \t cases because
  // decoding those corrupts unescaped Windows paths.
  group('parses a call list as llama.cpp does', () {
    for (final (output, content, calls) in <(String, String, List<_Call>)>[
      ('[special_function(arg1=1)]', '', [('special_function', '{"arg1": 1}')]),
      ('[get_time(city="XYZCITY")]', '', [('get_time', '{"city":"XYZCITY"}')]),
      ('[toggle(enabled=True)]', '', [('toggle', '{"enabled": true}')]),
      ('[set_nullable(value=None)]', '', [('set_nullable', '{"value": null}')]),
      (
        '[set_config(config={"enabled": True, "count": 3})]',
        '',
        [('set_config', '{"config": {"enabled": true, "count": 3}}')],
      ),
      (
        '[set_config(config={"enabled": true, "note": null})]',
        '',
        [('set_config', '{"config": {"enabled": true, "note": null}}')],
      ),
      (
        '[Calendar.create_event(title="demo", '
            'participants=["Alice", "Bob"], '
            'metadata={"priority": "high", "reminder": true})]',
        '',
        [
          (
            'Calendar.create_event',
            '{"title": "demo", "participants": ["Alice", "Bob"], '
                '"metadata": {"priority": "high", "reminder": true}}',
          ),
        ],
      ),
      (
        r'[python(code="print(\"hi\")")]',
        '',
        [('python', r'{"code": "print(\"hi\")"}')],
      ),
      (
        '[special_function(arg1=1), special_function_with_opt(arg1=1, arg2=2)]',
        '',
        [
          ('special_function', '{"arg1": 1}'),
          ('special_function_with_opt', '{"arg1": 1, "arg2": 2}'),
        ],
      ),
      ('[empty_args()]', '', [('empty_args', '{}')]),
    ]) {
      test(output, () {
        _expectCalls(
          Lfm2Handler().parse('<|tool_call_start|>$output<|tool_call_end|>'),
          content,
          calls,
        );
      });
    }

    test('after content', () {
      _expectCalls(
        Lfm2Handler().parse(
          'Let me check the time.'
          '<|tool_call_start|>[get_time(city="Paris")]<|tool_call_end|>',
        ),
        'Let me check the time.',
        [('get_time', '{"city":"Paris"}')],
      );
    });

    test('with the escapes normalize_quotes_to_json handles', () {
      _expectCalls(
        Lfm2Handler().parse(
          r'''<|tool_call_start|>[save(a='it\'s "ok"', b="\u00e9\/", '''
          r'''c={'k': ['v', False, -1.5e2]})]<|tool_call_end|>''',
        ),
        '',
        [
          (
            'save',
            jsonEncode({
              'a': 'it\'s "ok"',
              'b': 'é/',
              'c': {
                'k': ['v', false, -150.0],
              },
            }),
          ),
        ],
      );
    });

    test('with an escaped backslash', () {
      _expectCalls(
        Lfm2Handler().parse(
          r'<|tool_call_start|>[save(a="C:\\new\\table")]<|tool_call_end|>',
        ),
        '',
        [
          ('save', jsonEncode({'a': r'C:\new\table'})),
        ],
      );
    });

    test('keeps a string that reads like a call or a separator', () {
      _expectCalls(
        Lfm2Handler().parse(
          r'<|tool_call_start|>[save(a="{\"name\": \"other\"}; x", '
          r'b="f(c=1), g()", d="key=value")]<|tool_call_end|>',
        ),
        '',
        [
          (
            'save',
            jsonEncode({
              'a': '{"name": "other"}; x',
              'b': 'f(c=1), g()',
              'd': 'key=value',
            }),
          ),
        ],
      );
    });

    test('with space around every token', () {
      _expectCalls(
        Lfm2Handler().parse(
          '<|tool_call_start|>[ save ( a = [ 1 , 2 ] , b = { "k" : 1 } ) , '
          'load ( ) ]<|tool_call_end|>',
        ),
        '',
        [
          (
            'save',
            jsonEncode({
              'a': [1, 2],
              'b': {'k': 1},
            }),
          ),
          ('load', '{}'),
        ],
      );
    });

    test('numbers calls across lists', () {
      _expectCalls(
        Lfm2Handler().parse(
          '<|tool_call_start|>[a()]<|tool_call_end|>'
          '<|tool_call_start|>[b(), c()]<|tool_call_end|>',
        ),
        '',
        [('a', '{}'), ('b', '{}'), ('c', '{}')],
      );
    });

    test('leaves text it cannot read as Python to the loose parser', () {
      for (final (arguments, expected) in [
        ('x={kk: 1}', {'x': '{kk: 1}'}),
        (r'y="\q"', {'y': r'\q'}),
        (r'z="\frac{a}{b}"', {'z': r'\frac{a}{b}'}),
        (r'z="C:\back"', {'z': r'C:\back'}),
        (r'z="C:\repo"', {'z': r'C:\repo'}),
        (r'z="C:\new"', {'z': r'C:\new'}),
        (r'z="C:\table"', {'z': r'C:\table'}),
        (r'z="a\nb", n=True', {'z': r'a\nb', 'n': 'True'}),
      ]) {
        _expectCalls(
          Lfm2Handler().parse(
            '<|tool_call_start|>[f($arguments)]<|tool_call_end|>',
          ),
          '',
          [('f', jsonEncode(expected))],
        );
      }
    });

    test('takes no call from a list with trailing text', () {
      final parsed = Lfm2Handler().parse(
        '<|tool_call_start|>[a(b=1)] junk<|tool_call_end|>',
      );
      expect(parsed.toolCalls, isEmpty);
    });

    test('leaves a nested object in its own argument', () {
      _expectCalls(
        Lfm2Handler().parse(
          '<|tool_call_start|>[save(input={"a": 1}, n=2)]<|tool_call_end|>',
        ),
        '',
        [
          (
            'save',
            jsonEncode({
              'input': {'a': 1},
              'n': 2,
            }),
          ),
        ],
      );
    });
  });

  group('model output never throws out of parse', () {
    String nested(String open, String close, int depth) =>
        open * depth + close * depth;

    for (final (name, arguments, expected) in <(String, String, Object?)>[
      ('a negative unicode escape', r'x="\u-001"', {'x': r'\u-001'}),
      ('a signed unicode escape', r'x="\u+041"', {'x': r'\u+041'}),
      ('a short unicode escape', r'x="\u12"', {'x': r'\u12'}),
      ('an overflowing number in a list', 'x=[1e999]', {'x': '[1e999]'}),
      ('a lone quote', "x='", {'x': "'"}),
    ]) {
      test('$name reads as text', () {
        _expectCalls(
          Lfm2Handler().parse(
            '<|tool_call_start|>[f($arguments)]<|tool_call_end|>',
          ),
          '',
          [('f', jsonEncode(expected))],
        );
      });
    }

    test('counts depth along a value, not across its siblings', () {
      final lists = List.filled(200, '[]').join(',');
      final maps = List.filled(200, '{}').join(',');
      final parsed = Lfm2Handler().parse(
        '<|tool_call_start|>[f(x=[$lists], y=[$maps])]<|tool_call_end|>',
      );
      final arguments =
          jsonDecode(parsed.toolCalls.single.function!.arguments!) as Map;
      expect(arguments['x'], hasLength(200));
      expect(arguments['y'], hasLength(200));
    });

    test('keeps a value at the depth the wire format allows', () {
      final value = nested('[', ']', 127);
      final parsed = Lfm2Handler().parse(
        '<|tool_call_start|>[f(x=$value)]<|tool_call_end|>',
      );
      expect(parsed.toolCalls.single.function?.arguments, '{"x":$value}');
    });

    for (final (name, value) in [
      ('one level too deep', nested('[', ']', 128)),
      ('a deep list', nested('[', ']', 200000)),
      ('an unclosed deep list', '[' * 200000),
      ('an unclosed deep map', '{"a":' * 200000),
    ]) {
      test('$name reads as text', () {
        _expectCalls(
          Lfm2Handler().parse(
            '<|tool_call_start|>[f(x=$value)]<|tool_call_end|>',
          ),
          '',
          [
            ('f', jsonEncode({'x': value})),
          ],
        );
      });
    }

    for (final (name, payload) in [
      ('an overflowing number', '[f(x=1e999)]'),
      ('an overflowing negative number', '[f(x=-1e999)]'),
      ('a JSON overflowing number', '[{"name":"f","arguments":{"x":1e999}}]'),
      (
        'a JSON value nested too deep',
        '[{"name":"f","arguments":{"x":${nested('[', ']', 200)}}}]',
      ),
    ]) {
      test('$name takes no call', () {
        final parsed = Lfm2Handler().parse(
          'Before<|tool_call_start|>$payload<|tool_call_end|>',
        );
        expect(parsed.toolCalls, isEmpty);
        expect(parsed.content, 'Before');
      });
    }
  });

  test('still reads a list only the loose parser understands', () {
    _expectCalls(
      Lfm2Handler().parse(
        '<|tool_call_start|>[search(query=llama)]<|tool_call_end|>',
      ),
      '',
      [('search', '{"query":"llama"}')],
    );
    _expectCalls(
      Lfm2Handler().parse(
        '<|tool_call_start|>search(query="llama")<|tool_call_end|>',
      ),
      '',
      [('search', '{"query":"llama"}')],
    );
  });

  group('required tool choice grammar', () {
    LlamaChatTemplateResult render(
      List<ToolDefinition> tools, {
      bool parallel = false,
      String system = '',
      ToolChoice toolChoice = ToolChoice.required,
    }) => Lfm2Handler().render(
      templateSource: '{{ messages[0]["content"] }}',
      messages: [
        if (system.isNotEmpty)
          LlamaChatMessage.fromText(role: LlamaChatRole.system, text: system),
        const LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'hi'),
      ],
      metadata: {
        internalToolChoiceMetadataKey: toolChoice.name,
        internalParallelToolCallsMetadataKey: parallel.toString(),
      },
      tools: tools,
    );

    final search = ToolDefinition(
      name: 'search',
      description: 'Search',
      parameters: [ToolParam.string('query', required: true)],
      handler: _noop,
    );

    test('takes a second call only when the request allows it', () {
      final single = render([search]).grammar;
      expect(single, contains('root-item'));
      expect(render([search], parallel: true).grammar, isNot(single));
    });

    test('force-json-schema keeps the JSON list and its parallel flag', () {
      final single = render([search], system: 'Force JSON schema.\nSystem');
      expect(single.grammar, contains('root-item'));
      final parallel = render(
        [search],
        system: 'Force JSON schema.\nSystem',
        parallel: true,
      );
      expect(parallel.grammar, isNot(single.grammar));
    });

    test('buildGrammar is the single-call list', () {
      expect(Lfm2Handler().buildGrammar([search]), render([search]).grammar);
    });
  });

  test('Lfm2Handler matches llama.cpp force-json-schema semantics', () {
    final handler = Lfm2Handler();
    final tools = [
      ToolDefinition(
        name: 'search',
        description: 'Search',
        parameters: [ToolParam.string('query', required: true)],
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
    expect(rendered.grammar, isNull);
    expect(rendered.grammarLazy, isFalse);
    expect(rendered.grammarTriggers, isEmpty);
    expect(rendered.preservedTokens, contains('<|tool_call_start|>'));
    expect(rendered.additionalStops, isEmpty);

    final renderedWithMarker = handler.render(
      templateSource: '{{ messages[0]["content"] }}',
      messages: const [
        LlamaChatMessage.fromText(
          role: LlamaChatRole.system,
          text: 'Force JSON schema.\nSystem prompt',
        ),
      ],
      metadata: const {},
      tools: tools,
    );
    expect(renderedWithMarker.prompt, equals('System prompt'));
    expect(renderedWithMarker.grammar, isNotNull);
    expect(renderedWithMarker.grammar, contains('"<|tool_call_start|>"'));
    expect(renderedWithMarker.grammarLazy, isTrue);
    expect(renderedWithMarker.grammarTriggers, hasLength(1));

    final renderedWithRequiredChoice = handler.render(
      templateSource: '{{ messages[0]["content"] }}',
      messages: const [
        LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'hello'),
      ],
      metadata: {internalToolChoiceMetadataKey: ToolChoice.required.name},
      tools: tools,
    );
    expect(renderedWithRequiredChoice.grammar, isNotNull);
    expect(
      renderedWithRequiredChoice.grammar,
      contains('"<|tool_call_start|>"'),
    );
    expect(
      renderedWithRequiredChoice.grammar,
      contains(
        'root-item ::= "{" space root-item-name-kv "," space '
        'root-item-arguments-kv "}" space',
      ),
    );
    expect(renderedWithRequiredChoice.grammarLazy, isFalse);
    expect(renderedWithRequiredChoice.grammarTriggers, hasLength(1));

    final modern = handler.parse(
      '<|tool_call_start|>[{"name":"search","arguments":{"query":"llama"}}]<|tool_call_end|>',
    );
    expect(modern.toolCalls, hasLength(1));
    expect(modern.toolCalls.first.function?.name, equals('search'));
    expect(
      jsonDecode(modern.toolCalls.first.function!.arguments!),
      containsPair('query', 'llama'),
    );

    final pythonStyle = handler.parse(
      '<|tool_call_start|>[search(query=\'llama, dart\', limit=2, exact=true)]<|tool_call_end|>',
    );
    expect(pythonStyle.toolCalls, hasLength(1));
    expect(pythonStyle.toolCalls.first.function?.name, equals('search'));
    expect(jsonDecode(pythonStyle.toolCalls.first.function!.arguments!), {
      'query': 'llama, dart',
      'limit': 2,
      'exact': true,
    });

    final parallelPythonStyle = handler.parse(
      '<|tool_call_start|>[search(query=\'llama\'), search(query=\'dart\')]<|tool_call_end|>',
    );
    expect(parallelPythonStyle.toolCalls, hasLength(2));
    expect(parallelPythonStyle.toolCalls[0].index, 0);
    expect(parallelPythonStyle.toolCalls[1].index, 1);
    expect(parallelPythonStyle.toolCalls[0].function?.name, equals('search'));
    expect(parallelPythonStyle.toolCalls[1].function?.name, equals('search'));

    final inThinking = handler.parse(
      '<think>reasoning <|tool_call_start|>[{"name":"search","arguments":{"query":"llama"}}]<|tool_call_end|></think>',
    );
    expect(inThinking.toolCalls, hasLength(1));
    expect(inThinking.toolCalls.first.function?.name, equals('search'));
    expect(inThinking.reasoningContent, equals('reasoning'));
    expect(inThinking.content, isEmpty);

    final thinkingOnly = handler.parse(
      '<think>plan first</think>final answer',
      parseToolCalls: false,
    );
    expect(thinkingOnly.reasoningContent, equals('plan first'));
    expect(thinkingOnly.content, equals('final answer'));

    final legacy = handler.parse("[search(query='llama')] and text");
    expect(legacy.toolCalls, isEmpty);
    expect(legacy.content, equals("[search(query='llama')] and text"));
  });
}

Future<Object?> _noop(_) async {
  return 'ok';
}

typedef _Call = (String name, String arguments);

void _expectCalls(ChatParseResult parsed, String content, List<_Call> calls) {
  expect(parsed.content, content);
  expect(parsed.toolCalls.map((call) => call.function?.name), [
    for (final (name, _) in calls) name,
  ]);
  expect(
    parsed.toolCalls.map((call) => jsonDecode(call.function!.arguments!)),
    [for (final (_, arguments) in calls) jsonDecode(arguments)],
  );
  expect(parsed.toolCalls.map((call) => call.index), [
    for (var i = 0; i < calls.length; i++) i,
  ]);
}
