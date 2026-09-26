import 'dart:convert';

import 'package:llamadart/src/core/template/tool_call_parsing_utils.dart';
import 'package:test/test.dart';

void main() {
  group('ToolCallParsingUtils.literalOpening', () {
    test('finds the first whole or partial opening', () {
      const openings = ['<tool_call>', '[TOOL_CALLS]'];
      expect(
        ToolCallParsingUtils.literalOpening(
          'a [TOOL_CALLS] <tool_call>',
          openings,
        ),
        2,
      );
      expect(ToolCallParsingUtils.literalOpening('a <tool', openings), 2);
      expect(ToolCallParsingUtils.literalOpening('a [TOOL_CALLS', openings), 2);
      expect(
        ToolCallParsingUtils.literalOpening('a <tools> [x]', openings),
        13,
      );
    });

    test('returns the earliest whole or partial opening', () {
      expect(ToolCallParsingUtils.literalOpening('ab <XYZ', ['c', '<XYZW']), 3);
      expect(
        ToolCallParsingUtils.literalOpening('ab <XY c', ['c', '<XYZW']),
        7,
      );
    });

    test('starts at from', () {
      expect(ToolCallParsingUtils.literalOpening('<a> <a>', ['<a>'], 1), 4);
      expect(ToolCallParsingUtils.literalOpening('<a> <', ['<a>'], 5), 5);
    });
  });

  group('ToolCallParsingUtils', () {
    test(
      'rejects duplicate object keys before JSON decoding collapses them',
      () {
        expect(
          ToolCallParsingUtils.hasUniqueJsonObjectKeys(
            '{"outer":{"city":"Seoul","c\\u0069ty":"Tokyo"}}',
          ),
          isFalse,
        );
        expect(
          ToolCallParsingUtils.hasUniqueJsonObjectKeys(
            '[{"city":"Seoul"},{"city":"Tokyo"}]',
          ),
          isTrue,
        );
        expect(
          ToolCallParsingUtils.hasUniqueJsonObjectKeys('{"city":'),
          isFalse,
        );
      },
    );

    test('decodes JSON objects', () {
      final decoded = ToolCallParsingUtils.decodeJsonObject(
        '{"name":"get_weather","arguments":{"city":"Seoul"}}',
      );

      expect(decoded, {
        'name': 'get_weather',
        'arguments': {'city': 'Seoul'},
      });
    });

    test('coerces dynamic maps to string-keyed maps', () {
      final coerced = ToolCallParsingUtils.coerceMap(<Object, Object>{
        'city': 'Seoul',
        7: true,
      });

      expect(coerced, {'city': 'Seoul', '7': true});
      expect(ToolCallParsingUtils.coerceMap('nope'), isNull);
    });

    test('decodes map-shaped values from objects and strings', () {
      expect(
        ToolCallParsingUtils.decodeJsonMapValue(<Object, Object>{
          'city': 'Seoul',
        }),
        equals(<String, dynamic>{'city': 'Seoul'}),
      );
      expect(
        ToolCallParsingUtils.decodeJsonMapValue('{"city":"Seoul"}'),
        equals(<String, dynamic>{'city': 'Seoul'}),
      );
      expect(ToolCallParsingUtils.decodeJsonMapValue('[1,2,3]'), isNull);
    });

    test('decodes arbitrary JSON values', () {
      expect(
        ToolCallParsingUtils.decodeJsonValue('{"city":"Seoul"}'),
        isA<Map>(),
      );
      expect(ToolCallParsingUtils.decodeJsonValue('[1,2,3]'), isA<List>());
      expect(ToolCallParsingUtils.decodeJsonValue(' 42 ', trimInput: true), 42);
      expect(ToolCallParsingUtils.decodeJsonValue('not-json'), isNull);
    });

    test('falls back to strings when JSON decoding fails', () {
      expect(ToolCallParsingUtils.decodeJsonValueOrString('42'), 42);
      expect(ToolCallParsingUtils.decodeJsonValueOrString('null'), isNull);
      expect(ToolCallParsingUtils.decodeJsonValueOrString('Seoul'), 'Seoul');
      expect(
        ToolCallParsingUtils.decodeJsonValueOrString(
          '  Seoul  ',
          trimInput: true,
        ),
        'Seoul',
      );
    });

    test('encodes arguments consistently', () {
      expect(ToolCallParsingUtils.encodeArguments(null), '');
      expect(ToolCallParsingUtils.encodeArguments('raw'), 'raw');
      expect(
        jsonDecode(
          ToolCallParsingUtils.encodeArguments(<String, dynamic>{
            'city': 'Seoul',
          }),
        ),
        containsPair('city', 'Seoul'),
      );
    });

    test('normalizes JSON argument payloads', () {
      expect(
        ToolCallParsingUtils.normalizeJsonArguments('{"city":"Seoul"}'),
        '{"city":"Seoul"}',
      );
      expect(
        ToolCallParsingUtils.normalizeJsonArguments('  42  ', trimInput: true),
        '42',
      );
      expect(
        ToolCallParsingUtils.normalizeJsonArguments(
          'true',
          wrapScalarsAsValue: true,
        ),
        '{"value":true}',
      );
      expect(
        ToolCallParsingUtils.normalizeJsonArguments('', emptyFallback: '{}'),
        '{}',
      );
      expect(
        ToolCallParsingUtils.normalizeJsonArguments('not-json'),
        'not-json',
      );
    });

    test('extracts a leading JSON value slice', () {
      final objectSlice = ToolCallParsingUtils.extractLeadingJsonValue(
        '{"city":"Seoul"} trailing',
        0,
      );
      final scalarSlice = ToolCallParsingUtils.extractLeadingJsonValue(
        'true next',
        0,
      );

      expect(objectSlice!.end, 16);
      expect(objectSlice.value, {'city': 'Seoul'});
      expect(scalarSlice!.end, 4);
      expect(scalarSlice.value, isTrue);
      expect(ToolCallParsingUtils.extractLeadingJsonValue('oops', 0), isNull);
    });

    test('extracts a leading JSON null value', () {
      final parsed = ToolCallParsingUtils.extractLeadingJsonValue('null,', 0);

      expect(parsed!.value, isNull);
      expect(parsed.end, 4);
    });

    test('extracts the first embedded JSON object', () {
      final object = ToolCallParsingUtils.extractFirstJsonObject(
        'before {"city":"Seoul"} after',
      );

      expect(object, equals(<String, dynamic>{'city': 'Seoul'}));
      expect(
        ToolCallParsingUtils.extractFirstJsonObject('no object here'),
        isNull,
      );
    });

    test('parses tool call arrays with configurable keys', () {
      final parsed = ToolCallParsingUtils.parseToolCallArray(
        <Object?>[
          <String, Object?>{
            'tool_name': 'get_weather',
            'parameters': <String, Object?>{'city': 'Seoul'},
            'tool_call_id': 'abc',
          },
        ],
        nameKeys: const <String>['tool_name'],
        argumentKeys: const <String>['parameters'],
        idKeys: const <String>['tool_call_id'],
        assignFallbackIds: false,
      );

      expect(parsed, hasLength(1));
      expect(parsed!.single.id, 'abc');
      expect(parsed.single.function?.name, 'get_weather');
      expect(
        jsonDecode(parsed.single.function!.arguments!),
        containsPair('city', 'Seoul'),
      );
    });

    test('parses OpenAI-style function tool call arrays', () {
      final parsed = ToolCallParsingUtils.parseToolCallArray(<Object?>[
        <String, Object?>{
          'id': 'call_1',
          'type': 'function',
          'function': <String, Object?>{
            'name': 'get_weather',
            'arguments': <String, Object?>{'location': 'Seoul'},
          },
        },
      ]);

      expect(parsed, hasLength(1));
      expect(parsed!.single.id, 'call_1');
      expect(parsed.single.type, 'function');
      expect(parsed.single.function?.name, 'get_weather');
      expect(
        jsonDecode(parsed.single.function!.arguments!),
        containsPair('location', 'Seoul'),
      );
    });

    test('supports non-strict tool call arrays with custom start index', () {
      final parsed = ToolCallParsingUtils.parseToolCallArray(
        <Object?>[
          'skip-me',
          <String, Object?>{
            'name': 'get_weather',
            'arguments': {'city': 'Seoul'},
          },
        ],
        failOnInvalidItem: false,
        startIndex: 3,
      );

      expect(parsed, hasLength(1));
      expect(parsed!.single.index, 3);
      expect(parsed.single.function?.name, 'get_weather');
    });

    test('parses single-key tool call arrays', () {
      final parsed = ToolCallParsingUtils.parseSingleKeyToolCallArray(<Object?>[
        <String, Object?>{
          'get_weather': <String, Object?>{'city': 'Seoul'},
        },
      ]);

      expect(parsed, hasLength(1));
      expect(parsed!.single.function?.name, 'get_weather');
      expect(
        jsonDecode(parsed.single.function!.arguments!),
        containsPair('city', 'Seoul'),
      );
    });

    test(
      'fails strict single-key tool call array parsing on malformed items',
      () {
        final parsed = ToolCallParsingUtils.parseSingleKeyToolCallArray(
          <Object?>[
            <String, Object?>{
              'get_weather': <String, Object?>{'city': 'Seoul'},
            },
            <String, Object?>{
              'get_time': <String, Object?>{'city': 'Busan'},
              'extra': true,
            },
          ],
        );

        expect(parsed, isNull);
      },
    );

    test('fails strict tool call array parsing on malformed items', () {
      final parsed = ToolCallParsingUtils.parseToolCallArray(<Object?>[
        <String, Object?>{
          'name': 'get_weather',
          'arguments': {'city': 'Seoul'},
        },
        <String, Object?>{
          'arguments': {'city': 'Busan'},
        },
      ]);

      expect(parsed, isNull);
    });

    test('creates tool calls with configurable fallback ids', () {
      final withFallback = ToolCallParsingUtils.createFunctionToolCall(
        index: 2,
        name: 'get_weather',
        arguments: <String, dynamic>{'city': 'Seoul'},
      );
      final withoutFallback = ToolCallParsingUtils.createFunctionToolCall(
        index: 2,
        name: 'get_weather',
        arguments: const <String, dynamic>{'city': 'Seoul'},
        assignFallbackId: false,
      );

      expect(withFallback.id, 'call_2');
      expect(withoutFallback.id, isNull);
      expect(
        jsonDecode(withFallback.function!.arguments!),
        containsPair('city', 'Seoul'),
      );
    });
  });
}
