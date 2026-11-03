import 'dart:convert';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/core/template/handlers/lfm2_auto_grammar.dart';
import 'package:llamadart/src/core/template/handlers/lfm2_handler.dart';
import 'package:test/test.dart';

import '../../../../support/gbnf_recognizer.dart';

void main() {
  test(
    'singleton strings preserve legacy quote spellings without rewriting',
    () {
      final tools = [
        ToolDefinition(
          name: 'record',
          description: '',
          parameters: [ToolParam.string('value', required: true)],
        ),
      ];
      final grammar = GbnfRecognizer(
        buildLfm2AutoGrammar(tools, parallelToolCalls: false)!,
      );
      final values = [
        r'''"{'path': 'D:\\work', 'message': "'q'r'}"''',
        r'''"{'path': 'D:\\work', 'message': "'q'r'"}"''',
        r"'alpha\\.example\\'.tail'",
      ];
      for (final value in values) {
        final raw =
            '<|tool_call_start|>[record(value=$value)]<|tool_call_end|>';
        expect(grammar.accepts(raw), isTrue, reason: raw);
        final parsed = Lfm2Handler().parseWithTools(raw, tools: tools);
        expect(parsed.toolCalls, hasLength(1), reason: raw);
        expect(jsonDecode(parsed.toolCalls.single.function!.arguments!), {
          'value': value.substring(1, value.length - 1),
        }, reason: raw);
      }
      const ambiguous =
          '<|tool_call_start|>[record(value="{"count":13}")]<|tool_call_end|>';
      expect(grammar.accepts(ambiguous), isTrue);
      expect(
        Lfm2Handler().parseWithTools(ambiguous, tools: tools).toolCalls,
        isEmpty,
      );
    },
  );

  test('unclosed copied paths cannot absorb the completed call and prose', () {
    final tools = [
      ToolDefinition(
        name: 'record',
        description: '',
        parameters: [ToolParam.string('value', required: true)],
      ),
    ];
    final grammar = GbnfRecognizer(
      buildLfm2AutoGrammar(tools, parallelToolCalls: false)!,
    );
    for (final quote in ['"', "'"]) {
      for (final path in [r'prefix/\//-/suffix', r'D:\work\', r'\\server']) {
        final raw =
            '<|tool_call_start|>[record(value=$quote$path)]<|tool_call_end|>';
        expect(grammar.accepts(raw), isTrue, reason: raw);
        expect(grammar.accepts('$raw extra$quote)]<|tool_call_end|>'), isFalse);
        final legacy = Lfm2Handler().parse(raw);
        final candidate = Lfm2Handler().parseWithTools(raw, tools: tools);
        expect(candidate.toolCalls, hasLength(1));
        expect(
          candidate.toolCalls.single.function!.arguments,
          legacy.toolCalls.single.function!.arguments,
        );
      }
    }
  });

  test(
    'plain singleton strings retain copied wire spelling and value types',
    () {
      final tools = [
        ToolDefinition(
          name: 'record',
          description: '',
          parameters: [ToolParam.string('value', required: true)],
        ),
      ];
      final grammar = buildLfm2AutoGrammar(tools, parallelToolCalls: false)!;
      final recognizer = GbnfRecognizer(grammar);
      for (final value in [
        "{'count': 13, 'name': 'item'}",
        r'''{'path': 'D:\\work', 'message': "a\"b"}''',
        "['first', 'second', 'third']",
        "{'items': [1, None, True, {'name': 'item'}]}",
        r'a \ b',
        r'\\server',
        'False',
        '13',
        '서울',
      ]) {
        final raw =
            '<|tool_call_start|>[record(value=$value)]<|tool_call_end|>';
        expect(recognizer.accepts(raw), isTrue, reason: value);
        final parsed = Lfm2Handler().parseWithTools(raw, tools: tools);
        expect(parsed.toolCalls, hasLength(1), reason: value);
        expect(jsonDecode(parsed.toolCalls.single.function!.arguments!), {
          'value': value,
        }, reason: value);
      }
      for (final payload in [
        'record(value={"x":1}, extra=True)',
        'record(value=first, value=second)',
        'record(value=[1),',
        'record(value={"x":1)',
        'unknown(value=first)',
        'record(value=first), record(value=second)',
      ]) {
        expect(
          recognizer.accepts('<|tool_call_start|>[$payload]<|tool_call_end|>'),
          isFalse,
          reason: payload,
        );
      }
    },
  );

  test('copied wire strings do not relax other declarations', () {
    for (final parameters in [
      [ToolParam.string('value')],
      [ToolParam.integer('value', required: true)],
      [
        ToolParam.string('value', required: true),
        ToolParam.boolean('enabled', required: true),
      ],
      [
        ToolParam.enumType('value', values: ['one'], required: true),
      ],
    ]) {
      final grammar = buildLfm2AutoGrammar([
        ToolDefinition(name: 'record', description: '', parameters: parameters),
      ], parallelToolCalls: false)!;
      final extra = parameters.length == 2 ? ', enabled=True' : '';
      for (final value in ["{'count':13}", '[1,2]', 'word']) {
        expect(
          GbnfRecognizer(grammar).accepts(
            '<|tool_call_start|>[record(value=$value$extra)]<|tool_call_end|>',
          ),
          isFalse,
          reason: '$parameters: $value',
        );
      }
    }
  });

  test('no declared tools adds no grammar', () {
    expect(buildLfm2AutoGrammar(null, parallelToolCalls: false), isNull);
    expect(buildLfm2AutoGrammar([], parallelToolCalls: true), isNull);
  });

  test('rejects an empty enum instead of emitting an accepting fallback', () {
    expect(
      () => buildLfm2AutoGrammar([
        ToolDefinition(
          name: 'choose',
          description: '',
          parameters: [
            ToolParam.enumType('choice', values: [], required: true),
          ],
        ),
      ], parallelToolCalls: false),
      throwsA(isA<LlamaUnsupportedException>()),
    );
  });

  test('rejects enum values whose copied tail escapes the closing quote', () {
    for (final tail in [1, 3, 5]) {
      expect(
        () => buildLfm2AutoGrammar([
          ToolDefinition(
            name: 'choose',
            description: '',
            parameters: [
              ToolParam.enumType(
                'choice',
                values: ['path${'\\' * tail}'],
                required: true,
              ),
              ToolParam.boolean('enabled', required: true),
            ],
          ),
        ], parallelToolCalls: false),
        throwsA(
          isA<LlamaUnsupportedException>().having(
            (error) => error.message,
            'message',
            contains('odd number of backslashes'),
          ),
        ),
      );
    }
  });

  test('bounds unique-argument grammar expansion before generation', () {
    expect(
      () => buildLfm2AutoGrammar([
        ToolDefinition(
          name: 'many',
          description: '',
          parameters: [for (var i = 0; i < 13; i++) ToolParam.string('p$i')],
        ),
      ], parallelToolCalls: true),
      throwsA(isA<LlamaUnsupportedException>()),
    );
  });
}
