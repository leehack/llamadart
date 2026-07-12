@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

void main() {
  group('CLI entrypoint process behavior', () {
    test('--help exits with 0 and prints usage', () async {
      final result = await _runCli(<String>['--help']);

      expect(result.exitCode, 0);
      final stdoutText = result.stdout as String;
      final stderrText = result.stderr as String;

      expect(stdoutText, contains('OpenAI-compatible API Server Example'));
      expect(stdoutText, contains('--model'));
      expect(_withoutDartBuildHookBanner(stderrText).trim(), isEmpty);
    });

    test('unknown option exits with usage code', () async {
      final result = await _runCli(<String>['--unknown-option']);

      expect(result.exitCode, 64);
      final stderrText = result.stderr as String;

      expect(stderrText, contains('Error:'));
      expect(stderrText, contains('Run with --help to see usage.'));
    });

    test('invalid host value exits with usage code', () async {
      final result = await _runCli(<String>['--host', 'not-an-ip']);

      expect(result.exitCode, 64);
      final stderrText = result.stderr as String;

      expect(stderrText, contains('Invalid --host value: not-an-ip'));
      expect(stderrText, contains('Run with --help to see usage.'));
    });

    test('runtime failures exit with software code', () async {
      final result = await _runCli(<String>[
        '--model',
        '/__llamadart_nonexistent__/model.gguf',
        '--host',
        '127.0.0.1',
        '--port',
        '0',
      ]);

      expect(result.exitCode, 70);
      final stderrText = result.stderr as String;
      expect(stderrText, contains('Error:'));
    });
  });
}

Future<ProcessResult> _runCli(List<String> args) {
  return Process.run(Platform.resolvedExecutable, <String>[
    'run',
    'bin/llamadart_server.dart',
    ...args,
  ], workingDirectory: Directory.current.path);
}

String _withoutDartBuildHookBanner(String text) {
  return text.replaceAll('Running build hooks...', '');
}
