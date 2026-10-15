import '../exceptions.dart';
import '../grammar/json_schema_converter.dart';
import '../grammar/json_value_depth.dart';

const _supportedTypes = "'text', 'json_object' or 'json_schema'";
const _jsonSchemaKeys = {'schema', 'name', 'description', 'strict'};

/// Returns the JSON schema that [responseFormat] constrains output to.
///
/// Returns null when [responseFormat] is null or requests plain text
/// (`{'type': 'text'}`). `{'type': 'json_object'}` maps to an object schema and
/// `{'type': 'json_schema', 'json_schema': {'schema': ...}}` to its schema.
///
/// A key whose value is null counts as absent, as JSON serializers that emit
/// null fields write it. Every other shape, including unknown types and
/// misspelled keys, throws [LlamaUnsupportedException] so a typo cannot
/// silently drop the constraint. A schema the grammar cannot enforce throws
/// as described on [validateResponseFormatSchema].
Map<String, dynamic>? responseFormatSchema(
  Map<String, dynamic>? responseFormat,
) {
  if (responseFormat == null) {
    return null;
  }
  final type = responseFormat['type'];
  if (type is! String) {
    throw LlamaUnsupportedException(
      'responseFormat.type must be one of $_supportedTypes; '
      'got ${type == null ? 'no type' : type.runtimeType}.',
    );
  }
  switch (type) {
    case 'text':
    case 'json_object':
      _rejectUnknownKeys(
        responseFormat,
        const {'type'},
        'responseFormat',
        type,
      );
      return type == 'text' ? null : const {'type': 'object'};
    case 'json_schema':
      _rejectUnknownKeys(
        responseFormat,
        const {'type', 'json_schema'},
        'responseFormat',
        type,
      );
      return _jsonSchemaSchema(responseFormat['json_schema']);
    default:
      throw LlamaUnsupportedException(
        "Unsupported responseFormat.type '$type'; expected $_supportedTypes.",
      );
  }
}

Map<String, dynamic> _jsonSchemaSchema(Object? jsonSchema) {
  if (jsonSchema is! Map) {
    throw LlamaUnsupportedException(
      "responseFormat.json_schema must be an object with a 'schema' JSON "
      "object for type 'json_schema'.",
    );
  }
  _rejectUnknownKeys(
    jsonSchema,
    _jsonSchemaKeys,
    'responseFormat.json_schema',
    'json_schema',
  );
  final schema = jsonSchema['schema'];
  if (schema is! Map<String, dynamic>) {
    throw LlamaUnsupportedException(
      'responseFormat.json_schema.schema must be a JSON object typed '
      'Map<String, dynamic>, as jsonDecode returns or a <String, dynamic>{} '
      'literal declares; got ${schema == null ? 'none' : schema.runtimeType}.',
    );
  }
  for (final key in const ['name', 'description']) {
    final value = jsonSchema[key];
    if (value != null && value is! String) {
      throw LlamaUnsupportedException(
        'responseFormat.json_schema.$key must be a string.',
      );
    }
  }
  final strict = jsonSchema['strict'];
  if (strict != null && strict is! bool) {
    throw LlamaUnsupportedException(
      'responseFormat.json_schema.strict must be a bool.',
    );
  }
  validateResponseFormatSchema(schema);
  return schema;
}

/// Most container levels a `responseFormat` schema may nest.
///
/// The grammar converter recurses once or twice per level; this keeps that
/// well inside the smallest supported stack (dart2js overflows near 3,000).
const maxResponseFormatSchemaDepth = 512;

/// Assertion keywords the JSON-schema-to-GBNF converter does not enforce.
const _unenforcedKeywords = <String>{
  r'$dynamicRef',
  r'$recursiveRef',
  'contains',
  'dependencies',
  'dependentRequired',
  'dependentSchemas',
  'else',
  'exclusiveMaximum',
  'exclusiveMinimum',
  'format',
  'if',
  'maxContains',
  'maxProperties',
  'maximum',
  'minContains',
  'minProperties',
  'minimum',
  'multipleOf',
  'not',
  'patternProperties',
  'propertyNames',
  'then',
  'unevaluatedItems',
  'unevaluatedProperties',
  'uniqueItems',
};

