import 'package:meta/meta.dart';

import 'coding_workspace_fs_stub.dart'
    if (dart.library.io) 'coding_workspace_fs_io.dart'
    as impl;

/// Entry inside a Coding Workspace project directory.
@immutable
class WorkspaceFileEntry {
  /// Creates a [WorkspaceFileEntry].
  const WorkspaceFileEntry({
    required this.relativePath,
    required this.name,
    required this.isDirectory,
    this.sizeBytes = 0,
  });

  /// Path relative to the selected workspace root.
  final String relativePath;

  /// Base file or directory name.
  final String name;

  /// Whether this entry is a folder.
  final bool isDirectory;

  /// File byte length (`0` for directories).
  final int sizeBytes;
}

/// Paginated numbered-line slice read from a workspace file.
@immutable
class WorkspaceFileSlice {
  /// Creates a [WorkspaceFileSlice].
  const WorkspaceFileSlice({
    required this.relativePath,
    required this.content,
    required this.numberedPreview,
    required this.totalLines,
    required this.startLine,
    required this.endLine,
    required this.truncated,
  });

  /// Workspace-relative file path.
  final String relativePath;

  /// Raw UTF-8 text slice.
  final String content;

  /// Line-numbered text formatted for LLM tool output.
  final String numberedPreview;

  /// Total lines in the file.
  final int totalLines;

  /// 1-based starting line included in [content].
  final int startLine;

  /// 1-based ending line included in [content].
  final int endLine;

  /// Whether additional lines exist beyond [endLine].
  final bool truncated;
}

/// Single text match returned by `search_code`.
@immutable
class WorkspaceSearchMatch {
  /// Creates a [WorkspaceSearchMatch].
  const WorkspaceSearchMatch({
    required this.relativePath,
    required this.lineNumber,
    required this.lineText,
  });

  /// Workspace-relative file path.
  final String relativePath;

  /// 1-based line number.
  final int lineNumber;

  /// Trimmed line text.
  final String lineText;
}

/// Operation kind performed by a Coding agent tool.
enum CodingChangeKind {
  /// New file created.
  created('Created'),

  /// Existing file modified or patched.
  modified('Modified');

  const CodingChangeKind(this.label);

  /// Display badge label.
  final String label;
}

/// Recorded edit produced by `write_file` or `patch_file`.
@immutable
class CodingFileChange {
  /// Creates a [CodingFileChange].
  const CodingFileChange({
    this.id = '',
    required this.relativePath,
    required this.kind,
    required this.beforePreview,
    required this.afterPreview,
    required this.timestamp,
    this.previousContent,
    this.unifiedDiff = '',
    this.reverted = false,
  });

  /// Unique identifier for revert and UI tracking.
  final String id;

  /// Workspace-relative file path.
  final String relativePath;

  /// Change kind (`created` or `modified`).
  final CodingChangeKind kind;

  /// Previous content excerpt (empty when newly created).
  final String beforePreview;

  /// New content excerpt.
  final String afterPreview;

  /// Change timestamp.
  final DateTime timestamp;

  /// Full pre-edit file content when modifying an existing file (`null` if
  /// newly created). Used for 1-click revert.
  final String? previousContent;

  /// Compact unified diff text suitable for inline review cards.
  final String unifiedDiff;

  /// Whether this change has already been reverted cleanly.
  final bool reverted;

  /// Whether 1-click revert can undo this change cleanly.
  bool get canRevert =>
      !reverted &&
      id.isNotEmpty &&
      (kind == CodingChangeKind.created || previousContent != null);

  /// Returns an updated copy of [CodingFileChange].
  CodingFileChange copyWith({bool? reverted}) {
    return CodingFileChange(
      id: id,
      relativePath: relativePath,
      kind: kind,
      beforePreview: beforePreview,
      afterPreview: afterPreview,
      timestamp: timestamp,
      previousContent: previousContent,
      unifiedDiff: unifiedDiff,
      reverted: reverted ?? this.reverted,
    );
  }
}

/// Output captured from a gated `run_command` invocation.
@immutable
class WorkspaceCommandOutput {
  /// Creates a [WorkspaceCommandOutput].
  const WorkspaceCommandOutput({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.elapsedMs,
  });

  /// Subprocess exit code.
  final int exitCode;

  /// Captured stdout text.
  final String stdout;

  /// Captured stderr text.
  final String stderr;

  /// Execution duration in milliseconds.
  final int elapsedMs;
}

/// Conditional filesystem helpers backing Studio's Coding Workspace tools.
abstract final class CodingWorkspaceFs {
  /// Returns an initial default workspace directory path if available on desktop.
  static Future<String?> detectDefaultWorkspaceRoot() =>
      impl.detectDefaultWorkspaceRootImpl();

