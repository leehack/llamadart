@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

import '../../../tool/prepare_workspace.dart';

Directory _workspaceFixture() {
  final root = Directory.systemTemp.createTempSync('prepare_workspace_test');
  addTearDown(() => root.deleteSync(recursive: true));
  for (final package in workspacePackages) {
    final directory =
        package.path == '.' ? root : Directory('${root.path}/${package.path}')
          ..createSync(recursive: true);
    File('${directory.path}/pubspec.yaml').writeAsStringSync('name: fixture\n');
  }
  return root;
}

void main() {
  test('checked-in package roots are fully classified', () {
    expect(validateWorkspaceManifest(Directory.current), isEmpty);
  });

  test('prepares every package with its declared SDK in order', () async {
    final root = _workspaceFixture();
    final commands = <String>[];

    final result = await prepareWorkspace(
      root,
      commandRunner: (executable, arguments, workingDirectory) async {
        final relative = workingDirectory == root.path
            ? '.'
            : workingDirectory.substring(root.path.length + 1);
        commands.add('$executable ${arguments.join(' ')} @ $relative');
        return 0;
      },
    );

    expect(result, 0);
    expect(commands, <String>[
      for (final package in workspacePackages)
        '${package.packageManager.name} pub get @ ${package.path}',
    ]);
    expect(commands, contains('flutter pub get @ example/chat_app'));
  });

  test('rejects a package that is not in the preparation manifest', () {
    final root = _workspaceFixture();
    final pubspec = File('${root.path}/example/new_example/pubspec.yaml');
    pubspec.parent.createSync(recursive: true);
    pubspec.writeAsStringSync('name: new_example\n');

    expect(
      validateWorkspaceManifest(root),
      contains(
        'Unclassified workspace package: example/new_example/pubspec.yaml',
      ),
    );
  });

  test('ignores explicitly generated package trees', () {
    final root = _workspaceFixture();
    for (final path in <String>[
      'example/chat_app/.dart_tool/generated/pubspec.yaml',
      'example/chat_app/build/generated/pubspec.yaml',
      'example/chat_app/macos/flutter/ephemeral/plugin/pubspec.yaml',
    ]) {
      final pubspec = File('${root.path}/$path');
      pubspec.parent.createSync(recursive: true);
      pubspec.writeAsStringSync('name: generated\n');
    }

    expect(validateWorkspaceManifest(root), isEmpty);
  });

  test(
    'does not traverse symlinked package trees',
    () {
      final root = _workspaceFixture();
      final externalPackage = Directory('${root.path}/external_fixture')
        ..createSync();
      File(
        '${externalPackage.path}/pubspec.yaml',
      ).writeAsStringSync('name: external\n');
      Link(
        '${root.path}/example/symlinked_package',
      ).createSync(externalPackage.path);

      expect(validateWorkspaceManifest(root), isEmpty);
    },
    skip: Platform.isWindows ? 'Symlink creation needs elevated access.' : null,
  );

  test('stops without hiding a failed dependency resolution', () async {
    final root = _workspaceFixture();
    var calls = 0;

    final result = await prepareWorkspace(
      root,
      commandRunner: (executable, arguments, workingDirectory) async {
        calls += 1;
        return calls == 3 ? 17 : 0;
      },
    );

    expect(result, 17);
    expect(calls, 3);
  });
}
