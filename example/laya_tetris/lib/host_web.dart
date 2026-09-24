import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// Whether the app runs on Android: false in a browser.
bool get isAndroid => false;

/// Whether the app runs on iOS: false in a browser.
bool get isIOS => false;

/// Most CPU threads worth offering: the WebGPU bridge's thread pool size,
/// which `web/index.html` sets, or 1 without one.
int? get maxThreads {
  final size = globalContext['__llamadartBridgeThreadPoolSize'];
  return size.isA<JSNumber>() ? (size as JSNumber).toDartInt : 1;
}

/// Returns null: a browser has no model folder, and the WebGPU bridge caches
/// the backbone in the browser's Cache Storage.
Future<String?> openModelDirectory() async => null;

/// Returns false: a browser has no local files.
bool fileExists(String path) => false;

/// Joins [directory] and [name] with `/`.
String joinPath(String directory, String name) => '$directory/$name';
