import 'dart:io';

import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'coding commands use an OS-provided shell in the selected workspace',
    () async {
      final root = await Directory.systemTemp.createTemp('studio shell ');
      addTearDown(() => root.delete(recursive: true));
      final shell = await CodingWorkspaceFs.runCommand(
        root.path,
        Platform.isWindows ? 'echo %COMSPEC%' : r'''printf '%s' "$0"''',
      );
      expect(shell.exitCode, 0, reason: shell.stderr);
      if (Platform.isWindows) {
        expect(shell.stdout.trim().toLowerCase(), endsWith(r'\cmd.exe'));
      } else {
        expect(shell.stdout.trim(), Platform.isMacOS ? '/bin/zsh' : '/bin/sh');
      }
      final cwd = await CodingWorkspaceFs.runCommand(
        root.path,
        Platform.isWindows ? 'cd' : 'pwd',
      );
      expect(cwd.exitCode, 0, reason: cwd.stderr);
      expect(
        Directory(cwd.stdout.trim()).resolveSymbolicLinksSync(),
        root.resolveSymbolicLinksSync(),
      );
    },
  );
}
