import 'dart:io';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart_basic_example/services/decision_cli_options.dart';
import 'package:llamadart_basic_example/services/decision_ticket_triage.dart';

Future<void> main(List<String> arguments) async {
  final parser = createDecisionArgParser();
  final DecisionCliOptions options;
  try {
    final results = parser.parse(arguments);
    if (results['help'] as bool) {
      stdout.write(buildDecisionHelpText(parser));
      return;
    }
    options = parseDecisionCliOptions(results);
  } on FormatException catch (error) {
    stderr
      ..writeln(error.message)
      ..writeln()
      ..writeln(parser.usage);
    exitCode = 64;
    return;
  }

  final engine = LlamaEngine(LlamaBackend());
  DecisionEngine? decisions;
  try {
    final head = await _ensureFile(engine, options.headSource, 'head');
    final configSource = options.configSource;
    final config = configSource == null
        ? null
        : await _ensureFile(engine, configSource, 'config');

    final model = options.modelSource;
    print('Loading backbone ${model.displayName}...');
    await _withProgress(
      'backbone',
      (onProgress) => engine.loadModelSource(
        model,
        modelParams: options.modelParams,
        onProgress: onProgress,
      ),
    );

    decisions = await DecisionEngine.load(
      engine,
      headPath: head,
      configPath: config,
    );
    print(
      'Backend: ${await engine.getBackendName()}, '
      'head device: ${decisions.info.deviceName}',
    );

    final state = options.state ?? defaultTicketState;
    print('Ticket: ${decisionValueText(state)}\n');

    final stopwatch = Stopwatch()..start();
    final result = await decisions.systemOne(
      state: state,
      questions: ticketTriageQuestions,
    );
    stopwatch.stop();

    stdout.write(formatDecisionAnswers(result));
    print(
      '\n${result.answers.length} questions in '
      '${stopwatch.elapsedMilliseconds} ms, '
      '${result.usage.inputTokens} input tokens.',
    );
    if (options.printJson) {
      print('\n${formatDecisionJson(result)}');
    }
  } on LlamaUnsupportedException catch (error) {
    stderr.writeln('Cannot run this decision model: $error');
    exitCode = 2;
  } catch (error) {
    stderr.writeln('Error: $error');
    if ('$error'.contains('"laya.config"')) {
      stderr.writeln("Pass the head's rl_agent_config.json with --config.");
    }
    exitCode = 1;
  } finally {
    await decisions?.dispose();
    await engine.dispose();
  }
}

Future<String> _ensureFile(
  LlamaEngine engine,
  ModelSource source,
  String label,
) async {
  print('Fetching $label ${source.displayName}...');
  final entry = await _withProgress(
    label,
    (onProgress) =>
        engine.modelDownloadManager.ensureModel(source, onProgress: onProgress),
  );
  return entry.filePath;
}

Future<T> _withProgress<T>(
  String label,
  Future<T> Function(ModelDownloadProgressCallback onProgress) run,
) async {
  String? last;
  try {
    return await run((progress) {
      final fraction = progress.fraction;
      final text = fraction == null
          ? '${progress.receivedBytes ~/ 1048576} MB'
          : '${(fraction * 100).toStringAsFixed(0)}%';
      if (text == last) return;
      last = text;
      stdout.write('\rDownloading $label: $text');
    });
  } finally {
    if (last != null) stdout.writeln();
  }
}
