import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/core/template/response_format.dart';
import 'package:test/test.dart';

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
}
