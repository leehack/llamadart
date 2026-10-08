@TestOn('mac-os')
@Tags(['local-only'])
@Timeout(Duration(minutes: 30))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Quits a Flutter macOS app that has models loaded on Metal and has disposed
/// nothing, through each AppKit path a test can drive, and requires exit
/// status 0 and no crash report (https://github.com/leehack/llamadart/issues/826).
///
/// The app is `integration_test/macos_quit_probe.dart` built into this
/// example's Runner, keeping the Runner's sandbox with read access to the model
/// files added. Every path also runs once with a model that nothing frees and
/// has to abort: that run is what shows the path reaches ggml-metal's check,
/// and it can leave a crash report in `~/Library/Logs/DiagnosticReports`.
///
/// Set `MACOS_QUIT_CHAT_MODEL` to a GGUF chat model. `MACOS_QUIT_IMAGE_MODEL`,
/// an image checkpoint such as SDXS, loads an image model too, and
/// `MACOS_QUIT_DECISION_MODEL` with `MACOS_QUIT_DECISION_HEAD` a decision
/// engine. `MACOS_QUIT_RUNS` repeats each clean case (default 3) and
/// `MACOS_QUIT_BUILD_MODES` picks the builds (default `debug,release`).
void main() {
  final environment = Platform.environment;
  final models = {for (final name in _modelVariables) name: ?environment[name]};
  final hasChat = models.containsKey('MACOS_QUIT_CHAT_MODEL');
  final hasImage = models.containsKey('MACOS_QUIT_IMAGE_MODEL');
  final hasDecision = models.containsKey('MACOS_QUIT_DECISION_MODEL');
  final runs = int.parse(environment['MACOS_QUIT_RUNS'] ?? '3');
  final modes = (environment['MACOS_QUIT_BUILD_MODES'] ?? 'debug,release')
      .split(',');

  tearDown(() {
    for (final probe in _started) {
      probe.kill();
    }
    _started.clear();
  });

  for (final mode in modes) {
    group('$mode build:', () {
      late _ProbeApp app;

      setUpAll(() async {
        if (hasChat) app = await _ProbeApp.build(mode, models);
      });

      // Not `skip:`, which --run-skipped (needed for `local-only`) overrides.
      bool skipped() {
        if (hasChat) return false;
        markTestSkipped('Set MACOS_QUIT_CHAT_MODEL to run it.');
        return true;
      }

      for (final path in _quitPaths) {
        test('a $path quit with models loaded and nothing disposed exits 0 '
            'and leaves no crash report', () async {
          if (skipped()) return;
          final quits = <_Quit>[];
          for (var run = 0; run < runs; run++) {
            final probe = await app.start(path);
            await probe.ready();
            expect(probe.stdout, contains('${_tag}_CHAT_BACKEND Metal'));
            if (hasImage) {
              expect(probe.stdout, contains('${_tag}_IMAGE_BACKEND MTL'));
            }
            if (hasDecision) {
              expect(probe.stdout, contains('${_tag}_DECISION_BACKEND MTL'));
            }
            final quit = await probe.quit();
            expect(quit.tracked.single, isNot(contains('llama_cpp=0')));
            expect(
              quit.tracked.single,
              hasImage
                  ? isNot(contains('stable_diffusion=0'))
                  : contains('stable_diffusion=0'),
            );
            quits.add(quit);
          }
          await _expectClean('$mode $path', quits);
        });

        test('a $path quit with a model nothing frees aborts', () async {
          if (skipped()) return;
          final probe = await app.start(path, control: true);
          await probe.ready();
          final quit = await probe.quit();
          expect(quit.tracked, ['llama_cpp=0 stable_diffusion=0']);
          expect(quit.exitCode, _sigabrt, reason: quit.stderr);
          expect(quit.stderr, contains('GGML_ASSERT'));

          // Logged and not required: macOS may stop writing crash reports,
          // or write only some, for a process that aborts repeatedly.
          final sinceExit = Stopwatch()..start();
          while (_crashReports(quit).isEmpty &&
              sinceExit.elapsed < _crashReportWait) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          _log('$mode $path control', {
            'exitCode': quit.exitCode,
            'crashReport': _crashReports(quit).isNotEmpty,
            'secondsToCrashReportCheck': _seconds(sinceExit.elapsed),
          });
        });
      }

      test('a hot restart, then an apple-event quit, exits 0 and leaves no '
          'crash report', () async {
        if (skipped()) return;
        if (mode != 'debug') {
          markTestSkipped('Only a debug build can hot restart.');
          return;
        }
        final quits = <_Quit>[];
        for (var run = 0; run < runs; run++) {
          final probe = await app.start('apple-event');
          await probe.ready();
          await probe.hotRestart();
          await probe.ready(times: 2);
          final quit = await probe.quit();
          // The isolates the restart discarded freed what they held: the
          // second load tracks as much as the first, not twice as much.
          expect(quit.tracked, hasLength(2));
          expect(quit.tracked.last, quit.tracked.first);
          quits.add(quit);
        }
        await _expectClean('$mode hot-restart', quits);
      });
    });
  }
}

