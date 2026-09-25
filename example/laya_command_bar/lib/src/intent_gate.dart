import 'intents.dart';

/// Decides which intent the bar shows, so it changes shape only when the
/// reader is confident and does not flicker while the text changes.
///
/// A reading whose confidence reaches [enter] shows its top intent. A weaker
/// reading keeps the shown intent while that intent is still the top one or
/// keeps at least [keep] probability; otherwise the bar goes back to plain
/// text. A text of fewer than [minWords] words always reads as plain. A
/// pinned intent overrides every reading until [pin] clears it or [clear]
/// runs.
class IntentGate {
  /// Creates a gate.
  IntentGate({this.enter = 0.6, this.keep = 0.25, this.minWords = 1});

  /// Confidence at which a reading changes the bar.
  double enter;

  /// Probability that keeps the shown intent through weaker readings.
  final double keep;

  /// Words a text needs before it can change the bar. Readers that stay
  /// confident on a word fragment, such as `rem`, need 2.
  int minWords;

  CommandIntent? _read;
  CommandIntent? _pinned;

  /// The intent the bar shows, or null for plain text.
  CommandIntent? get shown => _pinned ?? _read;

  /// The intent the user picked, if any.
  CommandIntent? get pinned => _pinned;

  /// Applies [reading] and returns [shown].
  CommandIntent? update(IntentReading reading) {
    final top = reading.top;
    final current = _read;
    final words = reading.text.trim().split(RegExp(r'\s+')).length;
    if (words < minWords) {
      _read = null;
    } else if (reading.confidence >= enter) {
      _read = top;
    } else if (current != null &&
        (top == current || reading.probabilityOf(current) >= keep)) {
      _read = current;
    } else {
      _read = null;
    }
    return shown;
  }

  /// Forgets every reading but keeps the pin, as when the reader changes.
  void forgetReadings() => _read = null;

  /// Pins [intent], or unpins with null.
  void pin(CommandIntent? intent) => _pinned = intent;

  /// Forgets every reading and the pin, as for an empty bar.
  void clear() {
    _read = null;
    _pinned = null;
  }
}
