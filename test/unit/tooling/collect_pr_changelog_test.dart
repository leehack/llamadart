@TestOn('vm')
@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import '../../../tool/release/collect_pr_changelog.dart';

const _root = 'CHANGELOG.md';
const _docs = 'website/docs/changelog/recent-releases.md';
const _archive = 'doc/changelog_archive.md';
const _marker = 'tool/release/changelog_pr_cutover.json';
const _rootIntro = '# Notes\n\n[Archive](doc/changelog_archive.md)\n\n';
const _docsIntro =
    '---\ntitle: Releases\n---\n\n[All releases](CHANGELOG.md)\n\n';
const _oldRelease =
    '## 0.20.2\n\n- Older note,  with spacing.\n\n'
    '## 0.19.3\n\n- Previous minor.\n\n';
const _defaultClaim =
    '- Keep the default WebGPU bridge assets at `v9.9.86` (unchanged from 0.20.2).';
const _baseline =
    'Runtime baseline: native llama.cpp `v1.0.0-2` and Web use upstream '
    '`v1.0.0@1111111111111111111111111111111111111111`; native LiteRT-LM uses '
    '`v0.19.1-5` and stable-diffusion uses `v0.4.0`. Web LiteRT-LM uses '
    '`@litert-lm/core@0.19.0`. Manifest SHA-256: '
    '`2222222222222222222222222222222222222222222222222222222222222222`.';

const _identity = {
  'GIT_AUTHOR_NAME': 'Release fixture',
  'GIT_AUTHOR_EMAIL': 'fixture@example.invalid',
  'GIT_COMMITTER_NAME': 'Release fixture',
  'GIT_COMMITTER_EMAIL': 'fixture@example.invalid',
};
const _coauthorBlock = '---------\n\nCo-authored-by: A <a@example.invalid>';
const _signoff = 'Signed-off-by: B <b@example.invalid>';

String _fixtureBridgeDefault(String tag) =>
    r'ASSETS_TAG="${WEBGPU_BRIDGE_ASSETS_TAG:-'
    '$tag'
    r'}"';

class _Repo {
  _Repo({
    String? legacyRoot,
    String? legacyDocs,
    String previous = '0.20.2',
    String history = _oldRelease,
    String activationSection = 'N/A: Enables maintainer tooling.',
    String? taggedVersion,
  }) : from = 'v$previous' {
    git(['init', '-b', 'main']);
    git(['config', 'core.autocrlf', 'false']);
    commit('Previous release', {
      'pubspec.yaml':
          'name: llamadart\nversion: ${taggedVersion ?? previous}\n',
      _root: '$_rootIntro$history',
      _docs: '$_docsIntro$history',
      _archive: '# Archive\n\n## 0.8.0\n\n- Archived.\n',
      'scripts/fetch_webgpu_bridge_assets.sh': _fixtureBridgeDefault('v9.9.86'),
      'tool/testing/check_webgpu_bridge_tag.dart': '''
const String bridgeLlamaCppTag = 'v1.0.0';
const String bridgeLlamaCppCommit = '1111111111111111111111111111111111111111';
''',
      'lib/src/hook/native_release_pins.dart': '''
const llamaCppTag = 'v1.0.0-2';
const liteRtLmReleaseTag = 'v0.19.1-5';
const stableDiffusionReleaseTag = 'v0.4.0';
''',
      'lib/src/web_setup/web_bridge_setup.dart': '''
const String webBridgeManifestSha256 =
    '2222222222222222222222222222222222222222222222222222222222222222';
''',
      'example/chat_app/web/index.html':
          'https://cdn.jsdelivr.net/npm/@litert-lm/core@0.19.0/+esm',
    });
    git(['tag', '-a', from, '-m', 'Annotated release']);
    boundary = commit('Last legacy main change', {
      _root: '$_rootIntro## Unreleased\n\n${legacyRoot ?? ''}$history',
      _docs:
          '$_docsIntro## Unreleased\n\n${legacyDocs ?? legacyRoot ?? ''}$history',
    });
    activation = commit(
      'Activate changelog collection (#1)\n\n## Changelog\n$activationSection',
      {
        _marker: jsonEncode({'commit': boundary, 'tag': from}),
        _root: '$_rootIntro$history',
        _docs: '$_docsIntro$history',
      },
    );
  }

  final dir = Directory.systemTemp.createTempSync('clpre-changelog-git-');
  final String from;
  late final String boundary;
  late final String activation;

  String get head => git(['rev-parse', 'HEAD']).trim();
  File file(String path) => File('${dir.path}/$path');
  void write(String path, String contents) {
    file(path)
      ..createSync(recursive: true)
      ..writeAsStringSync(contents);
  }

  String git(List<String> args) {
    final result = Process.runSync(
      'git',
      args,
      workingDirectory: dir.path,
      environment: _identity,
    );
    if (result.exitCode != 0) {
      throw StateError('git ${args.join(' ')}: ${result.stderr}');
    }
    return result.stdout as String;
  }

  String commit(String message, [Map<String, String> changes = const {}]) {
    changes.forEach(write);
    git(['add', '-A']);
    git(['commit', '--allow-empty', '-m', message]);
    return head;
  }

  String pr(
    int number,
    String section, [
    Map<String, String> changes = const {},
  ]) => commit('Change (#$number)\n\n## Changelog\n$section', changes);

  List<String> args({
    String version = '0.20.3',
    String? through,
    String? from,
    bool write = false,
    String? curated,
    String? verify,
    String? candidate,
    String? review,
  }) => [
    '--version',
    version,
    '--from',
    from ?? this.from,
    '--through',
    through ?? head,
    if (write) '--write',
    if (curated != null) ...['--curated', curated],
    if (verify != null) ...['--verify-input', verify],
    if (candidate != null) ...['--candidate', candidate],
    if (review != null) ...['--review', review],
  ];

  Future<ProcessResult> cli(List<String> args) => Process.run(
    Platform.resolvedExecutable,
    [File('tool/release/collect_pr_changelog.dart').absolute.path, ...args],
    workingDirectory: dir.path,
    environment: const {'GH_HOST': 'github.com'},
  );
}

_Repo _repo({
  String? legacyRoot,
  String? legacyDocs,
  String previous = '0.20.2',
  String history = _oldRelease,
  String activationSection = 'N/A: Enables maintainer tooling.',
  String? taggedVersion,
}) {
  final repo = _Repo(
    legacyRoot: legacyRoot,
    legacyDocs: legacyDocs,
    previous: previous,
    history: history,
    activationSection: activationSection,
    taggedVersion: taggedVersion,
  );
  addTearDown(() => repo.dir.deleteSync(recursive: true));
  return repo;
}

String _draft(String stdout) => stdout.substring(stdout.indexOf('## 0.20.3\n'));

String _receiptBlock(String output) => RegExp(
  r'^## Release notes input\n\nPrevious-tag: [^\n]+\nThrough: [a-f0-9]{40}\nInput-SHA256: [a-f0-9]{64}\n',
  multiLine: true,
).firstMatch(output)!.group(0)!;

Matcher _formatError(String message) => isA<FormatException>().having(
  (e) => e.message,
  'message',
  contains(message),
);

