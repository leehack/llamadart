import 'package:llamadart/llamadart.dart';

import '../../domain/mcp_server_config.dart';

/// Pure adapter converting arbitrary external MCP JSON Schemas into
/// `llamadart` [ToolDefinition]s without weakening input constraints.
abstract final class McpToolSchemaAdapter {
  /// Converts an [McpToolDescriptor] into a `llamadart` [ToolDefinition],
  /// preserving its JSON Schema. Unsupported schemas throw a named
  /// [LlamaUnsupportedException] before the tool can run.
  static ToolDefinition toLlamaToolDefinition(
    McpToolDescriptor tool, {
    required Future<Object?> Function(ToolParams params) handler,
  }) {
    final sanitized = sanitizeMcpInputSchema(tool.inputSchema);
    final rawDesc = _compactDescription(tool.description, maxChars: 180);
    final description = rawDesc.isEmpty
        ? 'MCP tool ${tool.name} from ${tool.serverName}.'
        : '[MCP:${tool.serverName}] $rawDesc';

    try {
      return ToolDefinition.fromJsonSchema(
        name: tool.exposedToolName,
        description: description,
        schema: sanitized,
        handler: handler,
      );
    } on LlamaUnsupportedException catch (error) {
      throw LlamaUnsupportedException(
        'MCP tool "${tool.name}" is unavailable: ${error.message} '
        'Its input constraints cannot be weakened safely.',
      );
    }
  }

  /// Converts canonical schemas without weakening validation constraints.
  ///
  /// [allowClosedObjectSubset] additionally permits restricting generation to
  /// finite declared object fields; [onRestriction] reports that reduction.
  /// Invocation always retains the original canonical validation. Dynamic
  /// object schemas and unrepresentable constraints fail closed.
  static ToolDefinition coerceToLegacyToolDefinition(
    ToolDefinition tool, {
    bool allowClosedObjectSubset = false,
    void Function(String reason)? onRestriction,
  }) {
    final schema = tool.toJsonSchema();
    // Canonical schemas always publish an explicit property policy. Existing
    // ToolParam tools already have the legacy runtime's closed-object policy.
    if (!schema.containsKey('additionalProperties')) return tool;
    final params = _tryJsonSchemaToToolParams(
      schema,
      allowClosedObjectSubset: allowClosedObjectSubset,
    );
    if (params == null) {
      throw LlamaUnsupportedException(
        'Tool "${tool.name}" requires canonical JSON Schema input constraints '
        'that this model/chat template cannot represent with legacy parameters. '
        'Disable the tool or choose a compatible model/runtime.',
      );
    }
    if (allowClosedObjectSubset && _containsOpenObject(schema)) {
      onRestriction?.call(
        'Restricted generation options: this model can supply only the tool\'s '
        'declared object fields. Choose a compatible model/runtime for additional fields.',
      );
    }
    return ToolDefinition(
      name: tool.name,
      description: tool.description,
      parameters: params,
      handler: tool.handler == null
          ? null
          : (params) => tool.invoke(params.raw),
    );
  }

  /// Copies an MCP schema root without discarding validation constraints.
  /// Missing root type defaults to the object required by MCP tool arguments.
  static Map<String, dynamic> sanitizeMcpInputSchema(
    Map<String, dynamic> rawSchema,
  ) {
    // The canonical tool constructor bounds and owns the complete JSON tree.
    final owned = Map<String, dynamic>.of(rawSchema);
    owned.putIfAbsent('type', () => 'object');
    return owned;
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

  static List<ToolParam>? _tryJsonSchemaToToolParams(
    Map<String, dynamic> objectSchema, {
    bool allowClosedObjectSubset = false,
  }) {
    final rawProps = objectSchema['properties'];
    final canCloseObject =
        allowClosedObjectSubset &&
        objectSchema['additionalProperties'] == true &&
        rawProps is Map &&
        rawProps.isNotEmpty;
    if ((!canCloseObject && objectSchema['additionalProperties'] != false) ||
        objectSchema.containsKey('anyOf') ||
        objectSchema.containsKey('const') ||
        objectSchema['additionalProperties'] is Map) {
      return null;
    }
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
    if (requiredSet.any((name) => !rawProps.containsKey(name))) return null;

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
        allowClosedObjectSubset: allowClosedObjectSubset,
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
    bool allowClosedObjectSubset = false,
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
          allowClosedObjectSubset: allowClosedObjectSubset,
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
        final nested = _tryJsonSchemaToToolParams(
          schema,
          allowClosedObjectSubset: allowClosedObjectSubset,
        );
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

  static bool _containsOpenObject(Object? node) {
    if (node is Map) {
      if (node['type'] == 'object' && node['additionalProperties'] == true) {
        return true;
      }
      return node.values.any(_containsOpenObject);
    }
    return node is List && node.any(_containsOpenObject);
  }
}
