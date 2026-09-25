import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:laya_command_bar_example/src/example_bank.dart';
import 'package:laya_command_bar_example/src/intents.dart';
import 'package:llamadart/llamadart.dart';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('model', help: 'Chat model GGUF path.')
    ..addOption('in', help: 'JSONL of {intent, text} rows.')
    ..addOption('out', help: 'JSONL of the rows the model labels the same.');
  final args = parser.parse(arguments);
  final model = args.option('model');
  final inPath = args.option('in'), outPath = args.option('out');
  if (model == null || inPath == null || outPath == null) {
    stdout.writeln(
      'Asks a chat model for the intent of each generated command and keeps '
      'the rows where it agrees with the label.\n\n${parser.usage}',
    );
    exitCode = 64;
    return;
  }

  final engine = LlamaEngine(LlamaBackend());
  await engine.loadModel(
    model,
    modelParams: const ModelParams(contextSize: 2048),
  );
  final names = [for (final i in CommandIntent.values) i.name];
  final system =
      'Classify a command typed into the command bar of a personal '
      'assistant app. The intents:\n'
      '${[for (final i in CommandIntent.values) '- ${i.name}: ${intentDescriptions[i]}'].join('\n')}\n'
      'Answer with the one intent that fits best.';
  final params = GenerationParams(
    maxTokens: 8,
    temp: 0,
    grammar: 'root ::= ${names.map((n) => '"$n"').join(' | ')}',
  );
  final out = File(outPath).openWrite();
  final disagreements = <String, int>{};
  var kept = 0, total = 0;
  try {
    for (final line in File(inPath).readAsLinesSync()) {
      if (jsonDecode(line) case {
        'intent': final String intent,
        'text': final String text,
      }) {
        total++;
        final buffer = StringBuffer();
        await for (final chunk in engine.create(
          [
            LlamaChatMessage.fromText(role: LlamaChatRole.system, text: system),
            LlamaChatMessage.fromText(
              role: LlamaChatRole.user,
              text: 'Command: $text',
            ),
          ],
          params: params,
          enableThinking: false,
        )) {
          buffer.write(chunk.choices.first.delta.content ?? '');
        }
        final answer = buffer.toString().trim();
        if (answer == intent) {
          out.writeln(line);
          kept++;
        } else {
          final key = '$intent->$answer';
          disagreements[key] = (disagreements[key] ?? 0) + 1;
        }
      }
    }
  } finally {
    await out.close();
    await engine.dispose();
  }
  stdout.writeln('kept $kept of $total');
  final sorted = disagreements.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  for (final e in sorted) {
    stdout.writeln('  ${e.key}: ${e.value}');
  }
}
