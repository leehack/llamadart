import 'package:llamadart/llamadart.dart';

import '../../domain/mcp_server_config.dart';

/// Pure adapter converting arbitrary external MCP JSON Schemas into
/// `llamadart` [ToolDefinition]s and sanitizing schema subsets for grammar and
/// chat-template compatibility.
abstract final class McpToolSchemaAdapter {
  /// Converts an [McpToolDescriptor] into a `llamadart` [ToolDefinition],
  /// sanitizing its JSON Schema and preferring `ToolParam` definitions when
  /// representable so all chat templates (including `qwen3CoderXml`) qualify.
  static ToolDefinition toLlamaToolDefinition(
    McpToolDescriptor tool, {
    required Future<Object?> Function(ToolParams params) handler,
  }) {
    final sanitized = sanitizeMcpInputSchema(tool.inputSchema);
    final rawDesc = _compactDescription(tool.description, maxChars: 180);
    final description = rawDesc.isEmpty
        ? 'MCP tool ${tool.name} from ${tool.serverName}.'
        : '[MCP:${tool.serverName}] $rawDesc';

    final simpleParams = _tryJsonSchemaToToolParams(sanitized);
    if (simpleParams != null) {
      return ToolDefinition(
        name: tool.exposedToolName,
        description: description,
        parameters: simpleParams,
        handler: handler,
      );
    }

    try {
      return ToolDefinition.fromJsonSchema(
        name: tool.exposedToolName,
        description: description,
        schema: sanitized,
        handler: handler,
      );
    } on LlamaUnsupportedException {
      return ToolDefinition(
        name: tool.exposedToolName,
        description: description,
        parameters: const <ToolParam>[],
        handler: handler,
      );
    }
  }

  /// Converts any [ToolDefinition] (including canonical JSON Schema tools)
  /// into a legacy [ToolParam]-backed [ToolDefinition] compatible with all
  /// chat templates including `ChatFormat.qwen3CoderXml` (Qwen3.5 / Qwen3.6).
  static ToolDefinition coerceToLegacyToolDefinition(ToolDefinition tool) {
    final schema = sanitizeMcpInputSchema(tool.toJsonSchema());
    final strictParams = _tryJsonSchemaToToolParams(schema);
    final params = strictParams ?? _lossyJsonSchemaToToolParams(schema);
    return ToolDefinition(
      name: tool.name,
      description: tool.description,
      parameters: params,
      handler: tool.handler,
    );
  }

  /// Sanitizes an arbitrary JSON Schema from an external MCP server so it
  /// conforms strictly to the subset supported by `ToolDefinition.fromJsonSchema`.
  static Map<String, dynamic> sanitizeMcpInputSchema(
    Map<String, dynamic> rawSchema,
  ) {
    final cleaned = _sanitizeSchemaNode(rawSchema, isRoot: true);
    cleaned['type'] = 'object';
    if (cleaned['properties'] is! Map) {
      cleaned['properties'] = <String, dynamic>{};
    }
    return cleaned;
  }

  /// Allocates a collision-free identifier for an exposed MCP tool name.
  static String allocateExposedToolName({
    required String serverName,
    required String rawToolName,
    required Set<String> usedNames,
  }) {
    String cleanIdentifier(String raw) {
      final cleaned = raw.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
      if (cleaned.isEmpty) {
        return 'mcp_tool';
      }
      return cleaned.length > 64 ? cleaned.substring(0, 64) : cleaned;
    }

    final preferred = cleanIdentifier(rawToolName);
    if (!usedNames.contains(preferred)) {
      return preferred;
    }
    final prefixed = cleanIdentifier('${serverName}_$rawToolName');
    if (!usedNames.contains(prefixed)) {
      return prefixed;
    }
    var n = 2;
    while (usedNames.contains('${prefixed}_$n')) {
      n++;
    }
    return cleanIdentifier('${prefixed}_$n');
  }

  static List<ToolParam> _lossyJsonSchemaToToolParams(
    Map<String, dynamic> objectSchema,
  ) {
    final rawProps = objectSchema['properties'];
    if (rawProps is! Map) {
      return const <ToolParam>[];
    }
    final requiredSet = <String>{
      if (objectSchema['required'] is List)
        for (final item in (objectSchema['required'] as List))
          if (item is String) item,
    };
    final params = <ToolParam>[];
    for (final entry in rawProps.entries) {
      final key = entry.key;
      final value = entry.value;
      if (key is! String || key.isEmpty || value is! Map) {
        continue;
      }
      params.add(
        _lossySchemaPropToToolParam(
          key,
          Map<String, dynamic>.from(value),
          isRequired: requiredSet.contains(key),
        ),
      );
    }
    return params;
  }