  /// Lists files and subdirectories inside [rootPath] (relative to [subdir]).
  static Future<List<WorkspaceFileEntry>> listFiles(
    String rootPath, {
    String subdir = '',
    int maxEntries = 200,
    bool recursive = false,
  }) => impl.listFilesImpl(
    rootPath,
    subdir: subdir,
    maxEntries: maxEntries,
    recursive: recursive,
  );

  /// Reads raw UTF-8 text from [relativePath] inside [rootPath].
  static Future<WorkspaceFileSlice> readFile(
    String rootPath,
    String relativePath, {
    int startLine = 1,
    int maxLines = 250,
  }) => impl.readFileImpl(
    rootPath,
    relativePath,
    startLine: startLine,
    maxLines: maxLines,
  );

  /// Searches plain-text files inside [rootPath] for case-insensitive [query].
  static Future<List<WorkspaceSearchMatch>> searchCode(
    String rootPath,
    String query, {
    String? fileExtension,
    int maxMatches = 40,
  }) => impl.searchCodeImpl(
    rootPath,
    query,
    fileExtension: fileExtension,
    maxMatches: maxMatches,
  );

  /// Writes [content] to [relativePath] inside [rootPath] and returns a
  /// recorded [CodingFileChange].
  static Future<CodingFileChange> writeFile(
    String rootPath,
    String relativePath,
    String content,
  ) => impl.writeFileImpl(rootPath, relativePath, content);

  /// Applies an exact string replacement inside [relativePath] and returns a
  /// recorded [CodingFileChange].
  static Future<CodingFileChange> patchFile(
    String rootPath,
    String relativePath, {
    required String findText,
    required String replaceText,
    bool replaceAll = false,
  }) => impl.patchFileImpl(
    rootPath,
    relativePath,
    findText: findText,
    replaceText: replaceText,
    replaceAll: replaceAll,
  );

  /// Deletes [relativePath] inside [rootPath] safely (used when reverting
  /// agent-created files).
  static Future<void> deleteFile(String rootPath, String relativePath) =>
      impl.deleteFileImpl(rootPath, relativePath);

  /// Executes [commandLine] inside [rootPath] (only when shell execution is
  /// explicitly enabled by the user).
  static Future<WorkspaceCommandOutput> runCommand(
    String rootPath,
    String commandLine, {
    Duration timeout = const Duration(seconds: 20),
  }) => impl.runCommandImpl(rootPath, commandLine, timeout: timeout);

  /// Builds a concise unified diff string comparing [before] and [after].
  static String buildUnifiedDiff(
    String before,
    String after, {
    int maxLines = 48,
  }) {
    final beforeLines = before.isEmpty
        ? const <String>[]
        : before.replaceAll('\r\n', '\n').split('\n');
    final afterLines = after.isEmpty
        ? const <String>[]
        : after.replaceAll('\r\n', '\n').split('\n');

    var prefix = 0;
    while (prefix < beforeLines.length &&
        prefix < afterLines.length &&
        beforeLines[prefix] == afterLines[prefix]) {
      prefix++;
    }
    var suffix = 0;
    while (suffix < (beforeLines.length - prefix) &&
        suffix < (afterLines.length - prefix) &&
        beforeLines[beforeLines.length - 1 - suffix] ==
            afterLines[afterLines.length - 1 - suffix]) {
      suffix++;
    }

    final contextStart = (prefix - 2).clamp(0, beforeLines.length);
    final oldEnd = beforeLines.length - suffix;
    final newEnd = afterLines.length - suffix;
    final contextTailEnd = (oldEnd + 2).clamp(oldEnd, beforeLines.length);
    final tailLen = contextTailEnd - oldEnd;

    final out = <String>[
      '@@ -${contextStart + 1},${(oldEnd - contextStart) + tailLen} +${contextStart + 1},${(newEnd - contextStart) + tailLen} @@',
    ];
    for (var i = contextStart; i < prefix; i++) {
      out.add(' ${beforeLines[i]}');
    }
    for (var i = prefix; i < oldEnd; i++) {
      out.add('-${beforeLines[i]}');
    }
    for (var i = prefix; i < newEnd; i++) {
      out.add('+${afterLines[i]}');
    }
    for (var i = 0; i < tailLen; i++) {
      out.add(' ${beforeLines[oldEnd + i]}');
    }

    if (out.length > maxLines) {
      return <String>[
        ...out.take(maxLines - 1),
        '... (${out.length - maxLines + 1} more diff lines)',
      ].join('\n');
    }
    return out.join('\n');
  }
}
