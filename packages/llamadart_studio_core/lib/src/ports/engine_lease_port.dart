import 'package:llamadart/llamadart.dart';

import '../domain/studio_runtime_snapshot.dart';
import '../reactive/state_store.dart';

/// Narrow abstraction for coordinating exclusive access to a shared live
/// [LlamaEngine] across inference and auxiliary playground/lab ports.
///
/// Decouples auxiliary adapters (such as `DirectLlamaPlaygroundPort`) from
/// concrete `StudioInferencePort` implementations (`DirectLlamaInferencePort`).
abstract interface class SharedLlamaEngineProvider {
  /// Reactive runtime/hardware/capability snapshot for the shared engine.
  ReadOnlyStore<StudioRuntimeSnapshot> get runtimeStore;

  /// Whether the shared engine currently has an active, ready model loaded.
  bool get isEngineReady;

  /// Runs [action] exclusively on the shared [LlamaEngine], failing fast when
  /// another workspace operation already holds the engine slot.
  Future<T> runExclusiveOnEngine<T>(
    String label,
    Future<T> Function(LlamaEngine engine) action,
  );
}
