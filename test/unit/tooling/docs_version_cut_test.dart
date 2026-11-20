@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

const _script = 'tool/release/reopen_unreleased_changelog.dart';
const _workflow = '.github/workflows/docs_version_cut.yml';
const _commitStep = 'Commit versioned docs';
const _docsChangelog = 'website/docs/changelog/recent-releases.md';
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

    group('commit step', () {
      late Directory root;
      late _Origin origin;
      setUp(() {
        root = Directory.systemTemp.createTempSync('docs-cut-step-');
        origin = _Origin.create(root);
      });
      tearDown(() => root.deleteSync(recursive: true));

      test('cuts only versioned docs in one commit', () {
        final before = origin.mainSha();
        final result = origin.runStep(cutDocs: true);
        expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');

        expect(origin.git(['rev-parse', 'main~1']), before);
        expect(
          origin.git(['log', '-1', '--format=%s', 'main']),
          'docs: cut version 1.0.0',
        );
        expect(
          origin.git(['show', '--name-only', '--format=', 'main']).split('\n'),
          unorderedEquals([
            'website/versioned_docs/version-1.0.0/index.md',
            'website/versions.json',
          ]),
        );
        expect(origin.mainFile('CHANGELOG.md'), _released);
        expect(origin.mainFile(_docsChangelog), '$_docsIntro$_released');
      });

      test('a rerun after the cut pushes nothing', () {
        expect(origin.runStep(cutDocs: true).exitCode, 0);
        final cut = origin.mainSha();

        for (final cutDocs in [true, false]) {
          final rerun = origin.runStep(cutDocs: cutDocs);
          expect(rerun.exitCode, 0, reason: '${rerun.stdout}${rerun.stderr}');
          expect(rerun.stdout, contains('Nothing to push.'));
          expect(origin.mainSha(), cut);
        }
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

        final result = origin.runStep(cutDocs: true);
        expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');

        expect(origin.git(['rev-parse', 'main~1']), before);
        expect(
          origin.git(['show', '--name-only', '--format=', 'main']),
          isNot(contains('CHANGELOG.md')),
        );
        expect(origin.mainFile('CHANGELOG.md'), pending);
        expect(origin.mainFile(_docsChangelog), '$_docsIntro$pending');
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
      'CHANGELOG.md': _released,
      _docsChangelog: '$_docsIntro$_released',
      'website/versions.json': '[]\n',
      'website/versioned_docs/version-0.9.0/index.md': '# 0.9.0\n',
      'website/versioned_sidebars/version-0.9.0.json': '{}\n',
      _script: File(_script).readAsStringSync(),
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

  /// Runs the workflow's commit step in a fresh checkout of the tag, after
  /// optionally simulating `cut_version.dart`.
  ProcessResult runStep({required bool cutDocs}) {
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
    checkout.git(['checkout', '-q', '--detach', 'v1.0.0']);
    if (cutDocs) {
      File(
        '${checkout.directory.path}/website/versions.json',
      ).writeAsStringSync('["1.0.0"]\n');
      File(
          '${checkout.directory.path}/website/versioned_docs/version-1.0.0/'
          'index.md',
        )
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('# 1.0.0\n');
    }

    final steps =
        (((loadYaml(_read(_workflow)) as YamlMap)['jobs'] as YamlMap)
                    .values
                    .single
                as YamlMap)['steps']
            as YamlList;
    final step = steps.cast<YamlMap>().singleWhere(
      (step) => step['name'] == _commitStep,
    );
    final dartBin = File(Platform.resolvedExecutable).parent.path;
    return Process.runSync(
      'bash',
      ['-e', '-c', step['run'] as String],
      workingDirectory: checkout.directory.path,
      environment: {
        ...seed.environment,
        'GITHUB_REF_NAME': 'v1.0.0',
        'PATH': '$dartBin:${Platform.environment['PATH']}',
      },
    );
  }
}
