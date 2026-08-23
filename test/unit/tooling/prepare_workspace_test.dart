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

String _workspaceRelativePath(String rootPath, String workingDirectory) {
  if (workingDirectory == rootPath) {
    return '.';
  }
  return workingDirectory.substring(rootPath.length + 1).replaceAll('\\', '/');
}

void main() {
  test('checked-in package roots are fully classified', () {
    expect(validateWorkspaceManifest(Directory.current), isEmpty);
  });

  test('workspace manifest has one canonical entry for every owned lane', () {
    expect(workspacePackages.map((package) => package.path), <String>[
      '.',
      'example/basic_app',
      'example/chat_app',
      'example/llamadart_cli',
      'example/llamadart_server',
      'example/tui_coding_agent',
      'packages/llamadart_litert_lm_flutter',
      'packages/llamadart_llama_cpp_flutter',
    ]);
    expect(
      workspacePackages.map((package) => package.path).toSet(),
      hasLength(workspacePackages.length),
    );
    expect(
      workspacePackages.where((package) => package.path == '.'),
      hasLength(1),
    );
    expect(
      workspacePackages.map((package) => package.path),
      everyElement(
        anyOf(
          equals('.'),
          allOf(isNot(startsWith('/')), isNot(contains('\\'))),
        ),
      ),
    );
  });

  test(
    'prepares every root-gate package with its declared SDK in order',
    () async {
      final root = _workspaceFixture();
      final commands = <String>[];

      final result = await prepareWorkspace(
        root,
        commandRunner: (executable, arguments, workingDirectory) async {
          final relative = _workspaceRelativePath(root.path, workingDirectory);
          commands.add('$executable ${arguments.join(' ')} @ $relative');
          return 0;
        },
      );

      expect(result, 0);
      expect(commands, <String>[
        'flutter pub get @ .',
        'flutter pub get @ example/basic_app',
        'flutter pub get @ example/chat_app',
        'dart pub get @ example/llamadart_cli',
        'dart pub get @ example/llamadart_server',
        'dart pub get @ example/tui_coding_agent',
      ]);
      expect(
        workspacePackages
            .where((package) => package.path.startsWith('example/'))
            .every((package) => package.prepareForRootQualityGates),
        isTrue,
        reason: 'Every maintained example belongs to the root quality lane.',
      );
      expect(
        workspacePackages
            .where((package) => package.path.startsWith('packages/'))
            .every((package) => !package.prepareForRootQualityGates),
        isTrue,
        reason: 'Companion packages own separate CI quality lanes.',
      );
    },
  );

  test('normalizes Windows workspace command paths for stable assertions', () {
    expect(
      _workspaceRelativePath(r'C:\repo', r'C:\repo\example\chat_app'),
      'example/chat_app',
    );
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

  test('rejects a missing package from the preparation manifest', () {
    final root = _workspaceFixture();
    File('${root.path}/example/llamadart_server/pubspec.yaml').deleteSync();

    expect(
      validateWorkspaceManifest(root),
      contains(
        'Missing workspace package: '
        'example/llamadart_server/pubspec.yaml',
      ),
    );
  });

  test('ignores explicitly generated package trees', () {
    final root = _workspaceFixture();
    for (final path in <String>[
      'example/chat_app/.dart_tool/generated/pubspec.yaml',
      'example/chat_app/build/generated/pubspec.yaml',
      'example/chat_app/macos/Flutter/ephemeral/plugin/pubspec.yaml',
      'example/chat_app/ios/.symlinks/plugins/example/pubspec.yaml',
      'example/chat_app/ios/Pods/generated/pubspec.yaml',
      'example/chat_app/macos/Pods/generated/pubspec.yaml',
    ]) {
      final pubspec = File('${root.path}/$path');
      pubspec.parent.createSync(recursive: true);
      pubspec.writeAsStringSync('name: generated\n');
    }

    expect(validateWorkspaceManifest(root), isEmpty);
  });

  test('does not prune maintained packages with generated-looking names', () {
    final root = _workspaceFixture();
    for (final name in <String>[
      '.dart_tooling',
      'builder',
      '.symlinks_backup',
      'PodsApp',
      'ephemeralized',
    ]) {
      final pubspec = File('${root.path}/example/$name/pubspec.yaml');
      pubspec.parent.createSync(recursive: true);
      pubspec.writeAsStringSync('name: generated_lookalike\n');
    }

    expect(validateWorkspaceManifest(root), <String>[
      'Unclassified workspace package: '
          'example/.dart_tooling/pubspec.yaml',
      'Unclassified workspace package: '
          'example/.symlinks_backup/pubspec.yaml',
      'Unclassified workspace package: example/PodsApp/pubspec.yaml',
      'Unclassified workspace package: example/builder/pubspec.yaml',
      'Unclassified workspace package: '
          'example/ephemeralized/pubspec.yaml',
    ]);
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
    final calls = <String>[];

    final result = await prepareWorkspace(
      root,
      commandRunner: (executable, arguments, workingDirectory) async {
        calls.add(
          '$executable ${arguments.join(' ')} @ '
          '${_workspaceRelativePath(root.path, workingDirectory)}',
        );
        return calls.length == 3 ? 17 : 0;
      },
    );

    expect(result, 17);
    expect(calls, <String>[
      'flutter pub get @ .',
      'flutter pub get @ example/basic_app',
      'flutter pub get @ example/chat_app',
    ]);
  });

  test('reports a stable exit code when an SDK command cannot start', () async {
    final root = _workspaceFixture();

    final result = await runWorkspaceCommand(
      'missing-workspace-sdk-command-for-test',
      const <String>['pub', 'get'],
      root.path,
    );

    expect(result, 127);
  });
}
