import 'dart:io';

import 'package:path/path.dart' as p;

/// Resolves file-tool paths without allowing them to escape a workspace.
class WorkspaceGuard {
  late final String _workspaceRoot;

  WorkspaceGuard(String workspaceRoot) {
    final absoluteRoot = p.normalize(p.absolute(workspaceRoot));
    if (FileSystemEntity.typeSync(absoluteRoot, followLinks: true) !=
        FileSystemEntityType.directory) {
      throw FileSystemException('Workspace directory not found', absoluteRoot);
    }
    _workspaceRoot = _resolveExistingPath(absoluteRoot);
  }

  String get workspaceRoot => _workspaceRoot;

  /// Returns the canonical, workspace-confined path represented by [input].
  ///
  /// Surrounding whitespace is ignored so model-generated path arguments do
  /// not become literal whitespace-bearing filenames.
  String resolvePath(String input) {
    final path = input.trim();
    if (path.contains('\u0000')) {
      throw ArgumentError('Path contains a null byte.');
    }
    final absolute = p.normalize(
      p.absolute(
        path.isEmpty
            ? _workspaceRoot
            : p.isAbsolute(path)
            ? path
            : p.join(_workspaceRoot, path),
      ),
    );
    final canonical = _resolveExistingPath(absolute);
    _ensureInsideWorkspace(canonical, input);
    return canonical;
  }

  /// Converts [path] to a canonical workspace-relative path.
  String toWorkspaceRelative(String path) {
    final canonical = _resolveExistingPath(path);
    _ensureInsideWorkspace(canonical, path);
    final relative = p.relative(canonical, from: _workspaceRoot);
    return relative.isEmpty ? '.' : relative;
  }

  void _ensureInsideWorkspace(String candidate, String original) {
    if (candidate != _workspaceRoot && !p.isWithin(_workspaceRoot, candidate)) {
      throw ArgumentError('Path escapes workspace root: $original');
    }
  }

  static String _resolveExistingPath(String path, [Set<String>? seenLinks]) {
    final normalized = p.normalize(p.absolute(path));
    final links = seenLinks ?? <String>{};
    final directType = FileSystemEntity.typeSync(
      normalized,
      followLinks: false,
    );

    if (directType == FileSystemEntityType.link) {
      if (!links.add(normalized)) {
        throw FileSystemException('Symbolic link cycle detected', normalized);
      }
      final target = Link(normalized).targetSync();
      return _resolveExistingPath(
        p.isAbsolute(target) ? target : p.join(p.dirname(normalized), target),
        links,
      );
    }

    final type = FileSystemEntity.typeSync(normalized, followLinks: true);
    if (type == FileSystemEntityType.notFound) {
      final parent = p.dirname(normalized);
      if (parent == normalized) {
        return normalized;
      }
      return p.normalize(
        p.join(_resolveExistingPath(parent, links), p.basename(normalized)),
      );
    }

    if (type == FileSystemEntityType.directory) {
      return p.normalize(Directory(normalized).resolveSymbolicLinksSync());
    }
    if (type == FileSystemEntityType.file) {
      return p.normalize(File(normalized).resolveSymbolicLinksSync());
    }
    throw FileSystemException(
      'Unsupported filesystem entity while resolving path',
      normalized,
    );
  }
}
