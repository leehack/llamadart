@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import '../../../tool/testing/check_released_changelog_sections.dart';

const _script = 'tool/testing/check_released_changelog_sections.dart';
const _command = 'dart run $_script';
const _docsChangelog = 'website/docs/changelog/recent-releases.md';
const _repository = 'leehack/llamadart';
const _posixOnly = 'drives git in a temporary repository';

const _released = '## 1.1.0\n\n- New.\n\n## 1.0.0\n\n- Old.\n';
const _docsIntro = '---\ntitle: Recent releases\n---\n\nIntro.\n\n';
const _base = '## Unreleased\n\n- Pending.\n\n$_released';

void main() {
  group('releasedSectionChange', () {
    test('accepts any change above the first released heading', () {
      for (final head in [
        '## Unreleased\n\n- Pending.\n- Another.\n\n$_released',
        _released,
        '# Changelog\n\n## Unreleased\n\n$_released',
      ]) {
        expect(releasedSectionChange('CHANGELOG.md', _base, head), isNull);
      }
    });

    test('names the first differing line of a moved bullet', () {
      const head =
          '## Unreleased\n\n## 1.1.0\n\n- New.\n- Pending.\n\n'
          '## 1.0.0\n\n- Old.\n';
      expect(
        releasedSectionChange('CHANGELOG.md', _base, head),
        startsWith(
          'CHANGELOG.md:6 changes a released section: the base has ``, this '
          'PR has `- Pending.`.',
        ),
      );
    });

    test('rejects a new, removed or truncated released section', () {
      expect(
        releasedSectionChange('CHANGELOG.md', _base, '## 1.2.0\n\n$_released'),
        startsWith(
          'CHANGELOG.md:1 changes a released section: the base has '
          '`## 1.1.0`, this PR has `## 1.2.0`.',
        ),
      );
      expect(
        releasedSectionChange('CHANGELOG.md', _base, '## Unreleased\n'),
        'CHANGELOG.md no longer has the released section `## 1.1.0`.',
      );
      expect(
        releasedSectionChange(
          'CHANGELOG.md',
          _base,
          '## Unreleased\n\n## 1.1.0\n\n- New.\n',
        ),
        contains('the base has ``, this PR has the end of the file'),
      );
      expect(
        releasedSectionChange(
          'CHANGELOG.md',
          _base,
          _base.substring(0, _base.length - 1),
        ),
        isNotNull,
      );
    });

    test('has nothing to protect before the first release', () {
      expect(
        releasedSectionChange('CHANGELOG.md', '## Unreleased\n', '# Draft\n'),
        isNull,
      );
    });
  });

  group('releasedSectionChange on the docs changelog', () {
    const base =
        '## Unreleased\n\n$_released\n## 0.9.0\n\n- Older.\n\n'
        '## 0.8.0\n\n- Oldest.\n';

    String? change(String head, {String path = _docsChangelog}) =>
        releasedSectionChange(path, base, head);

    test('accepts cutting whole sections from the tail', () {
      for (final head in [
        '## Unreleased\n\n$_released\n## 0.9.0\n\n- Older.\n',
        '## Unreleased\n\n$_released\n## 0.9.0\n\n- Older.\n\n',
        '## Unreleased\n\n$_released',
        '## Unreleased\n\n$_released\n',
        '## 1.1.0\n\n- New.\n',
      ]) {
        expect(change(head), isNull, reason: head);
      }
    });

    test('rejects the same cut in CHANGELOG.md', () {
      expect(
        change('## Unreleased\n\n$_released', path: 'CHANGELOG.md'),
        contains('changes a released section'),
      );
    });

    test('rejects a cut inside a section', () {
      for (final head in [
        '## Unreleased\n\n## 1.1.0\n',
        '## Unreleased\n\n## 1.1.0\n\n- New.\n\n## 1.0.0\n',
        '## Unreleased\n\n$_released\n## 0.9.0\n\n- Older.\n\n## 0.8.0\n',
      ]) {
        expect(change(head), isNotNull, reason: head);
      }
    });

    test('rejects a cut that also edits a kept section or the tail', () {
      expect(change('## Unreleased\n\n## 1.1.0\n\n- New edited.\n'), isNotNull);
      expect(
        change(
          '## Unreleased\n\n## 1.1.0\n\n- New.\n\n## 1.0.0\n\n- Old.\n'
          '\n## 0.9.0\n\n- Older.\n\n## 0.8.0\n\n- Oldest.\n- Extra.\n',
        ),
        isNotNull,
      );
      expect(change('## Unreleased\n\n## 1.1.0\n\n- Pending.\n'), isNotNull);
    });

    test('rejects adding a section or removing every section', () {
      expect(change('## 1.2.0\n\n$_released'), isNotNull);
      expect(
        change('## Unreleased\n'),
        '$_docsChangelog no longer has the released section `## 1.1.0`.',
      );
    });
  });

  group('isCoreReleasePrep', () {
    bool prep({
      List<String> labels = const [],
      String headRef = 'fix/thing',
      String headRepository = _repository,
    }) => isCoreReleasePrep(
      labels: labels,
      headRef: headRef,
      headRepository: headRepository,
      repository: _repository,
    );

    test('matches the release-prep label and versioned prep branches', () {
      expect(prep(labels: ['release-prep']), isTrue);
      expect(prep(headRef: 'release/prep-0.15.6'), isTrue);
      expect(prep(headRef: 'release/0.15.6-prep'), isTrue);
      expect(prep(headRef: 'release/prep-0.16.0-dev.1'), isTrue);
    });

    test('rejects other branches, forks and Genkit release branches', () {
      expect(prep(), isFalse);
      expect(prep(labels: ['docs']), isFalse);
      expect(prep(headRef: 'release/prep-next'), isFalse);
      expect(prep(headRef: 'release/0.15.6'), isFalse);
      expect(
        prep(labels: ['release-prep'], headRepository: 'someone/llamadart'),
        isFalse,
      );
      expect(
        prep(labels: ['release-prep'], headRef: 'release/genkit_llamadart-0.6'),
        isFalse,
      );
    });

    test('mirrors the release_on_prep_merge.yml gate', () {
      final gate = File(
        '.github/workflows/release_on_prep_merge.yml',
      ).readAsStringSync();
      for (final fragment in [
        r'grep -Fxq "release-prep"',
        r'"$head_ref" =~ ^release/prep-[0-9]+\.[0-9]+\.[0-9]+([-+][A-Za-z0-9._-]+)?$',
        r'"$head_ref" =~ ^release/[0-9]+\.[0-9]+\.[0-9]+([-+][A-Za-z0-9._-]+)?-prep$',
        r'"$head_repo" != "$GITHUB_REPOSITORY"',
        r'"$head_ref" == release/genkit_llamadart-*',
      ]) {
        expect(gate, contains(fragment));
      }
    });
  });

  group('CLI', () {
    late Directory root;
    late _Repo repo;
    setUp(() {
      root = Directory.systemTemp.createTempSync('released-changelog-');
      repo = _Repo.init(root, {
        'CHANGELOG.md': _base,
        _docsChangelog: '$_docsIntro$_base',
      });
      repo.git(['update-ref', 'refs/remotes/origin/main', 'main']);
      repo.git(['checkout', '-q', '-b', 'feature']);
    });
    tearDown(() => root.deleteSync(recursive: true));

    ProcessResult run({
      List<String> labels = const [],
      String headRef = 'feature',
      String baseRef = 'main',
      String eventName = 'pull_request',
    }) {
      final event = File('${root.path}/event.json')
        ..writeAsStringSync(
          jsonEncode({
            'pull_request': {
              'labels': [
                for (final label in labels) {'name': label},
              ],
              'base': {'ref': baseRef},
              'head': {
                'ref': headRef,
                'repo': {'full_name': _repository},
              },
            },
          }),
        );
      return Process.runSync(
        Platform.resolvedExecutable,
        [File(_script).absolute.path],
        workingDirectory: repo.directory.path,
        environment: {
          ...repo.environment,
          'GITHUB_EVENT_NAME': eventName,
          'GITHUB_EVENT_PATH': event.path,
          'GITHUB_REPOSITORY': _repository,
        },
      );
    }

    test('passes a PR that only adds an Unreleased bullet', () {
      const head = '## Unreleased\n\n- Pending.\n- Mine.\n\n$_released';
      repo.commit({'CHANGELOG.md': head, _docsChangelog: '$_docsIntro$head'});

      final result = run();
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(result.stdout, contains('match the base'));
    });

    test('fails a bullet moved into a released section', () {
      const head =
          '## Unreleased\n\n## 1.1.0\n\n- New.\n- Pending.\n\n'
          '## 1.0.0\n\n- Old.\n';
      repo.commit({_docsChangelog: '$_docsIntro$head'});

      final result = run();
      expect(result.exitCode, 1);
      expect(
        result.stderr,
        contains(
          '$_docsChangelog:12 changes a released section: the base has ``, '
          'this PR has `- Pending.`.',
        ),
      );
      expect(result.stderr, isNot(contains('- CHANGELOG.md')));
    });

    test('lets only the docs changelog drop its oldest sections', () {
      const head = '## Unreleased\n\n- Pending.\n\n## 1.1.0\n\n- New.\n';
      repo.commit({'CHANGELOG.md': head, _docsChangelog: '$_docsIntro$head'});

      final result = run();
      expect(result.exitCode, 1);
      expect(
        result.stderr,
        contains('CHANGELOG.md:8 changes a released section'),
      );
      expect(result.stderr, isNot(contains('- $_docsChangelog')));
    });

    test('passes a docs changelog trimmed at a version heading', () {
      repo.commit({
        _docsChangelog:
            '$_docsIntro## Unreleased\n\n- Pending.\n\n## 1.1.0\n\n- New.\n',
      });

      final result = run();
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(result.stdout, contains('match the base'));
    });

    test('compares against the merge base, not the base branch tip', () {
      repo.git(['checkout', '-q', 'main']);
      const released = '## 1.2.0\n\n- Pending.\n\n$_released';
      repo.commit({
        'CHANGELOG.md': '## Unreleased\n\n$released',
        _docsChangelog: '$_docsIntro## Unreleased\n\n$released',
      });
      repo.git(['update-ref', 'refs/remotes/origin/main', 'main']);
      repo.git(['checkout', '-q', 'feature']);

      expect(run().exitCode, 0);
    });

    test('exempts release prep', () {
      repo.commit({'CHANGELOG.md': '## 1.2.0\n\n- Pending.\n\n$_released'});

      expect(run().exitCode, 1);
      for (final result in [
        run(labels: ['release-prep']),
        run(headRef: 'release/prep-1.2.0'),
      ]) {
        expect(result.exitCode, 0, reason: '${result.stderr}');
        expect(result.stdout, contains('Release-prep PR'));
      }
    });

    test('fails closed when the base branch is not fetched', () {
      final result = run(baseRef: 'release-branch');
      expect(result.exitCode, 1);
      expect(
        result.stderr,
        contains(
          'Could not find the merge base of HEAD and origin/release-branch. '
          'Check out with `fetch-depth: 0`',
        ),
      );
    });

    test('skips events other than pull_request', () {
      repo.commit({'CHANGELOG.md': '## 1.2.0\n\n$_released'});
      final result = run(eventName: 'push');
      expect(result.exitCode, 0);
      expect(result.stdout, contains('Not a pull_request event'));
    });
  }, skip: Platform.isWindows ? _posixOnly : false);

  test(
    'ci.yml runs the check with full history wherever docs are verified',
    () {
      final jobs =
          (loadYaml(File('.github/workflows/ci.yml').readAsStringSync())
                  as YamlMap)['jobs']
              as YamlMap;
      for (final name in ['analyze', 'docs-versions']) {
        final steps = ((jobs[name] as YamlMap)['steps'] as YamlList)
            .cast<YamlMap>()
            .toList();
        final checkout = steps.singleWhere(
          (step) =>
              (step['uses'] as String? ?? '').startsWith('actions/checkout'),
        );
        expect((checkout['with'] as YamlMap)['fetch-depth'], 0, reason: name);
        final runs = steps.map((step) => step['run']).toList();
        final verify = runs.indexOf(
          'dart run tool/testing/verify_release_docs_versions.dart',
        );
        expect(verify, isNot(-1), reason: name);
        expect(runs.indexOf(_command), verify + 1, reason: name);
      }
    },
  );
}

