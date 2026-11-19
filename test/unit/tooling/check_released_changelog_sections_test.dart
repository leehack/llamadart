@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

import '../../../tool/testing/check_released_changelog_sections.dart';

const _repoName = 'owner/repo';
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
      ['-c', 'commit.gpgsign=false', ...args],
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

  String prep({Map<String, String> edits = const {}}) => commit({
    'pubspec.yaml': 'name: llamadart\nversion: 1.2.4\n',
    _root: '# Releases\n\n$_new$_published',
    _docs: '$_new$_published',
    ...edits,
  });

  List<String> check(
    String head, {
    bool prep = false,
    String repo = _repoName,
  }) {
    final event = {
      'pull_request': {
        'base': {'sha': base},
        'head': {
          'sha': head,
          'ref': 'fixture',
          'repo': {'full_name': repo},
        },
        'labels': [
          if (prep) {'name': 'release-prep'},
        ],
      },
    };
    return checkReleasedChangelogSections(root, event, repository: _repoName);
  }
}

void main() {
  late _Repo repo;
  setUp(() => repo = _Repo());
  tearDown(() => repo.root.deleteSync(recursive: true));

  for (final (path, replacement) in [
    (_root, '# Moved intro\n\n$_published'),
    (_docs, '## Unreleased\n\n- Pending.\n\n$_published'),
    (changelogArchive, '$_archive\n'),
    (changelogCutover, '$_marker\n'),
  ]) {
    test('ordinary PR protects $path even from a clean merge checkout', () {
      final head = repo.commit({path: replacement});
      repo.git(['checkout', '-q', '--detach', repo.base]);
      expect(repo.check(head), [contains(path)]);
    });
  }

  test('deletion, rename and executable modes are protected', () {
    repo.file(changelogCutover).deleteSync();
    repo.file(changelogArchive).renameSync(repo.file('archive.md').path);
    repo.git(['update-index', '--chmod=+x', _root]);
    repo.git(['commit', '-qam', 'evidence', '--allow-empty']);
    expect(
      repo.check(repo.git(['rev-parse', 'HEAD'])),
      containsAll([contains(changelogCutover)]),
    );
    expect(repo.check(repo.git(['rev-parse', 'HEAD~1'])), isEmpty);
  });

  test('allows an exact prep with published bytes unchanged', () {
    expect(repo.check(repo.prep(), prep: true), isEmpty);
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
    ('extra heading', {_docs: '$_new## Accidental heading\n\n$_published'}),
    ('changed archive join', {changelogArchive: '$_archive\n'}),
    ('repin', {changelogCutover: '$_marker\n'}),
  ]) {
    test('core prep rejects $label', () {
      expect(repo.check(repo.prep(edits: edits), prep: true), isNotEmpty);
    });
  }

  test(
    'a release-prep label cannot grant a fork or a Genkit change access',
    () {
      final head = repo.prep();
      expect(repo.check(head, prep: true, repo: 'fork/repo'), isNotEmpty);
      final genkit = repo.commit({
        'packages/genkit_llamadart/file.txt': 'other',
      });
      expect(repo.check(genkit, prep: true), isNotEmpty);
    },
  );

  test('legacy seed parity is required and numbered bytes stay fixed', () {
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
  });

  test('event accepts exactly one migration against its pinned main', () {
    final legacy = _Repo(activated: false);
    addTearDown(() => legacy.root.deleteSync(recursive: true));
    final expected = {
      _root: '# Releases\n\n$_published',
      _docs: 'This page keeps the current and previous minor.\n\n$_published',
      '.gitattributes': '# Other attributes\n',
      changelogCutover: '{"tag":"v1.2.3","commit":"${legacy.base}"}\n',
    };
    final head = legacy.commit(expected);
    expect(legacy.check(head), isEmpty);
    final mutated = legacy.commit({_root: '${expected[_root]}\n'});
    expect(legacy.check(mutated), [contains('prescribed pending wording')]);
  });
}
