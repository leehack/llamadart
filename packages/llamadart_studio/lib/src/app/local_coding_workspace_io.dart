import 'dart:io';

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

Future<Directory> _workspaceDirectory(String? appDataDirectory) async {
  final dataPath =
      appDataDirectory ??
      '${(await getApplicationSupportDirectory()).path}/llamadart_studio';
  if (dataPath.trim().isEmpty) {
    throw ArgumentError('Studio application storage must have a path.');
  }
  return Directory('$dataPath/coding_workspaces');
}
