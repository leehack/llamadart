import '../exceptions.dart';

const _supportedTypes = "'text', 'json_object' or 'json_schema'";
const _jsonSchemaKeys = {'schema', 'name', 'description', 'strict'};

/// Returns the JSON schema that [responseFormat] constrains output to.
///
/// Returns null when [responseFormat] is null or requests plain text
/// (`{'type': 'text'}`). `{'type': 'json_object'}` maps to an object schema and
/// `{'type': 'json_schema', 'json_schema': {'schema': ...}}` to its schema.
///
/// Every other shape, including unknown types and misspelled keys, throws
/// [LlamaUnsupportedException] so a typo cannot silently drop the constraint.
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
      'responseFormat.json_schema.schema must be a JSON object with string '
      'keys.',
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
  return schema;
}

void _rejectUnknownKeys(
  Map<dynamic, dynamic> map,
  Set<String> allowed,
  String path,
  String type,
) {
  for (final key in map.keys) {
    if (!allowed.contains(key)) {
      throw LlamaUnsupportedException(
        "Unsupported $path key '$key' for type '$type'; supported keys: "
        '${allowed.join(', ')}.',
      );
    }
  }
}
