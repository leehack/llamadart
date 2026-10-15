import 'dart:convert';
import 'dart:io';

import 'package:llamadart/llamadart.dart';

/// Runs an imported-schema tool against a local GGUF model.
Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln(
      'Usage: dart run bin/llamadart_schema_tool_example.dart MODEL.gguf',
    );
    exitCode = 64;
    return;
  }
  final engine = LlamaEngine(LlamaBackend());
  final tool = ToolDefinition.fromJsonSchema(
    name: 'sum',
    description: 'Add a list of numbers',
    schema: {
      'type': 'object',
      'properties': {
        'numbers': {
          'type': 'array',
          'items': {'type': 'number'},
          'minItems': 1,
        },
      },
      'required': ['numbers'],
      'additionalProperties': false,
    },
    handler: (params) async => params
        .getRequiredList<num>('numbers')
        .fold<num>(0, (total, value) => total + value),
  );
  try {
    await engine.setModel(LlamaModel(ModelSource.path(args.single)));
    final session = ChatSession(
      engine,
      systemPrompt: 'Use the sum tool when asked to add numbers.',
    );
    final result = await session.sendWithTools(
      'Add 12 and 30.',
      tools: [tool],
      maxRounds: 2,
      toolChoice: ToolChoice.required,
      onMessageAdded: (message) {
        for (final part in message.parts.whereType<LlamaToolResultContent>()) {
          stdout.writeln('Tool result: ${jsonEncode(part.result)}');
        }
      },
    );
    stdout.writeln(result.text);
    stdout.writeln('Stopped: ${result.stopReason.name}');
  } on LlamaUnsupportedException catch (error) {
    stderr.writeln(error.message);
    stderr.writeln(
      'Use a GGUF with a supported JSON tool format; see the tool-calling guide.',
    );
    exitCode = 1;
  } finally {
    await engine.dispose();
  }
}
