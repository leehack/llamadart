import 'dart:convert';
import 'dart:io';

import 'package:llamadart/llamadart.dart';

const _defaultPrompt =
    'Write a concise explanation of why on-device language models are useful.';

Future<void> main(List<String> args) async {
  final modelPath = args.isNotEmpty
      ? args.first
      : '.dart_tool/litert_lm_models/gemma-4-E2B-it.litertlm';
  final backend = args.length > 1 ? args[1] : 'gpu';
  final prompt = args.length > 2 ? args[2] : _defaultPrompt;

  final client = LiteRtLmRuntimeClient();
  try {
    stderr.writeln('Initializing LiteRT-LM ($backend): $modelPath');
    await client.initialize(
      modelPath: modelPath,
      backend: backend,
      maxTokens: 4096,
      outputTokens: 256,
      speculativeDecoding: false,
    );
    stderr.writeln('Running benchmark...');
    final result = await client.run(
      prompt: prompt,
      warmupRuns: 1,
      measuredRuns: 3,
    );
    print('RESULT litert_lm ${jsonEncode(result.metrics.toJson())}');
    print('LAST_TEXT ${jsonEncode(result.text)}');
  } catch (error, stackTrace) {
    stderr.writeln('ERROR $error');
    stderr.writeln(stackTrace);
    exitCode = 1;
  } finally {
    client.dispose();
  }
}