/// Rejects a `responseFormat` [schema] whose grammar would admit output the
/// schema forbids, or that is too deep to convert.
///
/// Throws [LlamaArgumentException] when [schema] holds a value that is not
/// JSON, such as a cycle, and [LlamaUnsupportedException] when it nests
/// deeper than [maxResponseFormatSchemaDepth], uses an assertion keyword the
/// grammar does not enforce (`format`, numeric bounds, `uniqueItems` and
/// similar), or has a `pattern` outside the compiled regex subset.
/// Annotations and unknown keywords are ignored, as JSON Schema specifies.
void validateResponseFormatSchema(Map<String, dynamic> schema) {
  final depth = jsonValueDepth(schema);
  if (depth == null) {
    throw LlamaArgumentException(
      'responseFormat.json_schema.schema must contain only JSON values: '
      'string keys, finite numbers and no cycles.',
    );
  }
  if (depth > maxResponseFormatSchemaDepth) {
    throw LlamaUnsupportedException(
      'responseFormat.json_schema.schema nests $depth levels deep; the limit '
      'is $maxResponseFormatSchemaDepth.',
    );
  }
  final pending = <(Map<dynamic, dynamic>, String)>[(schema, r'$')];
  while (pending.isNotEmpty) {
    final (node, path) = pending.removeLast();
    for (final key in node.keys) {
      if (_unenforcedKeywords.contains(key)) {
        throw LlamaUnsupportedException(
          'responseFormat schema keyword "$path.$key" cannot be enforced by '
          'grammar-constrained decoding. Remove it and validate that '
          'constraint after generation.',
        );
      }
    }
    if (node.containsKey('pattern')) {
      final pattern = node['pattern'];
      if (pattern is! String) {
        throw LlamaArgumentException(
          'responseFormat schema "$path.pattern" must be a string.',
        );
      }
      if (!JsonSchemaConverter.supportsPattern(pattern)) {
        throw LlamaUnsupportedException(
          'responseFormat schema "$path.pattern" is outside the supported '
          'regex subset: an anchored ^...\$ sequence of literals, character '
          'classes, groups and quantifiers.',
        );
      }
    }
    void push(Object? child, String childPath) {
      if (child is Map) pending.add((child, childPath));
    }

    for (final keyword in const ['properties', r'$defs', 'definitions']) {
      final schemas = node[keyword];
      if (schemas is Map) {
        for (final MapEntry(:key, :value) in schemas.entries) {
          push(value, '$path.$keyword.$key');
        }
      }
    }
    for (final keyword in const [
      'items',
      'prefixItems',
      'anyOf',
      'oneOf',
      'allOf',
    ]) {
      final value = node[keyword];
      if (value is List) {
        for (var i = 0; i < value.length; i++) {
          push(value[i], '$path.$keyword[$i]');
        }
      } else {
        push(value, '$path.$keyword');
      }
    }
    push(node['additionalProperties'], '$path.additionalProperties');
    push(node['additionalItems'], '$path.additionalItems');
  }
}

/// Converts a `responseFormat` [schema] to GBNF.
///
/// Throws [LlamaUnsupportedException] for a schema the converter cannot
/// represent, such as an unresolvable `$ref` or an untyped property.
String responseFormatGrammar(Map<String, dynamic> schema) {
  try {
    return JsonSchemaConverter.convert(schema);
  } on LlamaException {
    rethrow;
  } catch (error) {
    // The converter reports unsupported shapes as StateError or TypeError, and
    // a long $ref chain can still exhaust the stack below the depth limit.
    throw LlamaUnsupportedException(
      'Unsupported responseFormat JSON schema: $error',
    );
  }
}

void _rejectUnknownKeys(
  Map<dynamic, dynamic> map,
  Set<String> allowed,
  String path,
  String type,
) {
  for (final MapEntry(:key, :value) in map.entries) {
    if (value != null && !allowed.contains(key)) {
      throw LlamaUnsupportedException(
        "Unsupported $path key '$key' for type '$type'; supported keys: "
        '${allowed.join(', ')}.',
      );
    }
  }
}
