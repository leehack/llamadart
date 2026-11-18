@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late Directory outside;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('studio_boundary_');
    outside = await Directory.systemTemp.createTemp('studio_outside_');
  });
  tearDown(() async {
    await root.delete(recursive: true);
    await outside.delete(recursive: true);
  });

  for (final existed in [false, true]) {
    test(
      'Revert preserves an externally added BOM (existing=$existed)',
      () async {
        final file = File(p.join(root.path, 'bom.txt'));
        if (existed) await file.writeAsString('before');
        final change = await CodingWorkspaceFs.writeFile(
          root.path,
          'bom.txt',
          'after',
        );
        final externalBytes = [0xef, 0xbb, 0xbf, ...utf8.encode('after')];
        await file.writeAsBytes(externalBytes);
        await expectLater(
          CodingWorkspaceFs.revertFile(root.path, change),
          throwsStateError,
        );
        expect(await file.readAsBytes(), externalBytes);
        await file.writeAsString('after');
        await CodingWorkspaceFs.revertFile(root.path, change);
        if (existed) {
          expect(await file.readAsString(), 'before');
        } else {
          expect(await file.exists(), isFalse);
        }
      },
    );
  }

  test('write refuses a dangling symlink to a missing outside file', () async {
    final destination = File(p.join(outside.path, 'missing.txt'));
    await Link(p.join(root.path, 'output.txt')).create(destination.path);
    await expectLater(
      CodingWorkspaceFs.writeFile(root.path, 'output.txt', 'escape'),
      throwsArgumentError,
    );
    expect(await destination.exists(), isFalse);
  });

  test(
    'write refuses a dangling ancestor symlink to an outside directory',
    () async {
      final destination = Directory(p.join(outside.path, 'missing'));
      await Link(p.join(root.path, 'output')).create(destination.path);
      await expectLater(
        CodingWorkspaceFs.writeFile(root.path, 'output/new.txt', 'escape'),
        throwsArgumentError,
      );
      expect(await destination.exists(), isFalse);
    },
  );

  test(
    'write retains normal nested paths and resolved internal symlinks',
    () async {
      await CodingWorkspaceFs.writeFile(root.path, 'nested/new.txt', 'first');
      final destination = File(p.join(root.path, 'nested', 'new.txt'));
      await Link(p.join(root.path, 'internal.txt')).create(destination.path);
      await CodingWorkspaceFs.writeFile(root.path, 'internal.txt', 'second');
      expect(await destination.readAsString(), 'second');
    },
  );
}
