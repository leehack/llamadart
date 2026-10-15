@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

const _posixOnly = 'runs workflow scripts under a POSIX Bash runtime';

const _releaseWorkflow = '.github/workflows/release_on_prep_merge.yml';
const _companionWorkflow = '.github/workflows/publish_companion_pubdev.yml';
const _ciWorkflow = '.github/workflows/ci.yml';

const _releaseSha = '1111111111111111111111111111111111111111';
const _otherSha = '2222222222222222222222222222222222222222';
const _tagObjectSha = '3333333333333333333333333333333333333333';

const _companions = <String>[
  'llamadart_llama_cpp_flutter',
  'llamadart_litert_lm_flutter',
  'llamadart_stable_diffusion_flutter',
];

String _read(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');

YamlMap _step(String workflow, String job, String name) {
  final jobs = (loadYaml(workflow) as YamlMap)['jobs'] as YamlMap;
  final steps = (jobs[job] as YamlMap)['steps'] as YamlList;
  return steps.cast<YamlMap>().singleWhere((step) => step['name'] == name);
}

/// Commands the workflow scripts call, replaced by stubs that log every call
/// to `$STUB_LOG` and answer from files under `$STUB_STATE`.
const _stubs = <String, String>{
  'dart': 'exit 0\n',
  'gh': r'''
if [[ "$1" == release ]]; then
  exit 0
fi
''',
  'git': r'''
case "$1" in
  rev-parse)
    echo "$STUB_HEAD"
    ;;
  ls-remote)
    found=false
    for arg in "$@"; do
      [[ "$arg" == refs/tags/* ]] || continue
      while read -r sha ref; do
        if [[ "$ref" == "$arg" ]]; then
          printf '%s\t%s\n' "$sha" "$ref"
          found=true
        fi
      done < "$STUB_STATE/remote_tags"
    done
    if [[ "$found" == false && " $* " == *" --exit-code "* ]]; then
      exit 2
    fi
    ;;
  *)
    exit 1
    ;;
esac
''',
  'curl': r'''
url="${*: -1}"
body="$STUB_STATE/pub/${url//[!A-Za-z0-9]/_}"
if [[ -f "$body" ]]; then
  cat "$body"
else
  exit 22
fi
''',
  'flutter': r'''
{
  echo "pwd=$PWD"
  if [[ -f pubspec_overrides.yaml ]]; then
    echo "--- pubspec_overrides.yaml"
    cat pubspec_overrides.yaml
  fi
} >> "$STUB_STATE/flutter_calls"
''',
};

/// A scratch directory with logging stubs for [_stubs] first on `PATH`.
class _Sandbox {
  _Sandbox._(this.root);

  factory _Sandbox() {
    final root = Directory.systemTemp
        .createTempSync('companion_release_workflow_')
        .resolveSymbolicLinksSync();
    final sandbox = _Sandbox._(root);
    Directory(sandbox.bin).createSync();
    Directory('${sandbox.state}/pub').createSync(recursive: true);
    File('${sandbox.state}/remote_tags').writeAsStringSync('');
    for (final stub in _stubs.entries) {
      final path = '${sandbox.bin}/${stub.key}';
      File(path).writeAsStringSync(
        '#!/usr/bin/env bash\n'
        'printf \'%s\\n\' "${stub.key} \$*" >> "\$STUB_LOG"\n'
        '${stub.value}',
      );
      Process.runSync('chmod', ['+x', path]);
    }
    addTearDown(() => Directory(root).deleteSync(recursive: true));
    return sandbox;
  }

  final String root;

  String get bin => '$root/bin';
  String get state => '$root/state';
  String get log => '$root/stub.log';

  List<String> get calls =>
      File(log).existsSync() ? File(log).readAsLinesSync() : const <String>[];

  void remoteTag(String sha, String ref) => File(
    '$state/remote_tags',
  ).writeAsStringSync('$sha $ref\n', mode: FileMode.append);

  void pub(String url, String body) => File(
    '$state/pub/${url.replaceAll(RegExp('[^A-Za-z0-9]'), '_')}',
  ).writeAsStringSync(body);

  void file(String path, String contents) => File('$root/$path')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(contents);

  /// Runs [script] the way Actions runs a `shell: bash` step.
  ProcessResult run(
    String script, {
    required String workingDirectory,
    Map<String, String> env = const {},
  }) {
    final path = '$root/step.sh';
    File(path).writeAsStringSync(script);
    return Process.runSync(
      'bash',
      ['--noprofile', '--norc', '-eo', 'pipefail', path],
      workingDirectory: workingDirectory,
      environment: {
        'PATH': '$bin:${Platform.environment['PATH']}',
        'STUB_LOG': log,
        'STUB_STATE': state,
        'STUB_HEAD': _releaseSha,
        ...env,
      },
    );
  }
}

/// Resolves a step's `env` the way Actions would, using [values] for the
/// expressions the step may reference.
({Map<String, String> env, List<String> problems}) _resolveEnv(
  YamlMap step,
  Map<String, String> values,
) {
  final env = <String, String>{};
  final problems = <String>[];
  final expression = RegExp(r'^\$\{\{\s*([^}\s]+)\s*\}\}$');
  for (final entry in ((step['env'] as YamlMap?) ?? YamlMap()).entries) {
    final raw = '${entry.value}';
    final match = expression.firstMatch(raw);
    if (match == null) {
      env['${entry.key}'] = raw;
      continue;
    }
    final value = values[match.group(1)];
    if (value == null) {
      problems.add('${step['name']} maps ${entry.key} to unknown $raw');
      continue;
    }
    env['${entry.key}'] = value;
  }
  return (env: env, problems: problems);
}

Map<String, String> _outputs(String path) => {
  for (final line in File(path).readAsLinesSync())
    if (line.contains('='))
      line.substring(0, line.indexOf('=')): line.substring(
        line.indexOf('=') + 1,
      ),
};

/// Remote state for one release run of core `0.13.0`.
typedef _Release = ({
  String name,
  void Function(_Sandbox sandbox) remote,
  Set<String> missingCompanions,
});

const _coreListing = 'https://pub.dev/api/packages/llamadart';

/// Runs the release workflow's validation and publication steps from
/// [workflow] against [release], and returns the step results and calls.
({
  ProcessResult validate,
  ProcessResult? publish,
  List<String> calls,
  String output,
  List<String> problems,
})
_runRelease(String workflow, _Release release) {
  final sandbox = _Sandbox();
  final repo = '${sandbox.root}/repo';
  sandbox
    ..file('repo/pubspec.yaml', 'name: llamadart\nversion: 0.13.0\n')
    ..file('repo/CHANGELOG.md', '## 0.13.0\n\n- Release.\n')
    ..pub(_coreListing, '{"versions":[{"version":"0.13.0"}]}');
  for (final companion in _companions) {
    sandbox.file(
      'repo/packages/$companion/pubspec.yaml',
      'name: $companion\nversion: 0.13.0\n',
    );
    final listing = 'https://pub.dev/api/packages/$companion';
    sandbox.pub(listing, '{"versions":[{"version":"0.13.0"}]}');
    if (!release.missingCompanions.contains(companion)) {
      sandbox.pub('$listing/versions/0.13.0', '{}');
    }
  }
  release.remote(sandbox);

  final problems = <String>[];
  final validateStep = _step(workflow, 'release', 'Validate release state');
  final githubOutput = '${sandbox.root}/validate_output';
  File(githubOutput).createSync();
  final validate = sandbox.run(
    '${validateStep['run']}',
    workingDirectory: repo,
    env: {'GITHUB_OUTPUT': githubOutput},
  );
  if (validate.exitCode != 0) {
    return (
      validate: validate,
      publish: null,
      calls: sandbox.calls,
      output: File(githubOutput).readAsStringSync(),
      problems: problems,
    );
  }

  final publishStep = _step(
    workflow,
    'release',
    'Publish core tag and companion packages',
  );
  final resolved = _resolveEnv(publishStep, {
    for (final output in _outputs(githubOutput).entries)
      'steps.${validateStep['id']}.outputs.${output.key}': output.value,
    'github.token': 'github-token',
    'secrets.RELEASE_AUTOMATION_TOKEN': 'release-token',
  });
  problems.addAll(resolved.problems);
  final publish = sandbox.run(
    '${publishStep['run']}',
    workingDirectory: repo,
    env: {
      ...resolved.env,
      'GITHUB_REPOSITORY': 'leehack/llamadart',
      'PUBDEV_WAIT_ATTEMPTS': '1',
      'PUBDEV_WAIT_INTERVAL_SECONDS': '1',
      'GITHUB_RELEASE_WAIT_ATTEMPTS': '1',
      'GITHUB_RELEASE_WAIT_INTERVAL_SECONDS': '1',
    },
  );
  return (
    validate: validate,
    publish: publish,
    calls: sandbox.calls,
    output: File(githubOutput).readAsStringSync(),
    problems: problems,
  );
}

bool _pushed(List<String> calls, String tag) => calls.any(
  (call) =>
      call.startsWith('gh api') &&
      call.contains('ref=refs/tags/$tag ') &&
      call.contains('sha=$_releaseSha'),
);

/// Why [workflow] could push the core tag twice, resume at another commit or
/// leave a companion half-published without saying how to recover.
List<String> _releaseResumeProblems(String workflow) {
  final problems = <String>[];
  void check(bool ok, String problem) {
    if (!ok) problems.add(problem);
  }

  final fresh = _runRelease(workflow, (
    name: 'fresh',
    remote: (_) {},
    missingCompanions: {_companions.first},
  ));
  problems.addAll(fresh.problems);
  check(
    fresh.validate.exitCode == 0 && fresh.publish?.exitCode == 0,
    'a fresh release must succeed: ${fresh.validate.stderr}'
    '${fresh.publish?.stderr}',
  );
  check(
    fresh.output.contains('core_tag_exists=false\n'),
    'a fresh release must report no existing core tag',
  );
  check(_pushed(fresh.calls, 'v0.13.0'), 'a fresh release must push v0.13.0');
  final corePush = fresh.calls.indexWhere(
    (call) => call.contains('ref=refs/tags/v0.13.0 '),
  );
  final companionPush = fresh.calls.indexWhere(
    (call) => call.contains('ref=refs/tags/${_companions.first}-v0.13.0 '),
  );
  check(
    corePush != -1 && corePush < companionPush,
    'a missing companion must be tagged after the core',
  );
  final curls = fresh.calls.where((call) => call.startsWith('curl '));
  check(
    curls.isNotEmpty && curls.every((call) => call.contains('--max-time ')),
    'every pub.dev request must set --max-time',
  );

  for (final resume in <_Release>[
    (
      name: 'lightweight tag at the release commit',
      remote: (sandbox) => sandbox.remoteTag(_releaseSha, 'refs/tags/v0.13.0'),
      missingCompanions: const {},
    ),
    (
      name: 'annotated tag at the release commit',
      remote: (sandbox) => sandbox
        ..remoteTag(_tagObjectSha, 'refs/tags/v0.13.0')
        ..remoteTag(_releaseSha, 'refs/tags/v0.13.0^{}'),
      missingCompanions: const {},
    ),
  ]) {
    final run = _runRelease(workflow, resume);
    problems.addAll(run.problems);
    check(
      run.validate.exitCode == 0 && run.publish?.exitCode == 0,
      'a rerun with an existing ${resume.name} must succeed: ${run.validate.stderr}'
      '${run.publish?.stderr}',
    );
    check(
      run.output.contains('core_tag_exists=true\n'),
      'a rerun with an existing ${resume.name} must report the existing core tag',
    );
    check(
      !run.calls.any((call) => call.contains('ref=refs/tags/v0.13.0 ')),
      'a rerun with an existing ${resume.name} must not push v0.13.0 again',
    );
  }

  final moved = _runRelease(workflow, (
    name: 'tag at another commit',
    remote: (sandbox) => sandbox.remoteTag(_otherSha, 'refs/tags/v0.13.0'),
    missingCompanions: const {},
  ));
  check(
    moved.validate.exitCode != 0 &&
        '${moved.validate.stderr}'.contains(
          'already exists at $_otherSha, not $_releaseSha',
        ),
    'a core tag at another commit must stop the release',
  );
  check(
    !moved.output.contains('core_tag_exists='),
    'a core tag at another commit must not reach publication',
  );

  final halfPublished = _runRelease(workflow, (
    name: 'companion tag without a pub.dev version',
    remote: (sandbox) => sandbox
      ..remoteTag(_releaseSha, 'refs/tags/v0.13.0')
      ..remoteTag(_releaseSha, 'refs/tags/${_companions[1]}-v0.13.0'),
    missingCompanions: {_companions[1]},
  ));
  final stderr = '${halfPublished.publish?.stderr}';
  check(
    halfPublished.publish != null &&
        halfPublished.publish!.exitCode != 0 &&
        stderr.contains('rerun that run') &&
        stderr.contains('publish_companion_pubdev.yml') &&
        stderr.contains('bumps the core version'),
    'a companion tag without its pub.dev version must stop with both '
    'recovery paths: $stderr',
  );
  return problems;
}

/// Why [workflow]'s real companion publish could resolve `llamadart` from the
/// checkout instead of pub.dev.
List<String> _companionPublishProblems(String workflow) {
  final problems = <String>[];
  const job = 'publish-companion';
  const copy = r'${{ runner.temp }}/pub-package';
  final sandbox = _Sandbox();
  final package = '${sandbox.root}/checkout/packages/companion';
  sandbox
    ..file('checkout/packages/companion/pubspec.yaml', 'name: companion\n')
    ..file(
      'checkout/packages/companion/pubspec_overrides.yaml',
      'dependency_overrides:\n  llamadart:\n    path: ../..\n',
    )
    ..file('checkout/packages/companion/pubspec.lock', '')
    ..file('checkout/packages/companion/.dart_tool/state', '');
  final runnerTemp = '${sandbox.root}/runner';
  Directory(runnerTemp).createSync();

  final prepare = _step(workflow, job, 'Prepare package');
  final resolved = _resolveEnv(prepare, {
    'steps.package.outputs.path': package,
  });
  problems.addAll(resolved.problems);
  final result = sandbox.run(
    '${prepare['run']}',
    workingDirectory: '${sandbox.root}/checkout',
    env: {...resolved.env, 'RUNNER_TEMP': runnerTemp},
  );
  final published = '$runnerTemp/pub-package';
  if (result.exitCode != 0) {
    problems.add('Prepare package failed: ${result.stderr}');
  } else {
    if (!File('$published/pubspec.yaml').existsSync()) {
      problems.add('the prepared copy must hold the package');
    }
    for (final dropped in [
      'pubspec_overrides.yaml',
      'pubspec.lock',
      '.dart_tool',
    ]) {
      if (FileSystemEntity.typeSync('$published/$dropped') !=
          FileSystemEntityType.notFound) {
        problems.add('the prepared copy must not hold $dropped');
      }
    }
  }
  for (final name in [
    'Install dependencies',
    'Publish - dry run',
    'Publish to pub.dev',
  ]) {
    if (_step(workflow, job, name)['working-directory'] != copy) {
      problems.add('$name must run in the prepared copy, $copy');
    }
  }
  return problems;
}

/// Why [workflow]'s companion publish dry-run could resolve `llamadart` from
/// pub.dev, or from a path outside this checkout.
List<String> _ciDryRunProblems(String workflow) {
  final problems = <String>[];
  final sandbox = _Sandbox();
  final workspace = '${sandbox.root}/workspace';
  final package = '$workspace/packages/companion';
  sandbox
    ..file('workspace/packages/companion/pubspec.yaml', 'name: companion\n')
    ..file(
      'workspace/packages/companion/pubspec_overrides.yaml',
      'dependency_overrides:\n  llamadart:\n    path: ../..\n',
    );
  final runnerTemp = '${sandbox.root}/runner';
  Directory(runnerTemp).createSync();

  final step = _step(workflow, 'companion-packages', 'Publish dry-run');
  if (step['working-directory'] != r'${{ matrix.package }}') {
    problems.add('the dry-run must start in the companion package');
  }
  final result = sandbox.run(
    '${step['run']}',
    workingDirectory: package,
    env: {'RUNNER_TEMP': runnerTemp, 'GITHUB_WORKSPACE': workspace},
  );
  if (result.exitCode != 0) {
    return [...problems, 'Publish dry-run failed: ${result.stderr}'];
  }
  if (!sandbox.calls.contains('flutter pub publish --dry-run')) {
    problems.add('the step must run flutter pub publish --dry-run');
  }
  final calls = File('${sandbox.state}/flutter_calls');
  final record = calls.existsSync() ? calls.readAsStringSync() : '';
  final cwd = RegExp(r'^pwd=(.*)$', multiLine: true).firstMatch(record);
  if (cwd == null || !cwd.group(1)!.startsWith('$runnerTemp/')) {
    problems.add('the dry-run must publish a temporary copy');
  }
  final overrides = record.split('--- pubspec_overrides.yaml\n');
  final Object? parsed = overrides.length == 2
      ? loadYaml(overrides.last)
      : null;
  Object? path;
  if (parsed is YamlMap) {
    final dependencyOverrides = parsed['dependency_overrides'];
    final core = dependencyOverrides is YamlMap
        ? dependencyOverrides['llamadart']
        : null;
    path = core is YamlMap ? core['path'] : null;
  }
  if (path != workspace) {
    problems.add(
      'the dry-run copy must override llamadart with the checkout '
      '$workspace, not ${path ?? 'nothing'}',
    );
  }
  return problems;
}

void main() {
  group('release_on_prep_merge.yml', () {
    final workflow = _read(_releaseWorkflow);

    test('resumes companion publication only at the release commit', () {
      expect(_releaseResumeProblems(workflow), isEmpty);
    });

    test('rejects a miswired core tag resume', () {
      final mutations = <String, String Function(String)>{
        'W1 always skips the core tag push': (source) => source.replaceFirst(
          'if [[ "\$CORE_TAG_EXISTS" == "true" ]]; then',
          'if true; then',
        ),
        'W2 continues past a core tag at another commit': (source) =>
            source.replaceFirst(
              'Refusing to publish again." >&2\n'
                  '              exit 1\n',
              'Refusing to publish again." >&2\n',
            ),
        'W3 assumes the core tag exists': (source) => source.replaceFirst(
          'core_tag_exists=false',
          'core_tag_exists=true',
        ),
        'W4 maps CORE_TAG_EXISTS to another output': (source) =>
            source.replaceFirst(
              r'CORE_TAG_EXISTS: ${{ steps.release.outputs.core_tag_exists }}',
              r'CORE_TAG_EXISTS: ${{ steps.release.outputs.core_tag }}',
            ),
        'pub.dev requests without --max-time': (source) =>
            source.replaceAll('curl -fsSL --max-time 30 ', 'curl -fsSL '),
        'no recovery steps for a half-published companion': (source) =>
            source.replaceFirst(
              RegExp(r'^.*rerun that run.*\n', multiLine: true),
              '',
            ),
      };
      for (final mutation in mutations.entries) {
        final mutated = mutation.value(workflow);
        expect(mutated, isNot(workflow), reason: mutation.key);
        expect(
          _releaseResumeProblems(mutated),
          isNotEmpty,
          reason: mutation.key,
        );
      }
    });
  }, skip: Platform.isWindows ? _posixOnly : false);

  group('publish_companion_pubdev.yml', () {
    final workflow = _read(_companionWorkflow);

    test('publishes a copy without the checkout override', () {
      expect(_companionPublishProblems(workflow), isEmpty);
    });

    test('rejects a publish that keeps the checkout override', () {
      final mutations = <String, String Function(String)>{
        'W5 copies pubspec_overrides.yaml': (source) => source.replaceFirst(
          "            --exclude='pubspec_overrides.yaml' \\\n",
          '',
        ),
        'publishes from the checkout': (source) => source.replaceFirst(
          'run: flutter pub publish --force\n'
              r'        working-directory: ${{ runner.temp }}/pub-package',
          'run: flutter pub publish --force\n'
              r'        working-directory: ${{ steps.package.outputs.path }}',
        ),
      };
      for (final mutation in mutations.entries) {
        final mutated = mutation.value(workflow);
        expect(mutated, isNot(workflow), reason: mutation.key);
        expect(
          _companionPublishProblems(mutated),
          isNotEmpty,
          reason: mutation.key,
        );
      }
    });
  }, skip: Platform.isWindows ? _posixOnly : false);

  group('ci.yml companion publish dry-run', () {
    final workflow = _read(_ciWorkflow);

    test('resolves llamadart from this checkout', () {
      expect(_ciDryRunProblems(workflow), isEmpty);
    });

    test('rejects a dry-run without the checkout override', () {
      const override =
          "          printf 'dependency_overrides:\\n  llamadart:\\n    path: %s\\n' \\\n"
          '            "\$GITHUB_WORKSPACE" > "\$tmp_package/pubspec_overrides.yaml"\n';
      const exclude = "            --exclude='pubspec_overrides.yaml' \\\n";
      final mutations = <String, String Function(String)>{
        'W6 drops the override': (source) => source.replaceFirst(override, ''),
        'W7 keeps the checkout override in the copy': (source) => source
            .replaceFirst(override, '')
            .replaceFirst(
              "            --exclude='pubspec.lock' \\\n$exclude",
              "            --exclude='pubspec.lock' \\\n",
            ),
      };
      for (final mutation in mutations.entries) {
        final mutated = mutation.value(workflow);
        expect(mutated, isNot(workflow), reason: mutation.key);
        expect(_ciDryRunProblems(mutated), isNotEmpty, reason: mutation.key);
      }
    });
  }, skip: Platform.isWindows ? _posixOnly : false);
}