  static ToolParam _lossySchemaPropToToolParam(
    String name,
    Map<String, dynamic> schema, {
    required bool isRequired,
  }) {
    final description = schema['description'] as String?;

    if (schema.containsKey('const')) {
      final c = schema['const'];
      if (c is String) {
        return ToolParam.enumType(
          name,
          values: <String>[c],
          description: description,
          required: isRequired,
        );
      }
      if (c is bool) {
        return ToolParam.boolean(
          name,
          description: description,
          required: isRequired,
        );
      }
      if (c is int) {
        return ToolParam.integer(
          name,
          description: description,
          required: isRequired,
        );
      }
      if (c is num) {
        return ToolParam.number(
          name,
          description: description,
          required: isRequired,
        );
      }
      return ToolParam.string(
        name,
        description: description,
        required: isRequired,
      );
    }

    final anyOf = schema['anyOf'];
    if (anyOf is List && anyOf.isNotEmpty) {
      Map<String, dynamic>? chosen;
      for (final branch in anyOf) {
        if (branch is Map) {
          final branchMap = Map<String, dynamic>.from(branch);
          if (branchMap['type'] != 'null') {
            chosen = branchMap;
            break;
          }
          chosen ??= branchMap;
        }
      }
      if (chosen != null) {
        if (description != null && chosen['description'] == null) {
          chosen['description'] = description;
        }
        return _lossySchemaPropToToolParam(
          name,
          chosen,
          isRequired: isRequired,
        );
      }
    }

    final rawEnum = schema['enum'];
    final rawTypeField = schema['type'];
    String? rawType;
    if (rawTypeField is String) {
      rawType = rawTypeField;
    } else if (rawTypeField is List) {
      for (final item in rawTypeField) {
        if (item is String && item != 'null') {
          rawType = item;
          break;
        }
      }
      rawType ??= rawTypeField.whereType<String>().firstOrNull;
    }

    if (rawEnum is List &&
        rawEnum.isNotEmpty &&
        (rawType == null || rawType == 'string') &&
        rawEnum.every((Object? item) => item is String)) {
      return ToolParam.enumType(
        name,
        values: rawEnum.cast<String>(),
        description: description,
        required: isRequired,
      );
    }

    switch (rawType) {
      case 'integer':
        return ToolParam.integer(
          name,
          description: description,
          required: isRequired,
        );
      case 'number':
        return ToolParam.number(
          name,
          description: description,
          required: isRequired,
        );
      case 'boolean':
        return ToolParam.boolean(
          name,
          description: description,
          required: isRequired,
        );
      case 'null':
        return ToolParam.nullType(
          name,
          description: description,
          required: isRequired,
        );
      case 'array':
        final items = schema['items'];
        final itemParam = items is Map
            ? _lossySchemaPropToToolParam(
                '${name}_item',
                Map<String, dynamic>.from(items),
                isRequired: false,
              )
            : ToolParam.string('${name}_item');
        return ToolParam.array(
          name,
          itemType: itemParam,
          description: description,
          required: isRequired,
        );
      case 'object':
        return ToolParam.object(
          name,
          properties: _lossyJsonSchemaToToolParams(schema),
          description: description,
          required: isRequired,
        );
      case 'string':
      default:
        return ToolParam.string(
          name,
          description: description,
          required: isRequired,
        );
    }
  }

  static List<ToolParam>? _tryJsonSchemaToToolParams(
    Map<String, dynamic> objectSchema,
  ) {
    if (objectSchema.containsKey('anyOf') ||
        objectSchema.containsKey('const') ||
        objectSchema['additionalProperties'] is Map) {
      return null;
    }
    final rawProps = objectSchema['properties'];
    if (rawProps == null) {
      return const <ToolParam>[];
    }
    if (rawProps is! Map) {
      return null;
    }
    final requiredSet = <String>{
      if (objectSchema['required'] is List)
        for (final item in (objectSchema['required'] as List))
          if (item is String) item,
    };

    final params = <ToolParam>[];
    for (final entry in rawProps.entries) {
      final key = entry.key;
      final value = entry.value;
      if (key is! String || key.isEmpty || value is! Map) {
        return null;
      }
      final param = _schemaPropToToolParam(
        key,
        Map<String, dynamic>.from(value),
        isRequired: requiredSet.contains(key),
      );
      if (param == null) {
        return null;
      }
      params.add(param);
    }
    return params;
  }

