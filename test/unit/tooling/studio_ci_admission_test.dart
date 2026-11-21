@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  test('Studio core admission executes browser-only contracts', () {
    final workflow =
        loadYaml(File('.github/workflows/ci.yml').readAsStringSync()) as Map;
    final steps = (workflow['jobs'] as Map)['studio']['steps'] as List;
    final step =
        steps.singleWhere(
              (step) => step['name'] == 'Analyze and test Studio core',
            )
            as Map;
    expect(step['working-directory'], 'packages/llamadart_studio_core');
    expect(
      (step['run'] as String).split('\n').map((line) => line.trim()),
      contains(
        'dart test -p chrome test/browser_platform_contract_test.dart '
        'test/web_engine_batch_settings_test.dart '
        'test/studio_error_formatter_test.dart',
      ),
    );
    expect(step.containsKey('continue-on-error'), isFalse);
  });

  test('Studio UI admission supervises its only Flutter Chrome invocation', () {
    final workflow =
        loadYaml(File('.github/workflows/ci.yml').readAsStringSync()) as Map;
    final job = (workflow['jobs'] as Map)['studio'] as Map;
    final steps = (job['steps'] as List).cast<Map>();
    final chromeCommand = RegExp(r'\bflutter\s+test\s+--platform\s+chrome\b');
    final step = steps.singleWhere(
      (step) => chromeCommand.hasMatch('${step['run']}'),
    );
    final command = (step['run'] as String).trim().replaceAll(
      RegExp(r'\s+'),
      ' ',
    );
    expect(chromeCommand.allMatches(command), hasLength(1));
    expect(job['runs-on'], 'ubuntu-latest');
    expect(job['timeout-minutes'], 20);
    expect(step['working-directory'], 'packages/llamadart_studio');
    expect(step.containsKey('continue-on-error'), isFalse);
    expect(step.containsKey('if'), isFalse);
    expect(
      command,
      'python3 ../../tool/ci/supervise_chrome_test.py '
      r'--output-dir "$RUNNER_TEMP/studio-ui-chrome" '
      r'--reporter-file "$RUNNER_TEMP/studio-ui-chrome/reporter.jsonl" '
      '--timeout-seconds 600 -- flutter test --platform chrome '
      r'--file-reporter "json:$RUNNER_TEMP/studio-ui-chrome/reporter.jsonl" '
      'test/web_recording_test.dart test/web_platform_acceptance_test.dart '
      'test/tool_availability_widget_test.dart',
    );
    expect(
      steps.indexWhere((step) => step['name'] == 'Analyze and test Studio UI'),
      inInclusiveRange(0, steps.indexOf(step) - 1),
    );

    final diagnostics = steps.singleWhere(
      (step) => step['with']?['name'] == 'studio-ui-chrome-diagnostics',
    );
    expect(steps.indexOf(diagnostics), greaterThan(steps.indexOf(step)));
    expect(diagnostics['uses'], startsWith('actions/upload-artifact@'));
    expect(diagnostics['if'], 'always()');
    expect(diagnostics['with']['path'], r'${{ runner.temp }}/studio-ui-chrome');
    expect(diagnostics['with']['if-no-files-found'], 'ignore');
    expect(diagnostics['with']['retention-days'], 7);
  });

  test(
    'Studio production changes select both package and native admission',
    () async {
      for (final package in ['llamadart_studio', 'llamadart_studio_core']) {
        final result = await Process.run(
          Platform.isWindows ? 'python' : 'python3',
          [
            '-c',
            'import json,runpy,sys; m=runpy.run_path("tool/ci/select_jobs.py"); '
                'p=m["select"]([sys.argv[1]]); '
                'print(json.dumps({"plan":p,"expected":m["expected_jobs"](p)}))',
            'packages/$package/lib/main.dart',
          ],
        );
        expect(result.exitCode, 0, reason: '${result.stderr}');
        final output =
            jsonDecode(result.stdout as String) as Map<String, dynamic>;
        final jobs = output['plan']['jobs'] as Map<String, dynamic>;
        expect(jobs['studio'], isTrue, reason: package);
        expect(jobs['test-linux-coverage'], isFalse, reason: package);
        expect(output['expected']['studio'], isTrue, reason: package);
        expect(output['expected']['studio-macos'], isTrue, reason: package);
      }
    },
  );

  test(
    'Studio admission runs formatting, fatal analysis and both VM suites',
    () {
      final workflow =
          loadYaml(File('.github/workflows/ci.yml').readAsStringSync()) as Map;
      final jobs = workflow['jobs'] as Map;
      final steps = jobs['studio']['steps'] as List;
      for (final (name, package, analyze, test) in [
        (
          'Studio core',
          'llamadart_studio_core',
          'dart analyze --fatal-infos',
          'dart test',
        ),
        (
          'Studio UI',
          'llamadart_studio',
          'flutter analyze --fatal-infos',
          'flutter test',
        ),
      ]) {
        final step =
            steps.singleWhere(
                  (step) => step['name'] == 'Analyze and test $name',
                )
                as Map;
        expect(step['working-directory'], 'packages/$package');
        final command = step['run'] as String;
        expect(
          command,
          contains('dart format --output=none --set-exit-if-changed .'),
        );
        expect(command, contains(analyze));
        expect(
          command,
          contains('TMPDIR="\$(mktemp -d)" $test --exclude-tags local-only'),
        );
        expect(step.containsKey('continue-on-error'), isFalse);
      }
    },
  );

  for (final name in ['studio', 'studio-macos']) {
    test('$name explicitly resolves the Studio Flutter pin', () {
      final workflow =
          loadYaml(File('.github/workflows/ci.yml').readAsStringSync()) as Map;
      final job = workflow['jobs'][name] as Map;
      expect(job['if'], "needs.changes.outputs.$name == 'true'");
      final steps = (job['steps'] as List).cast<Map>();
      final setup = steps.singleWhere(
        (step) => '${step['uses']}'.startsWith('subosito/flutter-action@'),
      );
      expect(
        setup['with']['flutter-version'],
        r'${{ steps.pin.outputs.version }}',
      );
      expect(setup['with']['flutter-version-file'], isNull);
      expect(setup.containsKey('if'), isFalse);
      final pin = steps.singleWhere((step) => step['id'] == 'pin');
      final checkout = steps.singleWhere(
        (step) => '${step['uses']}'.startsWith('actions/checkout@'),
      );
      expect(steps.indexOf(pin), greaterThan(steps.indexOf(checkout)));
      expect(steps.indexOf(pin), lessThan(steps.indexOf(setup)));
      expect(pin.containsKey('working-directory'), isFalse);
      expect(pin.containsKey('if'), isFalse);
      expect(pin.containsKey('continue-on-error'), isFalse);
      expect(pin['run'], isA<String>());
    });

    group('$name Flutter pin reader', () {
      const pinPath = 'packages/llamadart_studio/.flutter-version';
      late Directory checkout;
      late File output;
      late String script;

      setUp(() {
        final workflow = loadYaml(
          File('.github/workflows/ci.yml').readAsStringSync(),
        );
        final steps = (workflow['jobs'][name]['steps'] as List).cast<Map>();
        script =
            steps.singleWhere((step) => step['id'] == 'pin')['run'] as String;
        checkout = Directory.systemTemp.createTempSync('w2098c-studio-pin-');
        output = File('${checkout.path}/github-output')..createSync();
        addTearDown(() => checkout.deleteSync(recursive: true));
      });

      Future<ProcessResult> readPin(String? contents) {
        if (contents != null) {
          File('${checkout.path}/$pinPath')
            ..createSync(recursive: true)
            ..writeAsStringSync(contents);
        }
        return Process.run(
          'bash',
          ['--noprofile', '--norc', '-e', '-o', 'pipefail', '-c', script],
          workingDirectory: checkout.path,
          environment: {'GITHUB_OUTPUT': output.path},
        );
      }

      for (final (label, contents) in [
        ('bare version', '3.50.0'),
        ('trailing blank lines', '3.50.0\n\n'),
        ('spaces and tabs', ' \t3.50.0\t \n'),
        ('CRLF', '\r\n3.50.0\r\n'),
      ]) {
        test('emits a bare version for $label', () async {
          final result = await readPin(contents);
          expect(result.exitCode, 0, reason: '${result.stderr}');
          expect(output.readAsStringSync(), 'version=3.50.0\n');
        });
      }

      for (final (label, contents) in [
        ('missing pin', null),
        ('empty pin', ''),
        ('whitespace-only pin', ' \t\r\n'),
        ('channel alias', 'stable'),
        ('partial version', '3.50'),
        ('multiple lines', '3.50.0\n3.50.1\n'),
      ]) {
        test('rejects $label with the pin path', () async {
          final result = await readPin(contents);
          expect(result.exitCode, isNonZero);
          expect(result.stderr, contains(pinPath));
          expect(output.readAsStringSync(), isEmpty);
        });
      }
    }, skip: Platform.isWindows ? 'Runs the POSIX workflow reader' : false);
  }

  test('Studio packaging-only changes omit Studio macOS admission', () async {
    for (final path in [
      'packages/llamadart_studio/web/index.html',
      'packages/llamadart_studio/windows/runner/main.cpp',
      'packages/llamadart_studio/linux/my_application.cc',
    ]) {
      final result = await Process.run(
        Platform.isWindows ? 'python' : 'python3',
        [
          '-c',
          'import json,runpy,sys; m=runpy.run_path("tool/ci/select_jobs.py"); '
              'p=m["select"]([sys.argv[1]], pull_request=True); '
              'print(json.dumps({"plan":p,"expected":m["expected_jobs"](p)}))',
          path,
        ],
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final output =
          jsonDecode(result.stdout as String) as Map<String, dynamic>;
      expect(output['expected']['studio'], isTrue, reason: path);
      expect(output['expected']['studio-macos'], isFalse, reason: path);
    }
  });

  test('Studio admission executes Android release acceptance unit tests', () {
    final workflow =
        loadYaml(File('.github/workflows/ci.yml').readAsStringSync()) as Map;
    final steps = ((workflow['jobs'] as Map)['studio']['steps'] as List)
        .cast<Map>();
    const acceptance =
        'python3 -m unittest tool/test/test_android_release_acceptance.py';
    final step = steps.singleWhere(
      (step) => '${step['run']}'.contains(acceptance),
    );
    final chrome = steps.indexWhere(
      (step) => '${step['run']}'.contains('flutter test --platform chrome'),
    );
    expect(chrome, inInclusiveRange(0, steps.indexOf(step) - 1));
    expect(step['run'].trim(), acceptance);
    expect(step['working-directory'], 'packages/llamadart_studio');
    expect(step.containsKey('if'), isFalse);
    expect(step.containsKey('continue-on-error'), isFalse);
  });
}
