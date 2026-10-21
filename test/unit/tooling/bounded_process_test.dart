@TestOn('vm && !windows')
library;

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

  test('kills a child past its budget and reports what it printed', () async {
    final stopwatch = Stopwatch()..start();

    await expectLater(
      runBoundedProcess('sh', const [
        '-c',
        'echo partial-out; echo partial-err >&2; exec sleep 30',
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
  });
}
