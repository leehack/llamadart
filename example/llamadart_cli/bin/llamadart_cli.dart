import 'dart:io';

import 'package:llamadart/llama_cpp_bindings.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_cli_example/llamadart_cli.dart';

Future<void> main(List<String> arguments) async {
  _configureNativeLogLevel();
  await LlamaLogging.configure(nativeLevel: LlamaLogLevel.warn);

  final parser = LlamaCliArgParser();
  LlamaCliConfig config;

  try {
    config = parser.parse(arguments);
  } on LlamaCliArgException catch (e) {
    stderr.writeln('Argument error: $e');
    stderr.writeln('');
    stderr.writeln(_usageHeader);
    stderr.writeln(parser.usage);
    exitCode = 64;
    return;
  }

  if (config.showHelp) {
    stdout.writeln(_usageHeader);
    stdout.writeln(parser.usage);
    stdout.writeln('');
    stdout.writeln(_examplesText);
    return;
  }

  final runner = LlamaCliRunner(config);
  try {
    await runner.run();
  } catch (e) {
    stderr.writeln('Error: $e');
    exitCode = 1;
  } finally {
    await runner.dispose();
  }
}

const String _usageHeader =
    'llamadart-cli (llama.cpp-style local chat CLI)\n\n'
    'Compatible flow for GLM examples:\n'
    '  --model /path/to/model.gguf\n'
    '  -hf owner/repo:QUANT_HINT';

const String _examplesText =
    'Examples:\n'
    '  dart run bin/llamadart_cli.dart \\\n'
    '    -hf unsloth/GLM-4.7-Flash-GGUF:UD-Q4_K_XL \\\n'
    '    --jinja --ctx-size 16384 --fit on \\\n'
    '    --temp 1.0 --top-p 0.95 --min-p 0.01\n\n'
    '  dart run bin/llamadart_cli.dart \\\n'
    '    --model ./models/GLM-4.7-Flash-UD-Q4_K_XL.gguf \\\n'
    '    --ctx-size 16384 --fit on --jinja';

void _configureNativeLogLevel() {
  try {
    llama_dart_set_log_level(LlamaLogLevel.warn.index);
  } catch (_) {
    // Ignore when native bindings are not initialized yet.
  }
}
