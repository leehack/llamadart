import 'dart:convert';

import 'package:llamadart/llamadart.dart';

import 'host.dart';
import 'intents.dart';
import 'laya.dart';

/// The app's `laya/` folder: model downloads, the label log, and optionally
/// a command-tuned head of your own. In a browser there is no folder: the
/// WebGPU bridge caches the models and the label log lives in
/// `localStorage`.
class AppStore {
  /// Creates a store rooted at [directory], or a browser store when null.
  AppStore(this.directory)
    : downloads = directory == null
          ? null
          : DefaultModelDownloadManager.appPrivate(cacheDirectory: directory);

  /// Opens `laya/` in the app's cache directory, or on Android in its
  /// external files directory, where `adb pull` can reach the label log.
  static Future<AppStore> open() async => AppStore(await openStoreDirectory());

  /// Absolute path of the folder, or null in a browser.
  final String? directory;

  /// Download manager caching into [directory], or null in a browser, where
  /// the engine loads models by URL.
  final ModelDownloadManager? downloads;

  /// A command-tuned head saved here replaces the published one; null in a
  /// browser.
  String? get commandHeadPath =>
      directory == null ? null : joinPath(directory!, commandHeadFile);

  /// The head at [commandHeadPath] when present, else [publishedCommandHead].
  ModelSource commandHead() {
    final path = commandHeadPath;
    return path != null && fileExists(path)
        ? ModelSource.path(path)
        : publishedCommandHead;
  }

  /// The label log in [directory], or in `localStorage` in a browser.
  LabelLog get labels =>
      LabelLog(joinPath(directory ?? 'laya', 'labels.jsonl'));
}

/// Appends one JSON object per run command: the text, the intent it ran as,
/// the reader, and whether the user picked that intent or the reader did.
/// Picked rows are corrections: the embedding reader learns them, and they
/// can train a tuned head.
class LabelLog {
  /// Creates a log that appends to [path].
  LabelLog(this.path);

  /// File the log appends to, or its `localStorage` key in a browser.
  final String path;

  Future<void> _last = Future.value();

  /// The commands whose intent the user picked, oldest first. Rows that do
  /// not parse are skipped.
  Future<List<(CommandIntent, String)>> corrections() async {
    await _last;
    final out = <(CommandIntent, String)>[];
    for (final line in await readLines(path)) {
      try {
        final row = jsonDecode(line);
        if (row is! Map || row['source'] != 'picked') continue;
        final intent = CommandIntent.values.asNameMap()[row['intent']];
        final text = row['text'];
        if (intent != null && text is String) out.add((intent, text));
      } on FormatException {
        continue;
      }
    }
    return out;
  }

  /// Appends [row] after every earlier append.
  Future<void> add(Map<String, Object?> row) =>
      _last = _last.then((_) => appendLine(path, jsonEncode(row)));
}
