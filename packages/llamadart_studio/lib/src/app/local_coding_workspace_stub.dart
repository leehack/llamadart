/// Local filesystem workspaces are unavailable in a browser.
Future<String> createLocalCodingWorkspaceDirectory({
  String? appDataDirectory,
}) async {
  throw UnsupportedError('Local Coding workspaces are unavailable on Web.');
}
