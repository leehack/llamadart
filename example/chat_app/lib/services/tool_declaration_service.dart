import 'dart:convert';

import 'package:llamadart/llamadart.dart';

/// Validates and maps JSON tool declarations to [ToolDefinition] values.
class ToolDeclarationService {
  const ToolDeclarationService();

  /// Normalizes empty declarations to an empty JSON array.
  String normalizeDeclarations(String rawDeclarations) {
    return rawDeclarations.trim().isEmpty ? '[]' : rawDeclarations;
  }

  /// Parses a JSON declaration array into typed [ToolDefinition] values.
  ///
  /// [handlerFor] binds each declared name to a safe host implementation or an
  /// explicit unsupported-tool result.
  List<ToolDefinition> parseDefinitions(
    String rawJson, {
    required ToolHandler Function(String toolName) handlerFor,
  }) {
    Object decoded;
    try {
      decoded = jsonDecode(rawJson);
    } catch (_) {
      throw const FormatException('Tool declarations must be valid JSON.');
    }

    if (decoded is! List) {
      throw const FormatException('Tool declarations must be a JSON array.');
    }

    final tools = <ToolDefinition>[];
    final seenNames = <String>{};

    for (var i = 0; i < decoded.length; i++) {
      final entry = decoded[i];
      if (entry is! Map) {
        throw FormatException('Tool #${i + 1} must be an object.');
      }

      final functionMap = _normalizeToolFunctionMap(
        Map<String, dynamic>.from(entry),
        i + 1,
      );

      final name = functionMap['name'];
      if (name is! String || name.trim().isEmpty) {
        throw FormatException(
          'Tool #${i + 1} name must be a non-empty string.',
        );
      }

      final description = _readOptionalString(
        functionMap,
        'description',
        location: 'Tool #${i + 1}',
      );

      final rawParameters = functionMap['parameters'];
      final parametersSchema = rawParameters ?? const <String, dynamic>{};
      if (parametersSchema is! Map) {
        throw FormatException('Tool #${i + 1} parameters must be an object.');
      }

      final parameters = _parseToolParameters(
        Map<String, dynamic>.from(parametersSchema),
        toolNumber: i + 1,
      );

      final normalizedName = name.trim();
      if (!seenNames.add(normalizedName)) {
        throw FormatException(
          'Tool #${i + 1} duplicates the name `$normalizedName`.',
        );
      }
      tools.add(
        ToolDefinition(
          name: normalizedName,
          description: description?.trim() ?? '',
          parameters: parameters,
          handler: handlerFor(normalizedName),
        ),
      );
    }

    return tools;
  }

  /// Builds a readable message from parser failures.
  String formatError(Object error, {required String fallback}) {
    if (error is FormatException) {
      final message = error.message.toString().trim();
      if (message.isNotEmpty) {
        return message;
      }
    }
    return fallback;
  }

  static Map<String, dynamic> _normalizeToolFunctionMap(
    Map<String, dynamic> raw,
    int toolNumber,
  ) {
    if (raw.containsKey('function')) {
      final type = raw['type'];
      if (type != null && type != 'function') {
        throw FormatException(
          'Tool #$toolNumber must use `type: "function"` when `function` is provided.',
        );
      }

      final functionRaw = raw['function'];
      if (functionRaw is! Map) {
        throw FormatException('Tool #$toolNumber function must be an object.');
      }

      return Map<String, dynamic>.from(functionRaw);
    }

    final type = raw['type'];
    if (type != null && type != 'function') {
      throw FormatException('Tool #$toolNumber has unsupported type `$type`.');
    }

    return raw;
  }

