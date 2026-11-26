@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

const _script = 'tool/release/reopen_unreleased_changelog.dart';
const _workflow = '.github/workflows/docs_version_cut.yml';
const _docsChangelog = 'website/docs/changelog/recent-releases.md';
const _versionedDocs = 'website/versioned_docs';
const _versions = 'website/versions.json';
const _posixOnly = 'runs the workflow step under a POSIX Bash runtime';

const _released = '## 1.0.0\n\n- Shipped.\n\n## 0.9.0\n\n- Older.\n';
const _docsIntro =
    '---\ntitle: Recent releases\n---\n\nFor full notes, see CHANGELOG.md.\n\n';

void main() {
  group('docs_version_cut.yml', () {
    test('runs only on core release tags', () {
      final on = (loadYaml(_read(_workflow)) as YamlMap)['on'] as YamlMap;
      expect(on.keys, ['push']);
      // Genkit tags are `genkit_llamadart-v*` and companion tags
      // `<package>-v*`, so neither can match.
      expect((on['push'] as YamlMap)['tags'], ['v*']);
    });

    test('the active snapshot writer only stages versioned docs', () {
      final source = _read(_workflow);
      expect(source, isNot(contains(_script)));
      expect(source, isNot(contains('git commit --amend')));
      expect(source, isNot(contains('git add CHANGELOG.md')));
    });

    group('snapshot steps', () {
      late Directory root;
      late _Origin origin;
      setUp(() {
        root = Directory.systemTemp.createTempSync('docs-cut-step-');
        origin = _Origin.create(root);
      });
      tearDown(() => root.deleteSync(recursive: true));

      test('cuts only versioned docs in one commit', () {
        final before = origin.mainSha();
        final result = origin.runSteps();
        expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');

        expect(origin.git(['rev-parse', 'main~1']), before);
        expect(
          origin.git(['log', '-1', '--format=%s', 'main']),
          'docs: cut version 1.0.0',
        );
        expect(
          origin.git(['show', '--name-only', '--format=', 'main']).split('\n'),
          unorderedEquals([
            '$_versionedDocs/version-1.0.0/index.md',
            '$_versionedDocs/version-1.0.0/changelog/recent-releases.md',
            'website/versioned_sidebars/version-1.0.0-sidebars.json',
            _versions,
          ]),
        );
        expect(
          origin.mainFile('$_versionedDocs/version-1.0.0/index.md'),
          '# 1.0.0\n',
        );
        expect(origin.mainFile(_versions), '[\n  "1.0.0",\n  "0.9.0"\n]\n');
        expect(
          origin.mainFile(
            'website/versioned_sidebars/version-1.0.0-sidebars.json',
          ),
          '{\n  "docsSidebar": [\n    "index"\n  ]\n}\n',
        );
        expect(origin.mainFile('CHANGELOG.md'), _released);
        expect(origin.mainFile(_docsChangelog), '$_docsIntro$_released');
      });

      test('a rerun after the cut pushes nothing', () {
        expect(origin.runSteps().exitCode, 0);
        final cut = origin.mainSha();

        final rerun = origin.runSteps();
        expect(rerun.exitCode, 0, reason: '${rerun.stdout}${rerun.stderr}');
        expect(rerun.stdout, contains('Nothing to push.'));
        expect(origin.mainSha(), cut);
      });

      test(
        'the frozen release workflow still invokes a zero-write command',
        () {
          final before = origin.mainSha();
          final retry = _runScript(origin.seed.directory, const []);
          expect(retry.exitCode, 0, reason: '${retry.stderr}');
          expect(origin.seed.git(['status', '--porcelain']), isEmpty);
          expect(origin.mainSha(), before);
        },
      );

      test('the frozen release command rejects unexpected arguments', () {
        final result = _runScript(origin.seed.directory, ['--write']);
        expect(result.exitCode, 64, reason: '${result.stderr}');
        expect(result.stderr, contains('Usage: dart $_script'));
        expect(origin.seed.git(['status', '--porcelain']), isEmpty);
      });

      test('preserves core changelog bytes on advanced main', () {
        const pending = '## 1.0.1\n\n- Published fix.\n\n$_released';
        origin.commitToMain({
          'CHANGELOG.md': pending,
          _docsChangelog: '$_docsIntro$pending',
        });
        final before = origin.mainSha();

        final result = origin.runSteps();
        expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');

        expect(origin.git(['rev-parse', 'main~1']), before);
        expect(
          origin.git(['show', '--name-only', '--format=', 'main']),
          isNot(contains('CHANGELOG.md')),
        );
        expect(origin.mainFile('CHANGELOG.md'), pending);
        expect(origin.mainFile(_docsChangelog), '$_docsIntro$pending');
      });

      for (final rewrite in [false, true]) {
        final action = rewrite ? 'is rewritten' : 'advances';
        test('refuses to push when main $action after fetch', () {
          final replacement = origin.git([
            'commit-tree',
            'main^{tree}',
            '-p',
            rewrite ? 'main^' : 'main',
            '-m',
            'Concurrent main update',
          ]);

          final result = origin.runSteps(moveMainTo: replacement);

          expect(result.exitCode, isNonZero);
          expect(result.stderr, contains('[rejected]'));
          expect(origin.mainSha(), replacement);
        });
      }

      test('cuts a diverged patch into current main from the tag bytes', () {
        const patch = '## 0.9.1\n\n- Patched.\n';
        origin.tagPatch('v0.9.1', {
          'CHANGELOG.md': patch,
          'pubspec.yaml': 'version: 0.9.1\n',
          _docsChangelog: '$_docsIntro$patch',
          'website/docs/index.md': '# Patch tag\n',
          'website/sidebars.json': '{"docsSidebar":["patch"]}\n',
        });
        origin.commitToMain({_versions: '["1.0.0", "0.9.0"]\n'});
        final before = origin.mainSha();

        final result = origin.runSteps(tag: 'v0.9.1');
        expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
        expect(origin.git(['rev-parse', 'main~1']), before);
        expect(
          origin.git(['log', '-1', '--format=%s', 'main']),
          'docs: cut version 0.9.1',
        );
        expect(
          origin.git(['show', '--name-only', '--format=', 'main']).split('\n'),
          unorderedEquals([
            '$_versionedDocs/version-0.9.1/index.md',
            '$_versionedDocs/version-0.9.1/changelog/recent-releases.md',
            'website/versioned_sidebars/version-0.9.1-sidebars.json',
            _versions,
          ]),
        );
        expect(origin.mainFile('pubspec.yaml'), 'version: 1.0.0\n');
        expect(origin.mainFile('CHANGELOG.md'), _released);
        expect(origin.mainFile(_docsChangelog), '$_docsIntro$_released');
        expect(origin.mainFile('website/docs/index.md'), '# 1.0.0\n');
        expect(
          origin.mainFile('$_versionedDocs/version-0.9.1/index.md'),
          '# Patch tag\n',
        );
        expect(
          origin.mainFile(
            '$_versionedDocs/version-0.9.1/changelog/recent-releases.md',
          ),
          '$_docsIntro$patch',
        );
        expect(
          jsonDecode(
            origin.mainFile(
              'website/versioned_sidebars/version-0.9.1-sidebars.json',
            ),
          ),
          {
            'docsSidebar': ['patch'],
          },
        );
        expect(jsonDecode(origin.mainFile(_versions)), [
          '1.0.0',
          '0.9.1',
          '0.9.0',
        ]);
        final cut = origin.mainSha();
        final rerun = origin.runSteps(tag: 'v0.9.1');
        expect(rerun.exitCode, 0, reason: '${rerun.stdout}${rerun.stderr}');
        expect(origin.mainSha(), cut);
      });

      test('refuses a half-written snapshot on main', () {
        origin.commitToMain({
          '$_versionedDocs/version-1.0.0/index.md': '# Incomplete\n',
        });
        final before = origin.mainSha();
        final result = origin.runSteps();
        expect(result.exitCode, isNonZero);
        expect(result.stderr, contains('Snapshot files for 1.0.0 exist'));
        expect(origin.mainSha(), before);
      });
    }, skip: Platform.isWindows ? _posixOnly : false);
  });
}

