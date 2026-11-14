import '../../ports/key_value_store.dart';

/// Deterministic in-memory [KeyValueStore] for tests, ephemeral CLI runs, and
/// fallback environments.
class InMemoryKeyValueStore implements KeyValueStore {
  /// Creates an empty or pre-populated [InMemoryKeyValueStore].
  InMemoryKeyValueStore([Map<String, Object>? seed])
    : _entries = <String, Object>{...?seed};

  final Map<String, Object> _entries;

  @override
  Future<String?> readString(String key) async {
    final value = _entries[key];
    return value is String ? value : null;
  }

  @override
  Future<void> writeString(String key, String value) async {
    _entries[key] = value;
  }

  @override
  Future<int?> readInt(String key) async {
    final value = _entries[key];
    return value is int ? value : null;
  }

  @override
  Future<void> writeInt(String key, int value) async {
    _entries[key] = value;
  }

  @override
  Future<double?> readDouble(String key) async {
    final value = _entries[key];
    if (value is double) {
      return value;
    }
    if (value is int) {
      return value.toDouble();
    }
    return null;
  }

  @override
  Future<void> writeDouble(String key, double value) async {
    _entries[key] = value;
  }

  @override
  Future<bool?> readBool(String key) async {
    final value = _entries[key];
    return value is bool ? value : null;
  }

  @override
  Future<void> writeBool(String key, bool value) async {
    _entries[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    _entries.remove(key);
  }
}
