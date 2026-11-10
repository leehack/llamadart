import 'dart:convert';
import 'dart:io';

import 'package:llamadart/llamadart.dart';

/// Uses an existing Qwen3 or Gemma 4 `.litertlm` bundle on macOS arm64.
Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    stderr.writeln(
      'Usage: dart run bin/llamadart_litert_json_example.dart '
      '<Qwen3-or-gemma-4.litertlm>',
    );
    exitCode = 64;
    return;
  }
  final engine = LlamaEngine(LlamaBackend());
  try {
    await engine.setModel(
      LlamaModel(ModelSource.path(arguments.single)),
      params: const ModelParams(device: ComputeDevice.cpu, contextSize: 1024),
    );
    if (!(await engine.capabilities).supportsStructuredOutput) {
      throw LlamaUnsupportedException(
        'This model/runtime has no admitted JSON Schema provider.',
      );
    }
    final output = LlamaStructuredOutput<Map<String, dynamic>>.jsonSchema(
      schema: const {
        'type': 'object',
        'properties': {
          'priority': {
            'type': 'string',
            'enum': ['low', 'high'],
          },
          'actions': {
            'type': 'array',
            'items': {'type': 'string', 'maxLength': 40},
            'minItems': 1,
            'maxItems': 3,
          },
        },
        'required': ['priority', 'actions'],
        'additionalProperties': false,
      },
      decoder: (json) => json,
    );
    final result = await engine.createStructuredJson(
      const [
        LlamaChatMessage.fromText(
          role: LlamaChatRole.user,
          text: 'A production database is unavailable. Classify the priority.',
        ),
      ],
      output: output,
      enableThinking: false,
      params: const GenerationParams(maxTokens: 128, temp: 0, topK: 1),
    );
    stdout.writeln(jsonEncode(result));
  } finally {
    await engine.dispose();
  }
}
