/// Platform-agnostic key-value persistence port.
abstract interface class KeyValueStore {
  /// Reads a string value for [key], or `null` when absent.
  Future<String?> readString(String key);

  /// Persists a string [value] under [key].
  Future<void> writeString(String key, String value);

  /// Reads an integer value for [key], or `null` when absent.
  Future<int?> readInt(String key);

  /// Persists an integer [value] under [key].
  Future<void> writeInt(String key, int value);

  /// Reads a floating-point value for [key], or `null` when absent.
  Future<double?> readDouble(String key);

  /// Persists a floating-point [value] under [key].
  Future<void> writeDouble(String key, double value);

  /// Reads a boolean value for [key], or `null` when absent.
  Future<bool?> readBool(String key);

  /// Persists a boolean [value] under [key].
  Future<void> writeBool(String key, bool value);

  /// Removes [key] if present.
  Future<void> remove(String key);
}
