import '../models/tools/tool_definition.dart';
import 'tool_call_parsing_utils.dart';

/// Result of reconstructing one tool argument against its declared schema.
typedef ToolSchemaValueResult = ({bool valid, Object? value});

/// Returns tool schemas keyed by the exact tool name emitted in the protocol.
Map<String, Map<String, dynamic>> toolSchemas(List<ToolDefinition>? tools) {
  if (tools == null || tools.isEmpty) {
    return const {};
  }
  return <String, Map<String, dynamic>>{
    for (final tool in tools) tool.name: tool.toJsonSchema(),
  };
}

/// Returns object-property schemas keyed by their exact protocol names.
Map<String, Map<String, dynamic>> schemaProperties(
  Map<String, dynamic> schema,
) {
  final raw = schema['properties'];
  if (raw is! Map) {
    return const {};
  }
  return <String, Map<String, dynamic>>{
    for (final entry in raw.entries)
      if (entry.key is String && entry.value is Map)
        entry.key as String: Map<String, dynamic>.from(entry.value as Map),
  };
}

/// Returns the required object-property names from [schema].
Set<String> schemaRequired(Map<String, dynamic> schema) {
  final raw = schema['required'];
  return raw is List ? raw.whereType<String>().toSet() : const {};
}

/// Whether a schema must preserve emitted text as a string.
bool schemaResolvesToString(Map<String, dynamic> schema) =>
    schema['type'] == 'string' || schema['enum'] is List;

/// Decodes protocol text according to [schema] without guessing string types.
ToolSchemaValueResult decodeToolSchemaText(
  String raw,
  Map<String, dynamic> schema,
) {
  if (schemaResolvesToString(schema)) {
    return validateToolSchemaValue(raw, schema);
  }
  final decoded = ToolCallParsingUtils.decodeJsonValue(raw);
  if (decoded == null && raw.trim() != 'null') {
    return (valid: false, value: null);
  }
  return validateToolSchemaValue(decoded, schema);
}

/// Validates and normalizes a decoded value according to [schema].
ToolSchemaValueResult validateToolSchemaValue(
  Object? value,
  Map<String, dynamic> schema,
) {
  final type = schema['type'];
  Object? normalized = value;

  if (type == 'string') {
    if (value is! String) {
      return (valid: false, value: null);
    }
  } else if (type == 'integer') {
    if (value is! int) {
      return (valid: false, value: null);
    }
  } else if (type == 'number') {
    if (value is! num) {
      return (valid: false, value: null);
    }
  } else if (type == 'boolean') {
    if (value is! bool) {
      return (valid: false, value: null);
    }
  } else if (type == 'null') {
    if (value != null) {
      return (valid: false, value: null);
    }
  } else if (type == 'object') {
    if (value is! Map) {
      return (valid: false, value: null);
    }
    final properties = schemaProperties(schema);
    final required = schemaRequired(schema);
    final object = <String, dynamic>{};
    for (final entry in value.entries) {
      if (entry.key is! String) {
        return (valid: false, value: null);
      }
      final propertySchema = properties[entry.key];
      if (propertySchema == null) {
        return (valid: false, value: null);
      }
      final nested = validateToolSchemaValue(entry.value, propertySchema);
      if (!nested.valid) {
        return (valid: false, value: null);
      }
      object[entry.key as String] = nested.value;
    }
    if (!object.keys.toSet().containsAll(required)) {
      return (valid: false, value: null);
    }
    normalized = object;
  } else if (type == 'array') {
    if (value is! List) {
      return (valid: false, value: null);
    }
    final itemSchema = schema['items'];
    if (itemSchema is Map) {
      final resolvedItemSchema = Map<String, dynamic>.from(itemSchema);
      final items = <Object?>[];
      for (final item in value) {
        final nested = validateToolSchemaValue(item, resolvedItemSchema);
        if (!nested.valid) {
          return (valid: false, value: null);
        }
        items.add(nested.value);
      }
      normalized = items;
    }
  }

  final enumValues = schema['enum'];
  if (enumValues is List && !enumValues.contains(normalized)) {
    return (valid: false, value: null);
  }
  return (valid: true, value: normalized);
}
