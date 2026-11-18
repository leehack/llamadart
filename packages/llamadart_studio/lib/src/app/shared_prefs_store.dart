import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// [KeyValueStore] implementation backed by Flutter's [SharedPreferences].
class SharedPreferencesKeyValueStore implements KeyValueStore {
  /// Creates a [SharedPreferencesKeyValueStore].
  const SharedPreferencesKeyValueStore(this._prefs);

  final SharedPreferences _prefs;

  static final _accesses = Expando<_PreferencesAccess>();

  _PreferencesAccess get _access => _accesses[_prefs] ??= _PreferencesAccess();

  Future<T> _run<T>(Future<T> Function() operation) {
    final access = _access;
    final result = access.tail.then((_) async {
      if (access.dirty) {
        await _prefs.reload();
        access.dirty = false;
      }
      return operation();
    });
    access.tail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<void> _mutate(Future<bool> Function() operation) => _run(() async {
    try {
      if (!await operation()) {
        throw LlamaContextException(
          'Preferences could not be saved. Retry the operation.',
        );
      }
    } catch (error, stack) {
      // The plugin updates its cache before the backing write finishes.
      _access.dirty = true;
      try {
        await _prefs.reload();
        _access.dirty = false;
      } catch (_) {
        // Reads stay fenced until a later reload succeeds.
      }
      Error.throwWithStackTrace(error, stack);
    }
  });

  @override
  Future<String?> readString(String key) =>
      _run(() async => _prefs.getString(key));

  @override
  Future<void> writeString(String key, String value) =>
      _mutate(() => _prefs.setString(key, value));

  @override
  Future<int?> readInt(String key) => _run(() async => _prefs.getInt(key));

  @override
  Future<void> writeInt(String key, int value) =>
      _mutate(() => _prefs.setInt(key, value));

  @override
  Future<double?> readDouble(String key) =>
      _run(() async => _prefs.getDouble(key));

  @override
  Future<void> writeDouble(String key, double value) =>
      _mutate(() => _prefs.setDouble(key, value));

  @override
  Future<bool?> readBool(String key) => _run(() async => _prefs.getBool(key));

  @override
  Future<void> writeBool(String key, bool value) =>
      _mutate(() => _prefs.setBool(key, value));

  @override
  Future<void> remove(String key) => _mutate(() => _prefs.remove(key));
}

class _PreferencesAccess {
  Future<void> tail = Future<void>.value();
  bool dirty = false;
}
