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

String _metadata(String sha, {int pr = 51}) =>
    'Backport of https://github.com/$_repo/pull/$pr\n'
    '(cherry picked from commit $sha)';

String _backport(String sha, {int pr = 51, String body = _authored}) => body
    .replaceFirst('## Summary\n', '## Summary\n${_metadata(sha, pr: pr)}\n');

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

  test('routed same-repository core prep is exempt', () async {
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
  late final String minor;
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

  String commit(
    String subject, {
    String body = '',
    required String file,
    String content = 'change\n',
  }) {
    File('${root.path}/$file')
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
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

  void checkoutRelease() => git(['checkout', '-qb', 'release/1.0.x', minor]);

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
    String base = 'release/1.0.x',
    String head = 'backport/51-1.0',
    String headRepository = _repo,
  }) => runPatchBranch(
    ['backport-guard', '--event'],
    directory: root,
    event: {
      'pull_request': {
        'base': {
          'ref': base,
          'repo': {'full_name': _repo},
        },
        'head': {
          'ref': head,
          'repo': {'full_name': headRepository},
        },
        'labels': [],
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
          if (!all) ...['--line', '1.0', '--branch', 'HEAD'],
          if (closed) '--require-closed-forward-ports',
        ],
        directory: root,
        lookup: lookup,
      );
}
