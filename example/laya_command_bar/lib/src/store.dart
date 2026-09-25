import 'dart:convert';
import 'dart:io';

import 'package:llamadart/llamadart.dart';
import 'package:path_provider/path_provider.dart';

import 'intents.dart';
import 'laya.dart';

/// The app's `laya/` folder: model downloads, the label log, and optionally
/// a command-tuned head of your own.
class AppStore {
  /// Creates a store rooted at [directory].
  AppStore(this.directory)
    : downloads = DefaultModelDownloadManager.appPrivate(
        cacheDirectory: directory,
      );

  /// Opens `laya/` in the app's cache directory, or on Android in its
  /// external files directory, where `adb pull` can reach the label log.
  static Future<AppStore> open() async {
    final external = Platform.isAndroid
        ? await getExternalStorageDirectory()
        : null;
    final base = external ?? await getApplicationCacheDirectory();
    final dir = Directory('${base.path}/laya');
    await dir.create(recursive: true);
    return AppStore(dir.path);
  }

  /// Absolute path of the folder.
  final String directory;

  /// Download manager caching into [directory].
  final ModelDownloadManager downloads;

  /// A command-tuned head saved here replaces the published one.
  String get commandHeadPath =>
      '$directory${Platform.pathSeparator}$commandHeadFile';

  /// The head at [commandHeadPath] when present, else [publishedCommandHead].
  ModelSource commandHead() => File(commandHeadPath).existsSync()
      ? ModelSource.path(commandHeadPath)
      : publishedCommandHead;

  /// The label log in [directory].
  LabelLog get labels =>
      LabelLog('$directory${Platform.pathSeparator}labels.jsonl');
}

/// Appends one JSON object per run command: the text, the intent it ran as,
/// the reader, and whether the user picked that intent or the reader did.
/// Picked rows are corrections: the embedding reader learns them, and they
/// can train a tuned head.
class LabelLog {
  /// Creates a log that appends to [path].
  LabelLog(this.path);

  /// File the log appends to.
  final String path;

  Future<void> _last = Future.value();

  /// The commands whose intent the user picked, oldest first. Rows that do
  /// not parse are skipped.
  Future<List<(CommandIntent, String)>> corrections() async {
    await _last;
    final file = File(path);
    if (!await file.exists()) return [];
    final out = <(CommandIntent, String)>[];
    for (final line in await file.readAsLines()) {
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
  Future<void> add(Map<String, Object?> row) => _last = _last.then(
    (_) => File(
      path,
    ).writeAsString('${jsonEncode(row)}\n', mode: FileMode.append, flush: true),
  );
}
