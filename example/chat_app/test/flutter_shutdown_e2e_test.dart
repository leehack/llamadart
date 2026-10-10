@TestOn('mac-os || linux')
@Tags(['local-only'])
@Timeout(Duration(minutes: 30))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Tests actual Flutter engine shutdown during a native load or an active
/// generation. The native observer registers an ordinary host C exit callback
/// and buffers C stdout. Its native load-progress callback never enters Dart.
/// Set FLUTTER_SHUTDOWN_HEADERS to the exact runtime's extracted header bundle.
void main() {
  final env = Platform.environment;
  final model = env['MACOS_QUIT_CHAT_MODEL'];
  final headers = env['FLUTTER_SHUTDOWN_HEADERS'];
  final works =
      (env['FLUTTER_SHUTDOWN_WORK_STATES'] ?? 'loading,generating,startup')
          .split(',');
  if (works.isEmpty ||
      works.any(
        (work) => !['loading', 'generating', 'startup'].contains(work),
      )) {
    throw ArgumentError('Use loading, generating or startup work states.');
  }
  final runs = int.parse(env['MACOS_QUIT_RUNS'] ?? '3');
  final modes = (env['MACOS_QUIT_BUILD_MODES'] ?? 'debug,release').split(',');
  if (runs < 1 || modes.any((mode) => mode != 'debug' && mode != 'release')) {
    throw ArgumentError(
      'Use positive MACOS_QUIT_RUNS and debug/release modes.',
    );
  }
  final paths = Platform.isMacOS
      ? [
          'apple-event',
          'terminate',
          'close-window',
          'exit-required',
          'exit-cancelable',
        ]
      : ['exit-required', 'exit-cancelable'];
  for (final mode in modes) {
    group('$mode active Flutter shutdown', () {
      late String executable;
      late String observer;
      setUpAll(() async {
        if (model == null || headers == null) {
          throw StateError(
            'Set MACOS_QUIT_CHAT_MODEL and FLUTTER_SHUTDOWN_HEADERS.',
          );
        }
        final result = await _build(mode, model, headers);
        executable = result.$1;
        observer = result.$2;
      });
      for (final work in works) {
        for (final path in paths) {
          test('$path during $work', () async {
            if (model == null || headers == null) {
              throw StateError(
                'Set MACOS_QUIT_CHAT_MODEL and FLUTTER_SHUTDOWN_HEADERS.',
              );
            }
            for (var repeat = 0; repeat < runs; repeat++) {
              await _run(executable, observer, model, mode, work, path, repeat);
            }
          });
        }
      }
    });
  }
}

Future<(String, String)> _build(
  String mode,
  String model,
  String headers,
) async {
  final build = Directory('build/flutter_shutdown_probe')
    ..createSync(recursive: true);
  final observer = p.absolute(
    build.path,
    Platform.isMacOS ? 'observer.dylib' : 'observer.so',
  );
  final compile = await Process.run('clang', [
    Platform.isMacOS ? '-dynamiclib' : '-shared',
    '-fPIC',
    '-std=c11',
    '-Wall',
    '-Wextra',
    '-Werror',
    '-I$headers/llama_cpp/include',
    '-I$headers/llama_cpp/ggml/include',
    'test/fixtures/flutter_shutdown_observer.c',
    '-o',
    observer,
    if (Platform.isLinux) '-ldl',
  ]);
  expect(compile.exitCode, 0, reason: '${compile.stdout}\n${compile.stderr}');
  final environment = Map<String, String>.of(Platform.environment)
    ..remove('FLUTTER_TEST');
  if (Platform.isMacOS) {
    final entitlement = File(
      p.join(
        'macos/Runner',
        '${mode == 'release' ? 'Release' : 'DebugProfile'}.entitlements',
      ),
    ).readAsStringSync();
    final file = File(p.join(build.path, '$mode.entitlements'));
    final escaped = [model, observer].map(
      (path) => const HtmlEscape(
        HtmlEscapeMode.element,
      ).convert(File(path).resolveSymbolicLinksSync()),
    );
    file.writeAsStringSync(
      entitlement.replaceFirst(
        '</dict>',
        '<key>com.apple.security.temporary-exception.files.absolute-path.read-only</key>\n'
            '<array>${escaped.map((path) => '<string>$path</string>').join()}</array>\n</dict>',
      ),
    );
    environment['FLUTTER_XCODE_CODE_SIGN_ENTITLEMENTS'] = file.absolute.path;
    final sign = await Process.run('codesign', [
      '--force',
      '--sign',
      '-',
      observer,
    ]);
    expect(sign.exitCode, 0, reason: '${sign.stderr}');
  }
  final flutter = p.join(Platform.environment['FLUTTER_ROOT']!, 'bin/flutter');
  final platform = Platform.isMacOS ? 'macos' : 'linux';
  final result = await Process.run(
    flutter,
    [
      'build',
      platform,
      '--$mode',
      '-t',
      'integration_test/flutter_shutdown_probe.dart',
    ],
    environment: environment,
    includeParentEnvironment: false,
  );
  expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  return (
    Platform.isMacOS
        ? p.join(
            'build/macos/Build/Products',
            mode == 'release' ? 'Release' : 'Debug',
            'llamadart_chat_example.app/Contents/MacOS/llamadart_chat_example',
          )
        : 'build/linux/arm64/$mode/bundle/llamadart_chat_example',
    observer,
  );
}

