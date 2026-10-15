import 'dart:convert';

import 'package:test/test.dart';
import 'package:llamadart/src/core/grammar/json_schema_converter.dart';

import '../../../support/llama_cpp_grammar_load.dart';

const _maxCount = 1024;
const _maxGroupDepth = 32;

String _nestedGroups(int depth) => '^${'(' * depth}a${')' * depth}\$';

void main() {
  group('llama.cpp grammar loading', () {
    // Boundaries checked against b10549 test-gbnf-validator.
    test('the repetition emulator matches llama.cpp at the limit', () {
      for (final (grammar, loads) in [
        ('root ::= ("a" "b"{0,1998})?', true),
        ('root ::= ("a" "b"{0,1999})?', false),
        ('root ::= ("a" b){0,999}\nb ::= "b"', true),
        ('root ::= ("a" b){0,1000}\nb ::= "b"', false),
      ]) {
        expect(
          llamaCppRepetitionRejection(grammar) == null,
          loads,
          reason: grammar,
        );
      }
    });

    for (final MapEntry(key: label, value: names) in largeKeySets.entries) {
      test('open objects with $label load and exclude declared keys', () {
        final grammar = JsonSchemaConverter.convert({
          'type': 'object',
          'properties': {
            for (final name in names) name: {'type': 'integer'},
          },
          'additionalProperties': true,
        });
        expect(llamaCppRepetitionRejection(grammar), isNull);
        final key = _ruleRegExp(grammar, 'root-additional-k');
        for (final name in [names.first, names.last]) {
          expect(key.hasMatch(jsonEncode(name)), isFalse, reason: name);
          expect(key.hasMatch(jsonEncode('${name}x')), isTrue, reason: name);
        }
      });
    }

    test('objects with 1023 closed optional properties load', () {
      final grammar = JsonSchemaConverter.convert({
        'type': 'object',
        'properties': {
          for (final name in largeKeySets['1023 properties']!)
            name: {'type': 'integer'},
        },
        'additionalProperties': false,
      });
      expect(llamaCppRepetitionRejection(grammar), isNull);
    });

    test('key exclusion beyond its budget falls back to a string key', () {
      final grammar = JsonSchemaConverter.convert({
        'type': 'object',
        'properties': {
          for (final name in overBudgetKeySet) name: {'type': 'integer'},
        },
        'additionalProperties': true,
      });
      expect(
        grammar,
        contains('root-additional-kv ::= string ":" space value'),
      );
      expect(grammar, isNot(contains('root-additional-k ::=')));
      expect(llamaCppRepetitionRejection(grammar), isNull);
    });

    test('maxItems 1999 loads for every minItems and item type', () {
      for (final item in boundedArrayItemSchemas) {
        for (final minItems in [0, 1, 1998, 1999]) {
          final grammar = JsonSchemaConverter.convert({
            'type': 'array',
            'items': item,
            'minItems': minItems,
            'maxItems': 1999,
          });
          expect(
            llamaCppRepetitionRejection(grammar),
            isNull,
            reason: '$item minItems $minItems',
          );
        }
      }
    });
  });

  group('JsonSchemaConverter', () {
    test('converts simple string schema', () {
      final grammar = JsonSchemaConverter.convert({'type': 'string'});
      expect(grammar, contains('root ::='));
      expect(grammar, contains('char'));
    });

    test('converts simple boolean schema', () {
      final grammar = JsonSchemaConverter.convert({'type': 'boolean'});
      expect(grammar, contains('root ::='));
      expect(grammar, contains('"true"'));
      expect(grammar, contains('"false"'));
    });

    test('converts simple number schema', () {
      final grammar = JsonSchemaConverter.convert({'type': 'number'});
      expect(grammar, contains('root ::='));
      expect(grammar, contains('integral-part'));
      expect(grammar, contains('decimal-part'));
    });

    test('converts simple integer schema', () {
      final grammar = JsonSchemaConverter.convert({'type': 'integer'});
      expect(grammar, contains('root ::='));
      expect(grammar, contains('integral-part'));
    });

    test('converts null schema', () {
      final grammar = JsonSchemaConverter.convert({'type': 'null'});
      expect(grammar, contains('"null"'));
    });

    test('converts enum schema', () {
      final grammar = JsonSchemaConverter.convert({
        'type': 'string',
        'enum': ['red', 'green', 'blue'],
      });
      expect(grammar, contains('root ::='));
      // Enums use escaped quotes: \"red\"
      expect(grammar, contains(r'\"red\"'));
      expect(grammar, contains(r'\"green\"'));
      expect(grammar, contains(r'\"blue\"'));
    });

    test('converts const schema', () {
      final grammar = JsonSchemaConverter.convert({'const': 'hello'});
      expect(grammar, contains('root ::='));
      expect(grammar, contains(r'\"hello\"'));
    });

    test('converts simple object schema', () {
      final grammar = JsonSchemaConverter.convert({
        'type': 'object',
        'properties': {
          'name': {'type': 'string'},
          'age': {'type': 'integer'},
        },
        'required': ['name'],
      });
      expect(grammar, contains('root ::='));
      // Property keys in GBNF use escaped quotes
      expect(grammar, contains('root-name-kv'));
      expect(grammar, contains('root-age-kv'));
      expect(grammar, contains(r'\"name\"'));
      expect(grammar, contains(r'\"age\"'));
    });

    test('converts object with all required properties', () {
      final grammar = JsonSchemaConverter.convert({
        'type': 'object',
        'properties': {
          'x': {'type': 'number'},
          'y': {'type': 'number'},
        },
        'required': ['x', 'y'],
      });
      expect(grammar, contains('root ::='));
      expect(grammar, contains(r'\"x\"'));
      expect(grammar, contains(r'\"y\"'));
    });

    test('converts array schema with items', () {
      final grammar = JsonSchemaConverter.convert({
        'type': 'array',
        'items': {'type': 'string'},
      });
      expect(grammar, contains('root ::='));
      expect(grammar, contains('"["'));
      expect(grammar, contains('"]"'));
    });

    test('converts array with minItems/maxItems', () {
      final grammar = JsonSchemaConverter.convert({
        'type': 'array',
        'items': {'type': 'integer'},
        'minItems': 1,
        'maxItems': 5,
      });
      expect(grammar, contains('root ::='));
    });

    test('converts oneOf schema', () {
      final grammar = JsonSchemaConverter.convert({
        'oneOf': [
          {'type': 'string'},
          {'type': 'integer'},
        ],
      });
      expect(grammar, contains('root ::='));
      expect(grammar, contains('|'));
    });

    test('converts anyOf schema', () {
      final grammar = JsonSchemaConverter.convert({
        'anyOf': [
          {'type': 'boolean'},
          {'type': 'null'},
        ],
      });
      expect(grammar, contains('root ::='));
      expect(grammar, contains('|'));
    });

    test('converts nested object schema', () {
      final grammar = JsonSchemaConverter.convert({
        'type': 'object',
        'properties': {
          'location': {
            'type': 'object',
            'properties': {
              'lat': {'type': 'number'},
              'lon': {'type': 'number'},
            },
            'required': ['lat', 'lon'],
          },
        },
        'required': ['location'],
      });
      expect(grammar, contains('root ::='));
      expect(grammar, contains(r'\"location\"'));
      expect(grammar, contains(r'\"lat\"'));
      expect(grammar, contains(r'\"lon\"'));
    });

    test('converts empty schema to generic value', () {
      final grammar = JsonSchemaConverter.convert({});
      expect(grammar, contains('root ::='));
    });

    test('converts string with minLength/maxLength', () {
      final grammar = JsonSchemaConverter.convert({
        'type': 'string',
        'minLength': 3,
        'maxLength': 10,
      });
      expect(grammar, contains('root ::='));
      expect(grammar, contains('char'));
    });

    test('converts an anchored character-class repetition pattern', () {
      final grammar = JsonSchemaConverter.convert({
        'type': 'string',
        'pattern': r'^[a-zA-Z0-9]{9}$',
      });

      expect(
        grammar,
        equals(
          'root ::= "\\"" (root-1{9,9}) "\\"" space\n'
          'root-1 ::= [a-zA-Z0-9]\n'
          '${r'space ::= | " " | "\n"{1,2} [ \t]{0,20}'}\n',
        ),
      );
    });

    test('converts pattern groups, alternation and quantifiers', () {
      String rootOf(String pattern) => JsonSchemaConverter.convert({
        'type': 'string',
        'pattern': pattern,
      }).split('\n').first;

      expect(rootOf(r'^abc$'), equals('root ::= "\\"" ("abc") "\\"" space'));
      expect(
        rootOf(r'^(foo|bar)$'),
        equals('root ::= "\\"" (("foo" | "bar")) "\\"" space'),
      );
      expect(
        rootOf(r'^x(?:y|z)w$'),
        equals('root ::= "\\"" ("x" ("y" | "z") "w") "\\"" space'),
      );
      expect(
        rootOf(r'^ab+c$'),
        equals('root ::= "\\"" ("a" "b"+ "c") "\\"" space'),
      );
      expect(
        rootOf(r'^a?b*$'),
        equals('root ::= "\\"" ("a"? "b"*) "\\"" space'),
      );
      expect(rootOf(r'^a\.b$'), equals('root ::= "\\"" ("a.b") "\\"" space'));
      expect(
        rootOf(r'^[a-z0-9-]+$'),
        equals('root ::= "\\"" ([a-z0-9-]+) "\\"" space'),
      );
      expect(
        rootOf(r'^[ -!]+$'),
        equals('root ::= "\\"" ([ -!]+) "\\"" space'),
      );
      expect(
        rootOf('^a{$_maxCount}\$'),
        equals('root ::= "\\"" (root-1{$_maxCount,$_maxCount}) "\\"" space'),
      );
      expect(
        rootOf(r'^[0-9]{2}$'),
        equals('root ::= "\\"" (root-1{2,2}) "\\"" space'),
      );
      expect(
        rootOf(r'^[0-9]{2,}$'),
        equals('root ::= "\\"" (root-1{2,}) "\\"" space'),
      );
      expect(
        rootOf(r'^(?:ab){2,3}$'),
        equals('root ::= "\\"" (root-1{2,3}) "\\"" space'),
      );
    });

    test('falls back to the plain string rule for unsupported patterns', () {
      final plain = JsonSchemaConverter.convert({'type': 'string'});

      const unsupported = [
        '[a-z]+',
        r'^[a-z]+',
        r'\d{3}$',
        r'^\d{3}$',
        r'^\w+$',
        r'^\s$',
        r'^a\bb$',
        r'^.{3}$',
        r'^[^"]+$',
        r'^[\x00-\x1f]$',
        r'^(?=x)a$',
        r'^(a)\1$',
        r'^a\\b$',
        r'^"$',
        r'^a{3,2}$',
        r'^a{0}$',
        r'^a{}$',
        r'^a{2$',
        r'^a**$',
        r'^*a$',
        r'^(ab$',
        r'^ab)$',
        r'^[a-z$',
        r'^[]$',
        r'^()$',
        r'^a|$',
        r'^$',
        r'^é$',
        r'^a|b$',
        r'^(a|b)|c$',
        r'^[ -~]+$',
        r'^[!-~]+$',
        r'^[A-_]$',
        r'^[X-a]+$',
        r'^[ -~]{2}$',
        r'^[a-z]{2}\d$',
        r'^(?:ab){2}\d$',
        '^a{${_maxCount + 1}}\$',
        r'^a{10000}$',
      ];

      for (final pattern in unsupported) {
        expect(
          JsonSchemaConverter.convert({'type': 'string', 'pattern': pattern}),
          equals(plain),
          reason: 'pattern $pattern must not constrain the string rule',
        );
      }
    });

    test('applies pattern in preference to minLength/maxLength', () {
      final grammar = JsonSchemaConverter.convert({
        'type': 'string',
        'pattern': r'^[a-z]{2}$',
        'minLength': 5,
        'maxLength': 8,
      });

      expect(grammar, startsWith('root ::= "\\"" (root-1{2,2}) "\\"" space'));
      expect(grammar, contains('root-1 ::= [a-z]'));
      expect(grammar, isNot(contains('char')));
    });

    test('a supported pattern discards minLength/maxLength', () {
      final grammar = JsonSchemaConverter.convert({
        'type': 'string',
        'pattern': r'^[a-z]+$',
        'maxLength': 10,
      });

      expect(grammar, startsWith('root ::= "\\"" ([a-z]+) "\\"" space'));
      expect(
        grammar,
        equals(
          JsonSchemaConverter.convert({
            'type': 'string',
            'pattern': r'^[a-z]+$',
          }),
        ),
      );
    });

    test('compiles group nesting up to the depth bound', () {
      final grammar = JsonSchemaConverter.convert({
        'type': 'string',
        'pattern': _nestedGroups(_maxGroupDepth),
      });

      expect(grammar, contains('"a"'));
      expect(grammar, isNot(contains('char')));
    });

    test('falls back past the group depth bound instead of overflowing', () {
      final plain = JsonSchemaConverter.convert({'type': 'string'});

      for (final depth in [_maxGroupDepth + 1, 512, 20000]) {
        expect(
          JsonSchemaConverter.convert({
            'type': 'string',
            'pattern': _nestedGroups(depth),
          }),
          equals(plain),
          reason: '$depth nested groups must fall back, not throw',
        );
      }
    });

    test('keeps maxLength when nesting exceeds the group depth bound', () {
      expect(
        JsonSchemaConverter.convert({
          'type': 'string',
          'pattern': _nestedGroups(_maxGroupDepth + 1),
          'maxLength': 10,
        }),
        equals(
          JsonSchemaConverter.convert({'type': 'string', 'maxLength': 10}),
        ),
      );
    });

    test('applies pattern to a schema without an explicit type', () {
      final grammar = JsonSchemaConverter.convert({'pattern': r'^[a-z]{2}$'});

      expect(grammar, startsWith('root ::= "\\"" (root-1{2,2}) "\\"" space'));
    });

    test('keeps minLength/maxLength when the pattern is unsupported', () {
      expect(
        JsonSchemaConverter.convert({
          'type': 'string',
          'pattern': r'^\d+$',
          'minLength': 5,
          'maxLength': 8,
        }),
        equals(
          JsonSchemaConverter.convert({
            'type': 'string',
            'minLength': 5,
            'maxLength': 8,
          }),
        ),
      );
    });

    test('falls back without leaving hoisted sub-rules behind', () {
      final plain = JsonSchemaConverter.convert({'type': 'string'});

      expect(
        JsonSchemaConverter.convert({
          'type': 'string',
          'pattern': r'^[a-z]{2}\d$',
        }),
        equals(plain),
      );
      expect(JsonSchemaConverter.convert({'pattern': r'^\d+$'}), equals(plain));
    });

    test('constrains a pattern-bearing object property', () {
      final grammar = JsonSchemaConverter.convert({
        'type': 'object',
        'properties': {
          'id': {'type': 'string', 'pattern': r'^[a-zA-Z0-9]{9}$'},
        },
        'required': ['id'],
      });

      expect(
        grammar,
        contains('root-id ::= "\\"" (root-id-1{9,9}) "\\"" space'),
      );
      expect(grammar, contains('root-id-1 ::= [a-zA-Z0-9]'));
      expect(
        grammar,
        contains('root-id-kv ::= "\\"id\\"" space ":" space root-id'),
      );
    });

    test(r'handles $ref resolution', () {
      final grammar = JsonSchemaConverter.convert({
        'type': 'object',
        'properties': {
          'address': {r'$ref': '#/definitions/Address'},
        },
        'required': ['address'],
        'definitions': {
          'Address': {
            'type': 'object',
            'properties': {
              'street': {'type': 'string'},
              'city': {'type': 'string'},
            },
            'required': ['street', 'city'],
          },
        },
      });
      expect(grammar, contains('root ::='));
      expect(grammar, contains(r'\"street\"'));
      expect(grammar, contains(r'\"city\"'));
    });

    test(r'resolves a $ref nested inside another $ref target', () {
      // Node has a $ref AND the target itself contains a nested $ref. The
      // nested ref must be resolved (no dangling rule / invalid GBNF).
      final grammar = JsonSchemaConverter.convert({
        'type': 'object',
        'properties': {
          'person': {r'$ref': '#/definitions/Person'},
        },
        'required': ['person'],
        'definitions': {
          'Person': {
            'type': 'object',
            'properties': {
              'home': {r'$ref': '#/definitions/Address'},
            },
            'required': ['home'],
          },
          'Address': {
            'type': 'object',
            'properties': {
              'city': {'type': 'string'},
            },
            'required': ['city'],
          },
        },
      });
      expect(grammar, contains('root ::='));
      expect(grammar, contains(r'\"home\"'));
      expect(grammar, contains(r'\"city\"'));
      // No rule may reference an undefined rule (dangling ref). Every "ref..."
      // token used on a right-hand side must have its own definition.
      final defined = RegExp(
        r'^([A-Za-z0-9-]+) ::=',
        multiLine: true,
      ).allMatches(grammar).map((m) => m.group(1)).toSet();
      final referenced = RegExp(
        r'\bref[A-Za-z0-9-]+\b',
      ).allMatches(grammar).map((m) => m.group(0)!).toSet();
      expect(referenced.difference(defined), isEmpty);
    });

    test(r'throws on an unresolvable external $ref', () {
      expect(
        () => JsonSchemaConverter.convert({
          'type': 'object',
          'properties': {
            'x': {r'$ref': 'https://example.com/schema.json#/X'},
          },
        }),
        throwsA(isA<StateError>()),
      );
    });

    test('converts array type union', () {
      final grammar = JsonSchemaConverter.convert({
        'type': ['string', 'null'],
      });
      expect(grammar, contains('root ::='));
      expect(grammar, contains('|'));
    });

    test('produces valid GBNF syntax', () {
      final grammar = JsonSchemaConverter.convert({
        'type': 'object',
        'properties': {
          'name': {'type': 'string'},
          'count': {'type': 'integer'},
          'active': {'type': 'boolean'},
        },
        'required': ['name'],
      });

      // Every rule should have ::= separator
      for (final line in grammar.split('\n')) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        expect(
          trimmed,
          contains(' ::= '),
          reason: 'Rule should use ::= separator: $trimmed',
        );
      }
    });

    test('handles allOf composition', () {
      final grammar = JsonSchemaConverter.convert({
        'allOf': [
          {
            'type': 'object',
            'properties': {
              'name': {'type': 'string'},
            },
          },
          {
            'type': 'object',
            'properties': {
              'age': {'type': 'integer'},
            },
          },
        ],
      });
      expect(grammar, contains('root ::='));
      expect(grammar, contains(r'\"name\"'));
      expect(grammar, contains(r'\"age\"'));
    });

    group('open object extra keys', () {
      final schema = <String, dynamic>{
        'type': 'object',
        'properties': {
          'city': {'type': 'string'},
          'ci': {'type': 'boolean'},
          'count': {'type': 'integer'},
          'mode': {
            'enum': ['a', 'b'],
          },
          'a"b': {'type': 'null'},
          'é': {'type': 'null'},
        },
        'required': ['city'],
        'additionalProperties': true,
      };

      test('use a key rule that excludes every declared key', () {
        final grammar = JsonSchemaConverter.convert(schema);
        expect(
          grammar,
          contains('root-additional-kv ::= root-additional-k ":" space value'),
        );
        final key = _ruleRegExp(grammar, 'root-additional-k');
        for (final name in schema['properties'].keys) {
          expect(key.hasMatch(jsonEncode(name)), isFalse, reason: name);
        }
        for (final name in [
          'other',
          'c',
          'cit',
          'cityx',
          'counter',
          'mod',
          'a"c',
          'a',
          'éa',
          '',
          r'\',
          'x\ny',
        ]) {
          expect(key.hasMatch(jsonEncode(name)), isTrue, reason: name);
        }
        expect(key.hasMatch(r'"\"'), isFalse, reason: 'unterminated');
        expect(key.hasMatch('"a\u0001"'), isFalse, reason: 'control');
      });

      test('exclude non-BMP keys as single characters', () {
        final grammar = JsonSchemaConverter.convert({
          'type': 'object',
          'properties': {
            for (final name in ['é', 'éa', '😀', '😀b'])
              name: {'type': 'boolean'},
          },
          'additionalProperties': true,
        });
        final key = _ruleRegExp(grammar, 'root-additional-k');
        for (final name in ['é', 'éa', '😀', '😀b']) {
          expect(key.hasMatch(jsonEncode(name)), isFalse, reason: name);
        }
        for (final name in ['😀c', '😀bc', '😁', 'éb', 'é😀']) {
          expect(key.hasMatch(jsonEncode(name)), isTrue, reason: name);
        }
      });

      test('keep closed objects free of an extra-key slot', () {
        final grammar = JsonSchemaConverter.convert({
          ...schema,
          'additionalProperties': false,
        });
        expect(grammar, isNot(contains('additional')));
      });
    });
  });
}