String _read(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');

ProcessResult _runScript(Directory root, List<String> arguments) =>
    Process.runSync(Platform.resolvedExecutable, [
      File(_script).absolute.path,
      ...arguments,
    ], workingDirectory: root.path);

/// Git with no user or system configuration, so signing, hooks and
/// templates on the host cannot change what the commands do.
Map<String, String> _gitEnvironment(Directory root) {
  final config = File('${root.path}/gitconfig')..writeAsStringSync('');
  return {
    'GIT_CONFIG_GLOBAL': config.path,
    'GIT_CONFIG_NOSYSTEM': '1',
    'GIT_AUTHOR_NAME': 'Test',
    'GIT_AUTHOR_EMAIL': 'test@example.com',
    'GIT_COMMITTER_NAME': 'Test',
    'GIT_COMMITTER_EMAIL': 'test@example.com',
  };
}

class _Repo {
  _Repo(this.directory, this.environment);

  factory _Repo.init(Directory root, Map<String, String> files) {
    final directory = Directory('${root.path}/repo')..createSync();
    final repo = _Repo(directory, _gitEnvironment(root));
    repo.git(['init', '-q', '-b', 'main']);
    repo.commit(files);
    return repo;
  }

  final Directory directory;
  final Map<String, String> environment;

  String git(List<String> arguments, {bool trim = true}) {
    final result = Process.runSync(
      'git',
      arguments,
      workingDirectory: directory.path,
      environment: environment,
    );
    if (result.exitCode != 0) {
      fail('git ${arguments.join(' ')} failed:\n${result.stderr}');
    }
    final output = result.stdout as String;
    return trim ? output.trim() : output;
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

/// A bare `origin` whose `main` is tagged `v1.0.0`, as after a core release.
class _Origin {
  _Origin(this.root, this.seed);

  factory _Origin.create(Directory root) {
    Process.runSync('git', [
      'init',
      '-q',
      '--bare',
      '-b',
      'main',
      '${root.path}/origin.git',
    ], environment: _gitEnvironment(root));
    final seed = _Repo.init(root, {
      'CHANGELOG.md': '## 0.9.0\n\n- Older.\n',
      'pubspec.yaml': 'version: 0.9.0\n',
      'website/docs/index.md': '# 0.9.0\n',
      _docsChangelog: '$_docsIntro## 0.9.0\n\n- Older.\n',
      _versions: '["0.9.0"]\n',
      'website/sidebars.json': '{"docsSidebar":["index"]}\n',
      '$_versionedDocs/version-0.9.0/index.md': '# 0.9.0\n',
      'website/versioned_sidebars/version-0.9.0.json': '{}\n',
      _script: File(_script).readAsStringSync(),
      for (final path in [
        'website/tool/cut_version.dart',
        'website/lib/src/tooling/version_cut.dart',
      ])
        path: _read(path),
    });
    seed.git(['tag', 'v0.9.0']);
    seed.commit({
      'CHANGELOG.md': _released,
      'pubspec.yaml': 'version: 1.0.0\n',
      'website/docs/index.md': '# 1.0.0\n',
      _docsChangelog: '$_docsIntro$_released',
    });
    seed.git(['tag', 'v1.0.0']);
    seed.git(['remote', 'add', 'origin', '${root.path}/origin.git']);
    seed.git(['push', '-q', 'origin', 'main', 'v1.0.0']);
    return _Origin(root, seed);
  }

  final Directory root;
  final _Repo seed;
  var _runs = 0;

  String git(List<String> arguments, {bool trim = true}) =>
      seed.git(['--git-dir=${root.path}/origin.git', ...arguments], trim: trim);

  String mainSha() => git(['rev-parse', 'main']);

  String mainFile(String path) => git(['show', 'main:$path'], trim: false);

  void commitToMain(Map<String, String> files) {
    seed.commit(files);
    seed.git(['push', '-q', 'origin', 'main']);
  }

  void tagPatch(String tag, Map<String, String> files) {
    seed.git(['checkout', '-q', '-b', 'release/0.9.x', 'v0.9.0']);
    seed.commit(files);
    seed.git(['tag', tag]);
    seed.git(['push', '-q', 'origin', 'release/0.9.x', tag]);
    seed.git(['checkout', '-q', 'main']);
  }

  ProcessResult runSteps({String tag = 'v1.0.0', String? moveMainTo}) {
    final checkout = _Repo(
      Directory('${root.path}/run${_runs++}'),
      seed.environment,
    );
    Process.runSync('git', [
      'clone',
      '-q',
      '${root.path}/origin.git',
      checkout.directory.path,
    ], environment: seed.environment);
    checkout.git(['checkout', '-q', '--detach', tag]);
    final config = _websitePackageConfig(checkout.directory);
    final bin = Directory('${root.path}/bin$_runs')..createSync();
    final dart = File('${bin.path}/dart')
      ..writeAsStringSync(r'''#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == run ]]
shift
if [[ -n "${MOVE_MAIN_TO:-}" ]]; then
  git --git-dir="$ORIGIN_GIT_DIR" update-ref refs/heads/main "$MOVE_MAIN_TO"
fi
exec "$REAL_DART" --packages="$PACKAGE_CONFIG" "$@"
''');
    final chmod = Process.runSync('chmod', ['+x', dart.path]);
    expect(chmod.exitCode, 0, reason: '${chmod.stderr}');

    final steps =
        (((loadYaml(_read(_workflow)) as YamlMap)['jobs'] as YamlMap)
                    .values
                    .single
                as YamlMap)['steps']
            as YamlList;
    final scripts = steps.cast<YamlMap>().where(
      (step) =>
          step['name'] != 'Install website dependencies' && step['run'] != null,
    );
    return Process.runSync(
      'bash',
      [
        '-e',
        '-o',
        'pipefail',
        '-c',
        scripts.map((step) => '(\n${step['run']}\n)').join('\n'),
      ],
      workingDirectory: checkout.directory.path,
      environment: {
        ...seed.environment,
        'GITHUB_REF_NAME': tag,
        'PATH': '${bin.path}:${Platform.environment['PATH']}',
        'REAL_DART': Platform.resolvedExecutable,
        'PACKAGE_CONFIG': config.path,
        'TMPDIR': root.path,
        if (moveMainTo != null) ...{
          'MOVE_MAIN_TO': moveMainTo,
          'ORIGIN_GIT_DIR': '${root.path}/origin.git',
        },
      },
    );
  }
}

// Resolve the real website cutter in the scratch tag without a network fetch.
File _websitePackageConfig(Directory checkout) {
  final existing = File('.dart_tool/package_config.json').absolute;
  final config =
      jsonDecode(existing.readAsStringSync()) as Map<String, dynamic>;
  final packages = (config['packages'] as List).cast<Map<String, dynamic>>();
  for (final package in packages) {
    package['rootUri'] = existing.uri
        .resolve(package['rootUri'] as String)
        .toString();
  }
  packages.add({
    'name': 'llamadart_website',
    'rootUri': Uri.directory('${checkout.path}/website').toString(),
    'packageUri': 'lib/',
    'languageVersion': '3.10',
  });
  return File('${checkout.path}/package_config.json')
    ..writeAsStringSync(jsonEncode(config));
}