/// Git with no user or system configuration, so signing, hooks and
/// templates on the host cannot change what the commands do.
class _Repo {
  _Repo(this.directory, this.environment);

  factory _Repo.init(Directory root, Map<String, String> files) {
    final config = File('${root.path}/gitconfig')..writeAsStringSync('');
    final repo = _Repo(Directory('${root.path}/repo')..createSync(), {
      'GIT_CONFIG_GLOBAL': config.path,
      'GIT_CONFIG_NOSYSTEM': '1',
      'GIT_AUTHOR_NAME': 'Test',
      'GIT_AUTHOR_EMAIL': 'test@example.com',
      'GIT_COMMITTER_NAME': 'Test',
      'GIT_COMMITTER_EMAIL': 'test@example.com',
    });
    repo.git(['init', '-q', '-b', 'main']);
    repo.commit(files);
    return repo;
  }

  final Directory directory;
  final Map<String, String> environment;

  void git(List<String> arguments) {
    final result = Process.runSync(
      'git',
      arguments,
      workingDirectory: directory.path,
      environment: environment,
    );
    if (result.exitCode != 0) {
      fail('git ${arguments.join(' ')} failed:\n${result.stderr}');
    }
  }

  void commit(Map<String, String> files) {
    for (final entry in files.entries) {
      File('${directory.path}/${entry.key}')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(entry.value);
    }
    git(['add', '-A']);
    git(['commit', '-q', '-m', 'change']);
  }
}
