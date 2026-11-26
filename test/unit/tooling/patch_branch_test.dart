@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../../tool/release/patch_branch.dart';

const _repo = 'leehack/llamadart';
const _main = 'refs/remotes/origin/main';
const _release = 'refs/remotes/origin/release/1.0.x';
const _authored = '''
## Summary

- Fix a release regression.

## Changelog

- Preserve the selected entry across reloads, including entries added in another session.
- [packages/genkit_llamadart] Update the adapter example.
''';
const _landed = '''
## Summary

- Fix a release regression.

## Changelog

- Preserve the selected entry across reloads, including entries added in
another session.
- [packages/genkit_llamadart] Update the adapter example.
''';
const _forward = 'Forward-port: https://github.com/$_repo/issues/61';
const _retained = 'tool/release/retained_backports';

String _revertBody(String sha) =>
    '## Summary\n\nThis reverts commit $sha.\n\n'
    '## Changelog\n\nN/A: Reverts a regression.\n';

String _record(
  String backport,
  String source,
  String revert, {
  Object issue = 61,
}) =>
    '${jsonEncode({'backport': backport, 'source': source, 'revert': revert, 'issue': issue})}\n';

String _metadata(String sha, {int pr = 51}) =>
    'Backport of https://github.com/$_repo/pull/$pr\n'
    '(cherry picked from commit $sha)';

String _backport(String sha, {int pr = 51, String body = _authored}) => body
    .replaceFirst('## Summary\n', '## Summary\n${_metadata(sha, pr: pr)}\n');

const _historicalPrepDocs = [
  'CHANGELOG.md',
  'README.md',
  'example/dartpad_gguf/README.md',
  'packages/llamadart_litert_lm_flutter/CHANGELOG.md',
  'packages/llamadart_litert_lm_flutter/README.md',
  'packages/llamadart_llama_cpp_flutter/CHANGELOG.md',
  'packages/llamadart_llama_cpp_flutter/README.md',
  'packages/llamadart_stable_diffusion_flutter/CHANGELOG.md',
  'packages/llamadart_stable_diffusion_flutter/README.md',
  'website/docs/changelog/recent-releases.md',
  'website/docs/examples/dartpad-gguf.md',
  'website/docs/getting-started/installation.md',
  'website/docs/guides/image-generation.md',
  'website/docs/integrations/choosing-an-api.md',
];
const _companion = 'llamadart_llama_cpp_flutter';
const _companionPubspec = 'packages/$_companion/pubspec.yaml';
const _chatLock = 'example/chat_app/pubspec.lock';

void _writePrepFiles(_Repository repo, String version, List<String> docs) {
  final companions = [
    'llamadart_litert_lm_flutter',
    _companion,
    'llamadart_stable_diffusion_flutter',
  ];
  repo.write('pubspec.yaml', 'name: llamadart\nversion: $version\n');
  for (final name in companions) {
    repo.write(
      'packages/$name/pubspec.yaml',
      'name: $name\nversion: $version\ndependencies:\n  llamadart: any\n',
    );
  }
  for (final (path, rootPath) in [
    (_chatLock, '../..'),
    ('packages/llamadart_validation/pubspec.lock', '../..'),
    ('website/examples/observability/pubspec.lock', '../../..'),
  ]) {
    repo.write(
      path,
      'packages:\n'
      '${_lockEntry('llamadart', rootPath, version)}'
      '${path == _chatLock ? companions.map((name) => _lockEntry(name, '../../packages/$name', version)).join() : ''}',
    );
  }
  for (final path in docs) {
    repo.write(path, 'Install version $version.\n');
  }
}

String _lockEntry(String name, String path, String version) =>
    '  $name:\n'
    '    dependency: "direct main"\n'
    '    description:\n'
    '      path: "$path"\n'
    '      relative: true\n'
    '    source: path\n'
    '    version: "$version"\n';

void _writeCoreFloor(
  _Repository repo,
  String version,
  String lower,
  String upper, {
  String extra = '',
}) {
  repo.write(
    _companionPubspec,
    'name: $_companion\nversion: $version\ndependencies:\n'
    "  llamadart: '>=$lower <$upper'\n"
    '$extra',
  );
}

Matcher _failure(String diagnostic) => isA<FormatException>().having(
  (e) => e.message,
  'diagnostic',
  contains(diagnostic),
);

