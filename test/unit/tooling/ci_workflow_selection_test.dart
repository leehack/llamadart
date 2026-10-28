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

/// `SHARD_JOBS` of `tool/ci/select_jobs.py`: each matrix job outside the plan
/// mapped to the planned job whose selection it shares and that consumes it.
Future<Map<String, String>> shardJobs() async {
  final result = await Process.run(Platform.isWindows ? 'python' : 'python3', [
    '-c',
    'import json,runpy; '
        'print(json.dumps(runpy.run_path("tool/ci/select_jobs.py")["SHARD_JOBS"]))',
  ]);
  expect(result.exitCode, 0, reason: '${result.stderr}');
  return (jsonDecode(result.stdout as String) as Map).cast<String, String>();
}

/// The job checks out its own revision without credentials, the guard compares
/// that revision with `main`, the upload directly follows the guard, and nothing
/// after the guard runs unless it allowed the deploy.
void expectGuardedUpload(Map<String, dynamic> job, String demo) {
  final steps = job['steps'] as List;
  final checkout = steps.singleWhere(
    (step) => '${step['uses']}'.contains('checkout@'),
  );
  expect(checkout['with'], {
    'ref': r'${{ github.sha }}',
    'persist-credentials': false,
  });
  final guard = steps.indexWhere((step) => step['id'] == 'current');
  expect(guard, greaterThanOrEqualTo(0));
  expect(steps[guard]['run'], 'python3 tool/ci/deploy_guard.py $demo');
  final guardEnv = {...?job['env'] as Map?, ...?steps[guard]['env'] as Map?};
  expect(guardEnv['DEPLOY_SHA'], r'${{ github.sha }}');
  expect(guardEnv['GH_TOKEN'], r'${{ github.token }}');
  expect((steps[guard] as Map).containsKey('if'), isFalse);
  expect(jsonEncode(steps[guard]), isNot(contains('secrets.')));
  final upload = steps.indexWhere(
    (step) => jsonEncode(step).contains('secrets.HF_TOKEN'),
  );
  expect(upload, guard + 1);
  expect(steps.length, greaterThan(upload + 1));
  for (final step in steps.skip(guard + 1)) {
    expect(step['if'], "steps.current.outputs.deploy == 'true'");
  }
  for (final step in steps) {
    expect((step as Map).containsKey('continue-on-error'), isFalse);
  }
}

