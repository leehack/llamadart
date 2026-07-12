import 'package:llamadart/llamadart.dart';

import '../../../../shared/openai_http_exception.dart';

ToolChoice? parseToolChoice(Object? raw, List<ToolDefinition>? tools) {
  if (raw == null) {
    if (tools == null || tools.isEmpty) {
      return null;
    }
    return ToolChoice.auto;
  }

  if (raw is String) {
    switch (raw) {
      case 'none':
        return ToolChoice.none;
      case 'auto':
        return ToolChoice.auto;
      case 'required':
        return ToolChoice.required;
      default:
        throw OpenAiHttpException.invalidRequest(
          'Unsupported `tool_choice` value `$raw`.',
          param: 'tool_choice',
        );
    }
  }

  if (raw is Map) {
    _forcedFunctionName(raw, tools);
    return ToolChoice.required;
  }

  throw OpenAiHttpException.invalidRequest(
    '`tool_choice` must be a string or object.',
    param: 'tool_choice',
  );
}

/// Restricts a named forced choice to the requested function definition.
///
/// Core [ToolChoice] only distinguishes required calls from automatic calls,
/// so filtering the definitions preserves OpenAI's named-function semantics.
List<ToolDefinition>? restrictToolsForToolChoice(
  Object? raw,
  List<ToolDefinition>? tools,
) {
  if (raw is! Map) {
    return tools;
  }

  final name = _forcedFunctionName(raw, tools);
  return tools!
      .where((ToolDefinition tool) => tool.name == name)
      .toList(growable: false);
}

String _forcedFunctionName(Object raw, List<ToolDefinition>? tools) {
  final choice = Map<String, dynamic>.from(raw as Map);
  if (choice['type'] != 'function') {
    throw OpenAiHttpException.invalidRequest(
      'Only function tool choices are supported.',
      param: 'tool_choice.type',
    );
  }

  final function = choice['function'];
  if (function is! Map) {
    throw OpenAiHttpException.invalidRequest(
      'A named tool choice requires a `function` object.',
      param: 'tool_choice.function',
    );
  }

  final name = function['name'];
  if (name is! String || name.trim().isEmpty) {
    throw OpenAiHttpException.invalidRequest(
      'A named tool choice requires a non-empty `function.name`.',
      param: 'tool_choice.function.name',
    );
  }

  if (tools == null || !tools.any((ToolDefinition tool) => tool.name == name)) {
    throw OpenAiHttpException.invalidRequest(
      'Named tool `$name` was not provided in `tools`.',
      param: 'tool_choice.function.name',
    );
  }

  return name;
}
