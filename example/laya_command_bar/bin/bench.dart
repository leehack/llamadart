import 'dart:io';

import 'package:args/args.dart';
import 'package:laya_command_bar_example/src/eval_cases.dart';
import 'package:laya_command_bar_example/src/gemma.dart';
import 'package:laya_command_bar_example/src/intent_gate.dart';
import 'package:laya_command_bar_example/src/intents.dart';
import 'package:laya_command_bar_example/src/laya.dart';
import 'package:laya_command_bar_example/src/llm.dart';
import 'package:laya_command_bar_example/src/sources.dart';
import 'package:llamadart/llamadart.dart';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption(
      'reader',
      allowed: ['laya', 'embedding', 'llm'],
      defaultsTo: 'laya',
      help: 'Which source reads the intent.',
    )
    ..addOption('model', help: 'Laya backbone GGUF path.')
    ..addOption('head', help: 'Laya head safetensors path.')
    ..addOption('embedding-model', help: 'EmbeddingGemma GGUF path.')
    ..addOption('llm-model', help: 'Instruction-tuned LLM GGUF path.')
    ..addOption('enter', help: 'Gate; defaults to the source default.')
    ..addFlag('cpu', help: 'Run on the CPU.', negatable: false)
    ..addFlag('verbose', abbr: 'v', help: 'Print every case.', negatable: false)
    ..addFlag('help', abbr: 'h', negatable: false);
  final ArgResults args;
  try {
    args = parser.parse(arguments);
  } on FormatException catch (e) {
    stderr.writeln('${e.message}\n\n${parser.usage}');
    exitCode = 64;
    return;
  }
  String? required(String name) {
    final value = args.option(name);
    if (value == null) {
      stderr.writeln('--$name is required for --reader ${args['reader']}');
      exitCode = 64;
    }
    return value;
  }

  if (args.flag('help')) {
    stdout.writeln(
      'Scores an intent source and its gate on the built-in cases.\n\n'
      '${parser.usage}',
    );
    return;
  }

  final IntentSource source;
  if (args.option('reader') == 'laya') {
    final model = required('model'), head = required('head');
    if (model == null || head == null) return;
    final laya = await Laya.load(
      backbone: ModelSource.path(model),
      head: ModelSource.path(head),
      cpu: args.flag('cpu'),
    );
    source = IntentSource(
      reader: laya.reader,
      enter: layaEnter,
      label: '${laya.backendName} · ${laya.deviceName}',
      minWords: layaMinWords,
      dispose: laya.dispose,
    );
  } else if (args.option('reader') == 'llm') {
    final model = required('llm-model');
    if (model == null) return;
    source = await loadLlmSource(
      model: ModelSource.path(model),
      cpu: args.flag('cpu'),
    );
  } else {
    final model = required('embedding-model');
    if (model == null) return;
    source = await loadEmbeddingSource(
      model: ModelSource.path(model),
      cpu: args.flag('cpu'),
    );
  }
  final enter = double.tryParse(args.option('enter') ?? '') ?? source.enter;

  try {
    stdout.writeln(
      '${args.option('reader')} on ${source.label}, gate $enter\n',
    );
    final micros = <int>[];
    Future<IntentReading> read(String text) async {
      final r = await source.reader(text);
      micros.add(r.elapsed.inMicroseconds);
      return r;
    }

    for (final (name, cases) in [
      ('Dev', evalCases),
      ('Held-out', heldOutCases),
    ]) {
      var top = 0, good = 0, wrong = 0, miss = 0;
      for (final (want, text) in cases) {
        final r = await read(text);
        if (r.top == want) top++;
        final words = text.trim().split(RegExp(r'\s+')).length;
        final shown =
            words >= source.minWords &&
                r.confidence >= enter &&
                r.top != CommandIntent.ask
            ? r.top
            : null;
        final String outcome;
        if (want == CommandIntent.ask) {
          outcome = shown == null ? 'good' : 'wrong';
        } else if (shown == null) {
          outcome = 'miss';
        } else {
          outcome = shown == want ? 'good' : 'wrong';
        }
        switch (outcome) {
          case 'good':
            good++;
          case 'wrong':
            wrong++;
          default:
            miss++;
        }
        if (args.flag('verbose')) {
          stdout.writeln(
            '${outcome.padRight(5)} ${want.name.padRight(9)} '
            '${r.top.name.padRight(9)} c=${r.confidence.toStringAsFixed(2)}  '
            '$text',
          );
        }
      }
      stdout.writeln(
        '$name (${cases.length}): top intent correct $top; '
        'good $good, wrong $wrong, miss $miss',
      );
    }

    stdout.writeln('\nTyping traces (shown intent after each pause):');
    for (final (want, steps) in typingTraces) {
      final gate = IntentGate(enter: enter, minWords: source.minWords);
      final shown = <String>[];
      for (final text in steps) {
        shown.add(gate.update(await read(text))?.name ?? '-');
      }
      stdout.writeln('  ${want.name.padRight(9)} ${shown.join(' > ')}');
    }

    micros.sort();
    String ms(double q) =>
        (micros[((micros.length - 1) * q).round()] / 1000).toStringAsFixed(1);
    stdout.writeln(
      '\nms per read over ${micros.length}: p50 ${ms(0.5)}, p95 ${ms(0.95)}, '
      'max ${ms(1)}',
    );
  } finally {
    await source.dispose();
  }
}
