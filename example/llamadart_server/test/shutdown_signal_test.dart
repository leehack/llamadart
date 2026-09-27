@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:llamadart_server/src/bootstrap/shutdown_signal.dart';
import 'package:test/test.dart';

void main() {
  test('watches only SIGINT on Windows', () {
    expect(shutdownSignals(isWindows: true), [ProcessSignal.sigint]);
  });

  test('watches SIGINT and SIGTERM elsewhere', () {
    expect(shutdownSignals(isWindows: false), [
      ProcessSignal.sigint,
      ProcessSignal.sigterm,
    ]);
  });

  test('every signal for this platform can be watched', () async {
    for (final signal in shutdownSignals()) {
      final subscription = signal.watch().listen((_) {});
      await subscription.cancel();
    }
  });

  for (final signal in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
    test(
      'a waiting process stops cleanly on $signal',
      () async {
        final process = await Process.start(Platform.resolvedExecutable, [
          'run',
          'test/support/shutdown_signal_probe.dart',
        ]);
        final lines = process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .asBroadcastStream();
        final stderrText = process.stderr.transform(utf8.decoder).join();

        await lines.firstWhere((line) => line == 'ready');
        expect(process.kill(signal), isTrue);
        final stopped = lines.contains('stopped');

        expect(await process.exitCode, 0, reason: await stderrText);
        expect(await stopped, isTrue);
      },
      testOn: '!windows',
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }
}