const _tag = 'MACOS_QUIT_PROBE';
const _target = 'integration_test/macos_quit_probe.dart';
const _product = 'llamadart_chat_example';
const _sigabrt = -6;
final List<_Probe> _started = [];
const _modelVariables = [
  'MACOS_QUIT_CHAT_MODEL',
  'MACOS_QUIT_IMAGE_MODEL',
  'MACOS_QUIT_DECISION_MODEL',
  'MACOS_QUIT_DECISION_HEAD',
];

// The Cmd-Q keystroke is left out: sending it needs the Accessibility
// permission and reaches whichever app is frontmost. `terminate` sends the
// action of the menu item it triggers.
const _quitPaths = [
  'apple-event',
  'terminate',
  'close-window',
  'exit-required',
  'exit-cancelable',
];

// Crash reports of the control runs appeared within two seconds of the exit.
const _crashReportWait = Duration(seconds: 5);

final Directory _reports = Directory(
  p.join(Platform.environment['HOME']!, 'Library', 'Logs', 'DiagnosticReports'),
);

final String _flutter = p.join(
  Platform.environment['FLUTTER_ROOT']!,
  'bin',
  'flutter',
);

// FLUTTER_TEST makes a Flutter app that inherits it report Android as its
// platform, so nothing started here gets the test runner's environment as is.
final Map<String, String> _toolEnvironment = Map.of(Platform.environment)
  ..remove('FLUTTER_TEST');

void _log(String name, Object? value) =>
    // ignore: avoid_print
    print('MACOS_QUIT_E2E ${jsonEncode({name: value})}');

String _seconds(Duration duration) =>
    (duration.inMicroseconds / 1e6).toStringAsFixed(2);

Future<void> _expectClean(String name, List<_Quit> quits) async {
  _log(name, {
    'exitCodes': [for (final quit in quits) quit.exitCode],
    'tracked': [for (final quit in quits) quit.tracked],
    'secondsToExit': [for (final quit in quits) _seconds(quit.elapsed)],
  });
  for (final quit in quits) {
    expect(quit.exitCode, 0, reason: quit.stderr);
    expect(quit.stderr, isNot(contains('GGML_ASSERT')));
  }
  await Future<void>.delayed(_crashReportWait);
  expect([
    for (final quit in quits) ..._crashReports(quit).map((file) => file.path),
  ], isEmpty);
}

List<File> _crashReports(_Quit quit) => [
  for (final entry in _reports.listSync())
    if (entry is File &&
        p.basename(entry.path).startsWith(_product) &&
        entry.path.endsWith('.ips') &&
        !entry.statSync().modified.isBefore(quit.started) &&
        entry.readAsStringSync().contains('"pid" : ${quit.pid},'))
      entry,
];

