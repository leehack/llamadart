#!/usr/bin/env dart

import 'dart:io';

/// The dependency resolver used for a package in this repository.
enum WorkspacePackageManager {
  /// Resolve with the Dart SDK.
  dart,

  /// Resolve with the Flutter SDK.
  flutter,
}

/// A maintained Dart or Flutter package prepared by the root quality gates.
class WorkspacePackage {
  /// Creates a package entry relative to the repository root.
  const WorkspacePackage(
    this.path,
    this.packageManager, {
    this.enforceLockfile = false,
  });

  /// The package directory relative to the repository root.
  final String path;

  /// The SDK command that resolves this package's dependencies.
  final WorkspacePackageManager packageManager;

  /// Whether dependency resolution must preserve a checked-in lockfile.
  final bool enforceLockfile;
}

/// Every maintained package that must be resolved before root format/analyze.
///
/// Keep this list explicit so SDK selection is reviewable. The layout check
/// below fails when a package is added or removed without updating the list.
const List<WorkspacePackage> workspacePackages = <WorkspacePackage>[
  WorkspacePackage('.', WorkspacePackageManager.flutter),
  WorkspacePackage('example/basic_app', WorkspacePackageManager.flutter),
  WorkspacePackage(
    'example/chat_app',
    WorkspacePackageManager.flutter,
    enforceLockfile: true,
  ),
  WorkspacePackage('example/llamadart_cli', WorkspacePackageManager.dart),
  WorkspacePackage('example/llamadart_server', WorkspacePackageManager.dart),
  WorkspacePackage('example/tui_coding_agent', WorkspacePackageManager.dart),
  WorkspacePackage(
    'packages/llamadart_litert_lm_flutter',
    WorkspacePackageManager.flutter,
  ),
  WorkspacePackage(
    'packages/llamadart_llama_cpp_flutter',
    WorkspacePackageManager.flutter,
  ),
];

/// Runs one dependency-resolution command.
typedef WorkspaceCommandRunner =
    Future<int> Function(
      String executable,
      List<String> arguments,
      String workingDirectory,
    );

/// Returns maintained `pubspec.yaml` paths found in the repository.
///
/// Generated `.dart_tool`, `build`, and Flutter platform `ephemeral` trees are
/// never package roots. The root, `example/`, and `packages/` directories are
/// the repository-owned package boundary; vendored or local-only trees outside
/// it are not workspace members.
Set<String> discoverWorkspacePubspecs(Directory repositoryRoot) {
  final paths = <String>{};
  final rootPubspec = File('${repositoryRoot.path}/pubspec.yaml');
  if (rootPubspec.existsSync()) {
    paths.add('pubspec.yaml');
  }

  for (final topLevel in const <String>['example', 'packages']) {
    final directory = Directory('${repositoryRoot.path}/$topLevel');
    if (!directory.existsSync()) {
      continue;
    }
    for (final entity in directory.listSync(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File ||
          !entity.path.endsWith('${Platform.pathSeparator}pubspec.yaml')) {
        continue;
      }
      final relative = entity.path
          .substring(repositoryRoot.path.length + 1)
          .replaceAll(Platform.pathSeparator, '/');
      final segments = relative.split('/');
      if (segments.contains('.dart_tool') ||
          segments.contains('build') ||
          _isFlutterEphemeral(segments)) {
        continue;
      }
      paths.add(relative);
    }
  }
  return paths;
}

bool _isFlutterEphemeral(List<String> segments) {
  for (var index = 0; index < segments.length - 1; index++) {
    if (segments[index] == 'flutter' && segments[index + 1] == 'ephemeral') {
      return true;
    }
  }
  return false;
}

/// Returns package-layout errors that would make preparation incomplete.
List<String> validateWorkspaceManifest(Directory repositoryRoot) {
  final expected = workspacePackages
      .map(
        (package) => package.path == '.'
            ? 'pubspec.yaml'
            : '${package.path}/pubspec.yaml',
      )
      .toSet();
  final discovered = discoverWorkspacePubspecs(repositoryRoot);
  final errors = <String>[];

  for (final missing in expected.difference(discovered).toList()..sort()) {
    errors.add('Missing workspace package: $missing');
  }
  for (final unclassified in discovered.difference(expected).toList()..sort()) {
    errors.add('Unclassified workspace package: $unclassified');
  }
  return errors;
}

/// Resolves every maintained package, stopping at the first failed command.
Future<int> prepareWorkspace(
  Directory repositoryRoot, {
  WorkspaceCommandRunner commandRunner = runWorkspaceCommand,
}) async {
  final layoutErrors = validateWorkspaceManifest(repositoryRoot);
  if (layoutErrors.isNotEmpty) {
    for (final error in layoutErrors) {
      stderr.writeln(error);
    }
    return 64;
  }

  for (final package in workspacePackages) {
    final executable = package.packageManager.name;
    final arguments = <String>[
      'pub',
      'get',
      if (package.enforceLockfile) '--enforce-lockfile',
    ];
    stdout.writeln(
      'Preparing ${package.path} with $executable ${arguments.join(' ')}',
    );
    final result = await commandRunner(
      executable,
      arguments,
      package.path == '.'
          ? repositoryRoot.path
          : '${repositoryRoot.path}/${package.path}',
    );
    if (result != 0) {
      stderr.writeln(
        'Dependency preparation failed for ${package.path} (exit $result).',
      );
      return result;
    }
  }
  return 0;
}

/// Runs a workspace command with output attached to the current terminal.
Future<int> runWorkspaceCommand(
  String executable,
  List<String> arguments,
  String workingDirectory,
) async {
  final process = await Process.start(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    mode: ProcessStartMode.inheritStdio,
  );
  return process.exitCode;
}

Future<void> main() async {
  final repositoryRoot = File.fromUri(Platform.script).parent.parent;
  final result = await prepareWorkspace(repositoryRoot);
  if (result != 0) {
    exitCode = result;
  }
}