void main() {
  test(
    'production deployment consumes the gated same-run artifact without rebuild',
    () {
      final jobs = readWorkflow('ci')['jobs'] as Map;
      final deploy = jobs['deploy-chat-app'] as Map;
      expect(deploy['needs'], ['test-linux-web', 'web-chat-contract']);
      // GitHub's implicit success() includes skipped ancestors of the aggregate.
      // Explicit cancellation status lets direct successful needs decide eligibility.
      expect(deploy['if'], startsWith('!cancelled() &&'));
      const mainOnly =
          "(github.event_name == 'push' || "
          "github.event_name == 'workflow_dispatch') && "
          "github.ref == 'refs/heads/main'";
      for (final guard in [
        mainOnly,
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
      expect(steps[upload]['if'], mainOnly);
      final workflow = readWorkflow('chat_app_hf_static_deploy');
      expect((workflow['on'] as Map).keys, ['workflow_call']);
      final callee = workflow['jobs']['deploy'];
      expect(
        callee['if'],
        "$mainOnly && github.repository == 'leehack/llamadart'",
      );
      final text = jsonEncode(callee);
      expect(text, contains('web_deployment.py verify'));
      expectGuardedUpload(callee as Map<String, dynamic>, 'chat-app');
      expect(text, isNot(contains('build_chat_app_web.sh')));
      expect(text, isNot(contains('flutter-action')));
    },
  );

  test(
    'Laya Tetris deploys only tested main commits of this repository',
    () async {
      final workflow = readWorkflow('laya_tetris_hf_static_deploy');
      final trigger = workflow['on'] as Map;
      expect(trigger.keys, unorderedEquals(['push', 'workflow_dispatch']));
      expect(trigger['push']['branches'], ['main']);
      final guardInputs = await Process.run(
        Platform.isWindows ? 'python' : 'python3',
        [
          '-c',
          'import json,sys; sys.path.insert(0, "tool/ci"); import deploy_guard; '
              'print(json.dumps(deploy_guard.LAYA_TETRIS_INPUTS))',
        ],
      );
      expect(guardInputs.exitCode, 0, reason: '${guardInputs.stderr}');
      // A commit outside these paths starts no deploy, so the guard must not
      // let it supersede one either.
      expect(
        trigger['push']['paths'],
        jsonDecode(guardInputs.stdout as String),
      );
      expect(workflow['permissions'], {'contents': 'read'});
      final deploy = workflow['jobs']['deploy'] as Map<String, dynamic>;
      expect(
        deploy['if'],
        "github.ref == 'refs/heads/main' && "
        "github.repository == 'leehack/llamadart'",
      );
      expect(deploy.containsKey('continue-on-error'), isFalse);
      final steps = deploy['steps'] as List;
      expectGuardedUpload(deploy, 'laya-tetris');
      final tests = steps.indexWhere(
        (step) => '${step['run']}'.contains('flutter test'),
      );
      final secretSteps = [
        for (var i = 0; i < steps.length; i++)
          if (jsonEncode(steps[i]).contains('secrets.')) i,
      ];
      expect(tests, greaterThanOrEqualTo(0));
      expect(secretSteps, hasLength(1));
      expect(secretSteps.single, greaterThan(tests));
      int secretReferences(Object? value) =>
          'secrets.'.allMatches(jsonEncode(value)).length;
      expect(
        secretReferences(workflow),
        secretReferences(steps[secretSteps.single]),
      );
      expect('${steps[secretSteps.single]['run']}', contains('--public'));
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
      expect(build['timeout-minutes'], 45);
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

  test('model-store lane checks the package on its own selection', () async {
    final plan = await selected([
      'packages/llamadart_model_store/lib/src/model_store_io.dart',
    ]);
    expect(
      (plan['jobs'] as Map).entries
          .where((e) => e.value == true)
          .map((e) => e.key),
      ['model-store'],
    );

    final job = readWorkflow('ci')['jobs']['model-store'] as Map;
    final steps = (job['steps'] as List).cast<Map>();
    Map step(String name) => steps.singleWhere((s) => s['name'] == name);
    final checks = step('Analyze and test');
    expect(checks['working-directory'], 'packages/llamadart_model_store');
    for (final command in [
      'dart format --output=none --set-exit-if-changed .',
      'flutter analyze --fatal-infos',
      'TMPDIR="\$(mktemp -d)" flutter test',
      'flutter test --platform chrome test/model_store_web_test.dart',
    ]) {
      expect(
        (checks['run'] as String).split('\n'),
        contains(command),
        reason: command,
      );
    }
    final unchanged = step('Check the lane leaves the package unchanged');
    expect(unchanged.containsKey('if'), isFalse);
    expect(unchanged['working-directory'], 'packages/llamadart_model_store');
    expect(
      unchanged['run'],
      allOf(
        contains('git status --porcelain --untracked-files=all -- .'),
        contains('exit 1'),
      ),
    );
    expect(steps.where((s) => s.containsKey('if')), isEmpty);
  });

  test('dependabot updates every independently resolved package', () {
    final config =
        loadYaml(File('.github/dependabot.yml').readAsStringSync()) as Map;
    final pubDirectories = [
      for (final update in config['updates'] as List)
        if (update['package-ecosystem'] == 'pub') update['directory'] as String,
    ];
    for (final directory in pubDirectories) {
      expect(
        File('.$directory/pubspec.yaml'.replaceAll('//', '/')).existsSync(),
        isTrue,
        reason: directory,
      );
    }
    expect(pubDirectories, contains('/packages/llamadart_model_store'));
  });

  test(
    'core workflow wires every planned job into truthful always aggregate',
    () async {
      final workflow = readWorkflow('ci');
      final jobs = workflow['jobs'] as Map<String, dynamic>;
      final plan = await selected(['lib/llamadart.dart']);
      final planned = (plan['jobs'] as Map).keys.toSet();
      final shards = await shardJobs();
      expect(shards, {'test-linux-vm': 'test-linux-coverage'});
      expect(jobs.keys.toSet(), {
        ...planned,
        ...shards.keys,
        'changes',
        'test-linux-web',
        'deploy-chat-app',
      });
      final aggregate = jobs['test-linux-web'] as Map;
      expect(aggregate['if'], r'${{ always() }}');
      expect((aggregate['needs'] as List).toSet(), {
        ...planned,
        ...shards.keys,
        'changes',
      });
      final steps = aggregate['steps'] as List;
      final check = steps.last as Map;
      expect(check['run'], 'python3 tool/ci/select_jobs.py aggregate');
      expect(check['env'], {
        'PLAN': r'${{ needs.changes.outputs.plan }}',
        'NEEDS': r'${{ toJSON(needs) }}',
      });
      final consumers = {for (final e in shards.entries) e.value: e.key};
      for (final name in planned) {
        final shard = consumers[name];
        // A consumer waits for its shards, so it is skipped when one fails.
        expect(
          jobs[name]['needs'],
          shard == null ? 'changes' : ['changes', shard],
          reason: '$name',
        );
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
      for (final MapEntry(key: shard, value: consumer) in shards.entries) {
        expect(jobs[shard]['needs'], 'changes', reason: shard);
        expect(
          jobs[shard]['if'],
          "needs.changes.outputs.$consumer == 'true'",
          reason: shard,
        );
        expect(jobs[shard]['strategy']['fail-fast'], isFalse, reason: shard);
      }
      expect(
        jobs['companion-packages']['strategy']['matrix']['package'],
        r'${{ fromJSON(needs.changes.outputs.companions) }}',
      );
      final triggers = workflow['on'] as Map;
      expect(triggers.keys.toSet(), {
        'push',
        'pull_request',
        'workflow_dispatch',
      });
      // No inputs: a manual run cannot name another ref or artifact to deploy.
      expect(triggers['workflow_dispatch'], isNull);
      for (final name in ['push', 'pull_request']) {
        final trigger = triggers[name] as Map;
        expect(trigger.containsKey('paths'), isFalse);
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
    'pinned tooling docs and chat-app VM tests select their gates',
    () async {
      Future<Set<String>> enabled(String path) async {
        final jobs = (await selected([path]))['jobs'] as Map;
        return {
          for (final entry in jobs.entries)
            if (entry.value == true) entry.key as String,
        };
      }

      for (final path in [
        'AGENTS.md',
        'CONTRIBUTING.md',
        'doc/testing_matrix.md',
        'README.md',
        'website/docs/guides/embeddings.md',
        'packages/llamadart_stable_diffusion_flutter/README.md',
        'example/chat_app/README.md',
      ]) {
        expect(await enabled(path), {
          'docs-check',
          'docs-versions',
          'test-linux-coverage',
        }, reason: path);
      }
      expect(
        await enabled('example/chat_app/test_vm/chat_settings_test.dart'),
        {'analyze', 'web-chat-contract'},
      );
    },
  );

  test(
    'capability registry changes select an unconditional inventory gate',
    () async {
      final jobs = readWorkflow('ci')['jobs'] as Map;
      for (final path in [
        'packages/llamadart_validation/assets/capability_coverage.json',
        'packages/llamadart_validation/lib/src/case_catalog.dart',
        'lib/src/core/engine/engine.dart',
      ]) {
        expect(
          (await selected([path]))['jobs']['analyze'],
          isTrue,
          reason: path,
        );
      }
      final gate =
          (jobs['analyze']['steps'] as List).singleWhere(
                (step) =>
                    step['name'] ==
                    'Verify public capability validation coverage',
              )
              as Map;
      expect(
        gate['run'],
        'dart test -p vm test/unit/tooling/validation_coverage_test.dart',
      );
      expect(gate.containsKey('if'), isFalse);
      expect(gate.containsKey('continue-on-error'), isFalse);
      final archive =
          (jobs['analyze']['steps'] as List).singleWhere(
                (step) => step['name'] == 'Pub Publish Dry Run',
              )
              as Map;
      expect(archive['run'], 'python3 tool/release/check_core_archive.py');
      expect(archive.containsKey('if'), isFalse);
      expect(archive.containsKey('continue-on-error'), isFalse);
    },
  );

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
        'validation_image_profile_test.dart',
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
          (s) => (s['run'] as String? ?? '')
              .split('\n')
              .contains('flutter test test test_vm'),
        ),
        isTrue,
      );
      final mixed = await selected([
        'packages/llamadart_validation/test/validation_test.dart',
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

  test('Example Package Tests run every other example package', () {
    final job = readWorkflow('ci')['jobs']['example-packages'] as Map;
    final steps = job['steps'] as List;
    expect(job.containsKey('continue-on-error'), isFalse);
    for (final step in steps.cast<Map>()) {
      expect(step.containsKey('continue-on-error'), isFalse, reason: '$step');
    }
    final tested = {
      for (final step in steps.cast<Map>())
        if (step['working-directory'] case final String dir) dir: step,
    };
    final packages = Directory('example')
        .listSync()
        .whereType<Directory>()
        .map((dir) => dir.path.replaceAll(r'\', '/'))
        .where((dir) => File('$dir/pubspec.yaml').existsSync())
        .where((dir) => Directory('$dir/test').existsSync())
        .toSet();
    expect(packages, contains('example/chat_app'));
    expect(tested.keys.toSet(), packages.difference({'example/chat_app'}));
    for (final MapEntry(key: dir, value: step) in tested.entries) {
      final pubspec = File('$dir/pubspec.yaml').readAsStringSync();
      final runner =
          pubspec.contains(RegExp(r'^\s+sdk: flutter$', multiLine: true))
          ? 'flutter'
          : 'dart';
      expect(step['if'], r'${{ !cancelled() }}', reason: dir);
      expect('${step['run']}'.trim().split('\n'), [
        'flutter pub get',
        'TMPDIR="\$(mktemp -d)" $runner test --exclude-tags local-only',
      ], reason: dir);
    }
  });

  test('Web Chat Contract opts the chat app out of stable_diffusion', () {
    final steps =
        readWorkflow('ci')['jobs']['web-chat-contract']['steps'] as List;
    int indexOfRun(Pattern needle) =>
        steps.indexWhere((s) => '${s['run']}'.contains(needle));
    final optOut = indexOfRun('llamadart_native_runtimes');
    final install = indexOfRun('flutter pub get');
    final tests = indexOfRun('flutter test test test_vm');
    final restore = indexOfRun('git checkout -- example/chat_app/pubspec.yaml');
    final build = indexOfRun('scripts/build_chat_app_web.sh');
    expect(optOut, isNonNegative);
    expect(optOut, lessThan(install));
    expect(install, lessThan(tests));
    expect(tests, lessThan(restore));
    expect(restore, lessThan(build));

    final lines = '${steps[optOut]['run']}'
        .split('\n')
        .map((l) => l.trim())
        .toList();
    expect(
      lines,
      contains(
        r"sed -i 's/^\( *llamadart_native_runtimes:\) all$/\1 both/' "
        'pubspec.yaml',
      ),
    );
    expect(
      lines,
      contains(r"grep -q '^ *llamadart_native_runtimes: both$' pubspec.yaml"),
    );
    expect(steps[optOut]['shell'], isNull);
    expect(steps[optOut]['continue-on-error'], isNull);
  });

  test(
    'runtime lanes retain full OS tests, model smoke, and coverage threshold',
    () {
      final jobs = readWorkflow('ci')['jobs'];
      final nativeSteps = jobs['test-other-os']['steps'] as List;
      expect(
        nativeSteps.any(
          (s) =>
              s['run'] ==
              'dart test -p vm -j 1 --exclude-tags local-only '
                  '--file-reporter=json:.dart_tool/native_test_events.jsonl',
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
      final shardSteps = jobs['test-linux-vm']['steps'] as List;
      final shardRuns = shardSteps.map((s) => '${s['run']}').toList();
      expect(
        shardRuns,
        contains(
          'dart test -p vm -j 1 --exclude-tags local-only '
          r'--coverage=coverage ${{ matrix.paths }}',
        ),
      );
      final upload =
          shardSteps.singleWhere(
                (s) => '${s['uses']}'.startsWith('actions/upload-artifact@'),
              )
              as Map;
      expect(upload['with'], {
        'name': r'linux-vm-coverage-${{ matrix.shard }}',
        'path': 'coverage/',
        'if-no-files-found': 'error',
        'retention-days': 1,
        'overwrite': true,
      });
      expect(upload.containsKey('if'), isFalse);

      final coverageSteps = jobs['test-linux-coverage']['steps'] as List;
      int index(bool Function(Map step) test) =>
          coverageSteps.indexWhere((s) => test(s as Map));
      final download = index(
        (s) => '${s['uses']}'.startsWith('actions/download-artifact@'),
      );
      expect(download, greaterThanOrEqualTo(0));
      expect(coverageSteps[download]['with'], {
        'pattern': 'linux-vm-coverage-*',
        'merge-multiple': true,
        'path': 'coverage/',
      });
      final format = index(
        (s) => '${s['run']}'.contains(
          'dart run tool/testing/format_lcov.dart --lcov '
          '--in=coverage/test --out=coverage/lcov.info --report-on=lib '
          '--check-ignore',
        ),
      );
      expect(format, greaterThan(download));
      expect(
        coverageSteps[format]['run'],
        contains(
          'dart run tool/testing/check_lcov_threshold.dart '
          'coverage/lcov.info 70',
        ),
      );
      final codecov = index(
        (s) => '${s['uses']}'.startsWith('codecov/codecov-action@'),
      );
      expect(codecov, greaterThan(format));
      expect(coverageSteps[codecov]['with']['files'], 'coverage/lcov.info');
      for (final steps in [shardSteps, coverageSteps]) {
        expect(
          steps.any(
            (s) => '${s['run']}'.contains('pub global activate coverage'),
          ),
          isFalse,
        );
      }
      expect(
        coverageSteps.any((s) => '${s['run']}'.contains('dart test')),
        isFalse,
      );
    },
  );

  test('Linux VM shards run every root test file exactly once', () {
    final matrix =
        readWorkflow('ci')['jobs']['test-linux-vm']['strategy']['matrix']
            as Map;
    final shards = {
      for (final entry in (matrix['include'] as List).cast<Map>())
        entry['shard'] as String: (entry['paths'] as String)
            .split(RegExp(r'\s+'))
            .where((path) => path.isNotEmpty)
            .toList(),
    };
    expect(shards.keys, unorderedEquals(['core', 'tooling', 'runtime']));
    final testFiles = Directory('test')
        .listSync(recursive: true)
        .whereType<File>()
        .map((file) => file.path.replaceAll(r'\', '/'))
        .where((path) => path.endsWith('_test.dart'))
        .toList();
    expect(testFiles, isNotEmpty);
    for (final paths in shards.values) {
      for (final path in paths) {
        expect(
          FileSystemEntity.typeSync(path),
          isNot(FileSystemEntityType.notFound),
          reason: path,
        );
      }
    }
    for (final file in testFiles) {
      final owners = [
        for (final MapEntry(key: shard, value: paths) in shards.entries)
          for (final path in paths)
            if (file == path || file.startsWith('$path/')) '$shard:$path',
      ];
      expect(owners, hasLength(1), reason: file);
    }
  });

  test('VM test lanes run against a temp directory guarded by a LiteRT-LM '
      'cache canary', () {
    final jobs = readWorkflow('ci')['jobs'];
    for (final job in ['test-linux-vm', 'test-other-os']) {
      final steps = jobs[job]['steps'] as List;
      int index(String run) => steps.indexWhere((s) => s['run'] == run);
      final seed = index('bash tool/ci/litert_lm_temp_canary.sh seed');
      final tests = steps.indexWhere(
        (s) => '${s['run']}'.startsWith('dart test -p vm -j 1 '),
      );
      final check = index('bash tool/ci/litert_lm_temp_canary.sh check');
      expect(seed, greaterThanOrEqualTo(0), reason: job);
      expect(tests, greaterThan(seed), reason: job);
      expect(check, greaterThan(tests), reason: job);
      expect((steps[seed] as Map).containsKey('if'), isFalse, reason: job);
      expect(steps[check]['if'], r'${{ !cancelled() }}', reason: job);
    }
  });

  test('the coverage formatter version is pinned exactly in pubspec.yaml', () {
    final pubspec =
        loadYaml(File('pubspec.yaml').readAsStringSync()) as YamlMap;
    final constraint =
        (pubspec['dev_dependencies'] as YamlMap)['coverage'] as String;

    expect(constraint, _pinnedCoverageVersion);
  });

  test('the resolved coverage version matches the pin', () {
    final lock = File('pubspec.lock');
    if (!lock.existsSync()) {
      markTestSkipped('pubspec.lock is gitignored; run `dart pub get` first.');
      return;
    }
    final packages =
        (loadYaml(lock.readAsStringSync()) as YamlMap)['packages'] as YamlMap;
    final resolved = (packages['coverage'] as YamlMap)['version'] as String;

    expect(
      resolved,
      _pinnedCoverageVersion,
      reason:
          'coverage resolved to $resolved, not the pinned '
          '$_pinnedCoverageVersion the LCOV formatter was verified against.',
    );
  });
}

/// `coverage` version `pubspec.yaml` pins and the LCOV formatter was verified
/// against.
const _pinnedCoverageVersion = '1.16.0';
