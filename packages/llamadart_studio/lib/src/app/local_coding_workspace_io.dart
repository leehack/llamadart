import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Creates a new persistent workspace in Studio's own application storage.
Future<String> createLocalCodingWorkspaceDirectory({
  String? appDataDirectory,
}) async {
  final dataPath =
      appDataDirectory ??
      '${(await getApplicationSupportDirectory()).path}/llamadart_studio';
  if (dataPath.trim().isEmpty) {
    throw ArgumentError('Studio application storage must have a path.');
  }
  final workspaces = Directory('$dataPath/coding_workspaces');
  await workspaces.create(recursive: true);
  // createTemp atomically chooses a unique name; these are persistent app data,
  // not entries in the system temporary directory.
  return (await workspaces.createTemp('workspace_')).path;
}
