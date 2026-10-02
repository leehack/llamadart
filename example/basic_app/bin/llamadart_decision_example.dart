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

  DecisionEngine? decisions;
  try {
    final model = DecisionModel(
      encoder: options.modelSource,
      head: options.headSource,
      config: options.configSource,
    );
    print('Loading ${model.encoder.displayName}...');
    final loaded = await _withProgress(
      'model files',
      (onProgress) => DecisionEngine.load(
        model,
        params: options.params,
        onProgress: onProgress,
      ),
    );
    decisions = loaded;
    final capabilities = await loaded.capabilities;
    print(
      'Backend: ${capabilities.backendName}, '
      'head device: ${loaded.info.deviceName}',
    );

    final state = options.state ?? defaultTicketState;
    print('Ticket: ${decisionValueText(state)}\n');

    final stopwatch = Stopwatch()..start();
    final result = await loaded.systemOne(
      state: state,
      questions: ticketTriageQuestions,
    );
    stopwatch.stop();

    stdout.write(formatTicketTriage(result));
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
  } on LlamaModelException catch (error) {
    stderr.writeln('Error: $error');
    if (error.message.contains('laya.config')) {
      stderr.writeln('Pass the head\'s rl_agent_config.json with --config.');
    }
    exitCode = 1;
  } catch (error) {
    stderr.writeln('Error: $error');
    exitCode = 1;
  } finally {
    await decisions?.dispose();
  }
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
