import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:args/args.dart';
import 'package:laya_command_bar_example/src/eval_cases.dart';
import 'package:laya_command_bar_example/src/example_bank.dart';
import 'package:laya_command_bar_example/src/intents.dart';
import 'package:llamadart/llamadart.dart';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption(
      'generated',
      help: 'JSONL of {intent, text} rows from bin/generate_commands.dart.',
    )
    ..addOption(
      'templates',
      defaultsTo: '250',
      help: 'Template commands per intent.',
    )
    ..addOption('seed', defaultsTo: '7')
    ..addFlag('help', abbr: 'h', negatable: false);
  final ArgResults args;
  try {
    args = parser.parse(arguments);
  } on FormatException catch (e) {
    stderr.writeln('${e.message}\n\n${parser.usage}');
    exitCode = 64;
    return;
  }
  if (args.flag('help') || args.rest.length != 1) {
    stdout.writeln(
      'Writes train.jsonl (seed, template and generated commands), val.jsonl '
      '(the development commands) and test.jsonl (the held-out commands) '
      'into <out-dir>.\n\n'
      'usage: dart run bin/make_dataset.dart [options] <out-dir>\n\n'
      '${parser.usage}',
    );
    if (!args.flag('help')) exitCode = 64;
    return;
  }

  final scored = {
    for (final (_, t) in [...evalCases, ...heldOutCases]) normalize(t),
  };
  final train = <(CommandIntent, String)>[...seedExamples];
  final seen = {for (final (_, t) in train) normalize(t), ...scored};
  void addAll(Iterable<(CommandIntent, String)> rows) {
    for (final row in rows) {
      if (seen.add(normalize(row.$2))) train.add(row);
    }
  }

  addAll(
    templateCommands(
      Random(int.parse(args.option('seed')!)),
      int.parse(args.option('templates')!),
    ),
  );
  final generated = args.option('generated');
  if (generated != null) {
    final intents = CommandIntent.values.asNameMap();
    addAll([
      for (final line in File(generated).readAsLinesSync())
        if (jsonDecode(line) case {
          'intent': final String intent,
          'text': final String text,
        })
          (intents[intent]!, text),
    ]);
  }

  final dir = Directory(args.rest.single)..createSync(recursive: true);
  final question = DecisionKey.questionsOf([intentKey]).values.single.toJson();
  for (final (name, cases) in [
    ('train', train),
    ('val', evalCases),
    ('test', heldOutCases),
  ]) {
    final sink = File('${dir.path}/$name.jsonl').openWrite();
    for (final (intent, text) in cases) {
      final target = [
        for (final i in CommandIntent.values) i == intent ? 1.0 : 0.0,
      ];
      sink.writeln(
        jsonEncode({
          'state': text,
          'q': question,
          'target': target,
          'h': target,
        }),
      );
    }
    await sink.close();
    stdout.writeln('$name: ${cases.length}');
  }
}

/// Lowercase letters, digits and spaces of [text], for duplicate checks.
String normalize(String text) =>
    text.toLowerCase().replaceAll(RegExp(r'[^a-z0-9 ]'), '').trim();

