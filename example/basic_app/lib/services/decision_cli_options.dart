import 'dart:convert';

import 'package:args/args.dart';
import 'package:llamadart/llamadart.dart';

/// Hugging Face revision of `fr0stbit3/laya-gguf` used by the defaults.
const String layaGgufRevision = 'ce2afdc0a8766af56a29a22dcf4a781e1f5c7d3c';

/// Default backbone source: the pinned `laya-Q8_0.gguf`.
const String defaultDecisionModelSource =
    'hf://fr0stbit3/laya-gguf@$layaGgufRevision/laya-Q8_0.gguf';

/// Default head source: the pinned `laya-head.safetensors`.
const String defaultDecisionHeadSource =
    'hf://fr0stbit3/laya-gguf@$layaGgufRevision/laya-head.safetensors';

/// Parsed command-line options for the decision example.
final class DecisionCliOptions {
  /// Creates parsed options.
  const DecisionCliOptions({
    required this.modelSource,
    required this.headSource,
    required this.configSource,
    required this.state,
    required this.forceCpu,
    required this.threads,
    required this.printJson,
  });

  /// Backbone GGUF.
  final ModelSource modelSource;

  /// Decision head safetensors.
  final ModelSource headSource;

  /// Laya `rl_agent_config.json` for heads without `laya.config` metadata.
  final ModelSource? configSource;

  /// State override: a JSON object or array, or text. Null keeps the default
  /// ticket.
  final Object? state;

  /// Whether to run the backbone and head on the CPU.
  final bool forceCpu;

  /// CPU threads for the encoder and head; 0 keeps llama.cpp's default.
  final int threads;

  /// Whether to print the Laya response JSON.
  final bool printJson;

  /// Backbone parameters: a 512-token context, the CPU backend when
  /// [forceCpu], and [threads] as [ModelParams.numberOfThreadsBatch].
  ModelParams get modelParams => ModelParams(
    contextSize: 512,
    preferredBackend: forceCpu ? GpuBackend.cpu : GpuBackend.auto,
    gpuLayers: forceCpu ? 0 : ModelParams.maxGpuLayers,
    numberOfThreadsBatch: threads,
  );
}

/// Creates the argument parser for the decision example.
ArgParser createDecisionArgParser() {
  return ArgParser()
    ..addOption(
      'model',
      abbr: 'm',
      help: 'Backbone GGUF: local path, HTTP(S) URL, or hf:// source.',
      defaultsTo: defaultDecisionModelSource,
    )
    ..addOption(
      'head',
      help:
          'Decision head safetensors: local path, HTTP(S) URL, or hf:// '
          'source.',
      defaultsTo: defaultDecisionHeadSource,
    )
    ..addOption(
      'config',
      help:
          'rl_agent_config.json (local path, HTTP(S) URL, or hf:// source) '
          'for a head without laya.config metadata, such as the official '
          'convaiinnovations/laya model.safetensors.',
    )
    ..addOption(
      'state',
      abbr: 's',
      help: 'Ticket to triage: text, or a JSON object or array.',
    )
    ..addFlag(
      'cpu',
      help: 'Run the backbone and head on the CPU.',
      negatable: false,
    )
    ..addOption(
      'threads',
      help: 'CPU threads for the encoder and head (0 keeps the default).',
      defaultsTo: '0',
    )
    ..addFlag(
      'json',
      help: 'Also print the Laya response JSON.',
      negatable: false,
    )
    ..addFlag('help', abbr: 'h', help: 'Show this help.', negatable: false);
}

/// Parses [results] from [createDecisionArgParser].
///
/// `--state` becomes a JSON value when it decodes to an object or array, and
/// stays text otherwise. Throws [FormatException] for an invalid `--threads`
/// or an invalid `--model`, `--head` or `--config` source.
DecisionCliOptions parseDecisionCliOptions(ArgResults results) {
  final threadsText = results['threads'] as String;
  final threads = int.tryParse(threadsText);
  if (threads == null || threads < 0) {
    throw FormatException(
      '--threads must be an integer of 0 or more: $threadsText',
    );
  }
  final stateText = results['state'] as String?;
  final configText = results['config'] as String?;
  return DecisionCliOptions(
    modelSource: _parseSource('model', results['model'] as String),
    headSource: _parseSource('head', results['head'] as String),
    configSource: configText == null
        ? null
        : _parseSource('config', configText),
    state: stateText == null ? null : parseDecisionState(stateText),
    forceCpu: results['cpu'] as bool,
    threads: threads,
    printJson: results['json'] as bool,
  );
}

ModelSource _parseSource(String option, String text) {
  try {
    return ModelSource.parse(text);
  } on ArgumentError catch (error) {
    throw FormatException('--$option: ${error.message}');
  }
}

/// Returns [text] decoded when it is a JSON object or array, else [text].
Object parseDecisionState(String text) {
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    return text;
  }
  return switch (decoded) {
    final Map<String, Object?> object => object,
    final List<Object?> array => array,
    _ => text,
  };
}

/// Builds the help text for the decision example.
String buildDecisionHelpText(ArgParser parser) {
  final buffer = StringBuffer()
    ..writeln('llamadart Decision Example')
    ..writeln()
    ..writeln(
      'Triages a support ticket with a Laya decision model: one choice, one '
      'score and one yes/no question.',
    )
    ..writeln()
    ..writeln(parser.usage)
    ..writeln()
    ..writeln('Examples:')
    ..writeln('  dart run bin/llamadart_decision_example.dart')
    ..writeln(
      '  dart run bin/llamadart_decision_example.dart --json '
      "--state 'The app crashes on login since the last update.'",
    )
    ..writeln(
      '  dart run bin/llamadart_decision_example.dart '
      '--head path/to/model.safetensors '
      '--config path/to/rl_agent_config.json',
    );
  return buffer.toString();
}
