import 'coding_workspace_fs.dart';

/// Web stub where direct local directory sandboxing is unavailable.
Future<String?> detectDefaultWorkspaceRootImpl() async => null;

/// Lists files inside [rootPath] (unsupported on Web).
Future<List<WorkspaceFileEntry>> listFilesImpl(
  String rootPath, {
  String subdir = '',
  int maxEntries = 200,
  bool recursive = false,
}) async => throw UnsupportedError(
  'Local workspace browsing requires a desktop/mobile IO host.',
);

/// Reads a line slice from [relativePath] inside [rootPath] (unsupported on Web).
Future<WorkspaceFileSlice> readFileImpl(
  String rootPath,
  String relativePath, {
  int startLine = 1,
  int maxLines = 250,
}) async => throw UnsupportedError(
  'Local file reading requires a desktop/mobile IO host.',
);

/// Searches code inside [rootPath] (unsupported on Web).
Future<List<WorkspaceSearchMatch>> searchCodeImpl(
  String rootPath,
  String query, {
  String? fileExtension,
  int maxMatches = 40,
}) async => throw UnsupportedError(
  'Local code search requires a desktop/mobile IO host.',
);

/// Writes [relativePath] inside [rootPath] (unsupported on Web).
Future<CodingFileChange> writeFileImpl(
  String rootPath,
  String relativePath,
  String content,
) async => throw UnsupportedError(
  'Local file writing requires a desktop/mobile IO host.',
);

/// Patches [relativePath] inside [rootPath] (unsupported on Web).
Future<CodingFileChange> patchFileImpl(
  String rootPath,
  String relativePath, {
  required String findText,
  required String replaceText,
  bool replaceAll = false,
}) async => throw UnsupportedError(
  'Local file patching requires a desktop/mobile IO host.',
);

/// Deletes [relativePath] inside [rootPath] (unsupported on Web).
Future<void> deleteFileImpl(String rootPath, String relativePath) async =>
    throw UnsupportedError(
      'Local file deletion requires a desktop/mobile IO host.',
    );

/// Runs a shell command inside [rootPath] (unsupported on Web).
Future<WorkspaceCommandOutput> runCommandImpl(
  String rootPath,
  String commandLine, {
  Duration timeout = const Duration(seconds: 20),
}) async => throw UnsupportedError(
  'Shell command execution requires a desktop/mobile IO host.',
);
