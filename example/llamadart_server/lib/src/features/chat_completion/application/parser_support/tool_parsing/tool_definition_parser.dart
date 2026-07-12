import 'package:llamadart/llamadart.dart';

import '../../../../shared/openai_http_exception.dart';
import 'tool_parameter_schema_parser.dart';

List<ToolDefinition>? parseToolDefinitions(Object? rawTools) {
  if (rawTools == null) {
    return null;
  }

  if (rawTools is! List) {
    throw OpenAiHttpException.invalidRequest(
      '`tools` must be an array.',
      param: 'tools',
    );
  }

  if (rawTools.isEmpty) {
    return null;
  }

  final tools = <ToolDefinition>[];

  for (final raw in rawTools) {
    if (raw is! Map) {
      throw OpenAiHttpException.invalidRequest(
        'Each tool must be an object.',
        param: 'tools',
      );
    }

    final tool = Map<String, dynamic>.from(raw);
    final type = tool['type'];
    if (type != 'function') {
      throw OpenAiHttpException.invalidRequest(
        'Only `type = "function"` tools are supported.',
        param: 'tools.type',
      );
    }

    final function = tool['function'];
    if (function is! Map) {
      throw OpenAiHttpException.invalidRequest(
        'Tool requires a `function` object.',
        param: 'tools.function',
      );
    }

    final functionMap = Map<String, dynamic>.from(function);

    final name = functionMap['name'];
    if (name is! String || name.isEmpty) {
      throw OpenAiHttpException.invalidRequest(
        'Tool function name must be a non-empty string.',
        param: 'tools.function.name',
      );
    }

    final description = functionMap['description'];
    if (description != null && description is! String) {
      throw OpenAiHttpException.invalidRequest(
        'Tool function description must be a string.',
        param: 'tools.function.description',
      );
    }

    tools.add(
      ToolDefinition(
        name: name,
        description: description as String? ?? '',
        parameters: parseToolParameters(functionMap['parameters']),
        handler: _clientManagedToolHandler,
      ),
    );
  }

  return tools;
}

Future<Object?> _clientManagedToolHandler(ToolParams _) {
  return Future<Object?>.error(
    LlamaUnsupportedException(
      'Tool execution is handled by the API client. Submit the tool result in '
      'a follow-up chat completion request.',
    ),
  );
}
