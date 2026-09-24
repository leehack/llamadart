import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Whether the app runs on Android.
bool get isAndroid => Platform.isAndroid;

/// Whether the app runs on iOS.
bool get isIOS => Platform.isIOS;

/// Most CPU threads worth offering, or null for no limit.
int? get maxThreads => null;

/// Creates and returns `laya/` in the app's cache directory, which iOS leaves
/// out of backups, or on Android in its external files directory, where
/// `adb push` can reach it.
Future<String?> openModelDirectory() async {
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
