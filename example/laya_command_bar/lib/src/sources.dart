import 'intents.dart';

/// Reports load progress: a message and, while downloading, a fraction.
typedef LoadStatus = void Function(String message, double? fraction);

/// A loaded way to read intents.
class IntentSource {
  /// Creates a source.
  IntentSource({
    required this.reader,
    required this.enter,
    required this.label,
    this.minWords = 1,
    this.learn,
    required Future<void> Function() dispose,
  }) : _dispose = dispose;

  /// Reads the intent of a text.
  final IntentReader reader;

  /// Confidence at which the bar changes shape by default. Sources measure
  /// confidence differently, so each has its own.
  final double enter;

  /// Where it runs, such as `Metal · MTL0`.
  final String label;

  /// Words a text needs before its reading can change the bar.
  final int minWords;

  /// Adds a command the user labelled, when the source learns from them.
  final Future<void> Function(CommandIntent intent, String text)? learn;

  final Future<void> Function() _dispose;

  /// Frees the source's models.
  Future<void> dispose() => _dispose();
}

/// A source the bar can switch to, loaded on first use.
class SourceOption {
  /// Creates an option named [name] that [load]s its source.
  SourceOption(this.name, this.detail, this._load);

  /// Short name for the switch.
  final String name;

  /// One line on what it is.
  final String detail;

  final Future<IntentSource> Function(LoadStatus onStatus) _load;
  Future<IntentSource>? _loading;
  IntentSource? _loaded;

  /// The source, once loaded.
  IntentSource? get loaded => _loaded;

  /// Loads the source once; a failed load can be retried.
  Future<IntentSource> load(LoadStatus onStatus) =>
      _loading ??= _load(onStatus).then(
        (source) => _loaded = source,
        onError: (Object error, StackTrace stack) {
          _loading = null;
          Error.throwWithStackTrace(error, stack);
        },
      );

  /// Frees the source if it loaded, after any load in progress.
  Future<void> dispose() async {
    final loading = _loading;
    _loading = null;
    _loaded = null;
    if (loading == null) return;
    try {
      await (await loading).dispose();
    } catch (_) {}
  }
}
