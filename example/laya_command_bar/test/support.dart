import 'package:laya_command_bar_example/src/intents.dart';

/// A reading of [text] that gives [top] probability [p], splits the rest
/// evenly, and has [confidence].
IntentReading readingOf(
  CommandIntent top,
  double p, {
  double? confidence,
  String text = 'text',
  Map<CommandIntent, double> others = const {},
}) {
  final rest = CommandIntent.values.length - 1 - others.length;
  final left = 1 - p - others.values.fold(0.0, (a, b) => a + b);
  return IntentReading(
    text: text,
    probabilities: [
      for (final i in CommandIntent.values)
        i == top ? p : others[i] ?? left / rest,
    ],
    confidence: confidence ?? p,
    elapsed: const Duration(milliseconds: 12),
  );
}
