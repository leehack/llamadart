import '../exceptions.dart';
import 'json_schema_converter.dart';
import 'json_value_depth.dart';

/// Checks the response-schema subset before recursive conversion or copying.
void validateResponseSchema(Map<String, dynamic> schema) {
  final depth = jsonValueDepth(schema);
  if (depth == null) {
    throw LlamaArgumentException(
      'Response schema at \$ must contain only JSON values: string keys, finite numbers and no cycles.',
    );
  }
  if (depth > 128) {
    _unsupported(r'$', 'JSON nesting must not exceed 128 levels');
  }
  _validateSupportedSchemaSubset(schema, r'$');
  _validateReferences(schema, schema, r'$');
}

const _supportedSchemaTypes = <String>{
  'object',
  'array',
  'string',
  'integer',
  'number',
  'boolean',
  'null',
};

const _supportedSchemaKeywords = <String>{
  r'$comment',
  r'$defs',
  r'$id',
  r'$ref',
  r'$schema',
  'additionalProperties',
  'anyOf',
  'const',
  'default',
  'definitions',
  'deprecated',
  'description',
  'enum',
  'examples',
  'items',
  'maxItems',
  'maxLength',
  'minItems',
  'minLength',
  'oneOf',
  'pattern',
  'prefixItems',
  'properties',
  'readOnly',
  'required',
  'title',
  'type',
  'writeOnly',
};

const _annotationSchemaKeywords = <String>{
  r'$comment',
  r'$id',
  r'$schema',
  'default',
  'deprecated',
  'description',
  'examples',
  'readOnly',
  'title',
  'writeOnly',
};

void _validateSupportedSchemaSubset(Map<String, dynamic> schema, String path) {
  for (final keyword in schema.keys) {
    if (!_supportedSchemaKeywords.contains(keyword) &&
        !keyword.startsWith('x-')) {
      throw LlamaUnsupportedException(
        'Unsupported structured JSON schema: keyword "$path.$keyword" is not '
        'supported by the current JSON-schema-to-GBNF subset.',
      );
    }
  }

  for (final keyword in schema.keys) {
    if (!_isMetadata(keyword) &&
        schema[keyword] == null &&
        keyword != 'const') {
      _unsupported('$path.$keyword', 'must not be null');
    }
  }
  final schemaTypes = responseSchemaTypes(schema['type'], path);
  _validateDispatch(schema, schemaTypes, path);
  _validateRefSchemaShape(schema, path);
  _validateKeywordContexts(schema, schemaTypes, path);
  _validateKeywordValues(schema, path);
  _validateNestedSchemas(schema, path);
}

/// Parses and checks the schema type keyword at [path].
Set<String>? responseSchemaTypes(Object? type, String path) {
  if (type == null) {
    return null;
  }
  if (type is String) {
    _validateSchemaType(type, '$path.type');
    return {type};
  }
  if (type is List) {
    final types = <String>{};
    for (var i = 0; i < type.length; i++) {
      final item = type[i];
      if (item is! String) {
        throw LlamaUnsupportedException(
          'Unsupported structured JSON schema: $path.type[$i] must be a '
          'schema type string.',
        );
      }
      _validateSchemaType(item, '$path.type[$i]');
      types.add(item);
    }
    if (types.isEmpty) {
      throw LlamaUnsupportedException(
        'Unsupported structured JSON schema: $path.type must not be empty.',
      );
    }
    return types;
  }
  throw LlamaUnsupportedException(
    'Unsupported structured JSON schema: $path.type must be a string or list '
    'of strings.',
  );
}

void _validateSchemaType(String type, String path) {
  if (!_supportedSchemaTypes.contains(type)) {
    throw LlamaUnsupportedException(
      'Unsupported structured JSON schema: $path uses unsupported type '
      '"$type".',
    );
  }
}

void _validateRefSchemaShape(Map<String, dynamic> schema, String path) {
  if (!schema.containsKey(r'$ref')) {
    return;
  }
  final ref = schema[r'$ref'];
  if (ref is! String || !ref.startsWith('#/')) {
    throw LlamaUnsupportedException(
      'Unsupported structured JSON schema: $path.\$ref must be a local "#/..." '
      'reference.',
    );
  }

  final siblingKeywords = schema.keys.where(
    (keyword) =>
        keyword != r'$ref' &&
        keyword != 'definitions' &&
        keyword != r'$defs' &&
        !_annotationSchemaKeywords.contains(keyword) &&
        !keyword.startsWith('x-'),
  );
  if (siblingKeywords.isNotEmpty) {
    throw LlamaUnsupportedException(
      'Unsupported structured JSON schema: $path.\$ref cannot be combined with '
      'sibling validation keywords.',
    );
  }
}

