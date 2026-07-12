import 'dart:io';

import 'package:args/args.dart';
import 'package:llamadart_tui_coding_agent/tui_coding_agent.dart';
import 'package:nocterm/nocterm.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption(
      'model',
      abbr: 'm',
      help: 'Local path, URL, or exact hf://owner/repo/model-file reference.',
      defaultsTo: defaultModelSource,
    )
    ..addOption(
      'workspace',
      abbr: 'w',
      help: 'Directory exposed to the coding tools.',
      defaultsTo: Directory.current.path,
    )
    ..addOption(
      'cache-dir',
      help: 'Model cache directory (defaults to the shared llamadart cache).',
    )
    ..addFlag(
      'thinking',
      help: 'Enable Qwen thinking (on/off; no reasoning-effort tiers).',
      negatable: false,
    )
    ..addFlag(
      'read-only',
      help: 'Expose only the read tool; disable write, edit, and bash.',
      negatable: false,
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
    _printUsage(parser, error: '$error');
    exitCode = 64;
    return;
  }

  if (results.flag('help')) {
    _printUsage(parser);
    return;
  }

  final workspace = p.normalize(
    p.absolute((results.option('workspace') ?? '').trim()),
  );
  if (!Directory(workspace).existsSync()) {
    _printUsage(parser, error: 'Workspace directory not found: $workspace');
    exitCode = 64;
    return;
  }

  final model = (results.option('model') ?? '').trim();
  if (model.isEmpty) {
    _printUsage(parser, error: '--model must not be empty.');
    exitCode = 64;
    return;
  }

  final cacheOption = results.option('cache-dir')?.trim();
  final cacheDirectory = cacheOption == null || cacheOption.isEmpty
      ? null
      : p.normalize(
          p.isAbsolute(cacheOption)
              ? cacheOption
              : p.join(workspace, cacheOption),
        );

  final preset = results.flag('thinking')
      ? qwen36ThinkingCodingAgentPreset
      : qwen36CodingAgentPreset;
  final config = CodingAgentConfig(
    workspaceRoot: workspace,
    modelSource: model,
    modelCacheDirectory: cacheDirectory,
    modelParams: preset.modelParams,
    generationParams: preset.generationParams,
    maxToolRounds: preset.maxToolRounds,
    readOnly: results.flag('read-only'),
    enableThinking: preset.enableThinking,
  );

  await runApp(
    NoctermApp(
      title: 'llamadart agent',
      child: CodingAgentTui(config: config),
    ),
  );
}

void _printUsage(ArgParser parser, {String? error}) {
  if (error != null) {
    stderr.writeln('Argument error: $error\n');
  }
  final sink = error == null ? stdout : stderr;
  sink.writeln('llamadart agent');
  sink.writeln('A small local coding agent powered by Qwen3.6.\n');
  sink.writeln(parser.usage);
  sink.writeln('\nExamples:');
  sink.writeln('  dart run bin/tui_coding_agent.dart');
  sink.writeln('  dart run bin/tui_coding_agent.dart --thinking');
  sink.writeln('  dart run bin/tui_coding_agent.dart -w /path/to/project');
  sink.writeln('  dart run bin/tui_coding_agent.dart -m /path/to/model.gguf');
}
