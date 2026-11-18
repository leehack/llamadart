import 'dart:convert';
import 'dart:io';

import 'package:llamadart_studio_core/llamadart_studio_core.dart';

const mobileDefaultAssets = <String, Map<String, Object>>{
  'Qwen3.5-0.8B-Q4_K_M.gguf': {
    'bytes': 532517120,
    'sha256':
        'bd258782e35f7f458f8aced1adc053e6e92e89bc735ba3be89d38a06121dc517',
  },
  'Qwen3.5-0.8B-mmproj-F16.gguf': {
    'bytes': 204987232,
    'sha256':
        '56e4c6cfe73b0c82e3e82bc518d7591997e61d81f723fc41a586f4fa69ea2453',
  },
};

void validateMobileDefaultManifest(Object? value) {
  if (value is! Map ||
      value.length != 2 ||
      value['schema'] is! int ||
      value['schema'] != 1 ||
      value['assets'] is! Map) {
    throw const FormatException('Invalid mobile asset manifest.');
  }
  final assets = value['assets'] as Map;
  if (assets.length != mobileDefaultAssets.length) {
    throw const FormatException('Unexpected mobile assets.');
  }
  for (final entry in mobileDefaultAssets.entries) {
    final actual = assets[entry.key];
    if (actual is! Map ||
        actual.length != 2 ||
        actual['bytes'] is! int ||
        actual['bytes'] != entry.value['bytes'] ||
        actual['sha256'] != entry.value['sha256']) {
      throw const FormatException('Mobile asset identity mismatch.');
    }
  }
}

Future<void> validateMobileDefaultDirectory(Directory root) async {
  if (await FileSystemEntity.type(root.path, followLinks: false) !=
      FileSystemEntityType.directory) {
    throw const FormatException('Model stage must be a real directory.');
  }
  final entries = await root.list(followLinks: false).toList();
  final names = entries.map((e) => e.uri.pathSegments.last).toSet();
  if (entries.any((e) => e is! File) ||
      names.length != 3 ||
      !names.containsAll([...mobileDefaultAssets.keys, 'manifest.json'])) {
    throw const FormatException('Unexpected staged input.');
  }
  final manifest = File('${root.path}/manifest.json');
  if (await manifest.length() > 4096) {
    throw const FormatException('Asset manifest exceeds bound.');
  }
  validateMobileDefaultManifest(jsonDecode(await manifest.readAsString()));
}

/// Test-only prefix; ordinary preference keys are never read or removed.
class NamespacedAcceptanceStore implements KeyValueStore {
  NamespacedAcceptanceStore(this.delegate, String namespace)
    : prefix = 'studio.mobile-default.$namespace.' {
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,100}$').hasMatch(namespace)) {
      throw ArgumentError.value(namespace, 'namespace');
    }
  }
  final KeyValueStore delegate;
  final String prefix;
  final Set<String> _written = {};
  String _key(String key) => '$prefix$key';
  String _writeKey(String key) {
    _written.add(key);
    return _key(key);
  }

  Future<void> removeWrittenKeys() async {
    for (final key in _written) {
      await delegate.remove(_key(key));
    }
    _written.clear();
  }

  @override
  Future<String?> readString(String key) => delegate.readString(_key(key));
  @override
  Future<int?> readInt(String key) => delegate.readInt(_key(key));
  @override
  Future<double?> readDouble(String key) => delegate.readDouble(_key(key));
  @override
  Future<bool?> readBool(String key) => delegate.readBool(_key(key));
  @override
  Future<void> writeString(String key, String value) =>
      delegate.writeString(_writeKey(key), value);
  @override
  Future<void> writeInt(String key, int value) =>
      delegate.writeInt(_writeKey(key), value);
  @override
  Future<void> writeDouble(String key, double value) =>
      delegate.writeDouble(_writeKey(key), value);
  @override
  Future<void> writeBool(String key, bool value) =>
      delegate.writeBool(_writeKey(key), value);
  @override
  Future<void> remove(String key) => delegate.remove(_key(key));
}
