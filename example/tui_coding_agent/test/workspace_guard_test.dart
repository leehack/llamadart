import 'dart:io';

import 'package:llamadart_tui_coding_agent/src/workspace_guard.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('WorkspaceGuard', () {
    late Directory workspace;
    late WorkspaceGuard guard;

    setUp(() async {
      workspace = await Directory.systemTemp.createTemp('workspace_guard_');
      guard = WorkspaceGuard(workspace.path);
    });

    tearDown(() async {
      if (workspace.existsSync()) {
        await workspace.delete(recursive: true);
      }
    });

    test('requires an existing workspace directory', () async {
      final missing = p.join(workspace.path, 'missing');
      final file = await File(
        p.join(workspace.path, 'file.txt'),
      ).writeAsString('x');

      expect(
        () => WorkspaceGuard(missing),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        () => WorkspaceGuard(file.path),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('canonicalizes paths and returns workspace-relative paths', () async {
      final file = File(p.join(workspace.path, 'lib', 'main.dart'));
      await file.parent.create(recursive: true);
      await file.writeAsString('void main() {}');

      final resolved = guard.resolvePath('lib/../lib/main.dart');

      expect(resolved, file.resolveSymbolicLinksSync());
      expect(
        guard.resolvePath(' \nlib/../lib/main.dart\t '),
        file.resolveSymbolicLinksSync(),
      );
      expect(guard.toWorkspaceRelative(resolved), p.join('lib', 'main.dart'));
      expect(guard.resolvePath(''), guard.workspaceRoot);
      expect(guard.resolvePath(' \n\t '), guard.workspaceRoot);
    });

    test('rejects lexical traversal and absolute outside paths', () async {
      final outside = await Directory.systemTemp.createTemp('guard_outside_');
      addTearDown(() async => outside.delete(recursive: true));

      expect(
        () => guard.resolvePath('../outside.txt'),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => guard.resolvePath(p.join(outside.path, 'outside.txt')),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => guard.resolvePath('bad\u0000path'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test(
      'allows internal symlinks and reports their canonical target',
      () async {
        final actual = Directory(p.join(workspace.path, 'actual'));
        await actual.create();
        await File(p.join(actual.path, 'note.txt')).writeAsString('safe');
        await Link(p.join(workspace.path, 'alias')).create(actual.path);

        final resolved = guard.resolvePath('alias/note.txt');

        expect(resolved, p.join(actual.resolveSymbolicLinksSync(), 'note.txt'));
        expect(
          guard.toWorkspaceRelative(resolved),
          p.join('actual', 'note.txt'),
        );
      },
      skip: Platform.isWindows
          ? 'Creating symbolic links requires elevated Windows privileges.'
          : false,
    );

    test(
      'rejects external final, parent, and dangling symlinks',
      () async {
        final outside = await Directory.systemTemp.createTemp('guard_outside_');
        addTearDown(() async => outside.delete(recursive: true));
        final outsideFile = await File(
          p.join(outside.path, 'outside.txt'),
        ).writeAsString('outside');
        await Link(
          p.join(workspace.path, 'file-link'),
        ).create(outsideFile.path);
        await Link(p.join(workspace.path, 'dir-link')).create(outside.path);
        await Link(
          p.join(workspace.path, 'dangling-link'),
        ).create(p.join(outside.path, 'missing.txt'));

        for (final path in <String>[
          'file-link',
          'dir-link/new.txt',
          'dangling-link',
        ]) {
          expect(
            () => guard.resolvePath(path),
            throwsA(isA<ArgumentError>()),
            reason: path,
          );
        }
      },
      skip: Platform.isWindows
          ? 'Creating symbolic links requires elevated Windows privileges.'
          : false,
    );
  });
}
