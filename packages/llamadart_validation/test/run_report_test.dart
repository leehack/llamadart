import 'dart:io';

import 'package:test/test.dart';

import '../bin/run.dart' as launcher;

void main() {
  late Directory output;
  late Directory kernelDir;
  late String runKernel;
  final fixtures = Directory('test/fixtures/windows_native_log');
  setUpAll(() async {
    kernelDir = Directory.systemTemp.createTempSync('run-report-kernel-');
    runKernel = '${kernelDir.path}/run.dill';
    final compiled = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'kernel',
      'bin/run.dart',
      '-o',
      runKernel,
    ]);
    expect(
      compiled.exitCode,
      0,
      reason: 'stdout:\n${compiled.stdout}\nstderr:\n${compiled.stderr}',
    );
  });
  tearDownAll(() => kernelDir.deleteSync(recursive: true));
  setUp(() {
    output = Directory.systemTemp.createTempSync('run-native-report-');
    File(
      '${fixtures.path}/tiny.events.jsonl',
    ).copySync('${output.path}/events.jsonl');
  });
  tearDown(() => output.deleteSync(recursive: true));

  test('same tiny CUDA journal requires its native log to qualify', () {
    final without = launcher.writeRunReports(output);
    expect(without.assertionsPassed, isTrue);
    expect(without.qualified, isFalse);
    final withLog = launcher.writeRunReports(
      output,
      nativeLogPath: '${fixtures.path}/tiny.native.txt',
    );
    expect(withLog.qualified, isTrue);
    expect(withLog.cases.length, 15);
  });
  test('native proof does not waive an actual history case failure', () {
    File(
      '${fixtures.path}/chat.events.jsonl',
    ).copySync('${output.path}/events.jsonl');
    final report = launcher.writeRunReports(
      output,
      nativeLogPath: '${fixtures.path}/chat.native.txt',
    );
    expect(report.qualified, isFalse);
    expect(
      report.cases.singleWhere(
        (row) => row['case_id'] == 'C06.history',
      )['status'],
      'FAIL',
    );
  });
  test('missing capture is an error', () {
    expect(
      () => launcher.writeRunReports(
        output,
        nativeLogPath: '${output.path}/missing',
      ),
      throwsA(isA<FileSystemException>()),
    );
  });
  test('invalid UTF-8 capture is an error', () {
    final log = File('${output.path}/invalid')..writeAsBytesSync([0xff]);
    expect(
      () => launcher.writeRunReports(output, nativeLogPath: log.path),
      throwsA(isA<FileSystemException>()),
    );
  });
  test('empty or unrelated text does not manufacture GPU proof', () {
    final log = File('${output.path}/empty');
    for (final text in ['', 'GPU success']) {
      log.writeAsStringSync(text);
      expect(
        launcher.writeRunReports(output, nativeLogPath: log.path).qualified,
        isFalse,
      );
    }
  });
  test('CLI rejects missing capture before runtime or model work', () async {
    final missing = '${output.path}/missing-cli';
    final run = await Process.run(Platform.resolvedExecutable, [
      runKernel,
      '--native-log',
      missing,
      '--profile',
      'tiny-gguf-cuda',
    ]);
    expect(
      run.exitCode,
      1,
      reason: 'stdout:\n${run.stdout}\nstderr:\n${run.stderr}',
    );
    expect('${run.stderr}', contains(missing));
    expect('${run.stderr}', contains('Cannot open file'));
    expect('${run.stdout}', isNot(contains('LLAMADART_VALIDATION')));
  });
  test('CLI rejects invalid UTF-8 capture before model work', () async {
    final log = File('${output.path}/invalid-cli')..writeAsBytesSync([0xff]);
    final run = await Process.run(Platform.resolvedExecutable, [
      runKernel,
      '--native-log',
      log.path,
      '--profile',
      'tiny-gguf-cuda',
    ]);
    expect(
      run.exitCode,
      1,
      reason: 'stdout:\n${run.stdout}\nstderr:\n${run.stderr}',
    );
    expect('${run.stderr}', contains('Failed to decode'));
    expect('${run.stdout}', isNot(contains('LLAMADART_VALIDATION')));
  });

  test(
    'CLI rejects missing capture with a truncated native-assets manifest',
    () async {
      final truncatedDir = Directory.systemTemp.createTempSync(
        'run-truncated-assets-',
      );
      addTearDown(() => truncatedDir.deleteSync(recursive: true));
      File(
        '${truncatedDir.path}/.dart_tool/native_assets.yaml',
      ).createSync(recursive: true);
      final run = await Process.run(Platform.resolvedExecutable, [
        runKernel,
        '--native-log',
        '${truncatedDir.path}/missing',
        '--profile',
        'tiny-gguf-cuda',
      ], workingDirectory: truncatedDir.path);
      expect(
        run.exitCode,
        1,
        reason: 'stdout:\n${run.stdout}\nstderr:\n${run.stderr}',
      );
      expect('${run.stderr}', contains('Cannot open file'));
    },
  );

  test('validation tests do not invoke dart run', () {
    // Dart run can rewrite the native-assets manifest while another test
    // subprocess is compiling.
    final dartRun = RegExp(
      r'''Platform\s*\.\s*resolvedExecutable\s*,\s*(?:<String>\s*)?\[\s*(['"])run\1''',
    );
    final offenders = <String>[];
    for (final file in Directory(
      'test',
    ).listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('_test.dart')) continue;
      final source = file.readAsStringSync();
      for (final match in dartRun.allMatches(source)) {
        final line = source.substring(0, match.start).split('\n').length;
        offenders.add('${file.path}:$line');
      }
    }
    expect(offenders, isEmpty);
  });
}