  static List<ToolParam> _parseToolParameters(
    Map<String, dynamic> schema, {
    required int toolNumber,
  }) {
    final type = schema['type'];
    if (type != null && type != 'object') {
      throw FormatException(
        'Tool #$toolNumber parameters root must use `type: "object"`.',
      );
    }

    final requiredSet = _parseRequiredSet(
      schema['required'],
      location: 'Tool #$toolNumber required list',
    );
    final rawProperties = schema['properties'];
    if (rawProperties == null) {
      if (requiredSet.isNotEmpty) {
        throw FormatException(
          'Tool #$toolNumber required list contains undeclared properties.',
        );
      }
      return const <ToolParam>[];
    }
    if (rawProperties is! Map) {
      throw FormatException(
        'Tool #$toolNumber parameters.properties must be an object.',
      );
    }

    final properties = Map<String, dynamic>.from(rawProperties);
    final unknownRequired = requiredSet.difference(properties.keys.toSet());
    if (unknownRequired.isNotEmpty) {
      throw FormatException(
        'Tool #$toolNumber required list contains undeclared properties.',
      );
    }
    final params = <ToolParam>[];

    for (final entry in properties.entries) {
      final propertySchema = entry.value;
      if (propertySchema is! Map) {
        throw FormatException(
          'Tool #$toolNumber parameter `${entry.key}` schema must be an object.',
        );
      }

      params.add(
        _mapSchemaToToolParam(
          entry.key,
          Map<String, dynamic>.from(propertySchema),
          required: requiredSet.contains(entry.key),
          location: 'Tool #$toolNumber parameter `${entry.key}`',
        ),
      );
    }

    return params;
  }

  static ToolParam _mapSchemaToToolParam(
    String name,
    Map<String, dynamic> schema, {
    required bool required,
    required String location,
  }) {
    final description = _readOptionalString(
      schema,
      'description',
      location: location,
    );

    final enumValues = schema['enum'];
    if (enumValues is List && enumValues.every((value) => value is String)) {
      return ToolParam.enumType(
        name,
        values: enumValues.cast<String>(),
        description: description,
        required: required,
      );
    }

    final type = schema['type'];
    if (type == null || type == 'string') {
      return ToolParam.string(
        name,
        description: description,
        required: required,
      );
    }
    if (type == 'integer') {
      return ToolParam.integer(
        name,
        description: description,
        required: required,
      );
    }
    if (type == 'number') {
      return ToolParam.number(
        name,
        description: description,
        required: required,
      );
    }
    if (type == 'boolean') {
      return ToolParam.boolean(
        name,
        description: description,
        required: required,
      );
    }
    if (type == 'array') {
      final itemsRaw = schema['items'];
      final itemType = itemsRaw is Map
          ? _mapSchemaToToolParam(
              '${name}_item',
              Map<String, dynamic>.from(itemsRaw),
              required: false,
              location: '$location items',
            )
          : ToolParam.string('${name}_item');
      return ToolParam.array(
        name,
        itemType: itemType,
        description: description,
        required: required,
      );
    }
    if (type == 'object') {
      final nestedPropertiesRaw = schema['properties'];
      final nestedRequired = _parseRequiredSet(
        schema['required'],
        location: '$location required list',
      );
      final nested = <ToolParam>[];
      if (nestedPropertiesRaw != null && nestedPropertiesRaw is! Map) {
        throw FormatException('$location properties must be an object.');
      }
      final nestedProperties = nestedPropertiesRaw == null
          ? const <String, dynamic>{}
          : Map<String, dynamic>.from(nestedPropertiesRaw as Map);
      final unknownRequired = nestedRequired.difference(
        nestedProperties.keys.toSet(),
      );
      if (unknownRequired.isNotEmpty) {
        throw FormatException(
          '$location required list contains undeclared properties.',
        );
      }
      if (nestedProperties.isNotEmpty) {
        for (final entry in nestedProperties.entries) {
          final nestedSchema = entry.value;
          if (nestedSchema is! Map) {
            throw FormatException(
              '$location nested parameter `${entry.key}` schema must be an object.',
            );
          }
          nested.add(
            _mapSchemaToToolParam(
              entry.key,
              Map<String, dynamic>.from(nestedSchema),
              required: nestedRequired.contains(entry.key),
              location: '$location nested parameter `${entry.key}`',
            ),
          );
        }
      }
      return ToolParam.object(
        name,
        properties: nested,
        description: description,
        required: required,
      );
    }

    throw FormatException('$location uses unsupported type `$type`.');
  }

  static Set<String> _parseRequiredSet(
    Object? raw, {
    required String location,
  }) {
    if (raw == null) {
      return const <String>{};
    }

    if (raw is! List || raw.any((entry) => entry is! String)) {
      throw FormatException('$location must be a list of strings.');
    }

    return raw.cast<String>().toSet();
  }

  static String? _readOptionalString(
    Map<String, dynamic> source,
    String key, {
    required String location,
  }) {
    final value = source[key];
    if (value == null) {
      return null;
    }
    if (value is! String) {
      throw FormatException('$location $key must be a string.');
    }
    return value;
  }
}
