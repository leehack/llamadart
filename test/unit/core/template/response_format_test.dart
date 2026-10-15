import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/core/grammar/json_schema_converter.dart';
import 'package:llamadart/src/core/template/response_format.dart';
import 'package:test/test.dart';

Map<String, dynamic> format(Object? schema) => {
  'type': 'json_schema',
  'json_schema': {'schema': schema},
};

void main() {
  const schema = {
    'type': 'object',
    'properties': {
      'ok': {'type': 'boolean'},
    },
  };

  group('responseFormatSchema', () {
    test('maps supported shapes to the constraining schema', () {
      expect(responseFormatSchema(null), isNull);
      expect(responseFormatSchema(const {'type': 'text'}), isNull);
      expect(responseFormatSchema(const {'type': 'json_object'}), {
        'type': 'object',
      });
      expect(
        responseFormatSchema(const {
          'type': 'json_schema',
          'json_schema': {
            'schema': schema,
            'name': 'status',
            'description': 'Status flag',
            'strict': true,
          },
        }),
        same(schema),
      );
    });

    test('treats null-valued keys as absent', () {
      expect(
        responseFormatSchema(const {'type': 'text', 'json_schema': null}),
        isNull,
      );
      expect(
        responseFormatSchema(const {'type': 'json_object', 'schema': null}),
        {'type': 'object'},
      );
      expect(
        responseFormatSchema(const {
          'type': 'json_schema',
          'schema': null,
          'json_schema': {
            'schema': schema,
            'name': null,
            'description': null,
            'strict': null,
            'schma': null,
          },
        }),
        same(schema),
      );
    });

    test('accepts LlamaStructuredOutput response formats', () {
      final output = LlamaStructuredOutput<Object?>.jsonValueSchema(
        schema: const {'type': 'array'},
        decoder: (value) => value,
        name: 'items',
        description: 'Items',
        strict: false,
      );

      expect(responseFormatSchema(output.responseFormat), {'type': 'array'});
    });

    for (final (format, message) in <(Map<String, dynamic>, String)>[
      (
        const {'type': 'json_shema'},
        "Unsupported responseFormat.type 'json_shema'; expected 'text', "
            "'json_object' or 'json_schema'.",
      ),
      (
        const {'json_object': true},
        "responseFormat.type must be one of 'text', 'json_object' or "
            "'json_schema'; got no type.",
      ),
      (
        const {'type': 'text', 'json_schema': schema},
        "Unsupported responseFormat key 'json_schema' for type 'text'; "
            'supported keys: type.',
      ),
      (
        const {
          'type': 'json_schema',
          'json_schema': {'schma': schema},
        },
        "Unsupported responseFormat.json_schema key 'schma' for type "
            "'json_schema'; supported keys: schema, name, description, strict.",
      ),
      (
        const {'type': 'json_schema', 'json_schema': 'x'},
        "responseFormat.json_schema must be an object with a 'schema' JSON "
            "object for type 'json_schema'.",
      ),
      (
        const {
          'type': 'json_schema',
          'json_schema': {'schema': schema, 'name': 1},
        },
        'responseFormat.json_schema.name must be a string.',
      ),
      (
        {
          'type': 'json_schema',
          'json_schema': {
            'schema': <dynamic, dynamic>{'type': 'object'},
          },
        },
        'responseFormat.json_schema.schema must be a JSON object typed '
            'Map<String, dynamic>, as jsonDecode returns or a '
            '<String, dynamic>{} literal declares; got '
            '${<dynamic, dynamic>{}.runtimeType}.',
      ),
      (
        const {
          'type': 'json_schema',
          'json_schema': {'schema': null},
        },
        'responseFormat.json_schema.schema must be a JSON object typed '
            'Map<String, dynamic>, as jsonDecode returns or a '
            '<String, dynamic>{} literal declares; got none.',
      ),
    ]) {
      test('rejects $format', () {
        expect(
          () => responseFormatSchema(format),
          throwsA(
            isA<LlamaUnsupportedException>().having(
              (error) => error.message,
              'message',
              message,
            ),
          ),
        );
      });
    }
  });

  group('validateResponseFormatSchema', () {
    Matcher throwsTyped<T extends LlamaException>(String message) => throwsA(
      isA<T>().having((error) => error.message, 'message', contains(message)),
    );

    Map<String, dynamic> nestedItems(int levels) {
      Map<String, dynamic> schema = {'type': 'integer'};
      for (var i = 0; i < levels; i++) {
        schema = {'type': 'array', 'items': schema};
      }
      return schema;
    }

    for (final (schema, path) in <(Map<String, dynamic>, String)>[
      ({'type': 'integer', 'minimum': 1, 'maximum': 10}, r'$.minimum'),
      ({'type': 'integer', 'maximum': 10}, r'$.maximum'),
      ({'type': 'integer', 'exclusiveMinimum': 3}, r'$.exclusiveMinimum'),
      ({'type': 'integer', 'exclusiveMaximum': 3}, r'$.exclusiveMaximum'),
      ({'type': 'number', 'multipleOf': 0.5}, r'$.multipleOf'),
      ({'type': 'string', 'format': 'uuid'}, r'$.format'),
      (
        {
          'type': 'object',
          'properties': {
            'n': {'type': 'integer', 'minimum': 1},
          },
        },
        r'$.properties.n.minimum',
      ),
      (
        {
          'type': 'array',
          'items': {'type': 'string', 'format': 'date-time'},
        },
        r'$.items.format',
      ),
      (
        {
          'type': 'array',
          'items': {'type': 'string'},
          'uniqueItems': true,
        },
        r'$.uniqueItems',
      ),
      (
        {
          'anyOf': [
            {'type': 'null'},
            {'type': 'array', 'contains': <String, dynamic>{}},
          ],
        },
        r'$.anyOf[1].contains',
      ),
      (
        {
          'oneOf': [
            {'type': 'object', 'minProperties': 1},
          ],
        },
        r'$.oneOf[0].minProperties',
      ),
      (
        {
          'allOf': [
            {'maxProperties': 1},
          ],
        },
        r'$.allOf[0].maxProperties',
      ),
      (
        {
          r'$defs': {
            'n': {'type': 'number', 'multipleOf': 2},
          },
          r'$ref': r'#/$defs/n',
        },
        r'$.$defs.n.multipleOf',
      ),
      (
        {
          'definitions': {
            'n': {'type': 'string', 'format': 'email'},
          },
          r'$ref': '#/definitions/n',
        },
        r'$.definitions.n.format',
      ),
      (
        {
          'type': 'object',
          'additionalProperties': {
            'type': 'object',
            'propertyNames': {'pattern': r'^a$'},
          },
        },
        r'$.additionalProperties.propertyNames',
      ),
      (
        {
          'type': 'array',
          'prefixItems': [
            {'not': <String, dynamic>{}},
          ],
        },
        r'$.prefixItems[0].not',
      ),
      (
        {
          'type': 'array',
          'items': [
            {'type': 'object', 'patternProperties': <String, dynamic>{}},
          ],
        },
        r'$.items[0].patternProperties',
      ),
      (
        {
          'type': 'array',
          'items': [
            {'type': 'string'},
          ],
          'additionalItems': {'type': 'integer', 'minimum': 0},
        },
        r'$.additionalItems.minimum',
      ),
      (
        {
          'type': 'object',
          'properties': <String, dynamic>{},
          'dependentRequired': <String, dynamic>{},
        },
        r'$.dependentRequired',
      ),
      ({'if': <String, dynamic>{}, 'then': <String, dynamic>{}}, r'$.if'),
      ({'type': 'array', 'unevaluatedItems': false}, r'$.unevaluatedItems'),
    ]) {
      test('rejects unenforced keyword at $path', () {
        expect(
          () => responseFormatSchema(format(schema)),
          throwsTyped<LlamaUnsupportedException>(
            'responseFormat schema keyword "$path" cannot be enforced',
          ),
        );
      });
    }

    test('rejects patterns outside the compiled subset', () {
      for (final pattern in [r'^\w+$', 'abc', r'^a|b$', r'^[^"]$']) {
        expect(
          () => responseFormatSchema(
            format({'type': 'string', 'pattern': pattern}),
          ),
          throwsTyped<LlamaUnsupportedException>(
            r'"$.pattern" is outside the supported regex subset',
          ),
          reason: pattern,
        );
      }
      expect(
        () => responseFormatSchema(
          format({
            'type': ['string', 'null'],
            'pattern': 5,
          }),
        ),
        throwsTyped<LlamaArgumentException>(r'"$.pattern" must be a string'),
      );
    });

    test('accepts supported patterns with their compiled grammar', () {
      const schema = {
        'type': 'object',
        'properties': {
          'id': {'type': 'string', 'pattern': r'^[a-zA-Z0-9]{9}$'},
        },
        'required': ['id'],
      };
      expect(responseFormatSchema(format(schema)), same(schema));
      expect(
        responseFormatGrammar(schema),
        JsonSchemaConverter.convert(schema),
      );
      expect(responseFormatGrammar(schema), contains('[a-zA-Z0-9]'));
    });

    test('treats JSON data and unknown keywords as non-assertions', () {
      const schema = {
        'type': 'object',
        'x-vendor': {'minimum': 1},
        'nullable': true,
        'default': {'format': 'uuid'},
        'examples': [
          {'maximum': 2},
        ],
        'properties': {
          'format': {'type': 'string'},
          'minimum': {
            'const': {'multipleOf': 2},
          },
          'level': {
            'enum': [
              {'uniqueItems': true},
              'low',
            ],
          },
        },
      };
      expect(responseFormatSchema(format(schema)), same(schema));
      expect(
        responseFormatGrammar(schema),
        JsonSchemaConverter.convert(schema),
      );
    });

    test('bounds nesting before any recursive conversion', () {
      Object deepList = 1;
      for (var i = 0; i < 200000; i++) {
        deepList = [deepList];
      }
      expect(
        () => responseFormatSchema(format({'const': deepList})),
        throwsTyped<LlamaUnsupportedException>(
          'nests 200001 levels deep; the limit is 512',
        ),
      );
      expect(
        () => responseFormatSchema(format(nestedItems(100000))),
        throwsTyped<LlamaUnsupportedException>(
          'nests 100001 levels deep; the limit is 512',
        ),
      );
      expect(
        () => responseFormatSchema(format(nestedItems(512))),
        throwsTyped<LlamaUnsupportedException>('nests 513 levels deep'),
      );
      final deepest = nestedItems(511);
      expect(responseFormatSchema(format(deepest)), same(deepest));
      expect(
        responseFormatGrammar(deepest),
        JsonSchemaConverter.convert(deepest),
      );
    });

    test('rejects values that are not JSON', () {
      final cyclic = <String, dynamic>{'type': 'object'};
      cyclic['properties'] = {'self': cyclic};
      for (final schema in <Map<String, dynamic>>[
        {'const': double.nan},
        {
          'enum': [DateTime(2026)],
        },
        {
          'const': {1: 'x'},
        },
        cyclic,
      ]) {
        expect(
          () => responseFormatSchema(format(schema)),
          throwsTyped<LlamaArgumentException>('must contain only JSON values'),
        );
      }
    });
  });

  group('responseFormatGrammar', () {
    test('reports converter failures as LlamaUnsupportedException', () {
      for (final (schema, message) in <(Map<String, dynamic>, String)>[
        (
          {
            'type': 'object',
            'properties': {
              'x': {'description': 'x'},
            },
          },
          'Unrecognized schema: {"description":"x"}',
        ),
        ({r'$ref': 'https://example.com/s.json'}, r'Cannot resolve $ref'),
        ({r'$ref': '#/missing'}, 'Error resolving ref'),
        ({'type': 'date'}, 'Unrecognized schema'),
        ({'type': 'object', 'properties': 'x'}, 'String'),
      ]) {
        expect(
          () => responseFormatGrammar(schema),
          throwsA(
            isA<LlamaUnsupportedException>().having(
              (error) => error.message,
              'message',
              allOf(
                startsWith('Unsupported responseFormat JSON schema: '),
                contains(message),
              ),
            ),
          ),
          reason: '$schema',
        );
      }
    });

    test('reports a stack overflow from a long reference chain', () {
      const links = 20000;
      final schema = <String, dynamic>{
        r'$defs': {
          for (var i = 0; i < links; i++)
            'n$i': i == links - 1
                ? {'type': 'integer'}
                : {
                    'type': 'object',
                    'properties': {
                      'next': {r'$ref': '#/\$defs/n${i + 1}'},
                    },
                  },
        },
        r'$ref': r'#/$defs/n0',
      };
      expect(responseFormatSchema(format(schema)), same(schema));
      expect(
        () => responseFormatGrammar(schema),
        throwsA(
          isA<LlamaUnsupportedException>().having(
            (error) => error.message,
            'message',
            startsWith('Unsupported responseFormat JSON schema: '),
          ),
        ),
      );
    });
  });
}