void main() {
  test('pins the committed changelog cutover tag and first parent', () {
    expect(jsonDecode(File(_marker).readAsStringSync()), {
      'tag': 'v0.20.2',
      'commit': 'adbb25f0af22e769208e43b69851e34c24a97ce5',
    });
  });

  test(
    'CLI writes both files from first-parent Git with immutable history',
    () async {
      final repo = _repo();
      repo.git(['switch', '-c', 'side']);
      repo.pr(50, '- Side history.');
      repo.git(['tag', 'v9.0.0']);
      repo.git(['switch', 'main']);
      repo.git(['tag', 'genkit_llamadart-v9.0.0']);
      repo.pr(3, '- Same note.');
      repo.commit(
        'Change mentioning (#91) (#4)\n\n## Changelog\n- Same note.\n\nSigned-off-by: Fixture <fixture@example.invalid>',
      );
      repo.pr(5, 'N/A: Test fixtures only.');
      repo.commit('docs: cut version 0.20.2', {'website/versions.json': '[]'});
      final through = repo.head;
      repo.git(['switch', '-c', 'prep']);
      repo.pr(60, '- Later change.');

      final result = await repo.cli(repo.args(through: through, write: true));
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final stdout = result.stdout as String;
      expect(stdout, contains('"pr":4'));
      expect(stdout, contains('generated-docs'));
      expect(stdout, isNot(contains('Later change.')));
      expect(stdout, isNot(contains('Side history.')));
      const section =
          '## 0.20.3\n\n- Same note.\n- Same note.\n$_defaultClaim\n\n$_baseline\n\n';
      expect(
        repo.file(_root).readAsStringSync(),
        '$_rootIntro$section$_oldRelease',
      );
      expect(
        repo.file(_docs).readAsStringSync(),
        '$_docsIntro${section.replaceFirst('Keep the default', 'Keep default')}$_oldRelease',
      );
      final rerun = await repo.cli(repo.args(through: through, write: true));
      expect(rerun.exitCode, 0, reason: '${rerun.stderr}');
      expect(
        repo.file(_root).readAsStringSync(),
        '$_rootIntro$section$_oldRelease',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  for (final (shape, receiptEnding, lineEnding, valid, rewrapped) in [
    ('no trailers', '', '\n', true, false),
    ('only a sign-off', '\n\n$_signoff', '\n', true, false),
    (
      'a GitHub co-author block',
      '\n\n$_coauthorBlock\nCo-authored-by: B <b@example.invalid>',
      '\n',
      true,
      false,
    ),
    (
      'a GitHub co-author block with blank lines',
      '\n\n$_coauthorBlock\n\nCo-authored-by: B <b@example.invalid>',
      '\n',
      true,
      false,
    ),
    (
      'a mixed-case folded co-author trailer',
      '\n\nCo-Authored-By: A\n <a@example.invalid>',
      '\n',
      true,
      false,
    ),
    (
      'CRLF and a GitHub co-author block',
      '\n\n$_coauthorBlock',
      '\r\n',
      true,
      false,
    ),
    (
      'a user separator and sign-off',
      '\n\n---------\n\n$_signoff',
      '\n',
      false,
      false,
    ),
    (
      'a user sign-off paragraph before a GitHub co-author block',
      '\n\n$_signoff\n\n$_coauthorBlock',
      '\n',
      false,
      false,
    ),
    (
      'trailing field whitespace before a GitHub co-author block',
      '  \n\n$_coauthorBlock',
      '\n',
      false,
      false,
    ),
    ('a rewrapped receipt', '', '\n', true, true),
    (
      'a rewrapped receipt and co-author block',
      '\n\n$_coauthorBlock',
      '\n',
      true,
      true,
    ),
    (
      'a rewrapped receipt and directly appended sign-off',
      '\n$_signoff',
      '\n',
      true,
      true,
    ),
  ]) {
    test('verifies the immutable prep message with $shape', () async {
      final repo = _repo();
      final through = repo.pr(3, '- Included note.');
      final preview = await _collect(repo, repo.args(write: true));
      repo.git(['add', '-A']);
      final tree = repo.git(['write-tree']).trim();
      var receipt = _receiptBlock(preview).trimRight();
      if (rewrapped) {
        receipt = receipt.replaceFirst('Input-SHA256: ', 'Input-SHA256:\n');
      }
      final message =
          'Prepare release (#10)\n\n## Changelog\nN/A: Cuts the release.\n\n'
          '$receipt$receiptEnding\n';
      final input = repo.file('.git/clact4-landed-message.md')
        ..writeAsStringSync(message.replaceAll('\n', lineEnding));
      final candidate = repo.git([
        'commit-tree',
        tree,
        '-p',
        through,
        '-F',
        input.path,
      ]).trim();
      input.writeAsStringSync(
        repo.git(['show', '-s', '--format=%B', candidate]),
      );
      final result = _collect(
        repo,
        repo.args(through: through, verify: input.path, candidate: candidate),
      );
      if (valid) {
        expect(await result, contains('Release notes input verified.'));
      } else {
        await expectLater(
          result,
          throwsA(_formatError('duplicate or malformed field')),
        );
      }
    });
  }

  test('reads the final changelog before a GitHub co-author block', () async {
    final repo = _repo();
    final commit = repo.commit(
      'Sync release (#4)\n\n## Changelog\n- Refreshed native pins.\n\n'
      '---------\n\nCo-authored-by: A <a@example.invalid>\n'
      'Co-authored-by: B <b@example.invalid>',
    );
    final output = await _collect(repo, repo.args());
    expect(
      output,
      contains(
        '"sha":"$commit","pr":4,"source":"git","disposition":"included"',
      ),
    );
    expect(_draft(output), contains('- Refreshed native pins.'));
  });

  for (final (failure, headline, message) in [
    (null, 'Prepare release (#10)', 'rewrapped'),
    ('a fenced receipt', 'Prepare release (#10)', 'fenced'),
    ('a null body', 'Prepare release (#10)', null),
    ('a null headline', null, 'rewrapped'),
    ('a wrong PR suffix', 'Prepare release (#11)', 'rewrapped'),
    ('a failed fetch', 'Prepare release (#10)', 'unavailable'),
  ]) {
    test(
      failure == null
          ? 'prep CI verifies each squash attribution variant and the GitHub message'
          : 'prep CI rejects the GitHub message with $failure',
      () async {
        final repo = _repo();
        final through = repo.pr(3, '- Included note.');
        final preview = await _collect(repo, repo.args(write: true));
        final body =
            '## Changelog\nN/A: Cuts the release.\n\n${_receiptBlock(preview)}';
        const title = 'Prepare release';
        final head = repo.commit(title, {
          'pubspec.yaml': 'name: llamadart\nversion: 0.20.3\n',
        });
        final tree = repo.git(['rev-parse', 'HEAD^{tree}']).trim();
        final merge = repo.git([
          'commit-tree',
          tree,
          '-p',
          through,
          '-p',
          head,
          '-m',
          'Test merge',
        ]).trim();
        repo.git(['checkout', '--detach', merge]);
        final event = repo.file('.git/clact4-prep-event.json');
        void setBody(String body) => event.writeAsStringSync(
          jsonEncode({
            'pull_request': {
              'number': 10,
              'title': title,
              'body': body,
              'base': {'sha': through},
              'head': {'sha': head},
            },
          }),
        );
        setBody(body);
        final script = File('tool/release/verify_release_candidate.sh');
        repo.write(script.path, script.readAsStringSync());
        final dart = File(
          'tool/release/collect_pr_changelog.dart',
        ).absolute.path;
        repo.write('.git/dart', r'''#!/usr/bin/env bash
if [[ "$1" == tool/testing/check_released_changelog_sections.dart ]]; then
  echo 'Core release prep: true'
elif [[ "$2" == tool/release/collect_pr_changelog.dart ]]; then
  shift 2
  exec "$FIXTURE_DART" "$FIXTURE_COLLECTOR" "$@"
fi
''');
        // Stands in for GitHub's viewerMergeHeadlineText and viewerMergeBodyText.
        final github = repo.file('.git/clact4-github-squash.json');
        final rewrapped = body.trimRight().replaceFirst(
          'Input-SHA256: ',
          'Input-SHA256:\n',
        );
        if (message != 'unavailable') {
          github.writeAsStringSync(
            jsonEncode({
              'data': {
                'repository': {
                  'pullRequest': {
                    'viewerMergeHeadlineText': headline,
                    'viewerMergeBodyText': switch (message) {
                      'rewrapped' => rewrapped,
                      'fenced' => rewrapped.replaceFirst(
                        '## Release notes input',
                        '```',
                      ),
                      _ => null,
                    },
                  },
                },
              },
            }),
          );
        }
        repo.write('.git/gh', r'''#!/usr/bin/env bash
[[ "$*" == "api graphql -f owner=owner -f name=repo -F number=10 -f query="* ]] || exit 64
[[ "$*" == *'viewerMergeHeadlineText(mergeType: SQUASH)'* ]] || exit 64
[[ "$*" == *'viewerMergeBodyText(mergeType: SQUASH)'* ]] || exit 64
exec cat "$FIXTURE_GITHUB_SQUASH"
''');
        final chmod = Process.runSync('chmod', [
          '+x',
          repo.file('.git/dart').path,
          repo.file('.git/gh').path,
        ]);
        expect(chmod.exitCode, 0, reason: '${chmod.stderr}');
        final workflow =
            loadYaml(
                  File('.github/workflows/pr_changelog.yml').readAsStringSync(),
                )
                as YamlMap;
        final steps = workflow['jobs']['release-prep']['steps'] as YamlList;
        final verify = steps.cast<YamlMap>().singleWhere(
          (step) =>
              step['name'] == 'Check the real PR head and tested merge result',
        );
        final env = {
          ..._identity,
          'GITHUB_EVENT_PATH': event.path,
          'RUNNER_TEMP': repo.file('.git').path,
          'PATH': '${repo.file('.git').path}:${Platform.environment['PATH']}',
          'FIXTURE_DART': Platform.resolvedExecutable,
          'FIXTURE_COLLECTOR': dart,
          'FIXTURE_GITHUB_SQUASH': github.path,
          'GITHUB_REPOSITORY': 'owner/repo',
        };
        Future<ProcessResult> run() => Process.run(
          'bash',
          ['-c', verify['run'] as String],
          workingDirectory: repo.dir.path,
          environment: env,
        );
        final result = await run();
        final verified = 'Release notes input verified.'.allMatches(
          result.stdout as String,
        );
        if (failure != null) {
          expect(
            result.exitCode,
            isNot(0),
            reason: '${result.stdout}\n${result.stderr}',
          );
          expect(verified, hasLength(4));
          if (message == 'fenced') {
            expect(
              result.stderr,
              contains("GitHub's default squash message fails verification."),
            );
          }
          return;
        }

        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        expect(verified, hasLength(5));
        final squash = repo.head;
        expect(repo.git(['show', '-s', '--format=%P', squash]).trim(), through);
        expect(repo.git(['rev-parse', 'HEAD^{tree}']).trim(), tree);
        expect(
          repo.git(['show', '-s', '--format=%B', squash]).trimRight(),
          '$title (#10)\n\n$rewrapped',
        );

        final mismatched = await run();
        expect(mismatched.exitCode, isNot(0));
        expect(mismatched.stdout, isNot(contains('Core release prep: true')));

        for (final ending in ['\n\n$_signoff\n', '  \n']) {
          repo.git(['checkout', '--detach', merge]);
          setBody('${body.trimRight()}$ending');
          final rejected = await run();
          expect(
            rejected.exitCode,
            isNot(0),
            reason: '${rejected.stdout}\n${rejected.stderr}',
          );
          expect(
            rejected.stderr,
            contains(
              'End the receipt block with no trailing attribution or whitespace.',
            ),
          );
        }
      },
      skip: Platform.isWindows ? 'Runs the Bash workflow step.' : false,
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }

  test(
    'rejects write in verification and candidate without verification',
    () async {
      final repo = _repo();
      final preview = await _collect(repo, repo.args());
      final input = repo.file('.git/clact2-receipt.md')
        ..writeAsStringSync(_receiptBlock(preview));
      for (final args in [
        repo.args(write: true, verify: input.path),
        repo.args(candidate: repo.head),
      ]) {
        await expectLater(
          _collect(repo, args),
          throwsA(_formatError('Usage:')),
        );
      }
      expect(repo.git(['status', '--porcelain']), isEmpty);
    },
  );
  test('keeps the loose-list bullet glued to a Git trailer (ADV3)', () async {
    final repo = _repo();
    final commit = repo.commit(
      'Change (#4)\n\n## Changelog\n- A note.\n\n- B note.\n'
      'Signed-off-by: X <x@example.invalid>',
    );
    final message = repo.file('message')
      ..writeAsStringSync(repo.git(['show', '-s', '--format=%B', commit]));
    expect(
      repo.git(['interpret-trailers', '--parse', '--no-divider', message.path]),
      'Signed-off-by: X <x@example.invalid>\n',
    );
    final output = await _collect(repo, repo.args());
    expect(output, contains('WARNING $commit (#4):'));
    expect(_draft(output), contains('- A note.\n- B note.'));
    expect(output, isNot(contains('Signed-off-by:')));
  });

  test(
    'removes folded Git trailers on either side of a loose bullet',
    () async {
      final repo = _repo();
      final commit = repo.commit(
        'Change (#4)\n\n## Changelog\n- A note.\n\n'
        'Signed-off-by: X <x@example.invalid>\n  Folded value.\n'
        '- B note.\nCo-authored-by:\n  Y <y@example.invalid>',
      );
      final output = await _collect(repo, repo.args());
      expect(output, contains('WARNING $commit (#4): kept non-trailer lines'));
      expect(_draft(output), contains('- A note.\n- B note.'));
      expect(output, isNot(contains('Folded value.')));
    },
  );

  for (final (kind, body) in [
    ('omitted comment', '- A note.\n\n- B note.\n# Heading'),
    ('glued heading', '- A note.'),
    ('unit separator', '- First.\n\n- Keep \x1f this.'),
    ('record separator', '- First.\n\n- Keep \x1e this.'),
  ]) {
    test('reports only the unaligned commit with $kind', () async {
      final repo = _repo();
      repo.git(['config', 'core.commentChar', '#']);
      final bad = repo.commit(
        'Change (#4)\n\n## Changelog\n$body\nSigned-off-by: X <x@example.invalid>',
      );
      final good = repo.pr(5, '- Keep the later note.');
      await expectLater(
        _collect(repo, repo.args()),
        throwsA(
          allOf([
            _formatError(
              'WARNING $bad (#4): Cannot safely separate Git trailers',
            ),
            _formatError(
              '"sha":"$bad","pr":4,"source":"git","disposition":"unresolved"',
            ),
            _formatError(
              '"sha":"$good","pr":5,"source":"git","disposition":"included"',
            ),
            _formatError('Keep the later note.'),
            isNot(_formatError('## Release notes input')),
          ]),
        ),
      );
    });
  }

  test(
    'CLI prints the incomplete ledger and exits nonzero without a receipt',
    () async {
      final repo = _repo();
      final missing = repo.commit('Unknown direct push');
      final later = repo.pr(4, '- A later valid note.');
      final result = await repo.cli(repo.args());
      expect(result.exitCode, 1);
      expect(result.stdout, contains('WARNING $missing'));
      expect(result.stdout, contains('"sha":"$later","pr":4'));
      expect(result.stdout, contains('INCOMPLETE'));
      expect(result.stdout, isNot(contains('## Release notes input')));
    },
  );

  test('warns about conflicting duplicate PR sections (ADV1)', () async {
    final repo = _repo();
    final first = repo.pr(7, '- First landing.');
    final matching = repo.commit(
      'Same section (#7)\n\n## Changelog\n- [core] First landing.',
    );
    final different = repo.commit(
      'Follow-up direct push (#7)\n\n## Changelog\n- Different follow-up note.',
    );
    final output = await _collect(repo, repo.args());
    expect(
      output,
      contains(
        'WARNING $different (#7): Changelog section differs from $first',
      ),
    );
    expect(output, isNot(contains('WARNING $matching')));
    expect('First landing.'.allMatches(_draft(output)), hasLength(1));
    expect(_draft(output), isNot(contains('Different follow-up note.')));
  });

  test(
    'issues an input receipt and independently checks all three fields',
    () async {
      final repo = _repo();
      final through = repo.pr(9, '- First note.');
      final output = await _collect(repo, repo.args());
      final receipt = _receiptBlock(output);
      final receiptFile = repo.file('.git/clpre-receipt.md');
      receiptFile.writeAsStringSync(
        '## Changelog\nN/A: Prepares the release.\n\n$receipt',
      );
      expect(
        await _collect(repo, repo.args(verify: receiptFile.path)),
        contains('Release notes input verified.'),
      );
      for (final label in ['Previous-tag', 'Through', 'Input-SHA256']) {
        receiptFile.writeAsStringSync(
          receipt.replaceFirstMapped(
            RegExp('^$label: (.*)([0-9a-f])\$', multiLine: true),
            (match) => '$label: ${match[1]}${match[2] == '0' ? '1' : '0'}',
          ),
        );
        await expectLater(
          _collect(repo, repo.args(verify: receiptFile.path)),
          throwsA(_formatError('$label does not match')),
        );
      }
      receiptFile.writeAsStringSync(receipt);
      repo.pr(10, 'N/A: Internal maintenance.');
      await expectLater(
        _collect(repo, repo.args(verify: receiptFile.path)),
        throwsA(_formatError('Through does not match')),
      );
      expect(
        await _collect(
          repo,
          repo.args(verify: receiptFile.path, through: through),
        ),
        contains('Release notes input verified.'),
      );
    },
  );

  test('hashes the golden JSONL input in order with a final LF', () async {
    final repo = _repo(legacyRoot: '- Seed café.\n\n');
    final first = repo.pr(
      4,
      '- Fixture note.\n- [packages/genkit_llamadart] Package note.',
    );
    final last = repo.pr(4, '- Different note.');
    final previous = repo.git(['rev-parse', '${repo.from}^{commit}']).trim();
    final boundary = repo.boundary;
    final activation = repo.activation;
    final golden =
        '''
{"version":"0.20.3","previousTag":"v0.20.2","previousSha":"$previous","through":"$last","cutoverTag":"v0.20.2","cutoverSha":"$boundary","activationSha":"$activation"}
{"sha":"$boundary","source":"legacy-seed","target":"core","text":"Seed café."}
{"sha":"$activation","pr":1,"source":"git","disposition":"n/a","sectionSha256":"b7f96b7b559169a4b6132b21424227f837fae1e54a3968b8b0544af97246b1de","reason":"Enables maintainer tooling."}
{"sha":"$first","pr":4,"source":"git","disposition":"included","sectionSha256":"96d99d0973a16f4f4d7722fe3aedbae3bc5de11dbf45c2cae3924aacee1e959b","bullets":[{"target":"core","text":"Fixture note."},{"target":"packages/genkit_llamadart","text":"Package note."}]}
{"sha":"$last","pr":4,"source":"git","disposition":"duplicate-pr","sectionSha256":"2315e4528f90a220599d685dbbf3ea15ebb7dceb3fe3b2b96692375ebb703156","bullets":[{"target":"core","text":"Different note."}]}
{"sha":"$last","pr":4,"reviewCode":"divergent-duplicate","reviewShas":["$first","$last"]}
''';
    final hash = sha256.convert(utf8.encode(golden));
    final expected =
        '## Release notes input\n\nPrevious-tag: v0.20.2@$previous\nThrough: $last\nInput-SHA256: $hash\n';
    for (var repeat = 0; repeat < 2; repeat++) {
      final preview = await _collect(repo, repo.args());
      expect(preview, contains(expected));
    }
    final body = repo.file('.git/clpre-digest.md')
      ..writeAsStringSync(
        '## Summary\n\n## Changelog\n- [core] Fixture note.\n- [packages/genkit_llamadart] Package note.',
      );
    final digest = await _collect(repo, ['--section-sha256', body.path]);
    expect(
      digest,
      '96d99d0973a16f4f4d7722fe3aedbae3bc5de11dbf45c2cae3924aacee1e959b\n',
    );
    body.writeAsStringSync('## Changelog\n- ');
    await expectLater(
      _collect(repo, ['--section-sha256', body.path]),
      throwsFormatException,
    );
  });

  test(
    'detects effective API changes without requiring a different core draft',
    () async {
      final repo = _repo();
      final landed = repo.commit('Missing body (#4)');
      Map<String, Object?> lookup(String body, {bool reorderedPages = false}) {
        final exact = _pull(4, landed, body: body);
        final irrelevant = _pull(91, landed, branch: 'side');
        return {
          'commits/$landed/pulls': reorderedPages
              ? [
                  [irrelevant],
                  [exact],
                ]
              : [
                  [exact],
                  [irrelevant],
                ],
          'pulls/4': exact,
        };
      }

      const core = '- Core stays the same.';
      const a = '- [packages/genkit_llamadart] First package note.';
      const b = '- [packages/genkit_llamadart] Second package note.';
      const section = '## Changelog\n$core\n$a\n$b';
      final preview = await _collect(repo, repo.args(), lookup(section));
      final reordered = await _collect(
        repo,
        repo.args(),
        lookup(section, reorderedPages: true),
      );
      expect(reordered, preview);

      final prep = repo.commit(
        'Prepare release (#10)\n\n## Changelog\nN/A: Prepares a release.\n\n${_receiptBlock(preview)}',
      );
      final input = repo.file('.git/clpre-landed-body.md')
        ..writeAsStringSync(repo.git(['show', '-s', '--format=%B', prep]));
      final command = repo.args(through: landed, verify: input.path);
      for (final changed in [
        section.replaceFirst('First package note.', 'Edited package note.'),
        section.replaceFirst(
          'packages/genkit_llamadart',
          'packages/llamadart_model_store',
        ),
        '## Changelog\n$core\n$b\n$a',
        'Reverts leehack/llamadart#123\n\n$section',
      ]) {
        final current = await _collect(
          repo,
          repo.args(through: landed),
          lookup(changed),
        );
        expect(_draft(current), _draft(preview));
        await expectLater(
          _collect(repo, command, lookup(changed)),
          throwsA(_formatError('Input-SHA256 does not match')),
        );
      }
      expect(
        await _collect(repo, command, lookup(section)),
        contains('Release notes input verified.'),
      );
    },
  );

  test(
    'requires review for both divergent duplicates and suppressed authored reverts',
    () async {
      final repo = _repo();
      final first = repo.pr(4, '- First landing.');
      final duplicate = repo.pr(4, '- Divergent note.');
      final feature = repo.pr(5, '- Added the feature.', {
        'feature.txt': 'Enabled.\n',
      });
      repo.file('feature.txt').deleteSync();
      final reversal = repo.commit(
        'Reverse a feature (#6)\n\nThis reverts commit $feature.\n\n## Changelog\n- The reversal uses a separate migration.',
      );
      final preview = await _collect(repo, repo.args());
      expect(preview, contains('The reversal uses a separate migration.'));
      expect(preview, contains('"reverts":["$feature"]'));
      expect(
        preview,
        contains(
          'exact revert of $feature suppressed authored reversal notes.',
        ),
      );
      expect(preview, contains('Divergent note.'));
      final input = repo.file('.git/clpre-review.md')
        ..writeAsStringSync(_receiptBlock(preview));
      final verify = repo.args(verify: input.path);
      final missing = _formatError(
        'missing dispositions for $first, $duplicate, $feature, $reversal',
      );
      await expectLater(_collect(repo, verify), throwsA(missing));
      await expectLater(
        _collect(repo, repo.args(write: true)),
        throwsA(missing),
      );

      input.writeAsStringSync(
        '${_receiptBlock(preview)}\n## Release notes review\n'
        '- $first Keep the first landing as the actual behavior.\n'
        '- $duplicate Omit the duplicate because it only adds fixture coverage.\n'
        '- $feature Omit the cancelled feature.\n'
        '- $reversal Keep the migration in the separate upgrade guide.\n',
      );
      expect(
        await _collect(repo, verify),
        contains('Release notes input verified.'),
      );
      expect(
        _receiptBlock(
          await _collect(repo, repo.args(write: true, review: input.path)),
        ),
        _receiptBlock(preview),
      );
    },
  );

  test('cancels an unambiguous inverse with N/A without a review', () async {
    final repo = _repo();
    final feature = repo.pr(5, '- Added the feature.', {
      'feature.txt': 'Enabled.\n',
    });
    repo.file('feature.txt').deleteSync();
    final reversal = repo.commit(
      'Reverse a feature (#6)\n\nThis reverts commit $feature.\n\n## Changelog\nN/A: Cancels the unshipped feature.',
    );
    final preview = await _collect(repo, repo.args(write: true));
    expect(
      preview,
      contains(
        '"sha":"$reversal","pr":6,"source":"git","disposition":"exact-revert"',
      ),
    );
    expect(_draft(preview), isNot(contains('Added the feature.')));
  });

  test(
    'requires a SHA-specific disposition for a removed candidate note',
    () async {
      final repo = _repo();
      final retained = repo.pr(8, '- Keep this note.');
      final source = repo.pr(9, '- Restore the missing feature.');
      final through = repo.head;
      final output = await _collect(repo, repo.args(write: true));
      final receipt = _receiptBlock(output);
      final candidate = repo.commit('Prepare release (#10)', {
        for (final path in [_root, _docs])
          path: repo
              .file(path)
              .readAsStringSync()
              .replaceFirst('- Restore the missing feature.\n', ''),
      });
      final file = repo.file('.git/clpre-receipt.md');
      final args = repo.args(
        through: through,
        verify: file.path,
        candidate: candidate,
      );
      for (final review in [
        '',
        '## Release notes review\n- ${repo.activation} Combined in the release summary.\n',
        '## Release notes review\n- $source TBD\n',
      ]) {
        file.writeAsStringSync('$receipt\n$review');
        await expectLater(_collect(repo, args), throwsA(_formatError(source)));
      }
      file.writeAsStringSync(
        '$receipt\n## Release notes review\n- $source Combined in the release summary.\n',
      );
      final result = await _collect(repo, args);
      expect(result, contains('Release notes input verified.'));
      expect(result, contains('--- generated/CHANGELOG.md'));
      expect(result, contains('\n-- Restore the missing feature.\n'));
      file.writeAsStringSync(
        '${file.readAsStringSync()}'
        '- $retained Accounted for in maintainer notes.\n',
      );
      await expectLater(
        _collect(repo, args),
        throwsA(_formatError('unrelated dispositions for $retained')),
      );
    },
  );

  test(
    'one candidate bullet cannot account for two identical sources',
    () async {
      final repo = _repo();
      final first = repo.pr(2, '- Shared wording.');
      final through = repo.pr(3, '- Shared wording.');
      final preview = await _collect(repo, repo.args(write: true));
      final candidate = repo.commit('Prepare release (#10)', {
        for (final path in [_root, _docs])
          path: repo
              .file(path)
              .readAsStringSync()
              .replaceFirst('- Shared wording.\n', ''),
      });
      final input = repo.file('.git/clact2-receipt.md')
        ..writeAsStringSync(_receiptBlock(preview));
      await expectLater(
        _collect(
          repo,
          repo.args(through: through, verify: input.path, candidate: candidate),
        ),
        throwsA(_formatError('missing dispositions for $first, $through')),
      );
    },
  );

  test('a hidden candidate bullet still requires a disposition', () async {
    final repo = _repo();
    final source = repo.pr(9, '- Restore the missing feature.');
    final draft = await _collect(repo, repo.args(write: true));
    final input = repo.file('.git/clpre-receipt.md')
      ..writeAsStringSync(_receiptBlock(draft));
    final original = {
      for (final path in [_root, _docs])
        path: repo.file(path).readAsStringSync(),
    };
    for (final (open, close) in [('~~~markdown', '~~~'), ('<!--', '-->')]) {
      final candidate = repo.commit('Prepare release (#10)', {
        for (final entry in original.entries)
          entry.key: entry.value.replaceFirst(
            '- Restore the missing feature.',
            '$open\n- Restore the missing feature.\n- Example.\n$close',
          ),
      });
      await expectLater(
        _collect(
          repo,
          repo.args(through: source, verify: input.path, candidate: candidate),
        ),
        throwsA(_formatError('missing dispositions for $source')),
      );
    }
  });

  test(
    'accepts supported native nightlies for the matching upstream family',
    () async {
      final repo = _repo();
      for (final tag in ['b1049', 'b1049-1', 'b1049-llamadart.1']) {
        repo.pr(9, 'N/A: Tests native pin inputs.', {
          'tool/testing/check_webgpu_bridge_tag.dart': repo
              .file('tool/testing/check_webgpu_bridge_tag.dart')
              .readAsStringSync()
              .replaceAll('v1.0.0', 'b1049'),
          'lib/src/hook/native_release_pins.dart':
              "const llamaCppTag = '$tag';\nconst liteRtLmReleaseTag = 'v0.19.1-5';\nconst stableDiffusionReleaseTag = 'v0.4.0';\n",
        });
        expect(
          await _collect(repo, repo.args()),
          contains('native llama.cpp `$tag` and Web use upstream `b1049@'),
        );
      }
      for (final tag in ['b01049', 'b1049-0', 'b1050-2', 'v1.0.0-2']) {
        repo.pr(9, 'N/A: Tests native pin inputs.', {
          'lib/src/hook/native_release_pins.dart':
              "const llamaCppTag = '$tag';\nconst liteRtLmReleaseTag = 'v0.19.1-5';\nconst stableDiffusionReleaseTag = 'v0.4.0';\n",
        });
        await expectLater(_collect(repo, repo.args()), throwsFormatException);
      }
    },
  );

  test('rejects an activation commit with a bullet instead of N/A', () async {
    final repo = _repo(activationSection: '- Adds a release note.');
    await expectLater(
      _collect(repo, repo.args()),
      throwsA(_formatError('introduced by its N/A activation commit')),
    );
  });

  test('rejects --from when it differs from the latest heading', () async {
    final repo = _repo(
      history: '## 0.20.4\n\n- Later release.\n\n$_oldRelease',
    );
    await expectLater(
      _collect(repo, repo.args()),
      throwsA(
        _formatError('--from does not match the latest pinned changelog'),
      ),
    );
  });

  test(
    'rejects a core tag whose version differs from the root pubspec',
    () async {
      final repo = _repo(taggedVersion: '0.20.1');
      await expectLater(
        _collect(repo, repo.args()),
        throwsA(
          _formatError('Core tag v0.20.2 disagrees with its root pubspec'),
        ),
      );
    },
  );

  test(
    'rejects shallow history even when the entire range is present',
    () async {
      final repo = _repo();
      final shallow = File('${repo.dir.path}/.git/shallow')
        ..writeAsStringSync(repo.git(['rev-parse', '${repo.from}^{commit}']));
      expect(shallow.readAsStringSync(), isNotEmpty);
      expect(repo.git(['rev-parse', '--is-shallow-repository']).trim(), 'true');
      await expectLater(
        _collect(repo, repo.args()),
        throwsA(_formatError('needs full Git history')),
      );
    },
  );

  test(
    'includes the matching legacy seed once and skips it after a newer tag',
    () async {
      final repo = _repo(legacyRoot: '- Seed note.\n  Preserve  wrapping.\n\n');
      repo.pr(3, '- First post-cutover note.');
      final first = await _collect(repo, repo.args(write: true));
      expect(_draft(first), contains('Seed note.\n  Preserve  wrapping.'));
      expect('Seed note.'.allMatches(_draft(first)), hasLength(1));
      expect(first, contains('"source":"legacy-seed"'));
      repo.commit('Release 0.20.3', {
        'pubspec.yaml': 'name: llamadart\nversion: 0.20.3\n',
      });
      repo.git(['tag', 'v0.20.3']);
      repo.pr(4, '- Next release note.');
      final second = await _collect(
        repo,
        repo.args(version: '0.20.4', from: 'v0.20.3'),
      );
      expect(second, isNot(contains('Seed note.')));
      expect(second, contains('Next release note.'));
    },
  );

  test('rejects unequal legacy seed blobs', () async {
    final repo = _repo(legacyRoot: '- First.\n\n', legacyDocs: '- Second.\n\n');
    await expectLater(
      _collect(repo, repo.args()),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('Legacy Unreleased entries differ'),
        ),
      ),
    );
  });

  test('rejects a cutover that is not the activation parent', () async {
    final repo = _repo();
    final tagCommit = repo.git(['rev-parse', '${repo.from}^{commit}']).trim();
    repo.pr(43, 'N/A: Changes the fixture.', {
      _marker: jsonEncode({'commit': tagCommit, 'tag': repo.from}),
    });
    await expectLater(_collect(repo, repo.args()), throwsFormatException);
  });

  test(
    'retains the previous published minor across a major rollover and patch gaps',
    () async {
      const headHistory =
          '## 0.20.2\r\n\r\n- Two.  \r\n\r\n'
          '## 0.20.0\n\n- Zero.\n\n';
      const tail = '## 0.18.7\n\n* Older  release.\n';
      final repo = _repo(history: '$headHistory$tail');
      await _collect(repo, repo.args(version: '1.0.0', write: true));
      final root = repo.file(_root).readAsStringSync();
      final docs = repo.file(_docs).readAsStringSync();
      expect(root, startsWith('$_rootIntro## 1.0.0\n'));
      expect(root, endsWith('$headHistory$tail'));
      expect(docs, startsWith('$_docsIntro## 1.0.0\n'));
      expect(docs, endsWith(headHistory));
    },
  );

  test(
    'only moves a whole root section to the archive when size requires it',
    () async {
      final oldest = '## 0.18.7\n\n- ${'x' * (256 * 1024)}.\n';
      final repo = _repo(history: '$_oldRelease$oldest');
      const rootPrefix = 'Releases before 0.18.7 are in the\narchive.\n\n';
      const archivePrefix =
          'Releases of `llamadart` before 0.18.7, moved verbatim from\nroot.\n\n';
      final priorArchive = repo.file(_archive).readAsStringSync();
      repo.commit(
        'Boundary wording (#10)\n\n## Changelog\nN/A: Test archive introductions.',
        {
          _root: '$rootPrefix$_oldRelease$oldest',
          _archive: priorArchive.replaceFirst('# Archive\n\n', archivePrefix),
        },
      );
      await _collect(repo, repo.args(write: true));
      final released = repo.file(_root).readAsStringSync();
      expect(released, startsWith(rootPrefix.replaceFirst('0.18.7', '0.19.3')));
      expect(released, endsWith(_oldRelease));
      expect(
        repo.file(_archive).readAsStringSync(),
        priorArchive
            .replaceFirst(
              '# Archive\n\n',
              archivePrefix.replaceFirst('0.18.7', '0.19.3'),
            )
            .replaceFirst('## 0.8.0', '$oldest## 0.8.0'),
      );
    },
  );

  test(
    'uses the pinned WebGPU update note and current runtime baseline',
    () async {
      final repo = _repo();
      repo.pr(
        3,
        '- Aligned the default WebGPU bridge assets to `v9.9.87` with a new feature.',
        {
          'scripts/fetch_webgpu_bridge_assets.sh': _fixtureBridgeDefault(
            'v9.9.87',
          ),
          'example/chat_app/web/index.html':
              'https://cdn.jsdelivr.net/npm/@litert-lm/core@0.20.0/+esm',
        },
      );
      final draft = _draft(await _collect(repo, repo.args(write: true)));
      expect('default WebGPU bridge assets'.allMatches(draft), hasLength(1));
      expect(draft, contains('with a new feature.'));
      expect(draft, contains('@litert-lm/core@0.20.0'));
      expect(
        repo.file(_docs).readAsStringSync(),
        contains('Aligned default WebGPU bridge assets'),
      );
    },
  );

  test(
    'writes reviewed canonical prose and refuses to replace it with a draft',
    () async {
      final repo = _repo();
      final through = repo.pr(3, '- Draft note.');
      final curated = repo.file('.git/clpre-curated.md')
        ..writeAsStringSync('- Reviewed note.\n');
      final review = repo.file('.git/clpre-review.md')
        ..writeAsStringSync(
          '## Release notes review\n- $through Reworded the setup note for release readers.\n',
        );
      final uncurated = await _collect(
        repo,
        repo.args(through: through, write: true),
      );
      await expectLater(
        _collect(
          repo,
          repo.args(through: through, write: true, curated: curated.path),
        ),
        throwsA(_formatError('missing dispositions for $through')),
      );
      final written = await _collect(
        repo,
        repo.args(
          through: through,
          write: true,
          curated: curated.path,
          review: review.path,
        ),
      );
      expect(_receiptBlock(written), _receiptBlock(uncurated));
      final root = repo.file(_root).readAsStringSync();
      final docs = repo.file(_docs).readAsStringSync();
      expect(root, contains('- Reviewed note.'));
      expect(docs, contains('- Reviewed note.'));
      expect(
        await _collect(repo, repo.args(through: through)),
        contains('- Draft note.'),
      );
      await expectLater(
        _collect(repo, repo.args(through: through, write: true)),
        throwsFormatException,
      );
      expect(repo.file(_root).readAsStringSync(), root);
      expect(repo.file(_docs).readAsStringSync(), docs);
    },
  );

  test('invalid second output leaves the first output unchanged', () async {
    final repo = _repo();
    final root = repo.file(_root).readAsStringSync();
    repo.write(_docs, 'Dirty docs changelog.\n');
    await expectLater(
      _collect(repo, repo.args(write: true)),
      throwsFormatException,
    );
    expect(repo.file(_root).readAsStringSync(), root);
    expect(repo.file(_docs).readAsStringSync(), 'Dirty docs changelog.\n');
  });

  test('restores the first output if replacing the second fails', () async {
    final repo = _repo();
    final root = repo.file(_root);
    final docs = repo.file(_docs);
    final priorRoot = root.readAsBytesSync();
    final priorDocs = docs.readAsBytesSync();
    final overrides = _FailSecondReplacement(docs.path, () {
      expect(root.readAsStringSync(), contains('## 0.20.3'));
      expect(docs.readAsBytesSync(), priorDocs);
    });
    await expectLater(
      IOOverrides.runWithIOOverrides(
        () => _collect(repo, repo.args(write: true)),
        overrides,
      ),
      throwsA(
        isA<FileSystemException>().having(
          (e) => e.message,
          'message',
          'Fixture refused the second replacement.',
        ),
      ),
    );
    expect(root.readAsBytesSync(), priorRoot);
    expect(docs.readAsBytesSync(), priorDocs);
  });

  test(
    'rejects every release operation for a direct push or merge and keeps later notes',
    () async {
      final repo = _repo();
      repo.git(['switch', '-c', 'side']);
      repo.pr(50, '- Side branch note.', {'side.txt': 'Side.'});
      repo.git(['switch', 'main']);
      final unknown = repo.commit('docs: cut version 0.20.2', {
        'code.dart': 'Code.',
      });
      repo.git(['merge', '--no-ff', '--no-edit', 'side']);
      final merge = repo.head;
      final good = repo.pr(51, '- Keep the later note.');
      final review = repo.file('.git/clpre-review.md')
        ..writeAsStringSync(
          '## Release notes review\n- $unknown Keep as internal maintenance.\n',
        );
      final curated = repo.file('.git/clpre-curated.md')
        ..writeAsStringSync('- Keep the later note.\n- An editorial note.\n');
      final outputs = {
        for (final path in [_root, _docs, _archive])
          path: repo.file(path).readAsBytesSync(),
      };
      for (final args in [
        repo.args(),
        repo.args(write: true),
        repo.args(write: true, curated: curated.path),
        repo.args(write: true, curated: curated.path, review: review.path),
        repo.args(verify: review.path),
      ]) {
        await expectLater(
          _collect(repo, args),
          throwsA(
            allOf([
              _formatError('WARNING $unknown: missing final PR number'),
              _formatError('WARNING $merge: unsupported main commit shape'),
              _formatError(
                '"sha":"$good","pr":51,"source":"git","disposition":"included"',
              ),
              _formatError('INCOMPLETE'),
              isNot(_formatError('Side branch note.')),
              isNot(_formatError('## Release notes input')),
            ]),
          ),
        );
      }
      for (final entry in outputs.entries) {
        expect(repo.file(entry.key).readAsBytesSync(), entry.value);
      }
      expect(repo.file('.git/cps-changelog-write.lock').existsSync(), isFalse);
    },
  );

  test(
    'uses paginated association fallback and the exact merged main PR',
    () async {
      final repo = _repo();
      final commit = repo.commit('Title with (#91) (#4)');
      final pull = _pull(4, commit, body: '## Changelog\n- Recovered note.');
      final output = await _collect(repo, repo.args(), {
        'commits/$commit/pulls': [
          [_pull(91, commit, branch: 'side')],
          [pull],
        ],
        'pulls/4': pull,
      });
      expect(
        output,
        contains('"pr":4,"source":"api","disposition":"included"'),
      );
      expect(output, contains('"sectionSha256"'));
      expect(_draft(output), contains('Recovered note.'));
    },
  );

  for (final (kind, missingFirst, missingLast, numbered, envelopeNote) in [
    (
      'planner replay with envelope N/A',
      true,
      false,
      true,
      'N/A: Contains the constituent PRs listed below.',
    ),
    (
      'first member with envelope union',
      true,
      false,
      true,
      '- Envelope union.',
    ),
    ('last member at the envelope SHA', false, true, true, '- Envelope union.'),
    ('sole member at the envelope SHA', true, true, true, '- Envelope union.'),
    ('missing anchored suffix', true, true, false, '- Envelope union.'),
  ]) {
    test('blocks batch fallback for $kind', () async {
      final repo = _repo();
      final a = missingFirst
          ? repo.commit(
              numbered ? 'One mentions (#91) (#4)' : 'One (#4) in prose',
            )
          : repo.pr(4, '- First constituent note.');
      final b = missingLast && missingFirst
          ? a
          : missingLast
          ? repo.commit('Two (#5)')
          : repo.pr(5, '- Second constituent note.');
      final bad = missingFirst ? a : b;
      final number = numbered ? (missingFirst ? 4 : 5) : null;
      final wrapper = _pull(999990, b, body: '## Changelog\n$envelopeNote');
      final calls = <String>[];
      final outputs = {
        for (final path in [_root, _docs, _archive])
          path: repo.file(path).readAsStringSync(),
      };
      final result = _collect(repo, repo.args(write: true), {
        'commits/$a/pulls': [
          [wrapper],
        ],
        'commits/$b/pulls': [
          [wrapper],
        ],
        'pulls/999990': wrapper,
      }, calls);
      await expectLater(
        result,
        throwsA(
          allOf([
            _formatError('"sha":"$bad","pr":$number'),
            _formatError('"disposition":"unresolved"'),
            if (a != b)
              _formatError(
                missingFirst
                    ? 'Second constituent note.'
                    : 'First constituent note.',
              ),
          ]),
        ),
      );
      expect(calls, isNot(contains('pulls/999990')));
      for (final entry in outputs.entries) {
        expect(repo.file(entry.key).readAsStringSync(), entry.value);
      }
    });
  }

  test(
    'renders validated constituents offline one time in their landed order',
    () async {
      final repo = _repo();
      repo.pr(4, '- First constituent note.');
      repo.pr(5, '- Second constituent note.');
      final result = await _collect(repo, repo.args());
      expect(
        _draft(result),
        startsWith(
          '## 0.20.3\n\n- First constituent note.\n- Second constituent note.\n',
        ),
      );
      expect('constituent note.'.allMatches(_draft(result)), hasLength(2));
    },
  );

  test('reports an invalid associated body as unresolved', () async {
    final repo = _repo();
    final invalid = repo.commit('Unusable pull request (#4)');
    final pull = _pull(4, invalid, body: '## Changelog\n- ');
    await expectLater(
      _collect(repo, repo.args(write: true), {
        'commits/$invalid/pulls': [
          [pull],
        ],
        'pulls/4': pull,
      }),
      throwsA(
        allOf(
          _formatError(
            'WARNING $invalid (#4): associated PR has no valid Changelog section',
          ),
          _formatError('"disposition":"unresolved"'),
        ),
      ),
    );
  });

  test('blocks a matching exact PR shared by adjacent commits', () async {
    final repo = _repo();
    final first = repo.pr(4, '- Valid member.');
    final last = repo.commit('Missing body (#5)');
    final envelope = _pull(
      5,
      last,
      body: '## Changelog\nN/A: Contains constituent PRs.',
    );
    final calls = <String>[];
    await expectLater(
      _collect(repo, repo.args(), {
        'commits/$first/pulls': [
          [envelope],
        ],
        'commits/$last/pulls': [
          [envelope],
        ],
        'pulls/5': envelope,
      }, calls),
      throwsA(_formatError('WARNING $last (#5): shared batch association')),
    );
    expect(calls, isNot(contains('pulls/5')));
  });

  test('rejects ambiguity between an exact PR and a rebase envelope', () async {
    final repo = _repo();
    final first = repo.commit('Missing body (#4)');
    final last = repo.pr(5, '- Last commit.');
    final exact = _pull(4, first, body: '## Changelog\n- Exact PR.');
    final envelope = _pull(10, last, body: '## Changelog\n- Batch PR.');
    await expectLater(
      _collect(repo, repo.args(), {
        'commits/$first/pulls': [
          [exact],
          [envelope],
        ],
        'commits/$last/pulls': [
          [envelope],
        ],
        'pulls/4': exact,
        'pulls/10': envelope,
      }),
      throwsA(
        _formatError(
          '$first (#4): ambiguous merged main PR associations (#4, #10)',
        ),
      ),
    );
  });

  test('rejects conflicting merge SHAs for the same PR across pages', () async {
    final repo = _repo();
    final commit = repo.commit('Missing body (#4)');
    final valid = _pull(4, commit, body: '## Changelog\n- Exact detail.');
    await expectLater(
      _collect(repo, repo.args(), {
        'commits/$commit/pulls': [
          [valid],
          [_pull(4, repo.activation)],
        ],
        'pulls/4': valid,
      }),
      throwsA(
        _formatError(
          '$commit (#4): PR association has conflicting merge commits',
        ),
      ),
    );
  });

  test('rejects a subject PR associated with the wrong merge SHA', () async {
    final repo = _repo();
    final commit = repo.commit('Missing body (#4)');
    final unrelated = repo.pr(5, '- Later squash.');
    await expectLater(
      _collect(repo, repo.args(), {
        'commits/$commit/pulls': [
          [_pull(4, unrelated)],
        ],
        'commits/$unrelated/pulls': [[]],
      }),
      throwsA(
        _formatError('$commit (#4): PR association has the wrong merge commit'),
      ),
    );
  });

  test(
    'ignores an envelope whose merge commit precedes the candidate',
    () async {
      final repo = _repo();
      final earlier = repo.pr(3, '- Landed earlier.');
      final commit = repo.commit('Missing body (#4)');
      final envelope = _pull(
        10,
        earlier,
        body: '## Changelog\n- Earlier batch.',
      );
      await expectLater(
        _collect(repo, repo.args(), {
          'commits/$commit/pulls': [
            [envelope],
          ],
        }),
        throwsA(
          allOf(
            _formatError('WARNING $commit (#4): no matching merged main PR'),
            isNot(_formatError('Earlier batch.')),
          ),
        ),
      );
    },
  );

  for (final mismatch in ['sha', 'repository', 'branch']) {
    test('rejects a fallback detail with the wrong $mismatch', () async {
      final repo = _repo();
      final commit = repo.commit('Missing body (#4)');
      final detail = _pull(
        4,
        mismatch == 'sha' ? repo.activation : commit,
        body: '## Changelog\n- Wrong identity.',
        repository: mismatch == 'repository'
            ? 'another/llamadart'
            : 'leehack/llamadart',
        branch: mismatch == 'branch' ? 'side' : 'main',
      );
      await expectLater(
        _collect(repo, repo.args(), {
          'commits/$commit/pulls': [
            [_pull(4, commit)],
          ],
          'pulls/4': detail,
        }),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('$commit (#4): PR detail conflicts'),
          ),
        ),
      );
    });
  }

  test(
    'fails with commit identity on GitHub errors or truncated pages',
    () async {
      final repo = _repo();
      final commit = repo.commit('Missing body (#4)');
      for (final result in [
        const HttpException('rate limited'),
        [[], 'truncated'],
      ]) {
        await expectLater(
          _collect(repo, repo.args(), {'commits/$commit/pulls': result}),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('$commit (#4)'),
            ),
          ),
        );
      }
    },
  );

  for (final kind in ['exact', 'partial', 'extra']) {
    test('$kind revert has the right disposition', () async {
      final repo = _repo();
      repo.pr(3, '- Context.', {'one.txt': 'Old.\n', 'two.txt': 'Old.\n'});
      final target = repo.pr(4, '- Original feature.', {
        'one.txt': 'New.\n',
        'two.txt': 'New.\n',
      });
      final revert = repo.commit(
        'Reverse part or all (#5)\n\n## Changelog\n- Reversal note.\n\nReverts-Commit: $target',
        {
          'one.txt': 'Old.\n',
          if (kind != 'partial') 'two.txt': 'Old.\n',
          if (kind == 'extra') 'other.txt': 'Extra.\n',
        },
      );
      final output = await _collect(repo, repo.args());
      final draft = _draft(output);
      if (kind == 'exact') {
        expect(draft, isNot(contains('Original feature.')));
        expect(draft, isNot(contains('Reversal note.')));
        expect(output, contains('"disposition":"exact-revert"'));
        expect(output, contains('"disposition":"reverted"'));
      } else {
        expect(draft, contains('Original feature.'));
        expect(draft, contains('Reversal note.'));
        expect(
          output,
          contains('WARNING $revert (#5): revert of $target (target #4)'),
        );
      }
    });
  }

  test('keeps all notes when an exact revert has another bullet', () async {
    final repo = _repo();
    final target = repo.pr(4, '- Original feature.', {'one.txt': 'New.\n'});
    repo.file('one.txt').deleteSync();
    final revert = repo.commit(
      'Revert (#5)\n\nThis reverts commit $target.\n\n## Changelog\n'
      '- Reverted feature.\n- Separate user-visible effect.',
    );
    final result = await _collect(repo, repo.args());
    expect(result, contains('WARNING $revert (#5)'));
    expect(_draft(result), contains('Original feature.'));
    expect(_draft(result), contains('Separate user-visible effect.'));
  });

  test('warns and keeps both notes for a GitHub UI revert (ADV6)', () async {
    final repo = _repo();
    final original = repo.pr(4, '- Original feature.', {'one.txt': 'New.\n'});
    repo.file('one.txt').deleteSync();
    final revert = repo.commit(
      'Revert "Change (#4)" (#5)\n\nReverts leehack/llamadart#4\n\n'
      '## Changelog\n- Reverted feature.',
    );
    final output = await _collect(repo, repo.args());
    expect(
      output,
      contains('WARNING $revert (#5): GitHub revert of leehack/llamadart#4'),
    );
    expect(
      _draft(output),
      contains('- Original feature.\n- Reverted feature.'),
    );
    final jsonLines = const LineSplitter().convert(output);
    final previous = repo.git(['rev-parse', '${repo.from}^{commit}']).trim();
    final canonical = [
      jsonEncode({
        'version': '0.20.3',
        'previousTag': repo.from,
        'previousSha': previous,
        'through': revert,
        'cutoverTag': repo.from,
        'cutoverSha': repo.boundary,
        'activationSha': repo.activation,
      }),
      ...jsonLines.where((line) => line.startsWith('{')),
      jsonEncode({
        'sha': revert,
        'pr': 5,
        'reviewCode': 'github-revert',
        'reviewShas': [revert, original],
        'reference': 'leehack/llamadart#4',
      }),
    ];
    final digest = sha256.convert(utf8.encode('${canonical.join('\n')}\n'));
    expect(_receiptBlock(output), contains('Input-SHA256: $digest'));
  });

  test('keeps the chain for a partial revert of a revert', () async {
    final repo = _repo();
    final target = repo.pr(4, '- Original feature.', {
      'one.txt': 'First.\n',
      'two.txt': 'Second.\n',
    });
    repo.file('one.txt').deleteSync();
    repo.file('two.txt').deleteSync();
    final reversal = repo.commit(
      'Revert (#5)\n\nThis reverts commit $target.\n\n## Changelog\n- Reverted feature.',
    );
    final partial = repo.commit(
      'Partly restore (#6)\n\nThis reverts commit $reversal.\n\n## Changelog\n- Partly restored feature.',
      {'one.txt': 'First.\n'},
    );
    final result = await _collect(repo, repo.args());
    expect(result, contains('WARNING $partial (#6)'));
    expect(_draft(result), contains('Original feature.'));
    expect(_draft(result), contains('Reverted feature.'));
    expect(_draft(result), contains('Partly restored feature.'));
  });

  test(
    'keeps both notes when only the API body claims an exact inverse',
    () async {
      final repo = _repo();
      final target = repo.pr(4, '- Original feature.', {'one.txt': 'New.\n'});
      repo.file('one.txt').deleteSync();
      final revert = repo.commit('Reverse a feature (#5)');
      final pull = _pull(
        5,
        revert,
        body:
            'This reverts commit $target.\n\n## Changelog\n- Revert the feature.',
      );
      final result = await _collect(repo, repo.args(), {
        'commits/$target/pulls': [
          [_pull(4, target)],
        ],
        'commits/$revert/pulls': [
          [pull],
        ],
        'pulls/5': pull,
      });
      expect(result, contains('WARNING $revert (#5): revert of $target'));
      expect(_draft(result), contains('Original feature.'));
      expect(_draft(result), contains('Revert the feature.'));
    },
  );

  test('revert of an exact revert restores the original once', () async {
    final repo = _repo();
    final target = repo.pr(4, '- Original feature.', {'one.txt': 'New.\n'});
    repo.file('one.txt').deleteSync();
    final reversal = repo.commit(
      'Revert (#5)\n\nThis reverts commit $target.\n\n## Changelog\n- Reverted feature.',
    );
    repo.commit(
      'Restore (#6)\n\nThis reverts commit $reversal.\n\n## Changelog\n- Restored feature.',
      {'one.txt': 'New.\n'},
    );
    final draft = _draft(await _collect(repo, repo.args()));
    expect('Original feature.'.allMatches(draft), hasLength(1));
    expect(draft, isNot(contains('Reverted feature.')));
    expect(draft, isNot(contains('Restored feature.')));
  });

  test(
    'keeps reversals of shipped notes and does not infer a revert from a subject',
    () async {
      final repo = _repo();
      final shipped = repo.git(['rev-parse', '${repo.from}^{commit}']).trim();
      repo.commit(
        'Revert shipped change (#4)\n\nThis reverts commit $shipped.\n\n## Changelog\n- Reversed a shipped change.',
      );
      repo.commit('Revert (#5)\n\n## Changelog\n- Ordinary note.');
      final draft = _draft(await _collect(repo, repo.args()));
      expect(draft, contains('Reversed a shipped change.'));
      expect(draft, contains('Ordinary note.'));
    },
  );

  test('an inverse does not account for a missing batch member', () async {
    final repo = _repo();
    final a = repo.commit('One (#4)', {'one.txt': 'New.\n'});
    final b = repo.commit('Two (#5)');
    repo.file('one.txt').deleteSync();
    final revert = repo.commit(
      'Revert (#6)\n\nThis reverts commit $a.\n\n## Changelog\n- Reverted batch constituent.',
    );
    final wrapper = _pull(10, b, body: '## Changelog\n- Batch union.');
    await expectLater(
      _collect(repo, repo.args(), {
        'commits/$a/pulls': [
          [wrapper],
        ],
        'commits/$b/pulls': [
          [wrapper],
        ],
        'pulls/10': wrapper,
      }),
      throwsA(
        allOf([
          _formatError('WARNING $a (#4): no matching merged main PR'),
          _formatError('WARNING $revert (#6): revert of $a (target #4)'),
          _formatError('Reverted batch constituent.'),
          isNot(_formatError('Batch union.')),
        ]),
      ),
    );
  });
}