void _validateKeywordContexts(
  Map<String, dynamic> schema,
  Set<String>? schemaTypes,
  String path,
) {
  final hasObjectKeywords =
      schema.containsKey('properties') ||
      schema.containsKey('required') ||
      schema.containsKey('additionalProperties');
  final objectContext =
      schemaTypes?.contains('object') ??
      (schema.containsKey('properties') ||
          schema.containsKey('additionalProperties'));
  if (hasObjectKeywords && !objectContext) {
    throw LlamaUnsupportedException(
      'Unsupported structured JSON schema: object keyword at $path requires '
      'type "object" or object-shaped properties.',
    );
  }

  final hasArrayKeywords =
      schema.containsKey('items') ||
      schema.containsKey('prefixItems') ||
      schema.containsKey('minItems') ||
      schema.containsKey('maxItems');
  final arrayContext =
      schemaTypes?.contains('array') ??
      (schema.containsKey('items') || schema.containsKey('prefixItems'));
  if (hasArrayKeywords && !arrayContext) {
    throw LlamaUnsupportedException(
      'Unsupported structured JSON schema: array keyword at $path requires '
      'type "array" or an item schema.',
    );
  }

  final hasStringKeywords =
      schema.containsKey('pattern') ||
      schema.containsKey('minLength') ||
      schema.containsKey('maxLength');
  final stringContext =
      schemaTypes?.contains('string') ?? schema.containsKey('pattern');
  if (hasStringKeywords && !stringContext) {
    throw LlamaUnsupportedException(
      'Unsupported structured JSON schema: string length keyword at $path '
      'requires type "string".',
    );
  }
}

void _validateKeywordValues(Map<String, dynamic> schema, String path) {
  final enumValues = schema['enum'];
  if (enumValues != null) {
    if (enumValues is! List || enumValues.isEmpty) {
      throw LlamaUnsupportedException(
        'Unsupported structured JSON schema: $path.enum must be a non-empty '
        'list.',
      );
    }
  }

  final required = schema['required'];
  if (required != null) {
    if (required is! List) {
      throw LlamaUnsupportedException(
        'Unsupported structured JSON schema: $path.required must be a list.',
      );
    }
    for (var i = 0; i < required.length; i++) {
      if (required[i] is! String) {
        throw LlamaUnsupportedException(
          'Unsupported structured JSON schema: $path.required[$i] must be a '
          'property name string.',
        );
      }
    }
  }

  _validateNonNegativeIntKeyword(schema, 'minItems', path);
  _validateNonNegativeIntKeyword(schema, 'maxItems', path);
  _validateNonNegativeIntKeyword(schema, 'minLength', path);
  _validateNonNegativeIntKeyword(schema, 'maxLength', path);
  _validateBounds(schema, 'minItems', 'maxItems', path);
  _validateBounds(schema, 'minLength', 'maxLength', path);
}

void _validateNonNegativeIntKeyword(
  Map<String, dynamic> schema,
  String keyword,
  String path,
) {
  if (!schema.containsKey(keyword)) {
    return;
  }
  final value = schema[keyword];
  if (value is! int || value < 0 || value > 2000) {
    throw LlamaUnsupportedException(
      'Unsupported structured JSON schema: $path.$keyword must be a '
      'non-negative integer at most 2000.',
    );
  }
}

void _validateBounds(
  Map<String, dynamic> schema,
  String minKeyword,
  String maxKeyword,
  String path,
) {
  final min = schema[minKeyword];
  final max = schema[maxKeyword];
  if (min is int && max is int && max < min) {
    throw LlamaUnsupportedException(
      'Unsupported structured JSON schema: $path.$maxKeyword must be greater '
      'than or equal to $path.$minKeyword.',
    );
  }
}

void _validateNestedSchemas(Map<String, dynamic> schema, String path) {
  final properties = schema['properties'];
  if (properties != null) {
    final propertySchemas = responseSchemaMap(properties, '$path.properties');
    for (final entry in propertySchemas.entries) {
      _validateSupportedSchemaSubset(
        responseSchemaMap(entry.value, '$path.properties.${entry.key}'),
        '$path.properties.${entry.key}',
      );
    }
  }

  final additionalProperties = schema['additionalProperties'];
  if (additionalProperties != null &&
      additionalProperties != true &&
      additionalProperties != false) {
    _validateSupportedSchemaSubset(
      responseSchemaMap(additionalProperties, '$path.additionalProperties'),
      '$path.additionalProperties',
    );
  }

  final items = schema['items'];
  if (items != null) {
    _validateSupportedSchemaSubset(
      responseSchemaMap(items, '$path.items'),
      '$path.items',
    );
  }

  final prefixItems = schema['prefixItems'];
  if (prefixItems != null) {
    _validateSchemaList(prefixItems, '$path.prefixItems');
  }

  for (final keyword in const ['oneOf', 'anyOf', 'allOf']) {
    final alternatives = schema[keyword];
    if (alternatives != null) {
      _validateSchemaList(alternatives, '$path.$keyword');
    }
  }

  for (final keyword in const ['definitions', r'$defs']) {
    final definitions = schema[keyword];
    if (definitions != null) {
      final definitionSchemas = responseSchemaMap(
        definitions,
        '$path.$keyword',
      );
      for (final entry in definitionSchemas.entries) {
        _validateSupportedSchemaSubset(
          responseSchemaMap(entry.value, '$path.$keyword.${entry.key}'),
          '$path.$keyword.${entry.key}',
        );
      }
    }
  }
}

