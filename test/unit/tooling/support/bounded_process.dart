import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';

/// Runs [executable] like [Process.run], but kills it after [timeout] and
/// fails the test with whatever it printed.
///
/// A test timeout does not stop a [Process.run] child: it keeps running into
/// the next test after `tearDown` has deleted its files, and competes with that
/// test's own processes.
Future<ProcessResult> runBoundedProcess(
  String executable,
  List<String> arguments, {
  required Duration timeout,
  Map<String, String>? environment,
}) async {
  final process = await Process.start(
    executable,
    arguments,
    environment: environment,
  );
  await process.stdin.close();
  final stdout = StringBuffer();
  final stderr = StringBuffer();
  final subscriptions = [
    process.stdout.transform(systemEncoding.decoder).listen(stdout.write),
    process.stderr.transform(systemEncoding.decoder).listen(stderr.write),
  ];
  final outputDone = Future.wait([
    for (final subscription in subscriptions) subscription.asFuture<void>(),
  ]);
  final exitCode = await process.exitCode.timeout(
    timeout,
    onTimeout: () async {
      process.kill();
      // A grandchild that inherited the pipes can hold them open.
      await outputDone.timeout(
        const Duration(seconds: 5),
        onTimeout: () async {
          for (final subscription in subscriptions) {
            await subscription.cancel();
          }
          return const [];
        },
      );
      fail(
        '`$executable ${arguments.join(' ')}` did not exit within '
        '${timeout.inSeconds} s.\nstdout:\n$stdout\nstderr:\n$stderr',
      );
    },
  );
  await outputDone;
  return ProcessResult(process.pid, exitCode, '$stdout', '$stderr');
}
