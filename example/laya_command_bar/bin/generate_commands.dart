import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:args/args.dart';
import 'package:laya_command_bar_example/src/eval_cases.dart';
import 'package:laya_command_bar_example/src/example_bank.dart';
import 'package:laya_command_bar_example/src/intents.dart';
import 'package:llamadart/llamadart.dart';

const _styles = [
  'terse fragments, lowercase, no punctuation',
  'polite full sentences',
  'casual, with slang or abbreviations',
  'dictated by voice: run-on, filler words',
  'typed fast on a phone, with a typo or two',
  'written by a non-native English speaker',
];

const _topics = [
  'work and meetings',
  'family and friends',
  'home, errands and chores',
  'travel and commuting',
  'health, fitness and food',
  'money, shopping and bills',
  'school and studying',
  'hobbies, media and games',
];

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('model', help: 'Chat model GGUF path.')
    ..addOption('out', help: 'JSONL file of {intent, text} rows.')
    ..addOption('per-prompt', defaultsTo: '20')
    ..addOption('prompts', defaultsTo: '16', help: 'Prompts per intent.')
    ..addOption('seed', defaultsTo: '1');
  final args = parser.parse(arguments);
  final model = args.option('model'), outPath = args.option('out');
  if (model == null || outPath == null) {
    stderr.writeln(parser.usage);
    exitCode = 64;
    return;
  }
  final perPrompt = int.parse(args.option('per-prompt')!);
  final seed = int.parse(args.option('seed')!);
  final prompts = int.parse(args.option('prompts')!);
  final grid = [
    for (final style in _styles)
      for (final topic in _topics) (style, topic),
  ];

  final excluded = {
    for (final (_, t) in [...evalCases, ...heldOutCases]) _norm(t),
  };
  final seen = <String>{};
  final out = File(outPath).openWrite();
  final engine = LlamaEngine(LlamaBackend());
  await engine.loadModel(
    model,
    modelParams: const ModelParams(contextSize: 4096),
  );
  final definitions = [
    for (final i in CommandIntent.values)
      '- ${i.name}: ${intentDescriptions[i]}',
  ].join('\n');
  try {
    var prompt = 0;
    for (final intent in CommandIntent.values) {
      var kept = 0;
      final picks = [...grid]..shuffle(Random(seed + intent.index));
      for (final (style, topic) in picks.take(prompts)) {
        prompt++;
        final messages = [
          LlamaChatMessage.fromText(
            role: LlamaChatRole.system,
            text:
                'You write realistic test data for the command bar of a '
                'personal assistant app. Each command the user types has '
                'one of these intents:\n$definitions',
          ),
          LlamaChatMessage.fromText(
            role: LlamaChatRole.user,
            text:
                'Write $perPrompt different commands a user might type, '
                'every one with the intent "${intent.name}". Style: '
                '$style. Topic area: $topic. Vary the length from 1 to 15 '
                'words, the wording and the sentence structure. Include '
                'a few that share words with other intents but clearly '
                'mean "${intent.name}". Return JSON {"commands": [...]}.',
          ),
        ];
        final buffer = StringBuffer();
        await for (final chunk in engine.create(
          messages,
          params: GenerationParams(
            maxTokens: 1024,
            temp: 1.0,
            topP: 0.95,
            seed: seed * 1000 + prompt,
          ),
          enableThinking: false,
          responseFormat: const {
            'type': 'json_schema',
            'json_schema': {
              'schema': {
                'type': 'object',
                'properties': {
                  'commands': {
                    'type': 'array',
                    'items': {'type': 'string'},
                  },
                },
                'required': ['commands'],
              },
            },
          },
        )) {
          buffer.write(chunk.choices.first.delta.content ?? '');
        }
        final List<Object?> commands;
        try {
          commands = (jsonDecode(buffer.toString()) as Map)['commands'] as List;
        } on FormatException {
          stderr.writeln('prompt $prompt: unparsable output, skipped');
          continue;
        }
        for (final c in commands.whereType<String>()) {
          final text = c.trim();
          final key = _norm(text);
          if (text.isEmpty || excluded.contains(key) || !seen.add(key)) {
            continue;
          }
          out.writeln(jsonEncode({'intent': intent.name, 'text': text}));
          kept++;
        }
      }
      stdout.writeln('${intent.name}: $kept');
    }
  } finally {
    await out.close();
    await engine.dispose();
  }
}

String _norm(String text) =>
    text.toLowerCase().replaceAll(RegExp(r'[^a-z0-9 ]'), '').trim();
