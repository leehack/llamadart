@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../../tool/testing/check_released_changelog_sections.dart';

const _notFound = '{"error":{"code":"NotFound"}}';
const _repoName = 'leehack/llamadart';
const _root = 'CHANGELOG.md';
const _docs = 'website/docs/changelog/recent-releases.md';
const _published = '## 1.2.3\n\n- Shipped.\n\n## 1.1.2\n\n- Older.\n';
const _archive = '## 1.0.0\n\n- Archived.\n';
const _new = '## 1.2.4\n\n- New.\n\n';
const _marker =
    '{"tag":"v1.2.3","commit":"1111111111111111111111111111111111111111"}';

const _pending = '## Unreleased\n\n- Seed.\n\n';
const _legacyDescription =
    'This page keeps the unreleased changes and the current and previous minor.\n\n';
const _legacyAttributes = """
# Other attributes
# Keep both sides' `## Unreleased` bullets in local merges and rebases. Union
# keeps both sides of any conflicting edit too, so resolve release-prep edits
# by hand (see website/docs/maintainers/release-workflow.md).
/CHANGELOG.md merge=union
/website/docs/changelog/recent-releases.md merge=union

""";

class _Repo {
  _Repo({bool activated = true}) {
    git(['init', '-q', '-b', 'main']);
    base = commit({
      _root: '# Releases\n\n$_published',
      _docs: _published,
      changelogArchive: _archive,
      if (activated) changelogCutover: _marker,
      'pubspec.yaml': 'name: llamadart\nversion: 1.2.3\n',
      'packages/genkit_llamadart/file.txt': 'genkit\n',
    });
    if (!activated) {
      git(['tag', 'v1.2.3']);
      base = commit({
        _root: '# Releases\n\n$_pending$_published',
        _docs: '$_legacyDescription$_pending$_published',
        '.gitattributes': _legacyAttributes,
      });
    }
  }

  final root = Directory.systemTemp.createTempSync('clact2-policy-');
  late String base;

  String git(List<String> args) {
    final result = Process.runSync(
      'git',
      ['-c', 'commit.gpgsign=false', '-c', 'core.autocrlf=false', ...args],
      workingDirectory: root.path,
      environment: {
        'GIT_AUTHOR_NAME': 'Fixture',
        'GIT_AUTHOR_EMAIL': 'fixture@example.invalid',
        'GIT_COMMITTER_NAME': 'Fixture',
        'GIT_COMMITTER_EMAIL': 'fixture@example.invalid',
      },
    );
    if (result.exitCode != 0) fail('git ${args.join(' ')}: ${result.stderr}');
    return (result.stdout as String).trim();
  }

  File file(String name) => File('${root.path}/$name');

  String commit(Map<String, String> changes) {
    for (final entry in changes.entries) {
      file(entry.key)
        ..createSync(recursive: true)
        ..writeAsStringSync(entry.value);
    }
    git(['add', '-A']);
    git(['commit', '-qm', 'Fixture', '--allow-empty']);
    return git(['rev-parse', 'HEAD']);
  }

  String prep({
    String version = '1.2.4',
    Map<String, String> edits = const {},
  }) {
    final notes = '## $version\n\n- New.\n\n$_published';
    return commit({
      'pubspec.yaml': 'name: llamadart\nversion: $version\n',
      _root: '# Releases\n\n$notes',
      _docs: notes,
      ...edits,
    });
  }

  Future<List<String>> check(
    String head, {
    bool prep = false,
    String repo = _repoName,
    String? eventBase,
    void Function(String)? log,
    GithubLookup? lookup,
    RecoveryTagLookup? tags,
    RecoveryPubGet? pub,
    String? proposedMerge,
    String baseRef = 'main',
    String headRef = 'fixture',
  }) {
    final event = {
      'pull_request': {
        'base': {'sha': eventBase ?? base, 'ref': baseRef},
        'head': {
          'sha': head,
          'ref': headRef,
          'repo': {'full_name': repo},
        },
        'labels': [
          if (prep) {'name': 'release-prep'},
        ],
      },
    };
    return checkReleasedChangelogSections(
      root,
      event,
      repository: _repoName,
      log: log,
      lookup:
          lookup ??
          ((_, {required paginate}) => fail("Unexpected GitHub lookup")),
      tags: tags ?? ((_) => fail("Unexpected tag lookup")),
      pub: pub ?? ((_) => fail("Unexpected pub.dev lookup")),
      proposedMerge: proposedMerge,
    );
  }
}

