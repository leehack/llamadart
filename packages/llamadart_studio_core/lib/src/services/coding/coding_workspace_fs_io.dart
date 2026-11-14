import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'coding_workspace_fs.dart';

const Set<String> _ignoredDirNames = <String>{
  '.git',
  '.dart_tool',
  'build',
  'node_modules',
  '.pub-cache',
  '.gradle',
  'Pods',
};

/// Returns the current working directory when running on a desktop/mobile IO host.
Future<String?> detectDefaultWorkspaceRootImpl() async {
  try {
    final cwd = Directory.current;
    if (await cwd.exists() && cwd.path != '/' && cwd.path.isNotEmpty) {
      return p.canonicalize(cwd.path);
    }
  } catch (_) {}
  return null;
}

String _canonicalRealRoot(String rootPath) {
  final canonical = p.canonicalize(rootPath);
  try {
    if (Directory(canonical).existsSync()) {
      return Directory(canonical).resolveSymbolicLinksSync();
    }
  } catch (_) {}
  return canonical;
}

String _resolveSafePath(String rootPath, String relativePath) {
  final canonicalRoot = _canonicalRealRoot(rootPath);
  final trimmedRel = relativePath.trim();
  if (trimmedRel.isEmpty || trimmedRel == '.') {
    return canonicalRoot;
  }

  late final String candidate;
  if (p.isAbsolute(trimmedRel)) {
    candidate = p.canonicalize(trimmedRel);
  } else {
    candidate = p.normalize(p.join(canonicalRoot, trimmedRel));
  }

  if (candidate != canonicalRoot && !p.isWithin(canonicalRoot, candidate)) {
    throw ArgumentError(
      'Path traversal rejected: "$relativePath" escapes workspace root.',
    );
  }

  // Verify the deepest existing ancestor (or entity itself) does not traverse
  // through a symlink outside the workspace root.
  var probe = candidate;
  while (probe.isNotEmpty && probe != p.dirname(probe)) {
    final type = FileSystemEntity.typeSync(probe, followLinks: false);
    if (type != FileSystemEntityType.notFound) {
      try {
        final resolvedReal = File(probe).resolveSymbolicLinksSync();
        if (resolvedReal != canonicalRoot &&
            !p.isWithin(canonicalRoot, resolvedReal)) {
          throw ArgumentError(
            'Symlink escape rejected: "$relativePath" resolves outside workspace root.',
          );
        }
      } on ArgumentError {
        rethrow;
      } on FileSystemException {
        throw ArgumentError(
          'Path access rejected: an existing ancestor cannot be resolved safely.',
        );
      }
      break;
    }
    probe = p.dirname(probe);
  }

  return candidate;
}

/// Lists directory entries inside [rootPath] safely.
Future<List<WorkspaceFileEntry>> listFilesImpl(
  String rootPath, {
  String subdir = '',
  int maxEntries = 200,
  bool recursive = false,
}) async {
  final canonicalRoot = _canonicalRealRoot(rootPath);
  final targetPath = _resolveSafePath(canonicalRoot, subdir);
  final dir = Directory(targetPath);
  if (!await dir.exists()) {
    throw FileSystemException('Directory not found', targetPath);
  }

  final entries = <WorkspaceFileEntry>[];
  Future<void> visit(Directory current, int depth) async {
    if (entries.length >= maxEntries) {
      return;
    }
    final children = await current.list(followLinks: false).toList();
    children.sort((FileSystemEntity a, FileSystemEntity b) {
      final aDir = a is Directory;
      final bDir = b is Directory;
      if (aDir != bDir) {
        return aDir ? -1 : 1;
      }
      return p
          .basename(a.path)
          .toLowerCase()
          .compareTo(p.basename(b.path).toLowerCase());
    });

    for (final entity in children) {
      if (entries.length >= maxEntries) {
        break;
      }
      final name = p.basename(entity.path);
      if (_ignoredDirNames.contains(name)) {
        continue;
      }
      final rel = p.relative(entity.path, from: canonicalRoot);
      if (entity is Directory) {
        entries.add(
          WorkspaceFileEntry(relativePath: rel, name: name, isDirectory: true),
        );
        if (recursive && depth < 4) {
          await visit(entity, depth + 1);
        }
      } else if (entity is File) {
        var size = 0;
        try {
          size = await entity.length();
        } catch (_) {}
        entries.add(
          WorkspaceFileEntry(
            relativePath: rel,
            name: name,
            isDirectory: false,
            sizeBytes: size,
          ),
        );
      }
    }
  }

  await visit(dir, 0);
  return entries;
}

