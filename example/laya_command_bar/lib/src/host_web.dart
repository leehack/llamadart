import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// Whether the app runs on Android: false in a browser.
bool get isAndroid => false;

/// Returns null: a browser has no model folder, and the WebGPU bridge caches
/// the models in the browser's Cache Storage.
Future<String?> openStoreDirectory() async => null;

/// Returns false: a browser has no local files.
bool fileExists(String path) => false;

/// Joins [directory] and [name] with `/`.
String joinPath(String directory, String name) => '$directory/$name';

JSObject? get _storage {
  try {
    final storage = globalContext['localStorage'];
    return storage.isA<JSObject>() ? storage as JSObject : null;
  } catch (_) {
    return null;
  }
}

/// The lines stored in `localStorage` under [path], or none.
Future<List<String>> readLines(String path) async {
  try {
    final value = _storage?.callMethod<JSAny?>('getItem'.toJS, path.toJS);
    if (!value.isA<JSString>()) return const [];
    return (value as JSString).toDart
        .split('\n')
        .where((l) => l.isNotEmpty)
        .toList();
  } catch (_) {
    return const [];
  }
}

/// Appends [line] to the text stored in `localStorage` under [path]. Does
/// nothing when the browser blocks storage.
Future<void> appendLine(String path, String line) async {
  final lines = [...await readLines(path), line];
  try {
    _storage?.callMethod<JSAny?>(
      'setItem'.toJS,
      path.toJS,
      '${lines.join('\n')}\n'.toJS,
    );
  } catch (_) {}
}
