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
    'production deployment consumes the gated same-run artifact without rebuild',
    () {
      final jobs = readWorkflow('ci')['jobs'] as Map;
      final deploy = jobs['deploy-chat-app'] as Map;
      expect(deploy['needs'], ['test-linux-web', 'web-chat-contract']);
      for (final guard in [
        "github.event_name == 'push'",
        "github.ref == 'refs/heads/main'",
        "github.repository == 'leehack/llamadart'",
        "needs.test-linux-web.result == 'success'",
        "needs.web-chat-contract.result == 'success'",
      ]) {
        expect(deploy['if'], contains(guard));
      }
      expect(
        deploy['with']['artifact_id'],
        r'${{ needs.web-chat-contract.outputs.artifact-id }}',
      );
      expect(
        deploy['with']['artifact_digest'],
        r'${{ needs.web-chat-contract.outputs.artifact-digest }}',
      );
      final steps = jobs['web-chat-contract']['steps'] as List;
      final smoke = steps.indexWhere(
        (step) => '${step['run']}'.contains(
          '--scenario chat-app-web-production-smoke',
        ),
      );
      final upload = steps.indexWhere(
        (step) => step['id'] == 'production-artifact',
      );
      expect(smoke, greaterThanOrEqualTo(0));
      expect(upload, greaterThan(smoke));
      expect(steps[upload]['if'], contains("github.event_name == 'push'"));
      final workflow = readWorkflow('chat_app_hf_static_deploy');
      expect((workflow['on'] as Map).keys, ['workflow_call']);
      final callee = workflow['jobs']['deploy'];
      expect(callee['if'], contains("github.event_name == 'push'"));
      expect(callee['if'], contains("github.ref == 'refs/heads/main'"));
      expect(
        callee['if'],
        contains("github.repository == 'leehack/llamadart'"),
      );
      final text = jsonEncode(callee);
      expect(text, contains('web_deployment.py verify'));
      expect(text, contains('git/ref/heads/main'));
      expect(text, isNot(contains('build_chat_app_web.sh')));
      expect(text, isNot(contains('flutter-action')));
    },
  );

  test(
    'preview selection precedes SDK and secrets while close cleanup is unfiltered',
    () {
      final workflow = readWorkflow('chat_app_hf_pr_preview');
      final trigger = workflow['on']['pull_request'] as Map;
      expect(trigger.containsKey('paths'), isFalse);
      expect(
        trigger['types'],
        containsAll(['closed', 'ready_for_review', 'labeled', 'unlabeled']),
      );
      final build = workflow['jobs']['build'];
      expect(build['permissions'], {'contents': 'read'});
      expect(jsonEncode(build), isNot(contains('secrets.')));
      final steps = build['steps'] as List;
      expect(steps.first['if'], "github.event.action == 'closed'");
      expect(steps.first['run'], contains('action=cleanup'));
      final select = steps.indexWhere((step) => step['id'] == 'select');
      final sdk = steps.indexWhere(
        (step) => '${step['uses']}'.contains('flutter-action'),
      );
      expect(select, lessThan(sdk));
      expect(steps[sdk]['if'], "steps.select.outputs.action == 'build'");
      final deploy = workflow['jobs']['preview'];
      expect(deploy['needs'], 'build');
      expect(deploy['if'], contains("needs.build.result == 'success'"));
      expect(deploy['env'].containsKey('HF_TOKEN'), isFalse);
      final checkout = (deploy['steps'] as List).singleWhere(
        (step) => '${step['uses']}'.contains('checkout@'),
      );
      expect(
        checkout['with']['ref'],
        r'${{ github.event.pull_request.base.sha }}',
      );
      expect(checkout['if'], "github.event.action != 'closed'");
    },
  );

  test(
    'core workflow wires every planned job into truthful always aggregate',
    () async {
      final workflow = readWorkflow('ci');
      final jobs = workflow['jobs'] as Map<String, dynamic>;
      final plan = await selected(['lib/llamadart.dart']);
      final planned = (plan['jobs'] as Map).keys.toSet();
      expect(jobs.keys.toSet(), {
        ...planned,
        'changes',
        'test-linux-web',
        'deploy-chat-app',
      });
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
    'full graph substitution executes both root and all Flutter consumers',
    () async {
      final jobs = readWorkflow('ci')['jobs'];
      final rootRun = (jobs['validation-integration']['steps'] as List)
          .singleWhere(
            (s) => '${s['run']}'.contains('validation_remote_test.dart'),
          );
      expect(
        rootRun['if'],
        "needs.changes.outputs.test-linux-coverage != 'true'",
      );
      final appSteps = (jobs['web-chat-contract']['steps'] as List).where(
        (s) => s['working-directory'] == 'example/chat_app',
      );
      expect(
        appSteps.any(
          (s) =>
              (s['run'] as String? ?? '').split('\n').contains('flutter test'),
        ),
        isTrue,
      );
      final mixed = await selected([
        'packages/llamadart_validation/lib/src/runner.dart',
        'test/unit/tooling/validation_remote_test.dart',
      ]);
      expect(mixed['jobs']['validation-integration'], isTrue);
      final integrationFlutter =
          (jobs['validation-integration']['steps'] as List).singleWhere(
            (s) => '${s['run']}'.contains('validation_controller_test.dart'),
          );
      expect(integrationFlutter.containsKey('if'), isFalse);
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
