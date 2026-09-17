@TestOn('windows')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  for (final resolver in [
    '_resolveReasoningBudgetApi',
    '_resolveTtsApi',
    '_resolveLogLevelFallbackFunction',
    '_resolveSpeculativeApi',
  ]) {
    test('production $resolver loads Windows wrapper sibling DLLs', () async {
      // dart run executes the real pinned build hook and production
      // resolver in a fresh process. In particular, llama-common.dll and
      // mtmd.dll must not have been preloaded by another test or model load.
      final process = await Process.start(Platform.resolvedExecutable, [
        'run',
        path.join('test', 'fixtures', 'native_wrapper_loading_probe.dart'),
        resolver,
      ], workingDirectory: Directory.current.path);
      final stdout = process.stdout.transform(utf8.decoder).join();
      final stderr = process.stderr.transform(utf8.decoder).join();
      int exitCode;
      try {
        exitCode = await process.exitCode.timeout(const Duration(minutes: 5));
      } on TimeoutException {
        process.kill();
        rethrow;
      }
      final output = await stdout;
      final errors = await stderr;
      expect(exitCode, 0, reason: '$output\n$errors');
      expect(output, contains('WRAPPER_RESOLVED $resolver'));
    }, timeout: const Timeout(Duration(minutes: 6)));
  }
}
