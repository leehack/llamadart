import 'dart:async';

import '../backends/backend.dart';
import 'llama_logger.dart';
import 'models/config/log_level.dart';

/// Library-wide logging configuration for Dart-side records and native
/// runtime output.
///
/// Every engine shares one configuration, so the last [configure] call
/// decides the levels and handler regardless of call order or engine.
abstract final class LlamaLogging {
  /// The level Dart-side records must reach to be handled.
  static LlamaLogLevel get level => LlamaLogger.instance.level;

  /// The level passed to the native llama.cpp and LiteRT-LM runtimes.
  static LlamaLogLevel get nativeLevel => _nativeLevel;

  /// Sets the Dart-side [level], the native runtime [nativeLevel] and the
  /// [handler] that receives Dart-side records.
  ///
  /// [nativeLevel] defaults to [level]. With no [handler], records at or
  /// above [level] are printed. Both levels default to [LlamaLogLevel.none].
  ///
  /// The new levels apply immediately on this isolate and to every engine
  /// created later. The returned future completes once they also reach the
  /// worker isolates and native runtimes of live engines; an engine that
  /// cannot take them logs a warning and takes them on its next model load.
  ///
  /// Native llama.cpp and LiteRT-LM backends log from a worker isolate that
  /// forwards records at or above [level] to this isolate, where [handler]
  /// receives them with the error as its `toString` text and the stack trace
  /// rebuilt from text. An error thrown by [handler] on a forwarded record is
  /// printed, not thrown. Some native output, such as the LiteRT-LM WebGPU
  /// accelerator's, ignores [nativeLevel]; see
  /// https://llamadart.leehack.com/docs/configuration/logging.
  static Future<void> configure({
    LlamaLogLevel level = LlamaLogLevel.none,
    LlamaLogLevel? nativeLevel,
    LlamaLogHandler? handler,
  }) {
    LlamaLogger.instance.setHandler(handler);
    return applyLogLevels(dart: level, native: nativeLevel ?? level);
  }
}

LlamaLogLevel _nativeLevel = LlamaLogLevel.none;

// Weak so an engine dropped without `dispose()` can still be collected.
final List<WeakReference<LlamaBackend>> _liveBackends =
    <WeakReference<LlamaBackend>>[];

/// Keeps [backend] in sync with later [LlamaLogging.configure] calls.
void registerLoggingBackend(LlamaBackend backend) {
  _liveBackends.add(WeakReference<LlamaBackend>(backend));
}

/// Stops syncing [backend] with [LlamaLogging.configure].
void unregisterLoggingBackend(LlamaBackend backend) {
  _liveBackends.removeWhere((reference) {
    final target = reference.target;
    return target == null || identical(target, backend);
  });
}

/// Sets the Dart and native levels, keeping the current handler, and pushes
/// them to every registered backend.
Future<void> applyLogLevels({
  required LlamaLogLevel dart,
  required LlamaLogLevel native,
}) async {
  LlamaLogger.instance.setLevel(dart);
  _nativeLevel = native;
  _liveBackends.removeWhere((reference) => reference.target == null);
  final backends = <LlamaBackend>[
    for (final reference in _liveBackends) ?reference.target,
  ];
  await Future.wait(<Future<void>>[
    for (final backend in backends) _pushLogLevels(backend, dart, native),
  ]);
}

Future<void> _pushLogLevels(
  LlamaBackend backend,
  LlamaLogLevel dart,
  LlamaLogLevel native,
) async {
  try {
    if (backend is BackendDartLogLevel) {
      await (backend as BackendDartLogLevel).setDartLogLevel(dart);
    }
    await backend.setLogLevel(native);
  } catch (error, stackTrace) {
    LlamaLogger.instance.warn(
      'Could not apply log levels to a running backend; they apply on its '
      'next model load.',
      error,
      stackTrace,
    );
  }
}
