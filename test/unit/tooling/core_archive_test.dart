@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

void main() {
  test(
    'archive gate rejects private files and failed extracted consumers',
    () async {
      final result =
          await Process.run(Platform.isWindows ? 'python' : 'python3', [
            '-m',
            'unittest',
            'discover',
            '-s',
            'test/ci',
            '-p',
            'test_core_archive.py',
          ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
  );
}