  static ToolParam? _schemaPropToToolParam(
    String name,
    Map<String, dynamic> schema, {
    required bool isRequired,
  }) {
    const unsupportedByToolParam = <String>{
      'anyOf',
      'const',
      'minItems',
      'maxItems',
      'minLength',
      'maxLength',
    };
    for (final k in unsupportedByToolParam) {
      if (schema.containsKey(k)) {
        return null;
      }
    }
    final description = schema['description'] as String?;
    final rawEnum = schema['enum'];
    final rawTypeField = schema['type'];
    if (rawTypeField != null && rawTypeField is! String) {
      return null;
    }
    final rawType = rawTypeField as String?;
    if (rawEnum is List &&
        rawEnum.isNotEmpty &&
        (rawType == null || rawType == 'string') &&
        rawEnum.every((Object? item) => item is String)) {
      return ToolParam.enumType(
        name,
        values: rawEnum.cast<String>(),
        description: description,
        required: isRequired,
      );
    }
    if (rawEnum != null) {
      return null;
    }

    switch (rawType) {
      case 'string':
        return ToolParam.string(
          name,
          description: description,
          required: isRequired,
        );
      case 'integer':
        return ToolParam.integer(
          name,
          description: description,
          required: isRequired,
        );
      case 'number':
        return ToolParam.number(
          name,
          description: description,
          required: isRequired,
        );
      case 'boolean':
        return ToolParam.boolean(
          name,
          description: description,
          required: isRequired,
        );
      case 'null':
        return ToolParam.nullType(
          name,
          description: description,
          required: isRequired,
        );
      case 'array':
        final items = schema['items'];
        if (items is! Map) {
          return null;
        }
        final itemParam = _schemaPropToToolParam(
          '${name}_item',
          Map<String, dynamic>.from(items),
          isRequired: false,
        );
        if (itemParam == null) {
          return null;
        }
        return ToolParam.array(
          name,
          itemType: itemParam,
          description: description,
          required: isRequired,
        );
      case 'object':
        final nested = _tryJsonSchemaToToolParams(schema);
        if (nested == null) {
          return null;
        }
        return ToolParam.object(
          name,
          properties: nested,
          description: description,
          required: isRequired,
        );
      default:
        return null;
    }
  }

  static String _compactDescription(String raw, {required int maxChars}) {
    final normalized = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.length <= maxChars) {
      return normalized;
    }
    final slice = normalized.substring(0, maxChars);
    final lastSpace = slice.lastIndexOf(' ');
    final cut = lastSpace > (maxChars ~/ 2)
        ? slice.substring(0, lastSpace)
        : slice;
    return '${cut.trimRight()}...';
  }

  static const Set<String> _allowedSchemaKeys = <String>{
    'type',
    'properties',
    'required',
    'additionalProperties',
    'items',
    'minItems',
    'maxItems',
    'minLength',
    'maxLength',
    'enum',
    'const',
    'anyOf',
    'description',
    'title',
    'default',
    r'$schema',
    'deprecated',
    'readOnly',
    'writeOnly',
  };

  static Map<String, dynamic> _sanitizeSchemaNode(
    Map<String, dynamic> node, {
    bool isRoot = false,
  }) {
    final out = <String, dynamic>{};
    for (final entry in node.entries) {
      final key = entry.key;
      final value = entry.value;
      if (!_allowedSchemaKeys.contains(key) && !key.startsWith('x-')) {
        continue;
      }
      if (key == 'description' && value is String) {
        final compact = _compactDescription(value, maxChars: 120);
        if (compact.isNotEmpty) {
          out['description'] = compact;
        }
      } else if (key == 'properties' && value is Map) {
        final props = <String, dynamic>{};
        for (final propEntry in value.entries) {
          if (propEntry.key is String && propEntry.value is Map) {
            props[propEntry.key as String] = _sanitizeSchemaNode(
              Map<String, dynamic>.from(propEntry.value as Map),
            );
          }
        }
        out['properties'] = props;
      } else if (key == 'items' && value is Map) {
        out['items'] = _sanitizeSchemaNode(Map<String, dynamic>.from(value));
      } else if (key == 'additionalProperties' && value is Map) {
        out['additionalProperties'] = _sanitizeSchemaNode(
          Map<String, dynamic>.from(value),
        );
      } else if (key == 'anyOf' && value is List) {
        final branches = <Map<String, dynamic>>[
          for (final item in value)
            if (item is Map)
              _sanitizeSchemaNode(Map<String, dynamic>.from(item)),
        ];
        if (branches.isNotEmpty) {
          out['anyOf'] = branches;
        }
      } else {
        out[key] = value;
      }
    }

    if (isRoot && !out.containsKey('type')) {
      out['type'] = 'object';
    }
    return out;
  }
}
