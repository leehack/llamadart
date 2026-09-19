@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

Map<String, dynamic> readWorkflow(String name) =>
    jsonDecode(
          jsonEncode(
            loadYaml(File('.github/workflows/$name.yml').readAsStringSync()),
          ),
        )
        as Map<String, dynamic>;

Future<Map<String, dynamic>> selected(List<String> paths) async {
  final result = await Process.run(Platform.isWindows ? 'python' : 'python3', [
    '-c',
    'import json,runpy,sys; m=runpy.run_path("tool/ci/select_jobs.py"); '
        'print(json.dumps(m["select"](json.loads(sys.argv[1]))))',
    jsonEncode(paths),
  ]);
  expect(result.exitCode, 0, reason: '${result.stderr}');
  return jsonDecode(result.stdout as String) as Map<String, dynamic>;
}

void main() {
  test(
    'core workflow wires every planned job into truthful always aggregate',
    () async {
      final workflow = readWorkflow('ci');
      final jobs = workflow['jobs'] as Map<String, dynamic>;
      final plan = await selected(['lib/llamadart.dart']);
      final planned = (plan['jobs'] as Map).keys.toSet();
      expect(jobs.keys.toSet(), {...planned, 'changes', 'test-linux-web'});
      final aggregate = jobs['test-linux-web'] as Map;
      expect(aggregate['if'], r'${{ always() }}');
      expect((aggregate['needs'] as List).toSet(), {...planned, 'changes'});
      final steps = aggregate['steps'] as List;
      final check = steps.last as Map;
      expect(check['run'], 'python3 tool/ci/select_jobs.py aggregate');
      expect(check['env'], {
        'PLAN': r'${{ needs.changes.outputs.plan }}',
        'NEEDS': r'${{ toJSON(needs) }}',
      });
      for (final name in planned) {
        expect(jobs[name]['needs'], 'changes', reason: '$name');
        expect(
          jobs[name]['if'],
          "needs.changes.outputs.$name == 'true'",
          reason: '$name',
        );
        expect(
          jobs['changes']['outputs'][name],
          '\${{ steps.select.outputs.$name }}',
        );
      }
      expect(
        jobs['companion-packages']['strategy']['matrix']['package'],
        r'${{ fromJSON(needs.changes.outputs.companions) }}',
      );
      final triggers = workflow['on'] as Map;
      expect(triggers.keys.toSet(), {'push', 'pull_request'});
      for (final trigger in triggers.values) {
        expect((trigger as Map).containsKey('paths'), isFalse);
        expect(trigger.containsKey('paths-ignore'), isFalse);
      }
    },
  );

  test(
    'bundles cover runtime inputs with target-aware matrices and final result',
    () async {
      final workflow = readWorkflow('validation_bundles');
      final jobs = workflow['jobs'] as Map;
      expect(jobs.keys.toSet(), {'changes', 'desktop', 'app', 'result'});
      expect(
        jobs['desktop']['if'],
        "needs.changes.outputs.desktops-enabled == 'true'",
      );
      expect(
        jobs['desktop']['strategy']['matrix']['os'],
        r'${{ fromJSON(needs.changes.outputs.desktops) }}',
      );
      expect(jobs['app']['if'], "needs.changes.outputs.apps-enabled == 'true'");
      expect(
        jobs['app']['strategy']['matrix']['target'],
        r'${{ fromJSON(needs.changes.outputs.apps) }}',
      );
      expect(jobs['result']['if'], r'${{ always() }}');
      expect((jobs['result']['needs'] as List).toSet(), {
        'changes',
        'desktop',
        'app',
      });
      expect(
        (jobs['result']['steps'] as List).last['run'],
        'python3 tool/ci/select_jobs.py aggregate --bundle',
      );
      expect(
        (workflow['on']['pull_request'] as Map).containsKey('paths'),
        isFalse,
      );
      expect(
        workflow['concurrency']['cancel-in-progress'],
        r"${{ github.event_name == 'pull_request' }}",
      );
      expect(workflow['concurrency']['group'], contains('github.run_id'));
      expect((await selected(['hook/build.dart']))['desktops'], hasLength(3));
      expect(
        (await selected([
          'packages/llamadart_validation/assets/profiles/chat-gguf-cpu.json',
        ]))['desktops'],
        isEmpty,
      );
    },
  );

  test('selection uses complete checkout and safe event metadata boundary', () {
    for (final name in ['ci', 'validation_bundles']) {
      final job = readWorkflow(name)['jobs']['changes'];
      final checkout = (job['steps'] as List).first;
      expect(checkout['with']['fetch-depth'], 0);
      expect(checkout['with']['persist-credentials'], isFalse);
      final select = (job['steps'] as List).singleWhere(
        (step) => step['id'] == 'select',
      );
      expect(select['run'], 'python3 tool/ci/select_jobs.py select');
      expect(select['run'], isNot(contains('github.event')));
    }
  });

  test(
    'isolated validation keeps root and Flutter consumer assertions',
    () async {
      final jobs = readWorkflow('ci')['jobs'];
      final plan = await selected([
        'packages/llamadart_validation/lib/src/runner.dart',
      ]);
      expect(plan['jobs']['validation-integration'], isTrue);
      final runs = (jobs['validation-integration']['steps'] as List)
          .where((step) => step['run'] != null)
          .map((step) => step['run'] as String)
          .join('\n');
      for (final assertion in [
        'validation_remote_test.dart',
        'validation_npu_test.dart',
        'prepare_workspace_test.dart',
        'validation_controller_test.dart',
        'validation_app_test.dart',
      ]) {
        expect(runs, contains(assertion));
      }
    },
  );

  test(
    'runtime lanes retain full OS tests, model smoke, and coverage threshold',
    () {
      final jobs = readWorkflow('ci')['jobs'];
      final nativeSteps = jobs['test-other-os']['steps'] as List;
      expect(
        nativeSteps.any(
          (s) => s['run'] == 'dart test -p vm -j 1 --exclude-tags local-only',
        ),
        isTrue,
      );
      expect(
        nativeSteps.any(
          (s) => '${s['run']}'.contains(
            '--run-skipped test/integration/apple_companion_flutter_cache_test.dart',
          ),
        ),
        isTrue,
      );
      final coverageSteps = jobs['test-linux-coverage']['steps'] as List;
      expect(
        coverageSteps.any(
          (s) => s['run'] == 'dart pub global activate coverage 1.15.1',
        ),
        isTrue,
      );
      expect(
        coverageSteps.any(
          (s) => '${s['run']}'.contains('coverage/lcov.info 70'),
        ),
        isTrue,
      );
      expect(
        coverageSteps.any((s) => '${s['run']}'.contains('--coverage=coverage')),
        isTrue,
      );
    },
  );
}
