import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Compiles the Dart [script] to a kernel snapshot and returns its path; the
/// snapshot is deleted when the calling group's tests finish.
///
/// `dart <script>` recompiles the script and all of its imports on every
/// launch, which costs seconds per run on CI. Call this from `setUpAll` and
/// pass the snapshot to `dart` in place of the script to run the same program.
Future<String> compileDartScript(String script) async {
  final directory = await Directory.systemTemp.createTemp('dart_script_');
  addTearDown(() => directory.delete(recursive: true));
  final snapshot = p.join(
    directory.path,
    '${p.basenameWithoutExtension(script)}.dill',
  );
  final result = await Process.run(Platform.resolvedExecutable, <String>[
    'compile',
    'kernel',
    '--packages=${p.absolute('.dart_tool/package_config.json')}',
    '--output=$snapshot',
    p.absolute(script),
  ]);
  if (result.exitCode != 0) {
    throw StateError(
      'dart compile kernel $script exited ${result.exitCode}:\n'
      '${result.stdout}${result.stderr}',
    );
  }
  return snapshot;
}
