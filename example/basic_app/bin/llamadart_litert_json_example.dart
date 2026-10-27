import 'dart:convert';
import 'dart:io';

import 'package:llamadart/llamadart.dart';

/// Uses an existing canonical Qwen3 `.litertlm` bundle on macOS arm64 CPU.
Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    stderr.writeln(
      'Usage: dart run bin/llamadart_litert_json_example.dart <Qwen3.litertlm>',
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
        },
        'required': ['priority'],
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
      params: const GenerationParams(maxTokens: 64, temp: 0, topK: 1),
    );
    stdout.writeln(jsonEncode(result));
  } finally {
    await engine.dispose();
  }
}
