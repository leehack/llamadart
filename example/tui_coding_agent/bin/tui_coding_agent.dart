import 'dart:io';

import 'package:args/args.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_tui_coding_agent/tui_coding_agent.dart';
import 'package:nocterm/nocterm.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption(
      'model',
      abbr: 'm',
      help: 'Model path, URL, or Hugging Face spec owner/repo[:hint].',
      defaultsTo: defaultModelSource,
    )
    ..addOption(
      'workspace',
      abbr: 'w',
      help: 'Workspace root used for coding tools.',
      defaultsTo: Directory.current.path,
    )
    ..addOption(
      'cache-dir',
      help:
          'Directory used to cache downloaded models. Defaults to the per-user shared llamadart model cache.',
    )
    ..addOption(
      'ctx-size',
      help: 'Model context window size.',
      defaultsTo: '8192',
    )
    ..addOption(
      'gpu-layers',
      help: 'GPU layers to offload (99 ~= auto).',
      defaultsTo: '99',
    )
    ..addOption('temp', help: 'Generation temperature.', defaultsTo: '0.2')
    ..addOption('top-p', help: 'Top-p sampling value.', defaultsTo: '0.95')
    ..addOption('min-p', help: 'Min-p sampling value.', defaultsTo: '0.05')
    ..addOption(
      'predict',
      help: 'Maximum generated tokens per turn.',
      defaultsTo: '1200',
    )
    ..addFlag(
      'native-tool-calling',
      help:
          'Enable template-native tool-calling grammar (experimental, may be unstable on some models).',
      defaultsTo: false,
      negatable: true,
    )
    ..addFlag(
      'help',
      abbr: 'h',
      help: 'Show this help message.',
      negatable: false,
    );

  late final ArgResults results;
  try {
    results = parser.parse(arguments);
  } on ArgParserException catch (error) {
    stderr.writeln('Argument error: $error');
    stderr.writeln('');
    stderr.writeln(_usageHeader);
    stderr.writeln(parser.usage);
    exitCode = 64;
    return;
  }

  if (results['help'] as bool) {
    stdout.writeln(_usageHeader);
    stdout.writeln(parser.usage);
    stdout.writeln('');
    stdout.writeln(_usageExamples);
    return;
  }

  final workspaceRoot = p.normalize(p.absolute(results['workspace'] as String));
  if (!Directory(workspaceRoot).existsSync()) {
    stderr.writeln('Workspace directory not found: $workspaceRoot');
    exitCode = 64;
    return;
  }

  final cacheDirRaw = (results['cache-dir'] as String?)?.trim();
  final cacheDirectory = cacheDirRaw == null || cacheDirRaw.isEmpty
      ? DefaultModelDownloadManager.auto().defaultCacheDirectory
      : p.isAbsolute(cacheDirRaw)
      ? p.normalize(cacheDirRaw)
      : p.normalize(p.join(workspaceRoot, cacheDirRaw));

  final contextSize = _parseIntOption(results, 'ctx-size', fallback: 8192);
  final gpuLayers = _parseIntOption(results, 'gpu-layers', fallback: 99);
  final maxTokens = _parseIntOption(results, 'predict', fallback: 1200);

  final temperature = _parseDoubleOption(results, 'temp', fallback: 0.2);
  final topP = _parseDoubleOption(results, 'top-p', fallback: 0.95);
  final minP = _parseDoubleOption(results, 'min-p', fallback: 0.05);

  final config = CodingAgentConfig(
    workspaceRoot: workspaceRoot,
    modelSource: (results['model'] as String).trim(),
    modelCacheDirectory: cacheDirectory,
    modelParams: ModelParams(contextSize: contextSize, gpuLayers: gpuLayers),
    generationParams: GenerationParams(
      maxTokens: maxTokens,
      temp: temperature,
      topP: topP,
      minP: minP,
      penalty: 1.0,
    ),
    enableNativeToolCalling: results['native-tool-calling'] as bool,
  );

  await runApp(
    NoctermApp(
      title: 'llamadart agent',
      child: CodingAgentTui(config: config),
    ),
  );
}

int _parseIntOption(ArgResults results, String key, {required int fallback}) {
  final value = int.tryParse(results[key] as String);
  return value ?? fallback;
}

double _parseDoubleOption(
  ArgResults results,
  String key, {
  required double fallback,
}) {
  final value = double.tryParse(results[key] as String);
  return value ?? fallback;
}

const String _usageHeader =
    'llamadart agent\n\n'
    'A terminal UI coding assistant built with llamadart + nocterm.';

const String _usageExamples =
    'Examples:\n'
    '  dart run bin/tui_coding_agent.dart\n'
    '  dart run bin/tui_coding_agent.dart -w /path/to/project\n'
    '  dart run bin/tui_coding_agent.dart --model /path/to/model.gguf\n'
    '  dart run bin/tui_coding_agent.dart --model owner/repo:Q4_K_M\n'
    '  dart run bin/tui_coding_agent.dart --native-tool-calling';
