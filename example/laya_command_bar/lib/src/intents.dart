import 'package:llamadart/llamadart.dart';

/// What the user wants to do with the typed text.
enum CommandIntent {
  /// Look up something the user already has.
  search('Search'),

  /// Add a to-do item.
  task('Task'),

  /// Create a calendar event.
  event('Event'),

  /// Set a reminder, alarm or timer.
  reminder('Reminder'),

  /// Send a message to a person.
  message('Message'),

  /// Do arithmetic or convert units.
  calculate('Calculate'),

  /// Ask the assistant a general question.
  ask('Ask'),

  /// Change an app setting.
  settings('Settings');

  const CommandIntent(this.title);

  /// Display name.
  final String title;
}

/// The question Laya answers about each typed text, with the text as the
/// state. `bin/bench.dart` scores it.
final ChoiceKey<CommandIntent> intentKey = ChoiceKey.enumOf<CommandIntent>(
  'intent',
  'What does the user want to do with this text typed into the app?',
  criteria: const {
    CommandIntent.search: 'find or look up something the user already has',
    CommandIntent.task: 'add a to-do item',
    CommandIntent.event: 'schedule a meeting or calendar event',
    CommandIntent.reminder: 'be reminded or alerted later, or set a timer',
    CommandIntent.message: 'send a message, text or email to a person',
    CommandIntent.calculate: 'do math or convert units or currencies',
    CommandIntent.ask: 'a general question for the assistant to answer',
    CommandIntent.settings: 'change an app setting or preference',
  },
);

/// Laya's reading of one text.
class IntentReading {
  /// Creates a reading.
  const IntentReading({
    required this.text,
    required this.probabilities,
    required this.confidence,
    required this.elapsed,
  });

  /// The text that was read.
  final String text;

  /// Probability of each intent, in [CommandIntent.values] order.
  final List<double> probabilities;

  /// One minus the normalized entropy of [probabilities], from 0 to 1.
  final double confidence;

  /// Wall time of the decision.
  final Duration elapsed;

  /// The most probable intent.
  CommandIntent get top {
    var best = 0;
    for (var i = 1; i < probabilities.length; i++) {
      if (probabilities[i] > probabilities[best]) best = i;
    }
    return CommandIntent.values[best];
  }

  /// Probability of [intent].
  double probabilityOf(CommandIntent intent) => probabilities[intent.index];
}

/// Reads the intent of a text.
typedef IntentReader = Future<IntentReading> Function(String text);

/// An [IntentReader] that asks [decisions] one [intentKey] question with the
/// text as the state.
IntentReader layaIntentReader(DecisionEngine decisions) => (text) async {
  final stopwatch = Stopwatch()..start();
  final result = await decisions.systemOne(
    state: text,
    questions: DecisionKey.questionsOf([intentKey]),
  );
  final answer = result.answerOf(intentKey);
  return IntentReading(
    text: text,
    probabilities: answer.optionProbabilities,
    confidence: answer.confidence,
    elapsed: stopwatch.elapsed,
  );
};