class _RecoveryFixture {
  _RecoveryFixture(
    this.repo, {
    this.version = '1.2.4',
    this.baseRef = 'main',
    Map<String, String> prepEdits = const {},
    Map<String, String> beforeEdits = const {},
    Map<String, String> publishedEdits = const {},
    bool twoParents = false,
  }) {
    if (baseRef != 'main') repo.git(['switch', '-c', baseRef]);
    if (publishedEdits.isNotEmpty) repo.base = repo.commit(publishedEdits);
    repo.git(['tag', 'v1.2.3']);
    remote = Directory.systemTemp.createTempSync('w2117-remote-');
    addTearDown(() => remote.deleteSync(recursive: true));
    repo.git(['init', '--bare', remote.path]);
    original = repo.base;
    tag('v1.2.3', original);
    before = repo.commit({'ordinary.txt': 'keep this\n', ...beforeEdits});
    final single = repo.prep(
      version: version,
      edits: {'README.md': 'attempt\n', ...prepEdits},
    );
    prep = twoParents
        ? repo.git([
            'commit-tree',
            '$single^{tree}',
            '-p',
            before,
            '-p',
            original,
            '-m',
            'Two-parent prep',
          ])
        : single;
    if (twoParents) repo.git(['checkout', '--detach', prep]);
    repo.base = repo.commit({'later.txt': 'also keep this\n'});
  }

  final _Repo repo;
  final String version;
  final String baseRef;
  late final Directory remote;
  late final String original;
  late final String before;
  late final String prep;
  String get path => 'tool/release/recoveries/$prep.json';

  void tag(String name, String sha) {
    repo.git([
      '--git-dir=${remote.path}',
      'fetch',
      '--no-tags',
      repo.root.path,
      sha,
    ]);
    repo.git([
      '--git-dir=${remote.path}',
      'update-ref',
      'refs/tags/$name',
      sha,
    ]);
  }

  Map<String, Object> pullDetail({String? headRef, String? pullBase}) => {
    'number': 42,
    'merged': true,
    'merge_commit_sha': prep,
    'head': {
      'ref': headRef ?? 'release/prep-$version',
      'repo': {'full_name': _repoName},
    },
    'base': {
      'ref': pullBase ?? baseRef,
      'sha': original,
      'repo': {'full_name': _repoName},
    },
  };

  Map<String, Object> activity(String tip, {int id = 10}) => {
    'id': id,
    'ref': 'refs/heads/$baseRef',
    'activity_type': 'pr_merge',
    'before': tip,
    'after': prep,
  };

  String record({String? markerVersion, String? markerBefore}) =>
      '${jsonEncode({'version': markerVersion ?? version, 'prep': prep, 'before': markerBefore ?? before, 'pr': 42})}\n';

  String recovery({
    String? markerBefore,
    String? recordPath,
    String? recordContents,
    bool wider = false,
    Map<String, String> edits = const {},
  }) {
    repo.git(['checkout', '--detach', repo.base]);
    final parents = repo
        .git(['rev-list', '--parents', '-n', '1', prep])
        .split(' ');
    repo.git([
      'revert',
      '--no-commit',
      if (parents.length > 2) ...['-m', '1'],
      prep,
    ]);
    if (wider) repo.git(['rm', 'ordinary.txt']);
    return repo.commit({
      (recordPath ?? path):
          recordContents ?? record(markerBefore: markerBefore),
      ...edits,
    });
  }

  Future<List<String>> check(
    String head, {
    Object? pages,
    Map<String, Object>? pull,
    List<Map<String, Object>>? timeline,
    Object? releases,
    RecoveryPubGet? pub,
    String? eventBase,
    String? proposedMerge,
    bool routed = false,
    String repository = _repoName,
    bool failActivity = false,
  }) => repo.check(
    head,
    repo: repository,
    prep: routed,
    eventBase: eventBase,
    baseRef: baseRef,
    proposedMerge:
        proposedMerge ??
        repo.git([
          'commit-tree',
          '$head^{tree}',
          '-p',
          eventBase ?? repo.base,
          '-p',
          head,
          '-m',
          'Proposed recovery',
        ]),
    lookup: (endpoint, {required paginate}) async {
      if (endpoint == 'repos/$_repoName/pulls/42') {
        expect(paginate, isFalse);
        return pull ?? pullDetail();
      }
      if (endpoint == 'repos/$_repoName/issues/42/timeline?per_page=100' &&
          timeline != null) {
        expect(paginate, isTrue);
        return [timeline];
      }
      if (endpoint.startsWith('repos/$_repoName/activity?')) {
        expect(paginate, isTrue);
        final encodedRef = Uri.encodeQueryComponent('refs/heads/$baseRef');
        expect(
          endpoint,
          'repos/$_repoName/activity?ref=$encodedRef&activity_type=pr_merge&per_page=100',
        );
        if (failActivity) throw const FormatException('GitHub read failed.');
        return pages ??
            [
              [activity(before)],
            ];
      }
      if (endpoint == 'repos/$_repoName/releases?per_page=100') {
        expect(paginate, isTrue);
        return releases ?? [<Object>[]];
      }
      fail('Unexpected endpoint $endpoint');
    },
    tags: (refs) async =>
        repo.git(['ls-remote', '--tags', remote.path, ...refs]),
    pub: pub ?? ((_) async => (status: 404, body: _notFound)),
  );
}

