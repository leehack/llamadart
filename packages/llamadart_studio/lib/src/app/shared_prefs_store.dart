import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// [KeyValueStore] implementation backed by Flutter's [SharedPreferences].
class SharedPreferencesKeyValueStore implements KeyValueStore {
  /// Creates a [SharedPreferencesKeyValueStore].
  const SharedPreferencesKeyValueStore(this._prefs);

  final SharedPreferences _prefs;

  @override
  Future<String?> readString(String key) async => _prefs.getString(key);

  @override
  Future<void> writeString(String key, String value) async {
    await _prefs.setString(key, value);
  }

  @override
  Future<int?> readInt(String key) async => _prefs.getInt(key);

  @override
  Future<void> writeInt(String key, int value) async {
    await _prefs.setInt(key, value);
  }

  @override
  Future<double?> readDouble(String key) async => _prefs.getDouble(key);

  @override
  Future<void> writeDouble(String key, double value) async {
    await _prefs.setDouble(key, value);
  }

  @override
  Future<bool?> readBool(String key) async => _prefs.getBool(key);

  @override
  Future<void> writeBool(String key, bool value) async {
    await _prefs.setBool(key, value);
  }

  @override
  Future<void> remove(String key) async {
    await _prefs.remove(key);
  }
}
