import 'dart:math' as math;

import 'intents.dart';

/// Labelled commands an [ExampleBank] starts from. None of them is in
/// `evalCases` or `heldOutCases`, so the benchmark never scores a command
/// against itself.
const List<(CommandIntent, String)> seedExamples = [
  (CommandIntent.search, 'find the wifi router manual'),
  (CommandIntent.search, 'show my photos from the beach'),
  (CommandIntent.search, 'search emails from my landlord'),
  (CommandIntent.search, 'where did I put the insurance card photo'),
  (CommandIntent.search, 'open last week meeting notes'),
  (CommandIntent.search, 'look for the car rental receipt'),
  (CommandIntent.task, 'pick up groceries'),
  (CommandIntent.task, 'add call the dentist to my list'),
  (CommandIntent.task, 'todo: pay the electricity bill'),
  (CommandIntent.task, 'need to fix the bike tire'),
  (CommandIntent.task, 'wash the car'),
  (CommandIntent.task, 'buy a birthday gift for Sam'),
  (CommandIntent.event, 'lunch with Kate on Thursday at noon'),
  (CommandIntent.event, 'schedule a team meeting next Monday 10am'),
  (CommandIntent.event, 'coffee with Ben tomorrow morning'),
  (CommandIntent.event, 'put the concert on my calendar for Saturday night'),
  (CommandIntent.event, 'book a haircut Friday at 4'),
  (CommandIntent.event, 'plan a movie night with friends on Sunday'),
  (CommandIntent.reminder, 'remind me to take out the trash tonight'),
  (CommandIntent.reminder, 'set an alarm for 6am'),
  (CommandIntent.reminder, 'timer 15 minutes'),
  (CommandIntent.reminder, 'remind me in an hour to check the oven'),
  (CommandIntent.reminder, "don't let me forget my keys"),
  (CommandIntent.reminder, 'nudge me at 3 to stand up'),
  (CommandIntent.message, "text Lisa I'm on my way"),
  (CommandIntent.message, 'send Mark the address'),
  (CommandIntent.message, "email my boss that I'm sick today"),
  (CommandIntent.message, 'tell dad I landed'),
  (CommandIntent.message, 'message the group chat that dinner is at 8'),
  (CommandIntent.message, 'reply to Sara ok see you then'),
  (CommandIntent.calculate, '25% of 80'),
  (CommandIntent.calculate, '12 x 7'),
  (CommandIntent.calculate, 'convert 30 celsius to fahrenheit'),
  (CommandIntent.calculate, 'how much is 200 euros in dollars'),
  (CommandIntent.calculate, '1500 / 12'),
  (CommandIntent.calculate, '5 feet in cm'),
  (CommandIntent.ask, 'what is the tallest building in the world'),
  (CommandIntent.ask, 'explain black holes simply'),
  (CommandIntent.ask, 'how do I boil an egg'),
  (CommandIntent.ask, 'who painted the mona lisa'),
  (CommandIntent.ask, 'write a short poem about rain'),
  (CommandIntent.ask, 'what does photosynthesis mean'),
  (CommandIntent.settings, 'turn off dark mode'),
  (CommandIntent.settings, 'increase the font size'),
  (CommandIntent.settings, 'silence all notifications'),
  (CommandIntent.settings, 'turn sounds back on'),
  (CommandIntent.settings, 'switch the app language to french'),
  (CommandIntent.settings, 'use a larger text size'),
];

/// One description per intent, embedded next to the examples.
const Map<CommandIntent, String> intentDescriptions = {
  CommandIntent.search:
      'find or look up something the user already has, such as notes, '
      'files, photos or emails',
  CommandIntent.task: 'add a to-do item',
  CommandIntent.event: 'schedule a meeting or calendar event',
  CommandIntent.reminder:
      'be reminded or alerted later, or set an alarm or timer',
  CommandIntent.message: 'send a message, text or email to a person',
  CommandIntent.calculate: 'do math or convert units or currencies',
  CommandIntent.ask:
      'a general question or request for the assistant to answer',
  CommandIntent.settings: 'change an app setting or preference',
};

/// Embeds texts, one L2-normalized vector per text, in order.
typedef Embedder = Future<List<List<double>>> Function(List<String> texts);

/// Labelled commands as vectors. A text reads as the intent whose closest
/// [neighbours] examples are most similar to it, so a correction added with
/// [add] changes the very next reading, without training.
class ExampleBank {
  /// Creates an empty bank that embeds through [embed].
  ExampleBank(this._embed, {this.neighbours = 2, this.sharpness = 40});

  final Embedder _embed;

  /// How many of each intent's closest examples are averaged.
  final int neighbours;

  /// Scale of the similarity softmax: higher is more decisive.
  final double sharpness;

  final Map<CommandIntent, List<List<double>>> _vectors = {
    for (final intent in CommandIntent.values) intent: [],
  };

  /// Number of examples per intent.
  Map<CommandIntent, int> get sizes => {
    for (final e in _vectors.entries) e.key: e.value.length,
  };

  /// Adds [examples], embedded in one batch.
  Future<void> addAll(Iterable<(CommandIntent, String)> examples) async {
    final list = examples.toList();
    if (list.isEmpty) return;
    final vectors = await _embed([for (final (_, text) in list) text]);
    for (var i = 0; i < list.length; i++) {
      _vectors[list[i].$1]!.add(vectors[i]);
    }
  }

  /// Adds one example.
  Future<void> add(CommandIntent intent, String text) =>
      addAll([(intent, text)]);

  /// Reads [text]. [IntentReading.confidence] is the lead of the most
  /// probable intent over the second.
  Future<IntentReading> read(String text) async {
    final stopwatch = Stopwatch()..start();
    final vector = (await _embed([text])).single;
    final scores = [
      for (final intent in CommandIntent.values)
        _score(vector, _vectors[intent]!),
    ];
    final top = scores.reduce(math.max);
    final exps = [for (final s in scores) math.exp((s - top) * sharpness)];
    final sum = exps.reduce((a, b) => a + b);
    final probabilities = [for (final e in exps) e / sum];
    final sorted = [...probabilities]..sort();
    return IntentReading(
      text: text,
      probabilities: probabilities,
      confidence: sorted.last - sorted[sorted.length - 2],
      elapsed: stopwatch.elapsed,
    );
  }

  double _score(List<double> vector, List<List<double>> examples) {
    if (examples.isEmpty) return -1;
    final sims = [for (final e in examples) _dot(vector, e)]
      ..sort((a, b) => b.compareTo(a));
    final n = math.min(neighbours, sims.length);
    return sims.take(n).reduce((a, b) => a + b) / n;
  }

  static double _dot(List<double> a, List<double> b) {
    var s = 0.0;
    for (var i = 0; i < a.length; i++) {
      s += a[i] * b[i];
    }
    return s;
  }
}