void main() {
  late _Repo repo;
  setUp(() => repo = _Repo());
  tearDown(() => repo.root.deleteSync(recursive: true));

  test(
    'an exact unpublished prep recovery preserves ordinary main work',
    () async {
      final fixture = _RecoveryFixture(repo, prepEdits: {_root: 'malformed\n'});
      final head = fixture.recovery();
      expect(await fixture.check(head), isEmpty);
      expect(await fixture.check(head), isEmpty);
      expect(repo.file('ordinary.txt').readAsStringSync(), 'keep this\n');
      expect(repo.file('later.txt').readAsStringSync(), 'also keep this\n');
      expect(await fixture.check(head, proposedMerge: head), [
        contains('tested merge'),
      ]);
      expect(await fixture.check(head, routed: true), [
        contains('ordinary same-repository'),
      ]);
      expect(await fixture.check(head, repository: 'fork/repo'), [
        contains('ordinary same-repository'),
      ]);
      expect(checkReleasePrepTrees(repo.root, repo.base, head), [
        contains('preserve all'),
      ]);
    },
  );

  test('proves unpublished recovery on the matching patch base', () async {
    final fixture = _RecoveryFixture(repo, baseRef: 'release/1.2.x');
    final head = fixture.recovery();
    expect(await fixture.check(head), isEmpty);
    expect(
      await fixture.check(head, pull: fixture.pullDetail(pullBase: 'main')),
      [contains('same-repository release/1.2.x prep')],
    );
    final wrongActivity = fixture.activity(fixture.before)
      ..['ref'] = 'refs/heads/main';
    expect(
      await fixture.check(
        head,
        pages: [
          [wrongActivity],
        ],
      ),
      [contains('Malformed GitHub release/1.2.x merge activity')],
    );
  });

  for (final (baseRef, version) in [
    ('release/1.3.x', '1.2.4'),
    ('release/1.2.x', '1.2.0'),
    ('release/1.2-prep', '1.2.4'),
  ]) {
    test('recovery rejects $version on $baseRef', () async {
      final fixture = _RecoveryFixture(
        repo,
        baseRef: baseRef,
        version: version,
      );
      expect(await fixture.check(fixture.recovery()), [
        contains(
          'Recovery version $version does not match the patch base $baseRef',
        ),
      ]);
    });
  }

  test(
    'recovery marker version must match the attempted core version',
    () async {
      final fixture = _RecoveryFixture(repo);
      final head = fixture.recovery(
        recordContents: fixture.record(markerVersion: '1.2.5'),
      );
      expect(await fixture.check(head), [
        contains('attempted stable core version'),
      ]);
    },
  );

  test('recovery record path must use the full prep SHA', () async {
    final fixture = _RecoveryFixture(repo);
    for (final path in [
      'tool/release/recoveries/${fixture.before}.json',
      'tool/release/recoveries/nested/${fixture.prep}.json',
      'tool/release/recoveries/${fixture.prep}.JSON',
      'tool/release/recoveries/${fixture.prep}',
    ]) {
      final head = fixture.recovery(recordPath: path);
      expect(await fixture.check(head), [
        contains('Invalid canonical'),
      ], reason: path);
    }
  });

  test('recovery record bytes must be canonical', () async {
    final fixture = _RecoveryFixture(repo);
    final canonical = fixture.record();
    final fields = jsonDecode(canonical) as Map<String, dynamic>;
    final variants = {
      'pretty-printed':
          '${const JsonEncoder.withIndent(' ').convert(fields)}\n',
      'reordered': '${jsonEncode({'prep': fields['prep'], ...fields})}\n',
      'missing newline': canonical.trimRight(),
      'CRLF': '${canonical.trimRight()}\r\n',
      'duplicate key': '{"version":"9.9.9",${canonical.substring(1)}',
      'extra key': '${jsonEncode({...fields, 'extra': 1})}\n',
      'uppercase SHA':
          '${jsonEncode({...fields, 'before': fixture.before.toUpperCase()})}\n',
      'string PR': '${jsonEncode({...fields, 'pr': '42'})}\n',
      'zero PR': '${jsonEncode({...fields, 'pr': 0})}\n',
      'prerelease version': fixture.record(markerVersion: '1.2.4-dev'),
    };
    expect(await fixture.check(fixture.recovery()), isEmpty);
    for (final entry in variants.entries) {
      final head = fixture.recovery(recordContents: entry.value);
      expect(await fixture.check(head), [
        contains('Invalid canonical'),
      ], reason: entry.key);
    }
  });

  test('a prep that decreases the core version cannot be recovered', () async {
    final fixture = _RecoveryFixture(repo, version: '1.2.2');
    expect(await fixture.check(fixture.recovery()), [
      contains('attempted stable core version increase'),
    ]);
  });

  test(
    'label-routed recovery requires release-prep at the merge event',
    () async {
      final fixture = _RecoveryFixture(repo);
      final head = fixture.recovery();
      final pull = fixture.pullDetail(headRef: 'custom-prep');
      const label = {'name': 'release-prep'};
      const labeled = {'event': 'labeled', 'label': label};
      const unlabeled = {'event': 'unlabeled', 'label': label};
      final merged = {'event': 'merged', 'commit_id': fixture.prep};
      expect(
        await fixture.check(
          head,
          pull: pull,
          timeline: [labeled, merged, unlabeled],
        ),
        isEmpty,
      );
      for (final timeline in [
        [merged, labeled],
        [labeled, unlabeled, merged],
        [labeled],
      ]) {
        expect(await fixture.check(head, pull: pull, timeline: timeline), [
          contains('outside core prep routing at merge'),
        ], reason: '$timeline');
      }
      expect(
        await fixture.check(
          head,
          pull: pull,
          timeline: [labeled, merged, merged],
        ),
        [contains('Conflicting merged events')],
      );
    },
  );

  test(
    'a Genkit prep branch cannot recover as core even with the core label',
    () async {
      final fixture = _RecoveryFixture(repo);
      final head = fixture.recovery();
      expect(
        await fixture.check(
          head,
          pull: fixture.pullDetail(
            headRef: 'release/genkit_llamadart-prep-1.2.4',
          ),
          timeline: [
            {
              'event': 'labeled',
              'label': {'name': 'release-prep'},
            },
            {'event': 'merged', 'commit_id': fixture.prep},
          ],
        ),
        [contains('does not identify the same-repository main prep')],
      );
    },
  );

  test(
    'both exact inverses cannot substitute for the GitHub boundary',
    () async {
      final fixture = _RecoveryFixture(repo);
      final narrow = fixture.recovery();
      final wide = fixture.recovery(
        markerBefore: fixture.original,
        wider: true,
      );
      expect(await fixture.check(narrow), isEmpty);
      expect(await fixture.check(wide), [contains('prove one main commit')]);
      final rebase = [
        [fixture.activity(fixture.original)],
      ];
      expect(await fixture.check(narrow, pages: rebase), [
        contains('prove one main commit'),
      ]);
      expect(await fixture.check(wide, pages: rebase), [
        contains('prove one main commit'),
      ]);
    },
  );

  test(
    'rejects both claimed boundaries of a four-commit update like #2030',
    () async {
      repo.git(['tag', 'v1.2.3']);
      final original = repo.base;
      repo.commit({'first': 'ab\n'});
      repo.commit({'second': 'cd\n'});
      final parent = repo.commit({'third': 'ef\n'});
      final prep = repo.prep();
      repo.base = prep;
      final recoveryPath = 'tool/release/recoveries/$prep.json';
      for (final before in [original, parent]) {
        repo.git(['checkout', '--detach', prep]);
        repo.git([
          'restore',
          '--staged',
          '--worktree',
          '--source=$before',
          '.',
        ]);
        final head = repo.commit({
          recoveryPath:
              '${jsonEncode({'version': '1.2.4', 'prep': prep, 'before': before, 'pr': 2030})}\n',
        });
        final proposed = repo.git([
          'commit-tree',
          '$head^{tree}',
          '-p',
          prep,
          '-p',
          head,
          '-m',
          'Recovery',
        ]);
        final problems = await repo.check(
          head,
          proposedMerge: proposed,
          lookup: (endpoint, {required paginate}) async {
            if (!paginate) {
              return {
                'number': 2030,
                'merged': true,
                'merge_commit_sha': prep,
                'base': {
                  'ref': 'main',
                  'repo': {'full_name': _repoName},
                },
                'head': {
                  'ref': 'release/prep-1.2.4',
                  'repo': {'full_name': _repoName},
                },
              };
            }
            return [
              [
                {
                  'id': 50596625102,
                  'ref': 'refs/heads/main',
                  'activity_type': 'pr_merge',
                  'before': original,
                  'after': prep,
                },
              ],
            ];
          },
        );
        expect(problems, [contains('prove one main commit')]);
      }
    },
  );

  test(
    'rejects missing, malformed, conflicting or failed GitHub activity',
    () async {
      final fixture = _RecoveryFixture(repo);
      final head = fixture.recovery();
      for (final pages in [
        [[]],
        [],
        [
          [fixture.activity(fixture.before)],
          null,
        ],
        [
          [
            fixture.activity(fixture.before),
            fixture.activity(fixture.before, id: 11),
          ],
        ],
        [
          [
            {...fixture.activity(fixture.before), 'ref': 'refs/heads/other'},
          ],
        ],
        [
          [
            {...fixture.activity(fixture.before), 'activity_type': 'push'},
          ],
        ],
      ]) {
        expect(await fixture.check(head, pages: pages), isNotEmpty);
      }
      expect(await fixture.check(head, failActivity: true), [
        contains('GitHub read failed'),
      ]);
      expect(
        await fixture.check(
          head,
          pull: {...fixture.pullDetail(), 'number': 43},
        ),
        [contains('identify')],
      );
    },
  );

  test('a recorded two-parent main update cannot be recovered', () async {
    final fixture = _RecoveryFixture(repo, twoParents: true);
    expect(await fixture.check(fixture.recovery()), [
      contains('prove one main commit'),
    ]);
  });

  test('requires previous release ancestry and numbered bytes', () async {
    final fixture = _RecoveryFixture(
      repo,
      beforeEdits: {_root: _published.replaceFirst('Shipped.', 'Changed.')},
    );
    final head = fixture.recovery();
    expect(await fixture.check(head), [contains('previous published history')]);
    repo.git(['tag', '-f', 'v1.2.3', head]);
    fixture.tag('v1.2.3', head);
    expect(await fixture.check(head), [
      contains('pre-prep first-parent chain'),
    ]);
  });

  test(
    'recovery requires the owner tag to match the previous release',
    () async {
      final fixture = _RecoveryFixture(repo);
      final head = fixture.recovery();
      expect(await fixture.check(head), isEmpty);

      fixture.tag('v1.2.3', fixture.before);
      expect(await fixture.check(head), [
        contains('disagrees with the previous release'),
      ]);

      repo.git([
        '--git-dir=${fixture.remote.path}',
        'update-ref',
        '-d',
        'refs/tags/v1.2.3',
      ]);
      expect(await fixture.check(head), [
        contains('disagrees with the previous release'),
      ]);
    },
  );

  test(
    'the authenticated prep must still be on current first-parent main',
    () async {
      final fixture = _RecoveryFixture(repo);
      final lookalike = repo.git([
        'commit-tree',
        '${fixture.prep}^{tree}',
        '-p',
        fixture.before,
        '-m',
        'Lookalike',
      ]);
      repo.base = lookalike;
      expect(await fixture.check(fixture.recovery()), [
        contains('prove one main commit'),
      ]);
    },
  );

  test(
    'records are permanent and only one recovery per version can land',
    () async {
      final fixture = _RecoveryFixture(repo);
      final valid = fixture.recovery();
      expect(await fixture.check(valid), isEmpty);
      final persisted = repo.file(fixture.path).readAsStringSync();
      final second = repo.prep();
      repo.base = second;
      repo.git(['revert', '--no-commit', second]);
      final secondRecovery = repo.commit({
        'tool/release/recoveries/$second.json':
            '${jsonEncode({'version': '1.2.4', 'prep': second, 'before': valid, 'pr': 43})}\n',
      });
      expect(await fixture.check(secondRecovery), [
        contains('already has a consumed recovery'),
      ]);

      repo.base = valid;
      repo.git(['checkout', '--detach', valid]);
      final changed = repo.commit({fixture.path: '$persisted\n'});
      expect(await fixture.check(changed), [
        contains('preserve all existing records'),
      ]);
      repo.git(['rm', fixture.path]);
      final removed = repo.commit({});
      expect(await fixture.check(removed), [
        contains('preserve all existing records'),
      ]);
      final renamed = repo.commit({'${fixture.path}.moved': persisted});
      expect(await fixture.check(renamed), [
        contains('preserve all existing records'),
      ]);

      repo.base = fixture.prep;
      repo.git(['checkout', '--detach', fixture.prep]);
      repo.git(['revert', '--no-commit', fixture.prep]);
      final twoRecords = repo.commit({
        fixture.path: persisted,
        'tool/release/recoveries/${fixture.before}.json': '{}\n',
      });
      expect(await fixture.check(twoRecords), [
        contains('add one regular record'),
      ]);
    },
  );

  test(
    'a published unchanged companion can stay but cannot be tagged at the failed prep',
    () async {
      const name = 'llamadart_llama_cpp_flutter';
      const version = '1.2.2';
      final fixture = _RecoveryFixture(
        repo,
        publishedEdits: {
          'packages/$name/pubspec.yaml': 'name: $name\nversion: $version\n',
        },
      );
      final head = fixture.recovery();
      Future<({int status, String body})> get(Uri uri) async =>
          uri.path.endsWith('/$version')
          ? (
              status: 200,
              body: '{"version":"$version","pubspec":{"name":"$name"}}',
            )
          : (status: 404, body: _notFound);
      expect(await fixture.check(head, pub: get), isEmpty);
      fixture.tag('$name-v$version', fixture.prep);
      expect(await fixture.check(head, pub: get), [
        contains('$name-v$version already exists'),
      ]);
    },
  );

  test('rejects changed blobs, modes, paths and overlapping edits', () async {
    final fixture = _RecoveryFixture(repo);
    expect(
      await fixture.check(fixture.recovery(edits: {'README.md': 'wrong\n'})),
      [contains('exactly invert')],
    );
    expect(await fixture.check(fixture.recovery(edits: {'unexpected': '\n'})), [
      contains('exactly invert'),
    ]);
    fixture.recovery();
    repo.git(['update-index', '--chmod=+x', _root]);
    repo.git(['commit', '-qm', 'Change restored mode']);
    expect(await fixture.check(repo.git(['rev-parse', 'HEAD'])), [
      contains('exactly invert'),
    ]);
    repo.git(['restore', '--worktree', _root]);
    final exact = fixture.recovery();
    repo.git(['checkout', '--detach', fixture.before]);
    final stale = repo.commit({'moved.txt': '\n'});
    expect(await fixture.check(exact, eventBase: stale), [
      contains('up-to-date'),
    ]);
  });

  test(
    'rejects publication and probes the actual bumped companion version',
    () async {
      const companion = 'llamadart_llama_cpp_flutter';
      final fixture = _RecoveryFixture(
        repo,
        prepEdits: {
          'packages/$companion/darwin/$companion/Package.swift': '// fixture',
          'packages/$companion/pubspec.yaml':
              'name: $companion\nversion: 1.2.9\n',
        },
      );
      final head = fixture.recovery();
      final paths = <String>[];
      expect(
        await fixture.check(
          head,
          pub: (uri) async {
            paths.add(uri.path);
            return (status: 404, body: _notFound);
          },
        ),
        isEmpty,
      );
      expect(paths, [
        '/api/packages/llamadart/versions/1.2.4',
        '/api/packages/$companion/versions/1.2.9',
      ]);
      for (final status in [200, 401, 503]) {
        expect(
          await fixture.check(
            head,
            pub: (uri) async => (
              status: uri.path.endsWith('/1.2.9') ? status : 404,
              body: _notFound,
            ),
          ),
          [contains('HTTP $status')],
        );
      }
      expect(
        await fixture.check(
          head,
          releases: [
            [
              {'tag_name': 'v1.2.4', 'draft': true},
            ],
          ],
        ),
        [contains('GitHub Release')],
      );
      fixture.tag('$companion-v1.2.9', fixture.original);
      expect(await fixture.check(head), [
        contains('$companion-v1.2.9 already exists'),
      ]);
      fixture.tag('v1.2.4', fixture.prep);
      expect(await fixture.check(head), [contains('v1.2.4 already exists')]);
    },
  );

  test(
    'recovery requires a pub.dev NotFound error body for HTTP 404',
    () async {
      final fixture = _RecoveryFixture(repo);
      final head = fixture.recovery();
      expect(await fixture.check(head), isEmpty);
      for (final body in ['{}', '{"error":{"code":"Unavailable"}}']) {
        expect(
          await fixture.check(
            head,
            pub: (_) async => (status: 404, body: body),
          ),
          [contains('Malformed pub.dev 404')],
          reason: body,
        );
      }
      expect(
        await fixture.check(
          head,
          pub: (_) async => (status: 404, body: '<html>'),
        ),
        isNotEmpty,
      );
    },
  );

  for (final (path, replacement) in [
    (_root, '# Moved intro\n\n$_published'),
    (_docs, '## Unreleased\n\n- Pending.\n\n$_published'),
    (changelogArchive, '$_archive\n'),
    (changelogCutover, '$_marker\n'),
  ]) {
    test(
      'ordinary PR protects $path even from a clean merge checkout',
      () async {
        final head = repo.commit({path: replacement});
        repo.git(['checkout', '-q', '--detach', repo.base]);
        expect(await repo.check(head), [contains(path)]);
      },
    );
  }

  test('deletion, rename and executable modes are protected', () async {
    repo.file(changelogCutover).deleteSync();
    repo.file(changelogArchive).renameSync(repo.file('archive.md').path);
    repo.git(['update-index', '--chmod=+x', _root]);
    repo.git(['commit', '-qam', 'evidence', '--allow-empty']);
    expect(
      await repo.check(repo.git(['rev-parse', 'HEAD'])),
      containsAll([contains(changelogCutover)]),
    );
    expect(await repo.check(repo.git(['rev-parse', 'HEAD~1'])), isEmpty);
  });

  test('allows an exact prep with published bytes unchanged', () async {
    expect(await repo.check(repo.prep(), prep: true), isEmpty);
  });

  group('minor prep imports', () {
    const minor = '## 1.0.0\n\n- Previous minor.\n\n';
    const newMinor = '## 1.1.0\n\n- New minor.\n\n';
    const archived = '## 0.9.0\n\n- Archived.\n';
    String section(String version, String path) =>
        '## $version\n\n'
        "- Keep ${path == _root ? 'the ' : ''}default WebGPU bridge assets.\n"
        '- Tagged café note.  \n\n';

    String createPatch(String version) => repo.commit({
      'pubspec.yaml': 'name: llamadart\nversion: $version\n',
      _root: '# Releases\n\n${section(version, _root)}$minor',
      _docs: '${section(version, _docs)}$minor$archived',
    });

    late String secondPatch;
    setUp(() {
      repo.base = repo.commit({
        'pubspec.yaml': 'name: llamadart\nversion: 1.0.0\n',
        _root: '# Releases\n\n$minor',
        _docs: '$minor$archived',
        changelogArchive: archived,
      });
      repo.git(['tag', 'v1.0.0']);
      repo.commit({'main.txt': 'Next minor development.\n'});
      repo.git(['tag', 'v1.0.3']);
      repo.base = repo.git(['rev-parse', 'HEAD']);
      repo.git(['switch', '-c', 'release/1.0.x', 'v1.0.0']);
      repo.git(['tag', 'v1.0.1', createPatch('1.0.1')]);
      secondPatch = createPatch('1.0.2');
      repo.git(['switch', 'main']);
    });

    String candidate({
      String version = '1.1.0',
      String? rootImport,
      String? docsImport,
      List<String> imports = const ['1.0.2', '1.0.1'],
    }) {
      final current = version == '1.1.0'
          ? newMinor
          : '## $version\n\n- New.\n\n';
      String imported(String path) =>
          imports.map((release) => section(release, path)).join();
      return repo.prep(
        version: version,
        edits: {
          _root: '# Releases\n\n$current${rootImport ?? imported(_root)}$minor',
          _docs:
              '$current${docsImport ?? imported(_docs)}$minor'
              '${version == '1.1.0' ? '' : archived}',
        },
      );
    }

    test('accepts exact tag bytes and rejects a late missing patch', () async {
      final initial = candidate(imports: ['1.0.1']);
      expect(await repo.check(initial, prep: true), isEmpty);
      repo.git(['tag', '-a', 'v1.0.2', secondPatch, '-m', 'Late patch']);
      expect(await repo.check(initial, prep: true), isNotEmpty);
      expect(await repo.check(candidate(), prep: true), isEmpty);
    });

    for (final path in [_root, _docs]) {
      test('rejects changed tagged bytes in $path', () async {
        repo.git(['tag', 'v1.0.2', secondPatch]);
        final changed =
            section('1.0.2', path).replaceFirst('  \n', '\n') +
            section('1.0.1', path);
        expect(
          await repo.check(
            candidate(
              rootImport: path == _root ? changed : null,
              docsImport: path == _docs ? changed : null,
            ),
            prep: true,
          ),
          isNotEmpty,
        );
      });
    }

    for (final (label, imports) in [
      ('an on-chain tag', ['1.0.3', '1.0.2', '1.0.1']),
      ('an unknown tag', ['1.0.4', '1.0.2', '1.0.1']),
      ('out-of-order tags', ['1.0.1', '1.0.2']),
    ]) {
      test('rejects $label', () async {
        repo.git(['tag', 'v1.0.2', secondPatch]);
        expect(
          await repo.check(candidate(imports: imports), prep: true),
          isNotEmpty,
        );
      });
    }

    test('rejects imports in patch prep', () async {
      repo.git(['tag', 'v1.0.2', secondPatch]);
      expect(
        await repo.check(candidate(version: '1.0.4'), prep: true),
        isNotEmpty,
      );
      expect(
        await repo.check(candidate(version: '1.0.4', imports: []), prep: true),
        isEmpty,
      );
    });
  });

  for (final (label, edits) in [
    ('preamble', {_root: '# Changed intro\n\n$_new$_published'}),
    (
      'removed retained patch',
      {_docs: '$_new${_published.split('## 1.1.2').first}'},
    ),
    (
      'changed retained bytes',
      {
        _root:
            '# Releases\n\n$_new${_published.replaceFirst('Shipped.', 'Shipped. ')}',
      },
    ),
    (
      'changed retained docs bytes',
      {_docs: '$_new${_published.replaceFirst('Shipped.', 'Shipped. ')}'},
    ),
    ('extra heading', {_docs: '$_new## Accidental heading\n\n$_published'}),
    ('changed archive join', {changelogArchive: '$_archive\n'}),
    ('repin', {changelogCutover: '$_marker\n'}),
  ]) {
    test('core prep rejects $label', () async {
      expect(await repo.check(repo.prep(edits: edits), prep: true), isNotEmpty);
    });
  }

  test(
    'a release-prep label cannot grant a fork or a Genkit change access',
    () async {
      final head = repo.prep();
      expect(await repo.check(head, prep: true, repo: 'fork/repo'), isNotEmpty);
      final genkit = repo.commit({
        'packages/genkit_llamadart/file.txt': 'other',
      });
      expect(await repo.check(genkit, prep: true), isNotEmpty);
    },
  );

  test(
    'core prep moves history only to meet the changelog size limit',
    () async {
      final previousMinor = _published.indexOf('## 1.1.2');
      final head = repo.prep(
        edits: {
          _root: '# Releases\n\n$_new${_published.substring(0, previousMinor)}',
          changelogArchive: '${_published.substring(previousMinor)}$_archive',
        },
      );
      expect(await repo.check(head, prep: true), [
        contains('pub.dev size limit'),
      ]);
    },
  );

  test('a metadata-only pubspec edit uses ordinary protection', () async {
    final head = repo.commit({
      'pubspec.yaml': 'name: llamadart\nversion: 1.2.3\ndescription: Changed\n',
    });
    final logs = <String>[];
    expect(await repo.check(head, prep: true, log: logs.add), isEmpty);
    expect(logs, ['Core release prep: false']);
  });

  test('Unreleased must precede all numbered sections at cutover', () async {
    expect(
      () => ChangelogHistory.parse(
        '$_published\n$_pending',
        allowUnreleased: true,
      ),
      throwsFormatException,
    );
  });

  test(
    'legacy seed parity is required and numbered bytes stay fixed',
    () async {
      final legacy = ChangelogHistory.parse(
        '## Unreleased\n\n- Seed.\n\n$_published',
        allowUnreleased: true,
      );
      expect(legacySeedNotes(legacy, legacy), ['Seed.']);
      final different = ChangelogHistory.parse(
        '## Unreleased\n\n- Other.\n\n$_published',
        allowUnreleased: true,
      );
      expect(() => legacySeedNotes(legacy, different), throwsFormatException);
    },
  );

  test('event accepts exactly one migration against its pinned main', () async {
    final legacy = _Repo(activated: false);
    addTearDown(() => legacy.root.deleteSync(recursive: true));
    final expected = {
      _root: '# Releases\n\n$_published',
      _docs: 'This page keeps the current and previous minor.\n\n$_published',
      '.gitattributes': '# Other attributes\n',
      changelogCutover: '{"tag":"v1.2.3","commit":"${legacy.base}"}\n',
    };
    final head = legacy.commit(expected);
    expect(await legacy.check(head), isEmpty);
    final wrongMarker = legacy.commit({
      changelogCutover: '{"tag":"v1.2.3","commit":"$head"}\n',
    });
    expect(await legacy.check(wrongMarker), [contains('last legacy main')]);
    legacy.git(['checkout', '--detach', legacy.base]);
    final movedMain = legacy.commit({'other.txt': 'A change on main\n'});
    expect(await legacy.check(head, eventBase: movedMain), [
      contains('last legacy main'),
    ]);
    legacy.git(['checkout', '--detach', head]);
    final mutated = legacy.commit({_root: '${expected[_root]}\n'});
    expect(await legacy.check(mutated), [
      contains('prescribed pending wording'),
    ]);
  });
}
