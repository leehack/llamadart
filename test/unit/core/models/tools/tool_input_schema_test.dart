import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/core/models/tools/tool_input_schema.dart';
import 'package:test/test.dart';

import '../../../../support/raw_tool_schema_fixture.dart';

void main() {
  test('malformed null keywords are rejected rather than defaulted', () {
    for (final schema in <Map<String, dynamic>>[
      {'type': 'object', 'properties': null},
      {'type': 'object', 'required': null},
      {
        'type': 'object',
        'properties': {
          'x': {'type': null},
        },
      },
      {
        'type': 'object',
        'properties': {
          'x': {'anyOf': null},
        },
      },
      {
        'type': 'object',
        'properties': {
          'x': {'type': 'string', 'minLength': null},
        },
      },
    ]) {
      expect(
        () => ToolDefinition.fromJsonSchema(
          name: 'invalid',
          description: 'Invalid',
          schema: schema,
        ),
        throwsA(isA<LlamaArgumentException>()),
      );
    }
  });

  test(
    'open properties and numbers still require finite JSON values',
    () async {
      var calls = 0;
      final tool = ToolDefinition.fromJsonSchema(
        name: 'open',
        description: 'Open',
        schema: {'type': 'object'},
        handler: (_) async {
          calls++;
          return true;
        },
      );
      final cycle = <String, dynamic>{};
      cycle['self'] = cycle;
      for (final value in [
        double.nan,
        double.infinity,
        Object(),
        cycle,
        {1: true},
      ]) {
        await expectLater(
          tool.invoke({'extra': value}),
          throwsA(isA<LlamaArgumentException>()),
        );
      }
      expect(calls, 0);
      expect(
        await tool.invoke({
          'extra': [1, null, 'ok'],
        }),
        isTrue,
      );
    },
  );

  test('schema constructor owns input and returned maps', () {
    final source = <String, dynamic>{
      'type': 'object',
      'properties': {
        'q': {'type': 'string'},
      },
      'required': ['q'],
      'additionalProperties': false,
    };
    final tool = ToolDefinition.fromJsonSchema(
      name: 'search',
      description: 'Search',
      schema: source,
    );
    (source['properties'] as Map)['q'] = {'type': 'integer'};
    final first = tool.toJsonSchema();
    expect((first['properties'] as Map)['q'], {'type': 'string'});
    (first['properties'] as Map).clear();
    expect(tool.toJsonSchema()['properties'], {
      'q': {'type': 'string'},
    });
    expect(
      (tool.toJson()['function'] as Map)['parameters'],
      tool.toJsonSchema(),
    );
    expect(tool.parameters, isEmpty);
  });

  test(
    'raw JSON defaults remain open while legacy helper behavior stays closed',
    () {
      final tool = ToolDefinition.fromJsonSchema(
        name: 'open',
        description: 'Open',
        schema: {'type': 'object', 'properties': {}},
      );
      expect(tool.toJsonSchema()['additionalProperties'], isTrue);
      expect(
        validateToolInputValue({'extra': 42}, tool.toJsonSchema()).valid,
        isTrue,
      );
      const legacy = ToolDefinition(
        name: 'closed',
        description: 'Closed',
        parameters: [],
      );
      expect(
        legacy.toJsonSchema().containsKey('additionalProperties'),
        isFalse,
      );
      expect(
        validateToolInputValue({'extra': 42}, legacy.toJsonSchema()).valid,
        isFalse,
      );
    },
  );

  test(
    'schema-backed handler receives valid typed values and rejects invalid input',
    () async {
      var invocations = 0;
      final tool = rawSchemaTool(
        handler: (params) async {
          invocations++;
          return params.getInt('mode');
        },
      );
      expect(await tool.invoke(Map<String, dynamic>.from(rawToolArguments)), 2);
      await expectLater(
        Future.sync(() => tool.invoke({...rawToolArguments, 'mode': '2'})),
        throwsA(isA<LlamaArgumentException>()),
      );
      expect(invocations, 1);
    },
  );

  test(
    'handler remains optional and missing handler has the same state error',
    () async {
      final tool = rawSchemaTool();
      await expectLater(
        tool.invoke(Map<String, dynamic>.from(rawToolArguments)),
        throwsA(isA<LlamaStateException>()),
      );
    },
  );

  for (final schema in <Map<String, dynamic>>[
    {},
    {'type': 'string'},
    {'type': 'object', 'properties': []},
    {
      'type': 'object',
      'properties': {
        'x': {'type': 'invalid'},
      },
    },
    {
      'type': 'object',
      'properties': {
        'x': {'type': []},
      },
    },
    {
      'type': 'object',
      'properties': {
        '': {'type': 'string'},
      },
    },
    {
      'type': 'object',
      'required': ['missing'],
    },
    {
      'type': 'object',
      'properties': {
        'x': {'type': 'string'},
      },
      'required': ['x', 'x'],
    },
    {
      'type': 'object',
      'properties': {
        'x': {'type': 'string', 'enum': []},
      },
    },
    {
      'type': 'object',
      'properties': {
        'x': {
          'type': 'string',
          'enum': ['a', 'a'],
        },
      },
    },
    {'type': 'object', 'properties': {}, 'additionalProperties': 42},
    {
      'type': 'object',
      'properties': {
        'x': {'type': 'string', 'minLength': -1},
      },
    },
    {
      'type': 'object',
      'properties': {
        'x': {
          'type': 'array',
          'items': {'type': 'string'},
          'minItems': 2,
          'maxItems': 1,
        },
      },
    },
    {
      'type': 'object',
      'properties': {
        'x': {'anyOf': []},
      },
    },
    {
      'type': 'object',
      'properties': {
        'x': {
          'anyOf': [true],
        },
      },
    },
  ]) {
    test('malformed schema is an argument error: $schema', () {
      expect(
        () => ToolDefinition.fromJsonSchema(
          name: 'invalid',
          description: 'Invalid',
          schema: schema,
        ),
        throwsA(isA<LlamaArgumentException>()),
      );
    });
  }

  for (final property in <Map<String, dynamic>>[
    {'type': 'number', 'minimum': 0},
    {'type': 'integer', 'maximum': 10},
    {'type': 'string', 'pattern': '^[a-z]+\$'},
    {
      'oneOf': [
        {'type': 'string'},
        {'type': 'null'},
      ],
    },
    {
      'allOf': [
        {'type': 'string'},
      ],
    },
    {r'$ref': 'https://example.invalid/schema.json'},
    {r'$ref': r'#/$defs/value'},
    {
      'type': 'array',
      'items': [
        {'type': 'string'},
      ],
    },
    {
      'type': 'string',
      'enum': [42],
    },
    {'type': 'string', 'const': true},
    {
      'enum': [{}],
    },
    {
      'type': 'string',
      'minLength': 1,
      'enum': ['a'],
    },
    {
      'anyOf': [
        {'type': 'string'},
      ],
      'type': 'string',
    },
    {'properties': {}},
    {
      'type': 'string',
      'items': {'type': 'string'},
    },
    {'type': 'integer', 'minLength': 2},
  ]) {
    test(
      'unsupported constraints fail rather than lose meaning: $property',
      () {
        expect(
          () => ToolDefinition.fromJsonSchema(
            name: 'unsupported',
            description: 'Unsupported',
            schema: {
              'type': 'object',
              'properties': {'x': property},
            },
          ),
          throwsA(isA<LlamaUnsupportedException>()),
        );
      },
    );
  }

  test(
    'nullable, numeric enums, containers and property policy validate together',
    () {
      final schema = rawSchemaTool().toJsonSchema();
      expect(validateToolInputValue(rawToolArguments, schema).valid, isTrue);
      for (final invalid in <Map<String, dynamic>>[
        {...rawToolArguments, 'code': 42},
        {...rawToolArguments, 'mode': '2'},
        {...rawToolArguments, 'mode': 3},
        {
          ...rawToolArguments,
          'nested': {'active': 'true'},
        },
        {...rawToolArguments, 'tags': []},
        {
          ...rawToolArguments,
          'tags': ['a', 'b', 'c'],
        },
        {
          ...rawToolArguments,
          'tags': [1],
        },
        {...rawToolArguments, 'extra': true},
        {...rawToolArguments}..remove('code'),
      ]) {
        expect(
          validateToolInputValue(invalid, schema).valid,
          isFalse,
          reason: '$invalid',
        );
      }
    },
  );

  test(
    'anyOf, scalar const, Unicode lengths and typed additional values validate',
    () {
      final tool = ToolDefinition.fromJsonSchema(
        name: 'union',
        description: 'Union',
        schema: {
          'type': 'object',
          'properties': {
            'value': {
              'anyOf': [
                {
                  'type': 'integer',
                  'enum': [1, 2],
                },
                {'type': 'null'},
              ],
            },
            'fixed': {'const': true},
            'text': {'type': 'string', 'minLength': 1, 'maxLength': 1},
          },
          'required': ['value', 'fixed', 'text'],
          'additionalProperties': {'type': 'boolean'},
        },
      );
      final schema = tool.toJsonSchema();
      expect(
        validateToolInputValue({
          'value': null,
          'fixed': true,
          'text': '😀',
          'extra': false,
        }, schema).valid,
        isTrue,
      );
      for (final invalid in [
        {'value': '2', 'fixed': true, 'text': 'a'},
        {'value': 3, 'fixed': true, 'text': 'a'},
        {'value': 1, 'fixed': false, 'text': 'a'},
        {'value': 1, 'fixed': true, 'text': ''},
        {'value': 1, 'fixed': true, 'text': 'ab'},
        {'value': 1, 'fixed': true, 'text': 'a', 'extra': 42},
      ]) {
        expect(validateToolInputValue(invalid, schema).valid, isFalse);
      }
    },
  );

  test('non-JSON values fail with a typed argument error', () {
    expect(
      () => copyToolInputSchema({'type': 'object', 'default': double.nan}),
      throwsA(isA<LlamaArgumentException>()),
    );
  });
}