String _entitlementString(String path) =>
    '\t\t<string>'
    '${const HtmlEscape(HtmlEscapeMode.element).convert(path)}</string>\n';

class _Quit {
  const _Quit({
    required this.pid,
    required this.started,
    required this.exitCode,
    required this.elapsed,
    required this.tracked,
    required this.stderr,
  });

  final int pid;
  final DateTime started;
  final int exitCode;
  final Duration elapsed;

  /// The objects each runtime's exit teardown tracked, once per model load.
  final List<String> tracked;
  final String stderr;
}

class _ProbeApp {
  const _ProbeApp(this._executable, this._models);

  final String _executable;
  final Map<String, String> _models;

  /// Builds the probe in [mode] with the Runner's entitlements plus read
  /// access to the model files, which the sandbox would otherwise refuse.
  static Future<_ProbeApp> build(
    String mode,
    Map<String, String> requested,
  ) async {
    // The sandbox compares resolved paths.
    final models = {
      for (final MapEntry(key: name, value: path) in requested.entries)
        name: File(path).resolveSymbolicLinksSync(),
    };
    final runner = File(
      p.join(
        'macos',
        'Runner',
        '${mode == 'release' ? 'Release' : 'DebugProfile'}.entitlements',
      ),
    ).readAsStringSync();
    final entitlements =
        File(p.join('build', 'macos_quit_probe', '$mode.entitlements'))
          ..createSync(recursive: true)
          ..writeAsStringSync(
            runner.replaceFirst(
              '</dict>',
              '\t<key>com.apple.security.temporary-exception.files'
                  '.absolute-path.read-only</key>\n\t<array>\n'
                  '${models.values.map(_entitlementString).join()}'
                  '\t</array>\n</dict>',
            ),
          );
    final build = await Process.run(
      _flutter,
      ['build', 'macos', '--$mode', '-t', _target],
      environment: {
        ..._toolEnvironment,
        'FLUTTER_XCODE_CODE_SIGN_ENTITLEMENTS': entitlements.absolute.path,
      },
      includeParentEnvironment: false,
    );
    expect(build.exitCode, 0, reason: '${build.stdout}\n${build.stderr}');
    return _ProbeApp(
      p.join(
        'build',
        'macos',
        'Build',
        'Products',
        mode == 'release' ? 'Release' : 'Debug',
        '$_product.app',
        'Contents',
        'MacOS',
        _product,
      ),
      models,
    );
  }

  Future<_Probe> start(String path, {bool control = false}) async {
    final started = DateTime.now();
    final process = await Process.start(
      _executable,
      const [],
      environment: {
        for (final name in ['HOME', 'PATH', 'TMPDIR', 'USER'])
          name: ?Platform.environment[name],
        ..._models,
        'MACOS_QUIT_PATH': path,
        if (control) 'MACOS_QUIT_CONTROL': '1',
      },
      includeParentEnvironment: false,
    );
    final probe = _Probe(process, path, started);
    _started.add(probe);
    return probe;
  }
}

class _Probe {
  _Probe(this._process, this._path, this._started) {
    _stdoutDone = _process.stdout
        .transform(utf8.decoder)
        .listen(_stdout.write)
        .asFuture<void>();
    _stderrDone = _process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(_stderr.write)
        .asFuture<void>();
    unawaited(_process.exitCode.then((code) => _exitCode = code));
  }

  final Process _process;
  final String _path;
  final DateTime _started;
  final StringBuffer _stdout = StringBuffer();
  final StringBuffer _stderr = StringBuffer();
  late final Future<void> _stdoutDone;
  late final Future<void> _stderrDone;
  Future<void>? _attachDone;
  int? _exitCode;

  String get stdout => _stdout.toString();

  /// Ends a probe that a failed test left running.
  void kill() {
    if (_exitCode == null) _process.kill(ProcessSignal.sigkill);
  }

