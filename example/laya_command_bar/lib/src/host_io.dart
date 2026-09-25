import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Whether the app runs on Android.
bool get isAndroid => Platform.isAndroid;

/// Creates and returns `laya/` in the app's cache directory, or on Android in
/// its external files directory, where `adb pull` can reach the label log.
Future<String?> openStoreDirectory() async {
  final external = Platform.isAndroid
      ? await getExternalStorageDirectory()
      : null;
  final base = external ?? await getApplicationCacheDirectory();
  final dir = Directory('${base.path}${Platform.pathSeparator}laya');
  await dir.create(recursive: true);
  return dir.path;
}

/// Whether a file exists at [path].
bool fileExists(String path) => File(path).existsSync();

/// Joins [directory] and [name] with the platform's separator.
String joinPath(String directory, String name) =>
    '$directory${Platform.pathSeparator}$name';

/// The lines of the file at [path], or none when it does not exist.
Future<List<String>> readLines(String path) async {
  final file = File(path);
  return await file.exists() ? file.readAsLines() : const [];
}

/// Appends [line] and a newline to the file at [path].
Future<void> appendLine(String path, String line) =>
    File(path).writeAsString('$line\n', mode: FileMode.append, flush: true);