/// Translates a non-recursive GBNF rule into an anchored [RegExp], enough to
/// check key rules built from literals, classes, groups and repetition.
RegExp _ruleRegExp(String grammar, String rule) {
  final rules = {
    for (final line in const LineSplitter().convert(grammar))
      if (line.contains(' ::= '))
        line.substring(0, line.indexOf(' ::= ')): line.substring(
          line.indexOf(' ::= ') + 5,
        ),
  };
  String expand(String body) {
    final out = StringBuffer();
    var i = 0;
    while (i < body.length) {
      final c = body[i];
      if (c == ' ') {
        i++;
      } else if (c == '"') {
        final literal = StringBuffer();
        for (i++; body[i] != '"'; i++) {
          if (body[i] == r'\') {
            i++;
            literal.write(body[i] == 'n' ? '\n' : body[i]);
          } else {
            literal.write(body[i]);
          }
        }
        i++;
        out.write('(?:${RegExp.escape(literal.toString())})');
      } else if (c == '[') {
        final start = i;
        for (i++; body[i] != ']'; i++) {
          if (body[i] == r'\') i++;
        }
        i++;
        out.write(
          body
              .substring(start, i)
              .replaceAllMapped(
                RegExp(r'\\U([0-9A-F]{8})'),
                (m) => '\\u{${m[1]}}',
              ),
        );
      } else if (c == '{') {
        final end = body.indexOf('}', i) + 1;
        out.write(body.substring(i, end));
        i = end;
      } else if ('()|?*+'.contains(c)) {
        out.write(c == '(' ? '(?:' : c);
        i++;
      } else {
        final name = RegExp(r'[A-Za-z0-9-]+').matchAsPrefix(body, i)![0]!;
        out.write('(?:${expand(rules[name]!)})');
        i += name.length;
      }
    }
    return out.toString();
  }

  return RegExp('^${expand(rules[rule]!)}\$', unicode: true);
}