void main() {
  late _Repository repo;
  setUp(() => repo = _Repository());
  tearDown(() => repo.root.deleteSync(recursive: true));

  test(
    'accepts an authored backport with a wrapped landed core bullet',
    () async {
      final sha = repo.mainFix();
      expect(await repo.guard(_backport(sha)), contains('verified'));
      expect(repo.requests, ['repos/$_repo/pulls/51']);
    },
  );

  test('a patch base requires backport or forward-port metadata', () async {
    for (final base in ['release/1.0.x', 'release/01.0.x']) {
      await expectLater(
        repo.guard(_authored, base: base),
        throwsA(_failure('Backport of')),
      );
    }
  });

  test('rejects incomplete, repeated, mixed and foreign metadata', () async {
    final sha = repo.mainFix();
    final body = _backport(sha);
    for (final (invalid, diagnostic) in [
      (
        body.replaceFirst(RegExp(r'\(cherry picked[^\n]+\n'), ''),
        'cherry picked',
      ),
      (body.replaceFirst(RegExp(r'Backport of[^\n]+\n'), ''), 'Backport of'),
      ('${_metadata(sha)}\n$body', 'exactly one'),
      ('$body\n$_forward\n', 'Forward-port'),
      (body.replaceFirst('/$_repo/', '/other/repo/'), 'Backport of'),
      (body.replaceFirst(sha, sha.substring(0, 12)), 'cherry picked'),
    ]) {
      await expectLater(repo.guard(invalid), throwsA(_failure(diagnostic)));
    }
  });

  test('rejects a source object merged as a side parent of main', () async {
    repo.git(['checkout', '-qb', 'side']);
    final side = repo.commit(
      'Fix a regression (#51)',
      body: _landed,
      file: 'side',
    );
    repo.git(['checkout', '-q', 'main']);
    repo.git(['merge', '-q', '--no-ff', 'side', '-m', 'Merge side']);
    repo.git(['update-ref', _main, 'HEAD']);
    await expectLater(
      repo.guard(_backport(side)),
      throwsA(_failure('first-parent')),
    );
  });

  test('rejects a source already included in the minor tag', () async {
    final included = repo.mainFix();
    final released = repo.commit('Release the minor', file: 'release-readme');
    repo.git(['tag', '-f', 'v1.0.0', released]);
    repo.git(['update-ref', _main, released]);
    await expectLater(
      repo.guard(_backport(included)),
      throwsA(_failure('v1.0.0')),
    );
  });

  test(
    'rejects a PR number that differs from the main commit subject',
    () async {
      await expectLater(
        repo.guard(_backport(repo.mainFix(), pr: 52)),
        throwsA(_failure('#52')),
      );
    },
  );

  test('rejects a backport that changes the landed main core bullet', () async {
    final sha = repo.mainFix(
      body: _landed.replaceFirst(
        'Preserve the selected',
        'Restore the selected',
      ),
    );
    await expectLater(
      repo.guard(_backport(sha)),
      throwsA(_failure('core Changelog')),
    );
  });

  test(
    'requires the authored body, including content outside Changelog',
    () async {
      final sha = repo.mainFix();
      final altered = _authored.replaceFirst(
        'Fix a release regression.',
        'Edit the PR summary.',
      );
      await expectLater(
        repo.guard(_backport(sha, body: altered)),
        throwsA(_failure('authored body')),
      );
      await expectLater(
        repo.guard(_backport(sha, body: _landed)),
        throwsA(_failure('Changelog')),
      );
    },
  );

  test('an N/A reason must be preserved', () async {
    const body = '## Summary\n\n## Changelog\n\nN/A: Maintainer tooling.';
    repo.prBody = body;
    final sha = repo.mainFix(body: body);
    expect(await repo.guard(_backport(sha, body: body)), contains('verified'));
    await expectLater(
      repo.guard(
        _backport(sha, body: body.replaceFirst('Maintainer', 'Release')),
      ),
      throwsA(_failure('core Changelog')),
    );
  });

  test(
    'forward-port metadata alone is allowed if its linked issue exists',
    () async {
      expect(await repo.guard(_forward), contains('forward-port'));
      expect(repo.requests, ['repos/$_repo/issues/61']);
      repo.issue = {'number': 61, 'state': 'open', 'pull_request': {}};
      await expectLater(repo.guard(_forward), throwsA(_failure('issue #61')));
    },
  );

  test('rejects an already closed forward-port issue at guard time', () async {
    repo.issue = {'number': 61, 'state': 'closed'};
    await expectLater(
      repo.guard(_forward),
      throwsA(_failure('Forward-port issue #61 is closed')),
    );
  });

  test('rejects backport metadata hidden inside the Changelog', () async {
    final sha = repo.mainFix();
    repo.prBody = '$_authored<!--\n-->\n';
    final hidden = repo.prBody.replaceFirst(
      '<!--\n',
      '<!--\n${_metadata(sha)}\n',
    );
    await expectLater(
      repo.guard(hidden),
      throwsA(_failure('standalone body lines')),
    );
  });

  test('routed same-repository core prep is exempt', () async {
    repo.checkoutRelease();
    repo.prep('1.0.1', pr: 52);
    expect(
      await repo.guard(null, head: 'release/prep-1.0.1'),
      contains('release prep'),
    );
    await expectLater(
      repo.guard(
        null,
        head: 'release/prep-1.0.1',
        headRepository: 'fork/llamadart',
      ),
      throwsA(_failure('Backport of')),
    );
  });

  test('a routed prep PR cannot exempt unrelated paths', () async {
    repo.checkoutRelease();
    repo.write('lib/branch_only.dart', 'void fix() {}');
    repo.write('.github/workflows/branch-only.yml', 'name: Extra');
    repo.prep('1.0.1', pr: 52);
    for (final (head, labels) in [
      ('release/prep-1.0.1', <String>[]),
      ('branch-only-fix', ['release-prep']),
    ]) {
      await expectLater(
        repo.guard(null, head: head, labels: labels),
        throwsA(
          allOf(
            _failure('lib/branch_only.dart'),
            _failure('.github/workflows/branch-only.yml'),
          ),
        ),
      );
    }
  });

  for (final (testName, before, after, docs) in [
    (
      'replays the 0.20.8 prep file set through guard and parity',
      '0.20.7',
      '0.20.8',
      _historicalPrepDocs,
    ),
    (
      'replays the 0.21.1 prep file set through guard and parity',
      '0.21.0',
      '0.21.1',
      [
        ..._historicalPrepDocs,
        'website/docs/platforms/apple-setup.md',
        'MIGRATION.md',
        'doc/changelog_archive.md',
      ],
    ),
  ]) {
    test(testName, () async {
      _writePrepFiles(repo, before, docs);
      repo.anchorPrepBase(before);
      repo.checkoutRelease();
      _writePrepFiles(repo, after, docs);
      final prep = repo.prep(after, pr: 52);
      repo.git(['tag', 'v$after']);
      expect(
        await repo.guard(null, head: 'release/prep-$after'),
        contains('release prep'),
      );
      expect(await repo.parity(), contains('$prep prep'));

      repo.write('lib/branch_only.dart', 'void fix() {}');
      repo.git(['add', '-A']);
      repo.git(['commit', '--amend', '--no-edit', '-q']);
      repo.git(['tag', '-f', 'v$after']);
      await expectLater(
        repo.guard(null, head: 'release/prep-$after'),
        throwsA(_failure('lib/branch_only.dart')),
      );
      await expectLater(
        repo.parity(),
        throwsA(_failure('lib/branch_only.dart')),
      );
    });
  }

  for (final (path, old, replacement, label) in [
    (
      'pubspec.yaml',
      '',
      'dependency_overrides:\n  yaml: any\n',
      'core dependency overrides',
    ),
    ('pubspec.yaml', '', 'hooks:\n  user_defines: {}\n', 'core hooks'),
    (
      _companionPubspec,
      'llamadart: any',
      'llamadart: ^1.0.1',
      'companion dependencies',
    ),
    (_chatLock, '    source: path', '    source: hosted', 'lock source'),
    (
      _chatLock,
      '    version: "1.0.1"',
      '    version: "1.0.9"',
      'lock version skew',
    ),
  ]) {
    test('prep rejects $label in guard and parity', () async {
      _writePrepFiles(repo, '1.0.0', []);
      repo.anchorPrepBase('1.0.0');
      repo.checkoutRelease();
      _writePrepFiles(repo, '1.0.1', []);
      final original = File('${repo.root.path}/$path').readAsStringSync();
      repo.write(
        path,
        old.isEmpty
            ? original + replacement
            : original.replaceFirst(old, replacement),
      );
      repo.commit(
        'Prepare llamadart 1.0.1 release (#52)',
        file: 'CHANGELOG.md',
      );
      repo.git(['tag', 'v1.0.1']);
      await expectLater(
        repo.guard(null, head: 'release/prep-1.0.1'),
        throwsA(_failure(path)),
      );
      await expectLater(repo.parity(), throwsA(_failure(path)));
    });
  }

  for (final (name, before, after, oldFloor, upper) in [
    (
      'a 0.20.1 repin can raise the companion core floor',
      '0.20.0',
      '0.20.1',
      '0.20.0',
      '0.21.0',
    ),
    (
      'a 0.20.4 repin can raise the companion core floor',
      '0.20.3',
      '0.20.4',
      '0.20.2',
      '0.21.0',
    ),
    (
      'a 0.20.5 repin can raise the companion core floor',
      '0.20.4',
      '0.20.5',
      '0.20.4',
      '0.21.0',
    ),
    (
      'a 0.20.7 repin can raise the companion core floor',
      '0.20.6',
      '0.20.7',
      '0.20.0',
      '0.21.0',
    ),
    (
      'a 0.21.1 repin can raise the companion core floor',
      '0.21.0',
      '0.21.1',
      '0.21.0',
      '0.22.0',
    ),
  ]) {
    test(name, () async {
      _writePrepFiles(repo, before, _historicalPrepDocs);
      _writeCoreFloor(repo, before, oldFloor, upper);
      repo.anchorPrepBase(before);
      repo.checkoutRelease();
      _writePrepFiles(repo, after, _historicalPrepDocs);
      _writeCoreFloor(repo, after, after, upper);
      final prep = repo.prep(after, pr: 52);
      repo.git(['tag', 'v$after']);
      expect(
        await repo.guard(null, head: 'release/prep-$after'),
        contains('release prep'),
      );
      expect(await repo.parity(), contains('$prep prep'));
    });
  }

  for (final (label, companionVersion, valid) in [
    ('a different minor', '1.1.0', false),
    ('a downgrade', '1.0.4', false),
    ('an independent patch increase', '1.0.8', true),
  ]) {
    test(
      'checks companion progression through guard and parity for $label',
      () async {
        const coreBefore = '1.0.2';
        const coreAfter = '1.0.3';
        const companionBefore = '1.0.5';
        const companionPath = '../../packages/$_companion';
        void writeCompanion(String core, String companion) {
          _writePrepFiles(repo, core, _historicalPrepDocs);
          _writeCoreFloor(repo, companion, core, '1.1.0');
          final lock = File('${repo.root.path}/$_chatLock').readAsStringSync();
          repo.write(
            _chatLock,
            lock.replaceFirst(
              _lockEntry(_companion, companionPath, core),
              _lockEntry(_companion, companionPath, companion),
            ),
          );
        }

        writeCompanion(coreBefore, companionBefore);
        repo.anchorPrepBase(coreBefore);
        repo.checkoutRelease();
        writeCompanion(coreAfter, companionVersion);
        final prep = repo.prep(coreAfter, pr: 52);
        repo.git(['tag', 'v$coreAfter']);
        final guard = repo.guard(null, head: 'release/prep-$coreAfter');
        if (valid) {
          expect(await guard, contains('release prep'));
          expect(await repo.parity(), contains('$prep prep'));
        } else {
          final failure = throwsA(
            _failure('Companion version $companionVersion'),
          );
          await expectLater(guard, failure);
          await expectLater(repo.parity(), failure);
        }
      },
    );
  }

  for (final (name, lower, upper, extra) in [
    ('prep rejects lowering the companion core floor', '1.0.1', '1.1.0', ''),
    ('prep rejects changing the companion upper bound', '1.0.3', '1.2.0', ''),
    (
      'prep rejects raising the companion floor above the new core',
      '1.0.4',
      '1.1.0',
      '',
    ),
    (
      'prep rejects changing another companion dependency with the floor',
      '1.0.3',
      '1.1.0',
      '  yaml: any\n',
    ),
    (
      'prep rejects adding companion hooks with the floor',
      '1.0.3',
      '1.1.0',
      'hooks:\n  user_defines: {}\n',
    ),
    (
      'prep rejects adding companion overrides with the floor',
      '1.0.3',
      '1.1.0',
      'dependency_overrides:\n  yaml: any\n',
    ),
  ]) {
    test(name, () async {
      _writePrepFiles(repo, '1.0.2', []);
      _writeCoreFloor(repo, '1.0.2', '1.0.2', '1.1.0');
      repo.anchorPrepBase('1.0.2');
      repo.checkoutRelease();
      _writePrepFiles(repo, '1.0.3', []);
      _writeCoreFloor(repo, '1.0.3', lower, upper, extra: extra);
      repo.prep('1.0.3', pr: 52);
      repo.git(['tag', 'v1.0.3']);
      await expectLater(
        repo.guard(null, head: 'release/prep-1.0.3'),
        throwsA(_failure(_companionPubspec)),
      );
      await expectLater(repo.parity(), throwsA(_failure(_companionPubspec)));
    });
  }

  for (final (name, version) in [
    ('prep rejects bumping to another minor', '1.7.3'),
    ('prep rejects downgrading the core version', '0.9.0'),
    ('prep rejects skipping a patch version', '1.0.2'),
  ]) {
    test(name, () async {
      repo.checkoutRelease();
      repo.prep(version, pr: 52);
      repo.git(['tag', 'v1.0.1']);
      await expectLater(
        repo.guard(null, head: 'release/prep-1.0.1'),
        throwsA(_failure('next patch')),
      );
      await expectLater(repo.parity(), throwsA(_failure('next patch')));
    });
  }

  test(
    'parity rejects a tag that disagrees with the next core patch',
    () async {
      repo.checkoutRelease();
      repo.prep('1.0.1', pr: 52);
      repo.git(['tag', 'v1.0.2']);
      await expectLater(repo.parity(), throwsA(_failure('v1.0.2')));
    },
  );

  test('parity rejects conflicting tags on the same prep', () async {
    repo.checkoutRelease();
    repo.prep('1.0.1', pr: 52);
    repo.git(['tag', 'v1.0.1']);
    repo.git(['tag', 'v1.0.2']);
    await expectLater(
      repo.parity(),
      throwsA(_failure('Conflicting patch tags')),
    );
  });

  for (final (name, path, mode) in [
    ('prep rejects an executable pubspec', 'pubspec.yaml', '100755'),
    ('prep rejects an executable README', 'README.md', '100755'),
    ('prep rejects a symlink README', 'README.md', '120000'),
    ('prep rejects a gitlink README', 'README.md', '160000'),
    ('prep rejects a deleted README', 'README.md', ''),
  ]) {
    test(name, () async {
      repo.write('README.md', 'Install the core.\n');
      repo.anchorPrepBase('1.0.0');
      repo.checkoutRelease();
      repo.prep('1.0.1', pr: 52);
      if (mode.isEmpty) {
        repo.git(['rm', path]);
      } else {
        final object = mode == '160000'
            ? repo.minor
            : repo.git(['rev-parse', 'HEAD:$path']);
        repo.git(['update-index', '--cacheinfo', '$mode,$object,$path']);
      }
      repo.git(['commit', '--amend', '--no-edit', '-q']);
      repo.git(['tag', 'v1.0.1']);
      final failure = allOf(_failure(path), _failure('regular file'));
      await expectLater(
        repo.guard(null, head: 'release/prep-1.0.1'),
        throwsA(failure),
      );
      await expectLater(repo.parity(), throwsA(failure));
    });
  }

  test('prep rejects moving code into a whitelisted README', () async {
    repo.write('lib/x.dart', 'void fix() {}\n');
    repo.anchorPrepBase('1.0.0');
    repo.checkoutRelease();
    repo.git(['config', 'diff.renames', 'true']);
    repo.git(['mv', 'lib/x.dart', 'README.md']);
    repo.prep('1.0.1', pr: 52);
    repo.git(['tag', 'v1.0.1']);
    await expectLater(
      repo.guard(null, head: 'release/prep-1.0.1'),
      throwsA(_failure('lib/x.dart')),
    );
    await expectLater(repo.parity(), throwsA(_failure('lib/x.dart')));
  });

  test('a routed prep PR requires event commit identities', () async {
    await expectLater(
      repo.guard(null, head: 'release/prep-1.0.1', includeShas: false),
      throwsA(_failure('full base and head SHAs')),
    );
  });

  for (final base in [
    'main',
    'release/prep-1.0.1',
    'release/genkit_llamadart-v1.0.0',
  ]) {
    test('ignores the $base base', () async {
      expect(await repo.guard(null, base: base), isEmpty);
      expect(repo.requests, isEmpty);
    });
  }

  test('parity distinguishes exact and adapted backports', () async {
    final sha = repo.mainFix();
    repo.checkoutRelease();
    final exact = repo.backport(sha);
    final adapted = repo.backport(sha, file: 'adapted');
    final output = await repo.parity();
    expect(output, contains('$exact backport exact'));
    expect(output, contains('$adapted backport adapted'));
    expect(repo.requests, isEmpty);
  });

  test('parity accepts a trailer-less patch-id equivalent', () async {
    final sha = repo.mainFix();
    repo.checkoutRelease();
    final equivalent = repo.backport(sha, body: '');
    expect(await repo.parity(), contains('$equivalent equivalent'));
  });

  test(
    'parity matches a trailer-less patch from a merged side branch',
    () async {
      repo.git(['checkout', '-qb', 'side']);
      final sha = repo.mainFix();
      repo.git(['checkout', '-q', 'main']);
      repo.git(['merge', '-q', '--no-ff', 'side', '-m', 'Merge side']);
      repo.git(['update-ref', _main, 'HEAD']);
      repo.checkoutRelease();
      final equivalent = repo.backport(sha, body: '');
      expect(await repo.parity(), contains('$equivalent equivalent'));
    },
  );

  test('parity fails naming every unaccounted-for commit', () async {
    repo.mainFix();
    repo.checkoutRelease();
    final first = repo.commit('Branch-only fix', file: 'branch-only');
    final second = repo.commit('Another branch-only fix', file: 'other');
    await expectLater(
      repo.parity(),
      throwsA(
        allOf(
          _failure('$first Branch-only fix'),
          _failure('$second Another branch-only fix'),
          _failure('missing from main'),
        ),
      ),
    );
  });

  group('reverted backport sources', () {
    late String source;
    setUp(() => source = repo.mainFix());

    Future<void> expectFlagged(String backport, String revert) => expectLater(
      repo.parity(),
      throwsA(
        allOf(
          _failure(backport),
          _failure('Backport source $source'),
          _failure(revert),
        ),
      ),
    );

    test('flags a declared revert', () async {
      final revert = repo.mainRevert(source);
      repo.checkoutRelease();
      final backport = repo.backport(source);
      await expectFlagged(backport, revert);
      expect(repo.requests, isEmpty);
    });

    test('flags an undeclared exact inverse', () async {
      final revert = repo.mainRevert(
        source,
        subject: 'Remove the fix (#59)',
        body: '',
      );
      repo.checkoutRelease();
      await expectFlagged(repo.backport(source), revert);
    });

    for (final (name, body) in [
      ('a commit', 'This reverts commit SOURCE.'),
      ('a pull request', 'Reverts $_repo#51'),
    ]) {
      test('flags a drifted revert declared by $name', () async {
        repo.mainCommit('Edit the fix (#56)', file: 'fix', content: 'more\n');
        final revert = repo.mainCommit(
          'Undo the fix (#59)',
          body: body.replaceAll('SOURCE', source),
          file: 'fix',
          content: 'drifted\n',
        );
        repo.checkoutRelease();
        await expectFlagged(repo.backport(source), revert);
      });
    }

    test('keeps a backport exact when main reverts another commit', () async {
      final other = repo.mainCommit('Other change (#57)', file: 'other');
      repo.mainRevert(other, subject: 'Revert "Other change (#57)" (#58)');
      repo.mainCommit(
        'Undo another change (#60)',
        body: 'Reverts $_repo#57',
        file: 'other',
        content: 'again\n',
      );
      repo.checkoutRelease();
      final backport = repo.backport(source);
      expect(await repo.parity(), contains('$backport backport exact'));
    });

    test('accepts an exact re-apply and flags a later revert', () async {
      final first = repo.mainRevert(source);
      final restore = repo.mainRevert(
        first,
        subject: 'Restore the fix (#60)',
        body: _revertBody(first),
      );
      repo.checkoutRelease();
      final backport = repo.backport(source);
      expect(await repo.parity(), contains('$backport backport exact'));
      repo.git(['checkout', '-q', 'main']);
      final second = repo.mainRevert(
        restore,
        subject: 'Revert "Restore the fix (#60)" (#61)',
      );
      repo.git(['checkout', '-q', 'release/1.0.x']);
      repo.retain(backport, _record(backport, source, first));
      await expectLater(
        repo.parity(),
        throwsA(allOf(_failure(backport), _failure(second))),
      );
    });

    test('accepts an exact restore of a drifted revert', () async {
      repo.mainCommit('Edit the fix (#56)', file: 'fix', content: 'more\n');
      final revert = repo.mainCommit(
        'Undo the fix (#59)',
        body: 'This reverts commit $source.',
        file: 'fix',
        content: 'drifted\n',
      );
      repo.mainRevert(
        revert,
        subject: 'Restore the fix (#60)',
        body: _revertBody(revert),
      );
      repo.checkoutRelease();
      final backport = repo.backport(source);
      expect(await repo.parity(), contains('$backport backport exact'));
    });

    test('keeps an adapted re-land flagged', () async {
      final revert = repo.mainRevert(source);
      repo.mainCommit(
        'Re-land the fix (#60)',
        body: 'This reverts commit $revert.',
        file: 'fix',
        content: 'adapted\n',
      );
      repo.checkoutRelease();
      await expectFlagged(repo.backport(source), revert);
    });

    for (final (name, remediate, passes) in [
      ('accepts a backport of the revert after the backport', true, true),
      ('flags a backport of the revert before the backport', false, false),
    ]) {
      test(name, () async {
        final revert = repo.mainRevert(source, subject: 'Revert fix (#59)');
        repo.checkoutRelease();
        String undo() => repo.backport(
          revert,
          body: _backport(revert, pr: 59, body: _revertBody(source)),
          file: 'undo',
        );
        late String backport;
        if (remediate) {
          backport = repo.backport(source);
          undo();
        } else {
          undo();
          backport = repo.backport(source);
        }
        if (passes) {
          expect(await repo.parity(), contains('$backport backport exact'));
          expect(repo.requests, isEmpty);
        } else {
          await expectFlagged(backport, revert);
        }
      });
    }

    test('accepts a bound retained backport record', () async {
      final revert = repo.mainRevert(source);
      repo.checkoutRelease();
      final backport = repo.backport(source);
      final record = repo.retain(backport, _record(backport, source, revert));
      final output = await repo.parity();
      expect(output, contains('$backport backport exact'));
      expect(output, contains('$record forward-port #61'));
      expect(repo.requests, isEmpty);
      await expectLater(
        repo.parity(closed: true),
        throwsA(_failure('issue #61 is open')),
      );
      repo.issue = {'number': 61, 'state': 'closed'};
      expect(await repo.parity(closed: true), contains(backport));
    });

    for (final (name, record, diagnostic) in [
      (
        'another backport',
        (String b, String r) => _record(r, source, r),
        'does not match',
      ),
      (
        'another source',
        (String b, String r) => _record(b, b, r),
        'does not match',
      ),
      (
        'another revert',
        (String b, String r) => _record(b, source, b),
        'reverted on main',
      ),
      (
        'another issue',
        (String b, String r) => _record(b, source, r, issue: 62),
        'Forward-port',
      ),
      (
        'a zero issue',
        (String b, String r) => _record(b, source, r, issue: 0),
        'does not match',
      ),
      (
        'a string issue',
        (String b, String r) => _record(b, source, r, issue: '61'),
        'not a retained',
      ),
      (
        'no trailing newline',
        (String b, String r) => _record(b, source, r).trim(),
        'does not match',
      ),
      (
        'reordered keys',
        (String b, String r) =>
            '{"source":"$source","backport":"$b","revert":"$r","issue":61}\n',
        'does not match',
      ),
      ('invalid JSON', (String b, String r) => 'not json\n', 'not valid JSON'),
    ]) {
      test('rejects a retained record with $name', () async {
        final revert = repo.mainRevert(source);
        repo.checkoutRelease();
        final backport = repo.backport(source);
        repo.retain(backport, record(backport, revert));
        await expectLater(
          repo.parity(),
          throwsA(allOf(_failure(backport), _failure(diagnostic))),
        );
      });
    }

    test('rejects a record whose commit is not bound to its issue', () async {
      final revert = repo.mainRevert(source);
      repo.checkoutRelease();
      final backport = repo.backport(source);
      repo.retain(
        backport,
        _record(backport, source, revert),
        body: 'Forward-port: https://github.com/$_repo/issues/62',
      );
      await expectLater(
        repo.parity(),
        throwsA(allOf(_failure(backport), _failure('issue #61'))),
      );
    });

    for (final (name, subject, path, passes) in [
      ('shares a path', 'Revert "Unknown change (#70)"', 'fix', false),
      ('shares no path', 'Revert "Unknown change (#70)"', 'other', true),
    ]) {
      test('an unresolved revert that $name', () async {
        final revert = repo.mainCommit(
          subject,
          body: 'This reverts commit ${'0' * 40}.',
          file: path,
          content: 'unknown\n',
        );
        repo.checkoutRelease();
        final backport = repo.backport(source);
        if (passes) {
          expect(await repo.parity(), contains('$backport backport exact'));
        } else {
          await expectFlagged(backport, revert);
        }
      });
    }

    test('all-lines parity checks only the maximal tip', () async {
      final revert = repo.mainRevert(source, subject: 'Revert fix (#59)');
      repo.checkoutRelease();
      final backport = repo.backport(source);
      repo.prep('1.0.1', pr: 52);
      repo.git(['tag', 'v1.0.1']);
      repo.git(['update-ref', _release, 'HEAD']);
      final failure = allOf(
        _failure('release/1.0.x: $backport'),
        _failure(revert),
      );
      await expectLater(repo.parity(all: true), throwsA(failure));
      repo.backport(
        revert,
        body: _backport(revert, pr: 59, body: _revertBody(source)),
        file: 'undo',
      );
      repo.git(['update-ref', _release, 'HEAD']);
      expect(await repo.parity(all: true), contains('$backport backport'));
    });

    test('the backport guard follows the main revert state', () async {
      final revert = repo.mainRevert(source);
      await expectLater(
        repo.guard(_backport(source)),
        throwsA(allOf(_failure(source), _failure(revert))),
      );
      repo.mainRevert(
        revert,
        subject: 'Restore the fix (#60)',
        body: _revertBody(revert),
      );
      expect(await repo.guard(_backport(source)), contains('verified'));
      expect(repo.requests, ['repos/$_repo/pulls/51']);
    });
  });

  test('a false cherry-pick trailer cannot fall back to patch-id', () async {
    final sha = repo.mainFix();
    repo.checkoutRelease();
    final fake = repo.backport(sha, body: _backport(repo.minor, body: _landed));
    await expectLater(
      repo.parity(),
      throwsA(allOf(_failure(fake), _failure('v1.0.0'))),
    );
  });

  test(
    'parity checks landed core bullets even when the patch is exact',
    () async {
      final sha = repo.mainFix();
      repo.checkoutRelease();
      final changed = repo.backport(
        sha,
        body: _backport(
          sha,
          body: _landed.replaceFirst(
            'Preserve the selected',
            'Restore the selected',
          ),
        ),
      );
      await expectLater(
        repo.parity(),
        throwsA(allOf(_failure(changed), _failure('core Changelog'))),
      );
    },
  );

  test('a tagged prep cannot exempt unrelated paths', () async {
    repo.mainFix();
    repo.checkoutRelease();
    repo.write('lib/branch_only.dart', 'void fix() {}');
    final sha = repo.prep('1.0.1', pr: 52);
    repo.git(['tag', '-a', 'v1.0.1', '-m', 'Published']);
    for (final all in [false, true]) {
      await expectLater(
        repo.parity(all: all),
        throwsA(allOf(_failure(sha), _failure('lib/branch_only.dart'))),
      );
    }
  });

  test(
    'parity requires the minor tag on the release first-parent chain',
    () async {
      repo.git(['checkout', '-q', '--orphan', 'other-history']);
      repo.commit('Unrelated root', file: 'unrelated');
      repo.git([
        'merge',
        '-q',
        '--allow-unrelated-histories',
        '--no-ff',
        repo.minor,
        '-m',
        'Minor is a side parent',
      ]);
      await expectLater(
        repo.parity(),
        throwsA(
          _failure('v1.0.0 is absent from the release first-parent chain'),
        ),
      );
    },
  );

  test(
    'parity rejects a release merge even with valid backport metadata',
    () async {
      final source = repo.mainFix();
      repo.checkoutRelease();
      repo.git(['checkout', '-qb', 'side']);
      repo.commit('Branch-only fix', file: 'branch-only');
      repo.git(['checkout', '-q', 'release/1.0.x']);
      repo.git([
        'merge',
        '-q',
        '--no-ff',
        'side',
        '-m',
        'Backport fix (#55)\n\n${_backport(source, body: _landed)}',
      ]);
      final sha = repo.git(['rev-parse', 'HEAD']);
      await expectLater(
        repo.parity(),
        throwsA(allOf(_failure(sha), _failure('merge commits'))),
      );
    },
  );

  test(
    'parity rejects a shallow clone before examining release lines',
    () async {
      repo.mainFix();
      final clone = Directory.systemTemp.createTempSync(
        'patch-branch-shallow-',
      );
      addTearDown(() => clone.deleteSync(recursive: true));
      repo.git([
        'clone',
        '-q',
        '--depth',
        '1',
        repo.root.uri.toString(),
        clone.path,
      ]);
      await expectLater(
        runPatchBranch(['parity', '--main', 'HEAD'], directory: clone),
        throwsA(_failure('full Git history')),
      );
    },
  );

  test('all-lines parity ignores patch tags on main', () async {
    repo.mainFix();
    repo.git(['tag', 'v1.0.1']);
    final output = await repo.parity(all: true);
    expect(output, contains('parity verified'));
    expect(output, isNot(contains('v1.0.1')));
  });

  test('all-lines parity names a missing minor tag', () async {
    repo.checkoutRelease();
    repo.prep('1.0.1', pr: 52);
    repo.git(['tag', 'v1.0.1']);
    repo.git(['tag', '-d', 'v1.0.0']);
    await expectLater(
      repo.parity(all: true),
      throwsA(_failure('Cannot resolve minor tag v1.0.0')),
    );
  });

  test('parity skips a tagged prep and a recovered prep pair', () async {
    repo.mainFix();
    repo.checkoutRelease();
    final released = repo.prep('1.0.1', pr: 52);
    repo.git(['tag', '-a', 'v1.0.1', '-m', 'Published']);
    final failed = repo.prep('1.0.2', pr: 53);
    final recovery = repo.recover(failed, released);
    final output = await repo.parity();
    expect(output, contains('$released prep'));
    expect(output, contains('$failed recovered-prep'));
    expect(output, contains('$recovery recovery'));
    expect(repo.requests, isEmpty);
  });

  test('a recovery marker cannot exempt unrelated changes', () async {
    repo.mainFix();
    repo.checkoutRelease();
    final failed = repo.commit('Branch-only fix (#53)', file: 'branch-only');
    repo.commit(
      'Claim a failed prep recovery',
      file: 'tool/release/recoveries/$failed.json',
    );
    await expectLater(repo.parity(), throwsA(_failure(failed)));
  });

  test('a recovery cannot carry a change outside the prep inverse', () async {
    repo.mainFix();
    repo.checkoutRelease();
    final before = repo.prep('1.0.1', pr: 52);
    repo.git(['tag', 'v1.0.1']);
    final failed = repo.prep('1.0.2', pr: 53);
    final recovery = repo.recover(failed, before, withExtraChange: true);
    await expectLater(repo.parity(), throwsA(_failure(recovery)));
  });

  test('parity checks the closed state only when requested', () async {
    repo.mainFix();
    repo.checkoutRelease();
    final forward = repo.commit(
      'Release-line workaround',
      body: _forward,
      file: 'pin',
    );
    expect(await repo.parity(), contains('$forward forward-port'));
    expect(repo.requests, isEmpty);
    await expectLater(
      repo.parity(closed: true),
      throwsA(_failure('issue #61 is open')),
    );
    repo.issue = {'number': 61, 'state': 'closed'};
    expect(await repo.parity(closed: true), contains('$forward forward-port'));
  });

  test(
    'all-lines parity finds branch work after the last published tag',
    () async {
      final sha = repo.mainFix();
      repo.checkoutRelease();
      repo.backport(sha);
      final tag = repo.prep('1.0.1', pr: 52);
      repo.git(['tag', 'v1.0.1']);
      expect(await repo.parity(all: true), contains('v1.0.1'));
      final unported = repo.commit('Unbackported after tag', file: 'pin');
      repo.git(['update-ref', _release, unported]);
      await expectLater(
        repo.parity(all: true),
        throwsA(_failure('$unported Unbackported after tag')),
      );
      repo.git(['update-ref', '-d', _release]);
      expect(await repo.parity(all: true), contains('$tag prep'));
    },
  );

  test('CLI distinguishes usage, policy failure, and a no-op', () {
    final script = File('tool/release/patch_branch.dart').absolute.path;
    final eventFile = File('${repo.root.path}/event.json');
    ProcessResult invoke(List<String> args, String base) {
      eventFile.writeAsStringSync(
        jsonEncode({
          'pull_request': {
            'base': {
              'ref': base,
              'repo': {'full_name': _repo},
            },
          },
        }),
      );
      return Process.runSync(
        Platform.resolvedExecutable,
        [script, ...args],
        workingDirectory: repo.root.path,
        environment: {'GITHUB_EVENT_PATH': eventFile.path},
      );
    }

    final usage = invoke(['parity', '--line', '1.0', '--main', _main], 'main');
    expect(usage.exitCode, 64, reason: '${usage.stderr}');
    expect(usage.stderr, contains('Usage:'));
    final denied = invoke(['backport-guard', '--event'], 'release/1.0.x');
    expect(denied.exitCode, 1, reason: '${denied.stderr}');
    expect(denied.stderr, contains('Backport of'));
    final bypass = invoke(['backport-guard', '--event'], 'main');
    expect(bypass.exitCode, 0, reason: '${bypass.stderr}');
    expect(bypass.stdout, isEmpty);
  });

  test(
    'all-lines parity checks off-chain tags even with no release ref',
    () async {
      repo.mainFix();
      repo.checkoutRelease();
      final unported = repo.commit('Unbackported before tag', file: 'pin');
      repo.prep('1.0.1', pr: 52);
      repo.git(['tag', 'v1.0.1']);
      await expectLater(repo.parity(all: true), throwsA(_failure(unported)));
    },
  );
}

