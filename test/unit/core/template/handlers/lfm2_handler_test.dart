import 'dart:convert';

import 'package:llamadart/src/core/models/chat/chat_message.dart';
import 'package:llamadart/src/core/models/chat/chat_role.dart';
import 'package:llamadart/src/core/models/chat/chat_template_result.dart';
import 'package:llamadart/src/core/models/inference/tool_choice.dart';
import 'package:llamadart/src/core/models/tools/tool_definition.dart';
import 'package:llamadart/src/core/models/tools/tool_param.dart';
import 'package:llamadart/src/core/template/chat_format.dart';
import 'package:llamadart/src/core/template/handlers/lfm2_handler.dart';
import 'package:llamadart/src/core/template/template_internal_metadata.dart';
import 'package:test/test.dart';

void main() {
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

  group('model output never throws out of parse', () {
    String nested(String open, String close, int depth) =>
        open * depth + close * depth;
    const isJavaScript = identical(0, 0.0);

    for (final (name, payload) in [
      ('an overflowing number', '[f(x=1e999)]'),
      ('an overflowing negative number', '[f(x=-1e999)]'),
      ('a JSON overflowing number', '[{"name":"f","arguments":{"x":1e999}}]'),
      (
        'JSON arguments nested past the wire limit',
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

    for (final quote in ["'", '"']) {
      test('a lone $quote reads as text', () {
        final parsed = Lfm2Handler().parse(
          '<|tool_call_start|>[f(x=$quote)]<|tool_call_end|>',
        );
        expect(
          parsed.toolCalls.single.function?.arguments,
          jsonEncode({'x': quote}),
        );
      });
    }

    for (final depth in [20000, 200000]) {
      final list = nested('[', ']', depth);
      for (final (name, payload) in [
        ('arguments', '[{"name":"f","arguments":{"x":$list}}]'),
        ('arguments themselves', '[{"name":"f","arguments":$list}]'),
        ('a name', '[{"name":$list}]'),
        ('a function', '[{"function":$list}]'),
        ('a whole list', list),
        ('loose JSON', '[f({"x":$list})]'),
      ]) {
        test('$name nested $depth levels take no call', () {
          final parsed = Lfm2Handler().parse(
            'Before<|tool_call_start|>$payload<|tool_call_end|>',
          );
          expect(parsed.toolCalls, isEmpty);
          expect(parsed.content, 'Before');
        });
      }

      for (final (name, payload) in [
        ('an id', '[{"name":"f","id":$list,"arguments":{"a":1}}]'),
        (
          'a function id',
          '[{"function":{"name":"f","id":$list,"arguments":{"a":1}}}]',
        ),
        ('another field', '[{"name":"f","junk":$list,"arguments":{"a":1}}]'),
      ]) {
        test('$name nested $depth levels does not lose the VM call', () {
          final calls = Lfm2Handler()
              .parse('<|tool_call_start|>$payload<|tool_call_end|>')
              .toolCalls;
          if (isJavaScript) {
            expect(calls, isEmpty);
          } else {
            expect(calls.single.function?.arguments, '{"a":1}');
          }
        });
      }
    }

    test('a deep id stringifies as toString would', () {
      final id = nested('[', ']', 20000);
      final calls = Lfm2Handler()
          .parse('<|tool_call_start|>[{"name":"f","id":$id}]<|tool_call_end|>')
          .toolCalls;
      expect(
        isJavaScript ? calls : calls.single.id,
        isJavaScript ? isEmpty : id,
      );
    });

    test('brackets in a string do not count as nesting', () {
      final text = '[' * 200000;
      final calls = Lfm2Handler()
          .parse(
            '<|tool_call_start|>[{"name":"f","arguments":{"x":"$text"}}]'
            '<|tool_call_end|>',
          )
          .toolCalls;
      expect(calls.single.function?.arguments, jsonEncode({'x': text}));
    });

    test('keeps a call with nesting JavaScript still reads', () {
      final id = nested('[', ']', 4000);
      final call = Lfm2Handler()
          .parse('<|tool_call_start|>[{"name":"f","id":$id}]<|tool_call_end|>')
          .toolCalls
          .single;
      expect(call.id, id);
    });
  });

  // llama.cpp reads these differently, by schema. A parser that follows it
  // needs the tool schemas: https://github.com/leehack/llamadart/issues/1610
  group('reads a Python-style list as it always did', () {
    for (final (arguments, expected) in <(String, Object)>[
      ('x=True', {'x': 'True'}),
      ('x=None', {'x': 'None'}),
      ('x=False', {'x': 'False'}),
      ('x=false', {'x': false}),
      ('config={"a": 1}', {'a': 1}),
      ('arguments={"a": 1}', {'a': 1}),
      ("text={'a': 1}", {'text': "{'a': 1}"}),
      (r'''x="print('C:\\temp')"''', {'x': r"print('C:\\temp')"}),
      (r"x='it\'s ok'", {'x': r"it\'s ok"}),
      (r's="s/\//-/g"', {'s': r's/\//-/g'}),
      (r'x="caf\u00e9"', {'x': r'caf\u00e9'}),
    ]) {
      test(arguments, () {
        final parsed = Lfm2Handler().parse(
          '<|tool_call_start|>[f($arguments)]<|tool_call_end|>',
        );
        expect(
          jsonDecode(parsed.toolCalls.single.function!.arguments!),
          expected,
        );
      });
    }

    test('takes no call from name()', () {
      expect(
        Lfm2Handler()
            .parse('<|tool_call_start|>[f()]<|tool_call_end|>')
            .toolCalls,
        isEmpty,
      );
    });

    test('keeps a JSON id of infinity as text', () {
      expect(
        Lfm2Handler()
            .parse(
              '<|tool_call_start|>[{"name":"f","id":1e999}]<|tool_call_end|>',
            )
            .toolCalls
            .single
            .id,
        'Infinity',
      );
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
