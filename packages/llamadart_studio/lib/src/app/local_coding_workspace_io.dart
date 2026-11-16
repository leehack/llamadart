import 'dart:convert';
import 'dart:io';

import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:path_provider/path_provider.dart';

/// Creates a new persistent workspace in Studio's own application storage.
Future<String> createLocalCodingWorkspaceDirectory({
  String? appDataDirectory,
}) async {
  final workspaces = await _workspaceDirectory(appDataDirectory);
  await workspaces.create(recursive: true);
  // createTemp atomically chooses a unique name; these are persistent app data,
  // not entries in the system temporary directory.
  return (await workspaces.createTemp('workspace_')).path;
}

/// Lists Studio-created folders without following links outside app storage.
Future<List<String>> listLocalCodingWorkspaceDirectories({
  String? appDataDirectory,
}) async {
  final directory = await _workspaceDirectory(appDataDirectory);
  if (!await directory.exists()) return [];
  final roots = <String>[];
  await for (final entry in directory.list(followLinks: false)) {
    if (entry is Directory &&
        entry.uri.pathSegments
            .where((part) => part.isNotEmpty)
            .last
            .startsWith('workspace_')) {
      roots.add(entry.path);
    }
  }
  return roots..sort();
}

/// Persists the selected Coding root so app-owned workspaces survive a move of
/// the application data directory (for example, an iOS container change).
CodingWorkspaceRootStore createLocalCodingWorkspaceRootStore({
  required KeyValueStore keyValueStore,
  String? appDataDirectory,
}) => _LocalCodingWorkspaceRootStore(keyValueStore, appDataDirectory);

Future<Directory> _workspaceDirectory(String? appDataDirectory) async {
  final dataPath =
      appDataDirectory ??
      '${(await getApplicationSupportDirectory()).path}/llamadart_studio';
  if (dataPath.trim().isEmpty) {
    throw ArgumentError('Studio application storage must have a path.');
  }
  return Directory('$dataPath/coding_workspaces');
}

const _unavailableRoot =
    'The saved workspace is unavailable. Open Coding setup and choose Open '
    'local workspace to reopen an app-stored folder, or choose another '
    'accessible folder.';
const _unreadableRoot =
    'The saved workspace setting could not be read. Open Coding setup and '
    'choose Open local workspace to reopen an app-stored folder, or choose '
    'another accessible folder.';

// Matches the createTemp names above: one immediate child, never a path.
final _ownedId = RegExp(r'^workspace_[A-Za-z0-9]{1,64}$');

// v1 holds an absolute path that goes stale when the app container moves; v2
// records app-owned roots by ID. A present v2 record is authoritative and never
// falls back to v1, which is left untouched for older app versions.
class _LocalCodingWorkspaceRootStore implements CodingWorkspaceRootStore {
  _LocalCodingWorkspaceRootStore(this._kv, this._appDataDirectory)
    : _legacy = KeyValueCodingWorkspaceRootStore(_kv);

  static const _key = 'studio.coding.workspace_root.v2';

  final KeyValueStore _kv;
  final String? _appDataDirectory;
  final KeyValueCodingWorkspaceRootStore _legacy;

  @override
  Future<String?> readRoot() async {
    final raw = await _kv.readString(_key);
    if (raw == null) {
      final legacy = await _legacy.readRoot();
      // A stale legacy path cannot be proven app-owned, so it is never remapped.
      if (legacy != null &&
          legacy.trim().isNotEmpty &&
          !await FileSystemEntity.isDirectory(legacy.trim())) {
        throw StateError(_unavailableRoot);
      }
      return legacy;
    }
    final record = _decode(raw);
    if (record.kind == 'absolute') return record.value;
    final namespace = await _workspaceDirectory(_appDataDirectory);
    final root = '${namespace.path}/${record.value}';
    if (!await _isRealDirectory(namespace.path) ||
        !await _isRealDirectory(root)) {
      throw StateError(_unavailableRoot);
    }
    return root;
  }

  @override
  Future<void> writeRoot(String root) async {
    Directory? namespace;
    try {
      namespace = await _workspaceDirectory(_appDataDirectory);
    } catch (_) {
      // Without current app storage, ownership is unproven: keep the exact path.
    }
    final id = Directory(root).uri.pathSegments
        .lastWhere((s) => s.isNotEmpty, orElse: () => '');
    final owned =
        namespace != null &&
        _ownedId.hasMatch(id) &&
        await _isRealDirectory(namespace.path) &&
        await _isRealDirectory(root) &&
        await FileSystemEntity.identical(
          Directory(root).parent.path,
          namespace.path,
        );
    await _kv.writeString(
      _key,
      jsonEncode(
        owned
            ? {'version': 2, 'kind': 'appOwned', 'id': id}
            : {'version': 2, 'kind': 'absolute', 'path': root},
      ),
    );
  }

  static ({String kind, String value}) _decode(String raw) {
    try {
      final json = jsonDecode(raw);
      if (json is Map && json['version'] == 2 && json.length == 3) {
        final id = json['id'];
        if (json['kind'] == 'appOwned' &&
            id is String &&
            _ownedId.hasMatch(id)) {
          return (kind: 'appOwned', value: id);
        }
        final path = json['path'];
        if (json['kind'] == 'absolute' &&
            path is String &&
            path.isNotEmpty &&
            path.trim() == path &&
            Directory(path).isAbsolute) {
          return (kind: 'absolute', value: path);
        }
      }
    } on FormatException {
      // Reported below with the same recovery guidance as a schema error.
    }
    throw StateError(_unreadableRoot);
  }

  static Future<bool> _isRealDirectory(String path) async =>
      await FileSystemEntity.type(path, followLinks: false) ==
      FileSystemEntityType.directory;
}
