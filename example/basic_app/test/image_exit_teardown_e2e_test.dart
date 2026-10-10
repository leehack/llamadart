@TestOn('mac-os || linux')
@Tags(['local-only'])
@Timeout(Duration(minutes: 30))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// Ends a child process in each way that leaves an image model alive on
/// Metal, where ggml-metal aborts at exit while a buffer is still allocated
/// and a progress callback into a VM that is shutting down aborts it
/// (stable-diffusion-native#10).
///
/// Set `IMAGE_EXIT_MODEL` to an image checkpoint such as SDXS;
/// `IMAGE_EXIT_RUNS` repeats each scenario (default 3). `IMAGE_EXIT_GGUF`, a
/// GGUF chat model, adds the scenario with both runtimes loaded.
void main() {
  final environment = Platform.environment;
  final model = environment['IMAGE_EXIT_MODEL'];
  final chatModel = environment['IMAGE_EXIT_GGUF'];
  final runs = int.parse(environment['IMAGE_EXIT_RUNS'] ?? '3');

  // A scenario of test/fixtures/image_exit_probe.dart with its remaining
  // arguments (null skips it) and the exit code of a clean end.
  for (final (scenario, arguments, exitCode) in <(String, List<String?>, int)>[
    if (Platform.isLinux) ...[
      ('quiet', [model], 0),
      ('host-shutdown-loaded', [model], 0),
      ('host-shutdown-generating', [model], 0),
      ('host-shutdown-loading', [model], 0),
      ('host-shutdown-loaded-logging', [model], 0),
      ('host-shutdown-generating-logging', [model], 0),
      ('host-shutdown-loading-logging', [model], 0),
      ('host-shutdown-both-loaded', [model, chatModel], 0),
    ] else ...[
      ('symbols', [model], 0),
      ('quiet', [model], 0),
      ('quit-loaded', [model], 0),
      ('quit-generating', [model], 0),
      ('quit-loading', [model], 0),
      ('quit-loaded-logging', [model], 0),
      ('quit-generating-logging', [model], 0),
      ('quit-loading-logging', [model], 0),
      ('throw-generating', [model], 255),
      ('throw-loading', [model], 255),
      ('kill-loading', [model], 0),
      ('dispose-quit', [model], 0),
      ('quit-both-loaded', [model, chatModel], 0),
    ],
  ]) {
    test('$scenario ends with exit code $exitCode', () async {
      // Not `skip:`, which --run-skipped (needed for `local-only`) overrides.
      if (arguments.contains(null)) {
        markTestSkipped(
          'Set the IMAGE_EXIT_ variables of $scenario to run it.',
        );
        return;
      }
      final codes = <int>[];
      final seconds = <String>[];
      for (var run = 0; run < runs; run++) {
        final probe = await _runProbe([scenario, ...arguments.nonNulls]);
        final reached = scenario.replaceFirst(RegExp(r'-logging$'), '');
        expect(
          probe.stdout,
          contains('IMAGE_PROBE_REACHED $reached'),
          reason: probe.stderr,
        );
        if (scenario == 'quiet') {
          // The recorder takes ggml's messages off stderr, and at the
          // default levels nothing reads them.
          expect(probe.stderr, isNot(contains('ggml_')));
          expect(probe.stdout, isNot(contains('IMAGE_PROBE_LOG_RECORDS')));
        }
        if (scenario.endsWith('-logging')) {
          expect(probe.stdout, contains('IMAGE_PROBE_LOG_RECORDS'));
        }
        if (probe.stdout.contains('IMAGE_PROBE_BACKEND')) {
          final backend = Platform.isLinux
              ? environment['IMAGE_EXIT_BACKEND'] ?? 'CPU'
              : 'MTL';
          expect(
            probe.stdout,
            matches(
              RegExp(
                'IMAGE_PROBE_BACKEND ${RegExp.escape(backend)}',
                caseSensitive: false,
              ),
            ),
          );
        }
        if (scenario == 'quit-both-loaded') {
          expect(probe.stdout, contains('IMAGE_PROBE_CHAT_BACKEND Metal'));
        }
        if (reached == 'quit-loaded') {
          expect(probe.stdout, contains('IMAGE_PROBE_TRACKED 1'));
        }
        if (scenario == 'dispose-quit') {
          expect(probe.stdout, contains('IMAGE_PROBE_TRACKED 0'));
        }
        if (scenario.startsWith('host-shutdown-')) {
          expect(probe.stdout, contains('IMAGE_PROBE_HOST_SHUTDOWN_COMPLETE'));
          expect(probe.stdout, contains('IMAGE_PROBE_TRACKED 0'));
        }
        if (scenario == 'host-shutdown-both-loaded') {
          final backend = environment['IMAGE_EXIT_CHAT_BACKEND'] ?? 'CPU';
          expect(
            probe.stdout,
            matches(
              RegExp(
                'IMAGE_PROBE_CHAT_BACKEND ${RegExp.escape(backend)}',
                caseSensitive: false,
              ),
            ),
          );
        }
        expect(probe.stderr, isNot(contains('GGML_ASSERT')));
        expect(probe.stderr, isNot(contains('GetFfiCallbackMetadata')));
        codes.add(probe.exitCode);
        seconds.add(probe.afterReached.toStringAsFixed(2));
      }
      // ignore: avoid_print
      print(
        'IMAGE_EXIT_E2E ${jsonEncode({
          scenario: {'exitCodes': codes, 'secondsAfterReached': seconds},
        })}',
      );
      expect(codes, everyElement(exitCode));
    });
  }

  test('a batch of images reports every sampling step in order and ends with '
      'the decoding event', () async {
    if (model == null) {
      markTestSkipped('Set IMAGE_EXIT_MODEL to run it.');
      return;
    }
    final probe = await _runProbe(['events', model]);
    expect(probe.exitCode, 0, reason: probe.stderr);
    final line = LineSplitter.split(
      probe.stdout,
    ).singleWhere((line) => line.startsWith('IMAGE_PROBE_EVENTS '));
    final events = jsonDecode(line.substring('IMAGE_PROBE_EVENTS '.length));

    // ignore: avoid_print
    print(line);
    expect(events, {
      for (final (count, steps) in [(2, 1), (3, 4), (2, 4)])
        '${count}x$steps': [
          'encodingPrompt 0/$steps image 0/$count',
          for (var image = 0; image < count; image++)
            for (var step = 0; step <= steps; step++)
              'sampling $step/$steps image $image/$count',
          'decoding 0/$count image ${count - 1}/$count',
        ],
    });
  });
}

/// Runs the probe fixture with [arguments] and reports how it ended and how
/// long after its last line it took to exit.
Future<({int exitCode, String stdout, String stderr, double afterReached})>
_runProbe(List<String> arguments) async {
  final process = await Process.start(Platform.resolvedExecutable, [
    'run',
    'test/fixtures/image_exit_probe.dart',
    ...arguments,
  ]);
  final sinceReached = Stopwatch();
  final stdout = process.stdout.transform(utf8.decoder).map((chunk) {
    if (chunk.contains('IMAGE_PROBE_REACHED')) sinceReached.start();
    return chunk;
  }).join();
  final stderr = process.stderr.transform(utf8.decoder).join();
  final int code;
  try {
    code = await process.exitCode.timeout(const Duration(minutes: 2));
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    fail('${arguments.first} did not exit: ${await stderr}');
  }
  sinceReached.stop();
  return (
    exitCode: code,
    stdout: await stdout,
    stderr: await stderr,
    afterReached: sinceReached.elapsedMicroseconds / 1e6,
  );
}