/// Reads a bounded line slice from [relativePath] inside [rootPath].
Future<WorkspaceFileSlice> readFileImpl(
  String rootPath,
  String relativePath, {
  int startLine = 1,
  int maxLines = 250,
}) async {
  final canonicalRoot = _canonicalRealRoot(rootPath);
  final resolved = _resolveSafePath(canonicalRoot, relativePath);
  final file = File(resolved);
  if (!await file.exists()) {
    throw FileSystemException('File not found', relativePath);
  }
  final length = await file.length();
  if (length > 2 * 1024 * 1024) {
    throw FormatException(
      'File "$relativePath" is ${(length / (1024 * 1024)).toStringAsFixed(1)} MB; limit is 2 MB.',
    );
  }

  final raw = await file.readAsString();
  final lines = raw.replaceAll('\r\n', '\n').split('\n');
  final safeStart = startLine.clamp(1, lines.isEmpty ? 1 : lines.length);
  final safeEnd = (safeStart + maxLines - 1).clamp(safeStart, lines.length);
  final sliceLines = lines.isEmpty
      ? const <String>[]
      : lines.sublist(safeStart - 1, safeEnd);

  final numbered = StringBuffer();
  for (var i = 0; i < sliceLines.length; i++) {
    numbered.writeln('${safeStart + i}: ${sliceLines[i]}');
  }

  return WorkspaceFileSlice(
    relativePath: p.relative(resolved, from: canonicalRoot),
    content: sliceLines.join('\n'),
    numberedPreview: numbered.toString().trimRight(),
    totalLines: lines.length,
    startLine: safeStart,
    endLine: safeEnd,
    truncated: safeEnd < lines.length,
  );
}

/// Searches text files inside [rootPath] for case-insensitive matches.
Future<List<WorkspaceSearchMatch>> searchCodeImpl(
  String rootPath,
  String query, {
  String? fileExtension,
  int maxMatches = 40,
}) async {
  final trimmedQuery = query.trim();
  if (trimmedQuery.isEmpty) {
    throw ArgumentError('Search query cannot be empty.');
  }
  final lowerQuery = trimmedQuery.toLowerCase();
  final extFilter = fileExtension?.trim().toLowerCase();
  final canonicalRoot = _canonicalRealRoot(rootPath);
  final matches = <WorkspaceSearchMatch>[];

  Future<void> scanDir(Directory dir) async {
    if (matches.length >= maxMatches) {
      return;
    }
    List<FileSystemEntity> children;
    try {
      children = await dir.list(followLinks: false).toList();
    } catch (_) {
      return;
    }
    for (final entity in children) {
      if (matches.length >= maxMatches) {
        break;
      }
      final name = p.basename(entity.path);
      if (entity is Directory) {
        if (!_ignoredDirNames.contains(name) && !name.startsWith('.')) {
          await scanDir(entity);
        }
        continue;
      }
      if (entity is! File) {
        continue;
      }
      if (extFilter != null && extFilter.isNotEmpty) {
        final normalizedExt = extFilter.startsWith('.')
            ? extFilter
            : '.$extFilter';
        if (!name.toLowerCase().endsWith(normalizedExt)) {
          continue;
        }
      }
      try {
        if (await entity.length() > 512 * 1024) {
          continue;
        }
        final content = await entity.readAsString();
        final rel = p.relative(entity.path, from: canonicalRoot);
        final lines = content.replaceAll('\r\n', '\n').split('\n');
        for (var i = 0; i < lines.length; i++) {
          if (lines[i].toLowerCase().contains(lowerQuery)) {
            matches.add(
              WorkspaceSearchMatch(
                relativePath: rel,
                lineNumber: i + 1,
                lineText: lines[i].trim(),
              ),
            );
            if (matches.length >= maxMatches) {
              break;
            }
          }
        }
      } catch (_) {
        // Skip binary or unreadable files cleanly.
      }
    }
  }

  await scanDir(Directory(canonicalRoot));
  return matches;
}

int _changeSeq = 0;

String _nextChangeId() {
  _changeSeq++;
  return 'chg_${DateTime.now().microsecondsSinceEpoch}_$_changeSeq';
}

