@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

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
  }) : from = 'v$previous' {
    git(['init', '-b', 'main']);
    git(['config', 'core.autocrlf', 'false']);
    commit('Previous release', {
      'pubspec.yaml': 'name: llamadart\nversion: $previous\n',
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
      'Activate changelog collection (#1)\n\n## Changelog\nN/A: Enables maintainer tooling.',
      {
        _marker: jsonEncode({'commit': boundary, 'tag': from}),
        _root: '$_rootIntro$history',
        _docs: '$_docsIntro$history',
      },
    );
  }

  final dir = Directory.systemTemp.createTempSync('cps-changelog-git-');
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
  }) => [
    '--version',
    version,
    '--from',
    from ?? this.from,
    '--through',
    through ?? head,
    if (write) '--write',
    if (curated != null) ...['--curated', curated],
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
}) {
  final repo = _Repo(
    legacyRoot: legacyRoot,
    legacyDocs: legacyDocs,
    previous: previous,
    history: history,
  );
  addTearDown(() => repo.dir.deleteSync(recursive: true));
  return repo;
}

String _draft(String stdout) => stdout.substring(stdout.indexOf('## 0.20.3\n'));

void main() {
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
      final priorArchive = repo.file(_archive).readAsStringSync();
      await _collect(repo, repo.args(write: true));
      expect(repo.file(_root).readAsStringSync(), endsWith(_oldRelease));
      expect(
        repo.file(_archive).readAsStringSync(),
        priorArchive.replaceFirst('## 0.8.0', '$oldest## 0.8.0'),
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
      repo.pr(3, '- Draft note.');
      final through = repo.head;
      final dir = Directory.systemTemp.createTempSync('cps-reviewed-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final curated = File('${dir.path}/cps-notes.md')
        ..writeAsStringSync('- Reviewed note.\n');
      await _collect(repo, repo.args(through: through, write: true));
      await _collect(
        repo,
        repo.args(through: through, write: true, curated: curated.path),
      );
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

  test(
    'walks first parents and warns on unknown direct pushes or merge shapes',
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
      final output = await _collect(repo, repo.args(), {
        'commits/$unknown/pulls': [[]],
      });
      expect(
        output,
        contains('WARNING $unknown: no matching merged main PR association'),
      );
      expect(output, contains('WARNING $merge: unsupported main commit shape'));
      expect(output, isNot(contains('Side branch note.')));
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

  test(
    'collects one union for a rebase batch and ignores closed constituents',
    () async {
      final repo = _repo();
      final a = repo.commit('One mentions (#91) (#4)');
      final b = repo.commit('Two (#5)');
      final wrapper = _pull(
        10,
        b,
        body: '## Changelog\n- First note.\n- Second note.',
      );
      final calls = <String>[];
      final output = await _collect(repo, repo.args(), {
        'commits/$a/pulls': [
          [_pull(4, a, merged: false), wrapper],
        ],
        'commits/$b/pulls': [
          [_pull(5, b, merged: false), wrapper],
        ],
        'pulls/10': wrapper,
      }, calls);
      expect('First note.'.allMatches(_draft(output)), hasLength(1));
      expect('Second note.'.allMatches(_draft(output)), hasLength(1));
      expect(
        output,
        contains('"pr":10,"source":"api","disposition":"duplicate-pr"'),
      );
      expect(calls.where((call) => call == 'pulls/10'), hasLength(1));
      expect(calls, isNot(contains(anyOf('pulls/4', 'pulls/5'))));
    },
  );

  test('warns about a missing PR and an invalid associated body', () async {
    final repo = _repo();
    final noPr = repo.commit('Unknown change');
    final invalid = repo.commit('Unusable pull request (#4)');
    final pull = _pull(4, invalid, body: '## Changelog\n- ');
    final output = await _collect(repo, repo.args(write: true), {
      'commits/$noPr/pulls': [[]],
      'commits/$invalid/pulls': [
        [pull],
      ],
      'pulls/4': pull,
    });
    expect(
      output,
      contains('WARNING $noPr: no matching merged main PR association'),
    );
    expect(
      output,
      contains(
        'WARNING $invalid (#4): associated PR has no valid Changelog section',
      ),
    );
    expect(_draft(output), contains(_baseline));
  });

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
      final output = await _collect(repo, repo.args(write: true));
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
    'does not suppress the batch union when a member reverses a squash',
    () async {
      final repo = _repo();
      final target = repo.pr(4, '- Original feature.', {'one.txt': 'New.\n'});
      repo.file('one.txt').deleteSync();
      final a = repo.commit('One (#5)');
      final b = repo.commit('Two (#6)');
      final wrapper = _pull(
        10,
        b,
        body: 'This reverts commit $target.\n\n## Changelog\n- Batch union.',
      );
      final result = await _collect(repo, repo.args(), {
        'commits/$a/pulls': [
          [wrapper],
        ],
        'commits/$b/pulls': [
          [wrapper],
        ],
        'pulls/10': wrapper,
      });
      expect(result, contains('WARNING $a (#10)'));
      expect(_draft(result), contains('Original feature.'));
      expect(_draft(result), contains('Batch union.'));
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

  test('warns and keeps even an inverse of a rebase batch commit', () async {
    final repo = _repo();
    final a = repo.commit('One (#4)', {'one.txt': 'New.\n'});
    final b = repo.commit('Two (#5)');
    repo.file('one.txt').deleteSync();
    final revert = repo.commit(
      'Revert (#6)\n\nThis reverts commit $a.\n\n## Changelog\n- Reverted batch constituent.',
    );
    final wrapper = _pull(10, b, body: '## Changelog\n- Batch union.');
    final output = await _collect(repo, repo.args(), {
      'commits/$a/pulls': [
        [wrapper],
      ],
      'commits/$b/pulls': [
        [wrapper],
      ],
      'pulls/10': wrapper,
    });
    expect(output, contains('WARNING $revert (#6): revert of $a (target #10)'));
    expect(_draft(output), contains('Batch union.'));
    expect(_draft(output), contains('Reverted batch constituent.'));
  });
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