  /// Waits until the probe has loaded its models [times] times.
  Future<void> ready({int times = 1}) => _until(
    'the probe to load its models',
    () => '${_tag}_READY'.allMatches(stdout).length >= times,
  );

  /// Sends the Quit event when the probe waits for one, then waits for the
  /// exit the probe's own path or that event causes.
  Future<_Quit> quit() async {
    final sinceQuit = Stopwatch()..start();
    if (_path == 'apple-event' && _exitCode == null) {
      // Its own exit status says nothing: the app is gone before it replies.
      await Process.run('osascript', [
        '-l',
        'JavaScript',
        '-e',
        'Application(${_process.pid}).quit()',
      ]);
    }
    await _until('the probe to exit', () => _exitCode != null, exits: true);
    sinceQuit.stop();
    await _stdoutDone;
    await _stderrDone;
    await _attachDone;
    return _Quit(
      pid: _process.pid,
      started: _started,
      exitCode: _exitCode!,
      elapsed: sinceQuit.elapsed,
      tracked: [
        for (final line in const LineSplitter().convert(stdout))
          if (line.startsWith('${_tag}_TRACKED '))
            line.substring('${_tag}_TRACKED '.length),
      ],
      stderr: _stderr.toString(),
    );
  }

  /// Hot restarts the probe through `flutter attach`, which stays attached
  /// until the probe exits, as `flutter run` would.
  Future<void> hotRestart() async {
    final vmService = RegExp(
      r'The Dart VM service is listening on (\S+)',
    ).firstMatch(stdout)!.group(1)!;
    final attach = await Process.start(
      _flutter,
      [
        'attach',
        '--machine',
        '-d',
        'macos',
        '-t',
        _target,
        '--debug-url',
        vmService,
      ],
      environment: _toolEnvironment,
      includeParentEnvironment: false,
    );
    final events = <Map<String, Object?>>[];
    final output = StringBuffer();
    _attachDone = Future.wait([
      attach.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            output.writeln(line);
            if (!line.startsWith('[{')) return;
            events.add(
              (jsonDecode(line) as List).single as Map<String, Object?>,
            );
          })
          .asFuture<void>(),
      attach.stderr
          .transform(utf8.decoder)
          .listen(output.write)
          .asFuture<void>(),
    ]);
    unawaited(_process.exitCode.then((_) => attach.kill()));

    Map<String, Object?>? event(bool Function(Map<String, Object?>) test) =>
        events.where(test).firstOrNull;
    await _until(
      'flutter attach to connect',
      () => event((event) => event['event'] == 'app.started') != null,
      details: output.toString,
    );
    final appId =
        (event((event) => event['event'] == 'app.started')!['params']!
            as Map<String, Object?>)['appId'];
    attach.stdin.writeln(
      jsonEncode([
        {
          'id': 1,
          'method': 'app.restart',
          'params': {'appId': appId, 'fullRestart': true},
        },
      ]),
    );
    await _until(
      'the hot restart',
      () => event((event) => event['id'] == 1) != null,
      details: output.toString,
    );
    expect(
      event((event) => event['id'] == 1)!['result'],
      containsPair('code', 0),
      reason: output.toString(),
    );
  }

  Future<void> _until(
    String what,
    bool Function() done, {
    bool exits = false,
    String Function()? details,
  }) async {
    final waited = Stopwatch()..start();
    while (!done()) {
      if (_exitCode != null) {
        // The exit can be seen before the last lines the probe printed.
        await _stdoutDone;
        if (done()) return;
      }
      if (stdout.contains('${_tag}_ERROR') ||
          waited.elapsed > const Duration(minutes: 3) ||
          (_exitCode != null && !exits)) {
        kill();
        fail(
          'Waiting for $what (exit code $_exitCode):\n$stdout\n$_stderr\n'
          '${details?.call() ?? ''}',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }
}