/// Up to [perIntent] distinct template commands per intent.
List<(CommandIntent, String)> templateCommands(Random rng, int perIntent) {
  T pick<T>(List<T> list) => list[rng.nextInt(list.length)];
  const people = [
    'mom',
    'dad',
    'Alex',
    'Priya',
    'Tom',
    'Maria',
    'Chen',
    'my sister',
    'the team',
    'Jordan',
    'Nina',
    'my manager',
    'Omar',
    'grandma',
    'Leo',
    'the landlord',
    'Hana',
    'coach',
  ];
  const days = [
    'today',
    'tomorrow',
    'tonight',
    'on Monday',
    'on Tuesday',
    'Wednesday',
    'this Friday',
    'next Thursday',
    'on Saturday',
    'this weekend',
    'next week',
    'on the 15th',
  ];
  const times = [
    'at 9',
    'at 7am',
    'at noon',
    'at 3:30',
    'at 6pm',
    'at 10',
    'in the morning',
    'after lunch',
    'in 20 minutes',
    'in an hour',
    'at 8:15',
  ];
  const things = [
    'the tax forms',
    'my passport scan',
    'the lease',
    'vacation photos',
    'the recipe for lasagna',
    "last month's invoices",
    'the project proposal',
    'my gym schedule',
    'the flight confirmation',
    'notes from the design review',
    'the wifi password',
    'the birthday video',
    'my resume',
    'the podcast I saved',
    'the warranty for the fridge',
  ];
  const chores = [
    'water the plants',
    'renew the car registration',
    'clean the garage',
    'order printer ink',
    'return the library books',
    'book a vet appointment for the cat',
    'fix the leaking tap',
    'back up my laptop',
    'pay the credit card',
    'buy batteries',
    'call the plumber',
    'pick up the dry cleaning',
    'sort the recycling',
    'update my resume',
    'buy dog food',
    'cancel the gym membership',
  ];
  const events = [
    'dinner',
    'a call',
    'a sync',
    'a dentist appointment',
    'drinks',
    'a team standup',
    'a 1:1',
    'brunch',
    'a study session',
    'a video call',
    'a haircut',
    'a doctor visit',
    'a board game night',
    'a review meeting',
  ];
  const messages = [
    "I'm running late",
    'the meeting moved to 4',
    'happy birthday!',
    'can you pick up milk',
    'thanks for today',
    "I'll call you later",
    'the package arrived',
    'are we still on for tonight',
    'I left the keys under the mat',
    'see you at the station',
    'the report is done',
  ];
  const questions = [
    'why is the sky blue',
    'how far is the moon',
    'what causes earthquakes',
    'who wrote pride and prejudice',
    'how do vaccines work',
    'summarize the french revolution',
    'how do I make sourdough starter',
    "what's a good name for a goldfish",
    "explain inflation like I'm five",
    'tell me a joke',
    'what year did the berlin wall fall',
    'how many bones are in the human body',
    'give me ideas for a rainy day',
    'what is quantum computing',
    'how long should I boil pasta',
    'is coffee bad for you',
    'recommend a sci-fi book',
    "what's the difference between a virus and bacteria",
  ];
  const units = [
    ('miles', 'km'),
    ('kg', 'pounds'),
    ('liters', 'gallons'),
    ('inches', 'cm'),
    ('fahrenheit', 'celsius'),
    ('usd', 'yen'),
    ('euros', 'pounds'),
    ('ounces', 'grams'),
    ('meters', 'feet'),
  ];
  const settings = [
    'dark mode',
    'notifications',
    'sounds',
    'large text',
    'vibration',
    'auto updates',
    'location access',
  ];
  String n() =>
      '${pick(const [3, 7, 12, 15, 18, 20, 25, 36, 48, 64, 99, 120, 250, 1024, 4.5, 0.75])}';

  final templates = <CommandIntent, List<String Function()>>{
    CommandIntent.search: [
      () => 'find ${pick(things)}',
      () => 'search for ${pick(things)}',
      () => 'where is ${pick(things)}',
      () => 'show me ${pick(things)}',
      () => 'look up ${pick(things)}',
      () => 'open ${pick(things)}',
      () => 'emails from ${pick(people)}',
      () =>
          'find the message ${pick(people)} sent about '
          '${pick(const ['the trip', 'rent', 'the party', 'the budget'])}',
      () =>
          'photos from '
          '${pick(const ['christmas', 'the wedding', 'last summer', 'paris'])}',
      () => 'where did I save ${pick(things)}',
    ],
    CommandIntent.task: [
      () => pick(chores),
      () => 'todo ${pick(chores)}',
      () => 'add ${pick(chores)} to my list',
      () => 'I need to ${pick(chores)}',
      () => 'task: ${pick(chores)}',
      () => 'put ${pick(chores)} on the todo list',
      () =>
          '${pick(chores)} '
          '${pick(const ['this week', 'sometime', 'soon'])}',
      () => 'must ${pick(chores)}',
    ],
    CommandIntent.event: [
      () => '${pick(events)} with ${pick(people)} ${pick(days)} ${pick(times)}',
      () => 'schedule ${pick(events)} ${pick(days)}',
      () => 'meet ${pick(people)} ${pick(days)} ${pick(times)}',
      () => 'add ${pick(events)} to my calendar ${pick(days)}',
      () => 'book ${pick(events)} ${pick(days)} ${pick(times)}',
      () => 'set up ${pick(events)} with ${pick(people)}',
      () =>
          '${pick(const ['block', 'reserve'])} ${pick(days)} ${pick(times)} '
          'for ${pick(events)}',
    ],
    CommandIntent.reminder: [
      () => 'remind me to ${pick(chores)} ${pick(days)}',
      () => 'remind me ${pick(times)} to ${pick(chores)}',
      () =>
          'set an alarm '
          '${pick(const ['for 6:30', 'at 7', 'for tomorrow 5am', 'in 10 minutes'])}',
      () => 'timer for ${pick(const [5, 10, 12, 25, 45])} minutes',
      () => 'wake me up ${pick(const ['at 6', 'at 7:30', 'in an hour'])}',
      () => 'alert me ${pick(times)}',
      () => 'ping me ${pick(days)} about ${pick(chores)}',
      () => "don't let me forget to ${pick(chores)}",
      () => 'reminder ${pick(chores)} ${pick(times)}',
    ],
    CommandIntent.message: [
      () => 'text ${pick(people)} ${pick(messages)}',
      () => 'message ${pick(people)} that ${pick(messages)}',
      () => 'tell ${pick(people)} ${pick(messages)}',
      () =>
          'email ${pick(people)} about '
          '${pick(const ['the invoice', 'the trip', 'tomorrow', 'the contract'])}',
      () => 'send ${pick(people)} a message saying ${pick(messages)}',
      () => 'reply to ${pick(people)}: ${pick(messages)}',
      () => 'let ${pick(people)} know ${pick(messages)}',
      () => 'dm ${pick(people)} ${pick(messages)}',
    ],
    CommandIntent.calculate: [
      () => '${n()} ${pick(const ['+', '-', '*', 'x', '/'])} ${n()}',
      () => 'what is ${n()} times ${n()}',
      () => '${pick(const [5, 10, 15, 18, 20, 25, 30])}% of ${n()}',
      () {
        final (from, to) = pick(units);
        return 'convert ${n()} $from to $to';
      },
      () {
        final (from, to) = pick(units);
        return '${n()} $from in $to';
      },
      () =>
          'split ${pick(const [60, 84, 120, 245])} between '
          '${pick(const [2, 3, 4, 5])} people',
      () => 'tip on ${pick(const [42, 58, 73, 120])} dollars',
      () => 'square root of ${pick(const [49, 81, 144, 200])}',
      () =>
          'how much is ${n()} ${pick(const ['usd', 'euros', 'yen'])} in '
          '${pick(const ['won', 'pounds', 'dollars'])}',
      () => '(${n()} + ${n()}) * ${n()}',
    ],
    CommandIntent.ask: [
      () => pick(questions),
      () =>
          'can you ${pick(const ['explain', 'summarize', 'describe'])} '
          '${pick(const ['black holes', 'the stock market', 'photosynthesis', 'the cold war', 'machine learning', 'how planes fly'])}',
      () =>
          'what does '
          '${pick(const ['ubiquitous', 'serendipity', 'entropy', 'gerrymandering'])} '
          'mean',
      () =>
          'write '
          '${pick(const ['a haiku', 'a limerick', 'a short story', 'a toast'])} '
          'about ${pick(const ['cats', 'autumn', 'friendship', 'coffee'])}',
      () =>
          'who is '
          '${pick(const ['ada lovelace', 'the president of france', 'marie curie'])}',
      () =>
          'how do I '
          '${pick(const ['tie a tie', 'change a tire', 'learn guitar', 'fall asleep faster'])}',
    ],
    CommandIntent.settings: [
      () => 'turn ${pick(const ['on', 'off'])} ${pick(settings)}',
      () => '${pick(const ['enable', 'disable'])} ${pick(settings)}',
      () => 'switch to ${pick(const ['dark', 'light'])} mode',
      () => 'make the text ${pick(const ['bigger', 'smaller', 'larger'])}',
      () =>
          '${pick(const ['mute', 'unmute'])} '
          '${pick(const ['sounds', 'notifications', 'the app'])}',
      () =>
          'change the language to '
          '${pick(const ['spanish', 'korean', 'german'])}',
      () => '${pick(const ['stop', 'resume'])} sending me notifications',
      () => 'set the theme to ${pick(const ['dark', 'light', 'system'])}',
      () => '${pick(const ['increase', 'decrease'])} the font size',
    ],
  };

  final out = <(CommandIntent, String)>[];
  for (final intent in CommandIntent.values) {
    final seen = <String>{};
    for (
      var tries = 0;
      seen.length < perIntent && tries < perIntent * 50;
      tries++
    ) {
      var text = pick(templates[intent]!)();
      if (rng.nextDouble() < 0.3) {
        text = text[0].toUpperCase() + text.substring(1);
      }
      if (seen.add(text)) out.add((intent, text));
    }
  }
  return out;
}
