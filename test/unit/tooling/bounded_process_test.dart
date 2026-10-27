@TestOn('vm && !windows')
library;

import 'dart:io';

import 'package:test/test.dart';

import 'support/bounded_process.dart';

void main() {
  test('returns the exit code and output of a child', () async {
    final result = await runBoundedProcess('sh', const [
      '-c',
      'echo out; echo err >&2; exit 3',
    ], timeout: const Duration(seconds: 30));

    expect(result.exitCode, 3);
    expect(result.stdout, 'out\n');
    expect(result.stderr, 'err\n');
  });

  test('gives a child that reads stdin end-of-file', () async {
    final result = await runBoundedProcess(
      'cat',
      const [],
      timeout: const Duration(seconds: 30),
    );

    expect(result.exitCode, 0);
  });

  test('runs a child in the requested working directory', () async {
    final directory = Directory.systemTemp.createTempSync(
      'bounded-process-cwd-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    File('${directory.path}/marker').writeAsStringSync('requested directory');
    final result = await runBoundedProcess(
      'cat',
      const ['marker'],
      workingDirectory: directory.path,
      timeout: const Duration(seconds: 30),
    );
    expect(result.exitCode, 0);
    expect(result.stdout, 'requested directory');
  });

  test('kills and reaps a TERM-ignoring child past its budget', () async {
    final stopwatch = Stopwatch()..start();
    final directory = Directory.systemTemp.createTempSync('bounded-process-');
    final childPid = File('${directory.path}/pid');
    addTearDown(() {
      if (childPid.existsSync()) {
        Process.killPid(
          int.parse(childPid.readAsStringSync().trim()),
          ProcessSignal.sigkill,
        );
      }
      directory.deleteSync(recursive: true);
    });

    await expectLater(
      runBoundedProcess('sh', [
        '-c',
        r'trap "" TERM; echo $$ > "$1"; echo partial-out; echo partial-err >&2; exec sleep 30',
        'bounded-process-test',
        childPid.path,
      ], timeout: const Duration(seconds: 1)),
      throwsA(
        isA<TestFailure>().having(
          (failure) => failure.message,
          'message',
          allOf(
            contains('did not exit within 1 s'),
            contains('stdout:\npartial-out\n'),
            contains('stderr:\npartial-err\n'),
          ),
        ),
      ),
    );
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 20)));
    expect(childPid.existsSync(), isTrue);
    final probe = await Process.run('kill', [
      '-0',
      childPid.readAsStringSync().trim(),
    ]);
    expect(
      probe.exitCode,
      isNot(0),
      reason: 'The timed-out direct child must be killed and reaped.',
    );
  });
}
