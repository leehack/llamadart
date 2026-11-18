import 'package:llamadart_studio_core/llamadart_studio_core.dart';

/// Local filesystem workspaces are unavailable in a browser.
Future<String> createLocalCodingWorkspaceDirectory({
  String? appDataDirectory,
}) async {
  throw UnsupportedError('Local Coding workspaces are unavailable on Web.');
}

/// Local filesystem workspaces are unavailable in a browser.
Future<List<String>> listLocalCodingWorkspaceDirectories({
  String? appDataDirectory,
}) async =>
    throw UnsupportedError('Local Coding workspaces are unavailable on Web.');

/// Web keeps the default absolute-root persistence.
CodingWorkspaceRootStore createLocalCodingWorkspaceRootStore({
  required KeyValueStore keyValueStore,
  String? appDataDirectory,
}) => KeyValueCodingWorkspaceRootStore(keyValueStore);