Future<void> _run(
  String executable,
  String observer,
  String model,
  String mode,
  String work,
  String path,
  int repeat,
) async {
  final environment = Map<String, String>.of(Platform.environment)
    ..remove('FLUTTER_TEST');
  final process = await Process.start(
    executable,
    [],
    environment: {
      ...environment,
      'MACOS_QUIT_CHAT_MODEL': model,
      'FLUTTER_SHUTDOWN_OBSERVER': observer,
      'FLUTTER_SHUTDOWN_WORK': work,
      'FLUTTER_SHUTDOWN_RUNTIME': Platform.isMacOS
          ? p.absolute(
              p.dirname(executable),
              '../Frameworks/llamadart.framework/llamadart',
            )
          : p.absolute(p.dirname(executable), 'lib/libllamadart.so'),
    },
    includeParentEnvironment: false,
  );
  final output = StringBuffer();
  final errors = StringBuffer();
  final stdoutDone = process.stdout
      .transform(utf8.decoder)
      .listen(output.write)
      .asFuture<void>();
  final stderrDone = process.stderr
      .transform(const Utf8Decoder(allowMalformed: true))
      .listen(errors.write)
      .asFuture<void>();
  int? code;
  final exit = process.exitCode.then((value) => code = value);
  try {
    final wait = Stopwatch()..start();
    final marker = (work == 'loading' || work == 'startup')
        ? 'FLUTTER_SHUTDOWN_NATIVE_LOAD_PROGRESS'
        : 'FLUTTER_SHUTDOWN_READY generating';
    while (!output.toString().contains(marker)) {
      if (code != null ||
          errors.toString().contains('Unhandled Exception') ||
          ((work == 'loading' || work == 'startup') &&
              errors.toString().contains(
                'FLUTTER_SHUTDOWN_NATIVE_LOAD_RETURNED',
              )) ||
          wait.elapsed > const Duration(minutes: 2)) {
        fail(_redactVmService('Probe did not reach $work: $output\n$errors'));
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(
      output.toString(),
      isNot(contains('FLUTTER_SHUTDOWN_GENERATION_DONE')),
    );
    if (work == 'generating') {
      expect(
        output.toString(),
        contains(
          'FLUTTER_SHUTDOWN_BACKEND ${Platform.isMacOS ? 'Metal' : 'CPU'}',
        ),
      );
    }
    final quitting = Stopwatch()..start();
    process.stdin.writeln(path);
    await process.stdin.flush();
    if (path == 'apple-event') {
      if (work == 'startup') {
        while (!output.toString().contains(
          'FLUTTER_SHUTDOWN_STARTUP_DISPOSED',
        )) {
          if (code != null ||
              errors.toString().contains('Unhandled Exception') ||
              quitting.elapsed > const Duration(minutes: 2)) {
            fail(
              _redactVmService(
                'Startup disposal did not finish: $output\n$errors',
              ),
            );
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      }
      await Process.run('osascript', [
        '-l',
        'JavaScript',
        '-e',
        'Application(${process.pid}).quit()',
      ]);
    }
    await exit.timeout(
      const Duration(minutes: 2),
      onTimeout: () => fail(
        _redactVmService('Probe did not exit during $work: $output\n$errors'),
      ),
    );
    await Future.wait([stdoutDone, stderrDone]);
    expect(code, 0, reason: _redactVmService(errors.toString()));
    expect(
      errors.toString(),
      contains('FLUTTER_SHUTDOWN_HOST_EXIT active_load=0 tracked=0'),
    );
    expect(output.toString(), contains('FLUTTER_SHUTDOWN_C_OUTPUT_FLUSHED'));
    expect(errors.toString(), isNot(contains('GGML_ASSERT')));
    expect(errors.toString(), isNot(contains('GetFfiCallbackMetadata')));
    expect(errors.toString(), isNot(contains('FLUTTER_SHUTDOWN_ERROR')));
    if ((work == 'loading' || work == 'startup')) {
      expect(
        errors.toString(),
        contains('FLUTTER_SHUTDOWN_QUIT_REQUEST active_load=1'),
      );
      expect(
        errors.toString(),
        contains('FLUTTER_SHUTDOWN_NATIVE_LOAD_RETURNED success=1'),
      );
    }
    if (work == 'startup') {
      expect(output.toString(), contains('FLUTTER_SHUTDOWN_STARTUP_DISPOSED'));
      expect(
        output.toString(),
        contains(
          'FLUTTER_SHUTDOWN_BACKEND ${Platform.isMacOS ? 'Metal' : 'CPU'}',
        ),
      );
    }
    // ignore: avoid_print
    print(
      'FLUTTER_SHUTDOWN_E2E ${jsonEncode({'mode': mode, 'work': work, 'path': path, 'repeat': repeat, 'exit': code, 'secondsToExit': quitting.elapsedMicroseconds / 1e6, 'stdout': _redactVmService(output.toString()), 'stderr': _redactVmService(errors.toString())})}',
    );
  } finally {
    if (code == null) process.kill(ProcessSignal.sigkill);
    await process.stdin.close();
    await Future.wait([stdoutDone, stderrDone]);
  }
}

String _redactVmService(String output) => output.replaceAll(
  RegExp(r'The Dart VM service is listening on [^\r\n]*'),
  'The Dart VM service is listening (address omitted).',
);
