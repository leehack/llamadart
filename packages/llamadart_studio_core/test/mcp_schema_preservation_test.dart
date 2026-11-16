import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'lossless closed-object legacy conversion keeps invocation validation',
    () async {
      var invocations = 0;
      final canonical = ToolDefinition.fromJsonSchema(
        name: 'closed',
        description: 'Closed inputs',
        schema: {
          'type': 'object',
          'additionalProperties': false,
          'properties': {
            'mode': {
              'type': 'string',
              'enum': ['safe', 'check'],
            },
            'flags': {
              'type': 'object',
              'additionalProperties': false,
              'properties': {
                'enabled': {'type': 'boolean'},
              },
              'required': ['enabled'],
            },
          },
          'required': ['mode', 'flags'],
        },
        handler: (params) async {
          invocations++;
          return params.raw;
        },
      );
      final legacy = McpToolSchemaAdapter.coerceToLegacyToolDefinition(
        canonical,
      );
      expect(legacy.parameters.map((p) => p.name), ['mode', 'flags']);
      await legacy.invoke({
        'mode': 'safe',
        'flags': {'enabled': true},
      });
      for (final invalid in <Map<String, dynamic>>[
        {
          'mode': 'unsafe',
          'flags': {'enabled': true},
        },
        {
          'mode': 'safe',
          'flags': {'enabled': true},
          'extra': true,
        },
        {'mode': 'safe', 'flags': <String, Object?>{}},
      ]) {
        await expectLater(
          legacy.invoke(invalid),
          throwsA(isA<LlamaArgumentException>()),
        );
      }
      expect(invocations, 1);
    },
  );

  test('legacy coercion never closes an open canonical schema', () {
    final canonical = ToolDefinition.fromJsonSchema(
      name: 'open',
      description: 'Open input',
      schema: {
        'type': 'object',
        'properties': {
          'message': {'type': 'string'},
        },
      },
    );
    expect(canonical.toJsonSchema()['additionalProperties'], isTrue);
    expect(
      () => McpToolSchemaAdapter.coerceToLegacyToolDefinition(canonical),
      throwsA(isA<LlamaUnsupportedException>()),
    );
  });
}