class _Repository {
  _Repository() : root = Directory.systemTemp.createTempSync('patch-branch-') {
    git(['init', '-q', '-b', 'main']);
    git(['config', 'user.name', 'Fixture']);
    git(['config', 'user.email', 'fixture@example.invalid']);
    git(['config', 'commit.gpgsign', 'false']);
    minor = prep('1.0.0', pr: 50);
    git(['tag', 'v1.0.0']);
    git(['update-ref', _main, minor]);
  }

  final Directory root;
  late String minor;
  String line = '1.0';
  final requests = <String>[];
  String prBody = _authored;
  Map<String, Object> issue = {'number': 61, 'state': 'open'};

  String git(List<String> arguments) {
    final result = Process.runSync(
      'git',
      arguments,
      workingDirectory: root.path,
    );
    if (result.exitCode != 0) {
      throw StateError('git $arguments: ${result.stderr}');
    }
    return (result.stdout as String).trim();
  }

  void write(String file, String content) {
    File('${root.path}/$file')
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  String commit(
    String subject, {
    String body = '',
    required String file,
    String content = 'change\n',
  }) {
    write(file, content);
    git(['add', '-A']);
    git(['commit', '-qm', '$subject\n\n$body']);
    return git(['rev-parse', 'HEAD']);
  }

  String prep(String version, {required int pr}) => commit(
    'Prepare llamadart $version release (#$pr)',
    body: '## Changelog\n\nN/A: Release prep.',
    file: 'pubspec.yaml',
    content: 'name: llamadart\nversion: $version\n',
  );

  String mainFix({String body = _landed}) {
    final sha = commit('Fix a regression (#51)', body: body, file: 'fix');
    git(['update-ref', _main, sha]);
    return sha;
  }

  String commitStaged(String subject, String body) {
    git(['commit', '-qm', '$subject\n\n$body']);
    return git(['rev-parse', 'HEAD']);
  }

  String mainCommit(
    String subject, {
    String body = '',
    required String file,
    String content = 'change\n',
  }) {
    final sha = commit(subject, body: body, file: file, content: content);
    git(['update-ref', _main, sha]);
    return sha;
  }

  String mainRevert(String sha, {String? subject, String? body}) {
    git(['revert', '--no-commit', sha]);
    final revert = commitStaged(
      subject ?? 'Revert "Fix a regression (#51)" (#59)',
      body ?? _revertBody(sha),
    );
    git(['update-ref', _main, revert]);
    return revert;
  }

  String retain(String backport, String record, {String body = _forward}) =>
      commit(
        'Retain the backport',
        body: body,
        file: '$_retained/$backport.json',
        content: record,
      );

  void anchorPrepBase(String version) {
    line = version.substring(0, version.lastIndexOf('.'));
    git(['add', '-A']);
    git(['commit', '-q', '-m', 'Seed release metadata']);
    minor = git(['rev-parse', 'HEAD']);
    git(['tag', '-f', 'v$line.0']);
    git(['update-ref', _main, minor]);
  }

  void checkoutRelease() => git(['checkout', '-qb', 'release/$line.x', minor]);

  String backport(String sha, {String? body, String file = 'fix'}) {
    if (git(['status', '--short']).isNotEmpty) {
      throw StateError('Dirty fixture');
    }
    if (File('${root.path}/$file').existsSync()) {
      return commit(
        'Backport fix (#55)',
        body: body ?? _backport(sha, body: _landed),
        file: file,
        content: 'adapted change\n',
      );
    }
    return commit(
      'Backport fix (#55)',
      body: body ?? _backport(sha, body: _landed),
      file: file,
    );
  }

  String recover(String prep, String before, {bool withExtraChange = false}) {
    git(['revert', '--no-commit', prep]);
    if (withExtraChange) {
      File('${root.path}/extra-recovery-change').writeAsStringSync('extra');
    }
    return commit(
      'Recover unpublished release prep (#54)',
      file: 'tool/release/recoveries/$prep.json',
      content:
          '${jsonEncode({'version': '1.0.2', 'prep': prep, 'before': before, 'pr': 53})}\n',
    );
  }

  Future<Object?> lookup(String endpoint, {required bool paginate}) async {
    expect(paginate, isFalse);
    requests.add(endpoint);
    return switch (endpoint) {
      'repos/$_repo/pulls/51' || 'repos/$_repo/pulls/52' => {
        'number': int.parse(endpoint.split('/').last),
        'base': {
          'ref': 'main',
          'repo': {'full_name': _repo},
        },
        'body': prBody,
      },
      'repos/$_repo/issues/61' => issue,
      _ => throw StateError('Unexpected lookup $endpoint'),
    };
  }

  Future<String> guard(
    String? body, {
    String? base,
    String head = 'backport/51-1.0',
    String headRepository = _repo,
    List<String> labels = const [],
    bool includeShas = true,
  }) => runPatchBranch(
    ['backport-guard', '--event'],
    directory: root,
    event: {
      'pull_request': {
        'base': {
          'ref': base ?? 'release/$line.x',
          if (includeShas) 'sha': minor,
          'repo': {'full_name': _repo},
        },
        'head': {
          'ref': head,
          if (includeShas) 'sha': git(['rev-parse', 'HEAD']),
          'repo': {'full_name': headRepository},
        },
        'labels': [
          for (final label in labels) {'name': label},
        ],
        'body': body,
      },
    },
    lookup: lookup,
  );

  Future<String> parity({bool all = false, bool closed = false}) =>
      runPatchBranch(
        [
          'parity',
          '--main',
          _main,
          if (!all) ...['--line', line, '--branch', 'HEAD'],
          if (closed) '--require-closed-forward-ports',
        ],
        directory: root,
        lookup: lookup,
      );
}