void _validateSchemaList(Object? value, String path) {
  if (value is! List || value.isEmpty) {
    throw LlamaUnsupportedException(
      'Unsupported structured JSON schema: $path must be a non-empty list of '
      'schemas.',
    );
  }
  for (var i = 0; i < value.length; i++) {
    _validateSupportedSchemaSubset(
      responseSchemaMap(value[i], '$path[$i]'),
      '$path[$i]',
    );
  }
}

/// Reads a schema-bearing object with string keys, reporting errors at [path].
Map<String, dynamic> responseSchemaMap(Object? value, String path) {
  if (value is! Map) {
    throw LlamaUnsupportedException(
      'Unsupported structured JSON schema: $path must be a JSON object.',
    );
  }
  final result = <String, dynamic>{};
  for (final entry in value.entries) {
    final key = entry.key;
    if (key is! String) {
      throw LlamaUnsupportedException(
        'Unsupported structured JSON schema: $path must contain only string '
        'keys.',
      );
    }
    result[key] = entry.value;
  }
  return result;
}

bool _isMetadata(String key) =>
    _annotationSchemaKeywords.contains(key) ||
    key == r'$defs' ||
    key == 'definitions' ||
    key.startsWith('x-');

Never _unsupported(String path, String reason) =>
    throw LlamaUnsupportedException(
      'Unsupported structured JSON schema: $path $reason.',
    );

void _validateDispatch(
  Map<String, dynamic> schema,
  Set<String>? types,
  String path,
) {
  for (final dispatch in ['anyOf', 'oneOf', 'const', 'enum']) {
    if (!schema.containsKey(dispatch)) continue;
    for (final key in schema.keys) {
      if (key == dispatch ||
          _isMetadata(key) ||
          (key == 'type' && (dispatch == 'const' || dispatch == 'enum'))) {
        continue;
      }
      _unsupported('$path.$key', 'is shadowed by $dispatch');
    }
    if ((dispatch == 'const' || dispatch == 'enum') && types != null) {
      final values = dispatch == 'const' ? [schema['const']] : schema['enum'];
      if (values is List) {
        for (final value in values) {
          final matches = types.any(
            (type) => switch (type) {
              'null' => value == null,
              'boolean' => value is bool,
              'integer' => value is int,
              'number' => value is num,
              'string' => value is String,
              'object' => value is Map,
              'array' => value is List,
              _ => false,
            },
          );
          if (!matches) _unsupported('$path.$dispatch', 'conflicts with type');
        }
      }
    }
  }
  if (schema.containsKey('pattern')) {
    final pattern = schema['pattern'];
    if (pattern is! String || !JsonSchemaConverter.supportsPattern(pattern)) {
      _unsupported('$path.pattern', 'is outside the compiled pattern subset');
    }
    for (final key in ['minLength', 'maxLength']) {
      if (schema.containsKey(key)) {
        _unsupported('$path.$key', 'is shadowed by pattern');
      }
    }
  }
  if (schema.containsKey('prefixItems')) {
    for (final key in ['items', 'minItems', 'maxItems']) {
      if (schema.containsKey(key)) {
        _unsupported('$path.$key', 'cannot be combined with fixed prefixItems');
      }
    }
  }
  if ((schema.containsKey('minItems') || schema.containsKey('maxItems')) &&
      !schema.containsKey('items') &&
      !schema.containsKey('prefixItems')) {
    _unsupported('$path.items', 'is required to enforce array bounds');
  }
  final required = schema['required'];
  if (required is List) {
    final properties = schema['properties'];
    for (final name in required) {
      if (properties is! Map || !properties.containsKey(name)) {
        _unsupported('$path.required', 'may only name declared properties');
      }
    }
  }
}

void _validateReferences(
  Map<String, dynamic> schema,
  Map<String, dynamic> root,
  String path,
) {
  final ref = schema[r'$ref'];
  if (ref is String) {
    Object? target = root;
    for (final segment in ref.substring(2).split('/')) {
      final key = segment.replaceAll('~1', '/').replaceAll('~0', '~');
      target = target is Map ? target[key] : null;
    }
    if (target is! Map<String, dynamic>) {
      _unsupported('$path.\$ref', 'must resolve to a local schema object');
    }
  }
  for (final key in ['properties', r'$defs', 'definitions']) {
    final children = schema[key];
    if (children is Map<String, dynamic>) {
      for (final entry in children.entries) {
        _validateReferences(
          responseSchemaMap(entry.value, '$path.$key.${entry.key}'),
          root,
          '$path.$key.${entry.key}',
        );
      }
    }
  }
  for (final key in ['items', 'additionalProperties']) {
    final child = schema[key];
    if (child is Map<String, dynamic>) {
      _validateReferences(child, root, '$path.$key');
    }
  }
  for (final key in ['prefixItems', 'anyOf', 'oneOf']) {
    final children = schema[key];
    if (children is List) {
      for (var i = 0; i < children.length; i++) {
        _validateReferences(
          responseSchemaMap(children[i], '$path.$key[$i]'),
          root,
          '$path.$key[$i]',
        );
      }
    }
  }
}
