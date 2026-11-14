import 'dart:convert';

import 'package:meta/meta.dart';

import '../ports/key_value_store.dart';

/// Alert surfaced on startup when the previous process terminated while loading
/// a model (for example, due to an OS out-of-memory kill or GPU driver reset).
@immutable
class BootRecoveryAlert {
  /// Creates a [BootRecoveryAlert].
  const BootRecoveryAlert({
    required this.modelName,
    required this.modelIdOrPath,
    required this.startedAt,
  });

  /// Display name of the model that was mid-load when the process died.
  final String modelName;

  /// Identifier or path of the interrupted model.
  final String modelIdOrPath;

  /// Timestamp when the interrupted load began.
  final DateTime startedAt;
}

/// Crash/OOM sentinel preventing infinite startup crash loops when an oversized
/// model kills the process during native allocation.
class BootGuardService {
  /// Creates a [BootGuardService] backed by [store].
  BootGuardService(this._store);

  static const String _sentinelKey = 'studio.in_flight_model_load.v1';

  final KeyValueStore _store;

  /// Checks whether the previous run died mid-load and clears the sentinel so
  /// Studio boots cleanly into Safe Mode.
  Future<BootRecoveryAlert?> inspectStartupAndClear() async {
    final raw = await _store.readString(_sentinelKey);
    if (raw == null || raw.isEmpty) {
      return null;
    }
    await _store.remove(_sentinelKey);
    try {
      final decoded = jsonDecode(raw) as Map<String, Object?>;
      return BootRecoveryAlert(
        modelName: (decoded['modelName'] as String?) ?? 'Unknown model',
        modelIdOrPath: (decoded['modelIdOrPath'] as String?) ?? '',
        startedAt:
            DateTime.tryParse((decoded['startedAt'] as String?) ?? '') ??
            DateTime.now().toUtc(),
      );
    } catch (_) {
      return BootRecoveryAlert(
        modelName: 'Previous model',
        modelIdOrPath: raw,
        startedAt: DateTime.now().toUtc(),
      );
    }
  }

  /// Records an in-flight model load right before native/WebGPU allocation.
  Future<void> beginModelLoad({
    required String modelName,
    required String modelIdOrPath,
  }) async {
    final payload = jsonEncode(<String, Object?>{
      'modelName': modelName,
      'modelIdOrPath': modelIdOrPath,
      'startedAt': DateTime.now().toUtc().toIso8601String(),
    });
    await _store.writeString(_sentinelKey, payload);
  }

  /// Clears the sentinel once a model load succeeds or catches a clean error.
  Future<void> completeModelLoad() async {
    await _store.remove(_sentinelKey);
  }
}
