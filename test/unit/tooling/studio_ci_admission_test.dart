@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
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
    'Studio admission uses its pinned SDK and fatal analysis for both packages',
    () {
      final workflow =
          loadYaml(File('.github/workflows/ci.yml').readAsStringSync()) as Map;
      final jobs = workflow['jobs'] as Map;
      for (final name in ['studio', 'studio-macos']) {
        final job = jobs[name] as Map;
        expect(job['if'], "needs.changes.outputs.studio == 'true'");
        final setup =
            (job['steps'] as List).singleWhere(
                  (step) =>
                      '${step['uses']}'.startsWith('subosito/flutter-action@'),
                )
                as Map;
        expect(
          setup['with']['flutter-version-file'],
          'packages/llamadart_studio/.flutter-version',
        );
      }
      final steps = jobs['studio']['steps'] as List;
      for (final (package, analyze, test) in [
        ('llamadart_studio_core', 'dart analyze --fatal-infos', 'dart test'),
        ('llamadart_studio', 'flutter analyze --fatal-infos', 'flutter test'),
      ]) {
        final step =
            steps.singleWhere(
                  (step) => step['working-directory'] == 'packages/$package',
                )
                as Map;
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
}