final class _FailSecondReplacement extends IOOverrides {
  _FailSecondReplacement(this.destination, this.beforeFailure);

  final String destination;
  final void Function() beforeFailure;

  @override
  File createFile(String path) {
    final file = super.createFile(path);
    return file.uri.pathSegments.last == 'next'
        ? _StagedFile(file, destination, beforeFailure)
        : file;
  }
}

class _StagedFile implements File {
  _StagedFile(this.file, this.destination, this.beforeFailure);

  final File file;
  final String destination;
  final void Function() beforeFailure;

  @override
  void writeAsStringSync(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) => file.writeAsStringSync(
    contents,
    mode: mode,
    encoding: encoding,
    flush: flush,
  );

  @override
  File renameSync(String newPath) {
    if (newPath == destination) {
      beforeFailure();
      throw const FileSystemException(
        'Fixture refused the second replacement.',
      );
    }
    return file.renameSync(newPath);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<String> _collect(
  _Repo repo,
  List<String> arguments, [
  Map<String, Object?> responses = const {},
  List<String>? calls,
]) => runPrChangelogCollector(
  arguments,
  directory: repo.dir,
  lookup: (path, {required paginate}) async {
    final endpoint = path.substring('repos/leehack/llamadart/'.length);
    expect(paginate, endpoint.startsWith('commits/'));
    calls?.add(endpoint);
    expect(
      responses,
      contains(endpoint),
      reason: 'Unexpected GitHub lookup: $endpoint',
    );
    final response = responses[endpoint];
    if (response is Exception) throw response;
    return response;
  },
);

Map<String, Object?> _pull(
  int number,
  String sha, {
  String? body,
  bool merged = true,
  String branch = 'main',
  String repository = 'leehack/llamadart',
}) => {
  'number': number,
  'merge_commit_sha': sha,
  'merged_at': merged ? '2026-11-19T00:00:00Z' : null,
  'base': {
    'ref': branch,
    'repo': {'full_name': repository},
  },
  'head': {
    'repo': {'full_name': 'fork/llamadart'},
  },
  'body': body,
};