/// Writes or creates [relativePath] inside [rootPath] safely.
Future<CodingFileChange> writeFileImpl(
  String rootPath,
  String relativePath,
  String content,
) async {
  final canonicalRoot = _canonicalRealRoot(rootPath);
  final resolved = _resolveSafePath(canonicalRoot, relativePath);
  final file = File(resolved);
  final existed = await file.exists();
  final before = existed ? await file.readAsString() : '';

  await file.parent.create(recursive: true);
  await file.writeAsString(content);

  return CodingFileChange(
    id: _nextChangeId(),
    relativePath: p.relative(resolved, from: canonicalRoot),
    kind: existed ? CodingChangeKind.modified : CodingChangeKind.created,
    beforePreview: _excerpt(before),
    afterPreview: _excerpt(content),
    timestamp: DateTime.now(),
    previousContent: existed && before.length <= 1024 * 1024 ? before : null,
    unifiedDiff: CodingWorkspaceFs.buildUnifiedDiff(before, content),
  );
}

/// Applies a verified find-and-replace patch on [relativePath] inside [rootPath].
Future<CodingFileChange> patchFileImpl(
  String rootPath,
  String relativePath, {
  required String findText,
  required String replaceText,
  bool replaceAll = false,
}) async {
  if (findText.isEmpty) {
    throw ArgumentError('findText cannot be empty.');
  }
  final canonicalRoot = _canonicalRealRoot(rootPath);
  final resolved = _resolveSafePath(canonicalRoot, relativePath);
  final file = File(resolved);
  if (!await file.exists()) {
    throw FileSystemException('File not found', relativePath);
  }
  final before = await file.readAsString();
  final firstIdx = before.indexOf(findText);
  if (firstIdx < 0) {
    throw ArgumentError(
      'Exact snippet not found in "$relativePath". Read the file first to verify whitespace and content.',
    );
  }
  if (!replaceAll) {
    final secondIdx = before.indexOf(findText, firstIdx + findText.length);
    if (secondIdx >= 0) {
      throw ArgumentError(
        'Multiple occurrences of findText found in "$relativePath". Provide more surrounding lines or set replaceAll=true.',
      );
    }
  }

  final updated = replaceAll
      ? before.replaceAll(findText, replaceText)
      : before.replaceFirst(findText, replaceText);
  await file.writeAsString(updated);

  return CodingFileChange(
    id: _nextChangeId(),
    relativePath: p.relative(resolved, from: canonicalRoot),
    kind: CodingChangeKind.modified,
    beforePreview: _excerpt(findText),
    afterPreview: _excerpt(replaceText),
    timestamp: DateTime.now(),
    previousContent: before.length <= 1024 * 1024 ? before : null,
    unifiedDiff: CodingWorkspaceFs.buildUnifiedDiff(before, updated),
  );
}

/// Deletes [relativePath] inside [rootPath] safely if it exists.
Future<void> deleteFileImpl(String rootPath, String relativePath) async {
  final canonicalRoot = _canonicalRealRoot(rootPath);
  final resolved = _resolveSafePath(canonicalRoot, relativePath);
  final file = File(resolved);
  if (await file.exists()) {
    await file.delete();
  }
}

/// Executes a bounded shell command inside [rootPath].
Future<WorkspaceCommandOutput> runCommandImpl(
  String rootPath,
  String commandLine, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final canonicalRoot = _canonicalRealRoot(rootPath);
  final trimmed = commandLine.trim();
  if (trimmed.isEmpty) {
    throw ArgumentError('Command cannot be empty.');
  }
  final watch = Stopwatch()..start();
  final shell = Platform.isWindows
      ? 'cmd'
      : (Platform.isMacOS ? '/bin/zsh' : '/bin/sh');
  final args = Platform.isWindows
      ? <String>['/C', trimmed]
      : <String>[Platform.isMacOS ? '-lc' : '-c', trimmed];
  final process = await Process.start(
    shell,
    args,
    workingDirectory: canonicalRoot,
  );
  final stdoutFuture = process.stdout.transform(systemEncoding.decoder).join();
  final stderrFuture = process.stderr.transform(systemEncoding.decoder).join();

  final exitCode = await process.exitCode.timeout(
    timeout,
    onTimeout: () {
      process.kill();
      throw TimeoutException('Command timed out after ${timeout.inSeconds}s.');
    },
  );
  watch.stop();
  final out = await stdoutFuture;
  final err = await stderrFuture;
  return WorkspaceCommandOutput(
    exitCode: exitCode,
    stdout: out.length > 16000
        ? '${out.substring(0, 16000)}\n...[truncated]'
        : out,
    stderr: err.length > 8000
        ? '${err.substring(0, 8000)}\n...[truncated]'
        : err,
    elapsedMs: watch.elapsedMilliseconds,
  );
}

String _excerpt(String raw) {
  final trimmed = raw.trim();
  if (trimmed.length <= 400) {
    return trimmed;
  }
  return '${trimmed.substring(0, 400)}...';
}
