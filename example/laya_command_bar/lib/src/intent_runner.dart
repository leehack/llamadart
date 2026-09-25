import 'dart:async';

import 'intents.dart';

/// Reads the text on every change without queueing: at most one read runs,
/// and texts submitted meanwhile collapse into the latest one, which runs
/// next. So the bar never waits behind stale reads, however fast the user
/// types or however slow the device is.
class IntentRunner {
  /// Creates a runner that reports each reading to [onReading] and each
  /// failure to [onError].
  IntentRunner(this._read, {required this.onReading, required this.onError});

  final IntentReader _read;

  /// Receives each reading of a text that is still current: readings of a
  /// text submitted before [clear] are dropped.
  final void Function(IntentReading reading) onReading;

  /// Receives each failed read.
  final void Function(Object error) onError;

  String? _pending;
  String? _lastSubmitted;
  int _epoch = 0;
  Future<void>? _running;
  bool _disposed = false;

  /// Reads that ran.
  int reads = 0;

  /// Texts replaced by a later one before they ran.
  int skipped = 0;

  /// Whether a read is running.
  bool get isBusy => _running != null;

  /// Reads [text] now, or after the running read. Blank text clears.
  void submit(String text) {
    if (_disposed) return;
    if (text.trim().isEmpty) {
      clear();
      return;
    }
    if (text == _lastSubmitted) return;
    _lastSubmitted = text;
    if (_running != null) {
      if (_pending != null) skipped++;
      _pending = text;
      return;
    }
    _running = _loop(text);
  }

  /// Drops the pending text and the result of the running read.
  void clear() {
    _epoch++;
    _pending = null;
    _lastSubmitted = null;
  }

  Future<void> _loop(String first) async {
    String? text = first;
    while (text != null && !_disposed) {
      final epoch = _epoch;
      try {
        final reading = await _read(text);
        reads++;
        if (!_disposed && epoch == _epoch) onReading(reading);
      } catch (error) {
        if (!_disposed && epoch == _epoch) onError(error);
      }
      text = _pending;
      _pending = null;
    }
    _running = null;
  }

  /// Stops reporting and waits for the running read.
  Future<void> dispose() async {
    _disposed = true;
    _pending = null;
    await _running;
  }
}
