@TestOn('vm')
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import 'support/markdown_reader_exemptions.dart';
import 'support/markdown_readers.dart';

const String _inventoryPath = 'tool/ci/markdown_test_suites.txt';

void expectMarkdownJob(Map job) {
  expect(job['runs-on'], 'ubuntu-latest');
  expect(job['continue-on-error'], anyOf(isNull, isFalse));
  final step = (job['steps'] as List).cast<Map>().singleWhere(
    (step) => step['name'] == 'Run Markdown tests',
  );
  expect(step.containsKey('if'), isFalse);
  expect(step['continue-on-error'], anyOf(isNull, isFalse));
  expect(
    step['run'],
    'xargs dart test -p vm -j 1 --exclude-tags local-only '
    '< $_inventoryPath',
  );
}

/// A scratch checkout: the files written to it are the discoverable universe.
class _Tree {
  _Tree() : root = Directory.systemTemp.createTempSync('markdown_readers');

  final Directory root;
  final Set<String> files = {};

  void write(String path, String content) {
    File(p.join(root.path, path))
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
    files.add(path);
  }

  /// Present on disk but outside the universe, like an ignored path.
  void writeUntracked(String path, String content) {
    File(p.join(root.path, path))
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  void delete(String path) {
    File(p.join(root.path, path)).deleteSync();
    files.remove(path);
  }

  MarkdownReaders readers({
    Map<String, String> packageRoots = const {'llamadart': 'lib'},
  }) => MarkdownReaders(
    files: files,
    root: root.path,
    packageRoots: packageRoots,
  );

  List<String> problems({
    Set<String> inventory = const {},
    Map<String, Exemption> suites = const {},
    Map<String, Exemption> helpers = const {},
    Map<String, String> packageRoots = const {'llamadart': 'lib'},
  }) => readerProblems(
    readers: readers(packageRoots: packageRoots),
    inventory: inventory,
    suiteExemptions: suites,
    helperExemptions: helpers,
  );

  void close() => root.deleteSync(recursive: true);
}

Exemption _exempt(
  Map<String, String> evidence, {
  String reason = 'Checked by hand.',
  String? gate,
}) => (reason: reason, evidence: evidence, gate: gate);

_Tree _tree() {
  final tree = _Tree();
  addTearDown(tree.close);
  return tree;
}

void main() {
  final inventory = File(_inventoryPath).readAsLinesSync();
  final rootTests =
      Directory('test')
          .listSync(recursive: true)
          .whereType<File>()
          .map((file) => file.path.replaceAll(r'\', '/'))
          .where((path) => path.endsWith('_test.dart'))
          .toList()
        ..sort();

  test('the inventory is sorted, unique root test files', () {
    expect(inventory, isNotEmpty);
    expect(inventory, orderedEquals([...inventory.toSet()]..sort()));
    expect(rootTests, containsAll(inventory));
    expect(
      inventory,
      contains('test/unit/tooling/markdown_test_suites_test.dart'),
    );
  });

  test('the Markdown Tests job runs the inventory on Linux', () {
    final workflow =
        loadYaml(File('.github/workflows/ci.yml').readAsStringSync())
            as YamlMap;
    expectMarkdownJob(workflow['jobs']['markdown-tests'] as Map);
  });

  test('the Markdown job contract rejects masking its test step', () {
    final workflow =
        loadYaml(File('.github/workflows/ci.yml').readAsStringSync()) as Map;
    final job = workflow['jobs']['markdown-tests'] as Map;
    final steps = (job['steps'] as List).cast<Map>();
    for (final mutation in [
      {'continue-on-error': true},
      {'if': false},
      {
        'run':
            '${steps.singleWhere((s) => s['name'] == 'Run Markdown tests')['run']} || exit 0',
      },
    ]) {
      final mutated = {
        ...job,
        'steps': [
          for (final step in steps)
            if (step['name'] == 'Run Markdown tests')
              {...step, ...mutation}
            else
              step,
        ],
      };
      expect(
        () => expectMarkdownJob(mutated),
        throwsA(isA<TestFailure>()),
        reason: '$mutation',
      );
    }
  });

  test('the reader inventory, engine and exemptions have CODEOWNERS', () {
    expect(
      File('.github/CODEOWNERS').readAsLinesSync(),
      containsAll([
        '/test/unit/tooling/markdown_test_suites_test.dart @leehack',
        '/test/unit/tooling/support/markdown_readers.dart @leehack',
        '/test/unit/tooling/support/markdown_reader_exemptions.dart @leehack',
      ]),
    );
  });

  test(
    'every suite that may read Markdown is listed or exempt with evidence',
    () {
      final files = repositoryFiles();
      final problems = readerProblems(
        readers: MarkdownReaders(
          files: files,
          packageRoots: workspacePackageRoots(files),
        ),
        inventory: inventory.toSet(),
        suiteExemptions: suiteExemptions,
        helperExemptions: helperExemptions,
      );
      expect(
        problems,
        isEmpty,
        reason:
            'List a suite that reads tracked Markdown in $_inventoryPath, or '
            'exempt it in test/unit/tooling/support/markdown_reader_exemptions.dart '
            'after reading what it reaches.',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  group('discovery finds', () {
    void expectFinds(
      String name,
      Map<String, String> files,
      String evidence, {
      String suite = 'test/a_test.dart',
      Map<String, String> packageRoots = const {'llamadart': 'lib'},
    }) {
      test(name, () {
        final tree = _tree();
        files.forEach(tree.write);
        final reach = tree.readers(packageRoots: packageRoots).reach(suite);
        expect(reach.recorded.values.join(';'), contains(evidence));
        expect(tree.problems(packageRoots: packageRoots), [contains(suite)]);
      });
    }

    for (final code in [
      "File('NOTES.md').readAsStringSync();",
      "File('README').readAsStringSync();",
      "Directory('skills').listSync();",
      "Directory('doc').listSync();",
      "File('website/sidebars.json').existsSync();",
      "Process.runSync('git', ['ls-files']);",
      "Directory('.').listSync(recursive: true);",
    ]) {
      test('a suite that has $code', () {
        final tree = _tree()
          ..write('test/a_test.dart', 'void main() { $code }');
        expect(tree.readers().reach('test/a_test.dart').recorded, isNotEmpty);
      });
    }

    const extra = {'extra_pkg': 'packages/extra/lib'};
    expectFinds(
      'a conditional import branch',
      {
        'test/a_test.dart':
            "import 'package:extra_pkg/stub.dart'\n"
            "    if (dart.library.io) 'package:extra_pkg/io_reader.dart';\n"
            'void main() {}',
        'packages/extra/lib/stub.dart': 'const x = 1;',
        'packages/extra/lib/io_reader.dart': "final a = File('README.md');",
      },
      '.md | README',
      packageRoots: extra,
    );
    expectFinds(
      'a package import through a workspace root',
      {
        'test/a_test.dart':
            "import 'package:extra_pkg/reader.dart';\nvoid main() {}",
        'packages/extra/lib/reader.dart': "final b = Directory('doc');",
      },
      'doc/',
      packageRoots: extra,
    );
    expectFinds('a path joined from literals', {
      'test/a_test.dart':
          "void main() { Process.runSync('python3', "
          "[p.join('tool', 'docs', 'reader.py')]); }",
      'tool/docs/reader.py': "open('CHANGELOG.md')\n",
    }, '.md | CHANGELOG');
    expectFinds('a path joined with plus', {
      'test/a_test.dart': "void main() { run('tool/docs/' + 'reader.py'); }",
      'tool/docs/reader.py': "open('CHANGELOG.md')\n",
    }, '.md | CHANGELOG');
    expectFinds('an interpolated script path', {
      'test/a_test.dart':
          "void main() { Process.runSync('python3', "
          "['\$root/tool/docs/reader.py']); }",
      'tool/docs/reader.py': "open('CHANGELOG.md')\n",
    }, '.md | CHANGELOG');
    expectFinds('a script under a working directory', {
      'test/a_test.dart':
          "void main() { Process.runSync('dart', ['tool/cut.dart'], "
          "workingDirectory: 'site'); }",
      'site/tool/cut.dart': "final c = File('docs/a.md');",
    }, '.md');
    expectFinds('a unittest discover of a directory', {
      'test/a_test.dart':
          "void main() { Process.runSync('python3', ['-m', 'unittest', "
          "'discover', '-s', 'test/ci', '-p', 'test_reader.py']); }",
      'test/ci/test_reader.py': 'import reader_lib\n',
      'tool/ci/reader_lib.py': "open('AGENTS.md')\n",
    }, '.md | AGENTS');
    expectFinds('a discover without a pattern', {
      'test/a_test.dart':
          "void main() { run(['unittest', 'discover', '-s', 'test/ci']); }",
      'test/ci/test_other.py': "open('AGENTS.md')\n",
    }, '.md | AGENTS');
    expectFinds('a Python import of a sibling module', {
      'test/a_test.dart': "void main() { run('tool/x/entry.py'); }",
      'tool/x/entry.py': 'from helpers import load\n',
      'tool/x/helpers.py': "open('README.md')\n",
    }, '.md | README');
    expectFinds('a walk rooted at the working directory', {
      'test/a_test.dart': 'void main() { Directory.current.listSync(); }',
    }, 'listSync');
    expectFinds('a walk in a helper beside a repository root', {
      'test/a_test.dart': "import 'walk.dart';\nvoid main() {}",
      'test/walk.dart':
          'void walk() { Directory(Directory.current.path).listSync(); }',
    }, 'listSync');
    expectFinds('a git grep of tracked content', {
      'test/a_test.dart':
          "void main() { Process.runSync('git', ['grep', '-l', 'x']); }",
    }, 'git grep');
    expectFinds('an import with no file', {
      'test/a_test.dart': "import 'gone.dart';\nvoid main() {}",
    }, 'unresolved gone.dart');
    expectFinds(
      'a package import with no file',
      {
        'test/a_test.dart':
            "import 'package:extra_pkg/gone.dart';\nvoid main() {}",
      },
      'unresolved package:extra_pkg/gone.dart',
      packageRoots: extra,
    );
  });

  group('discovery ignores', () {
    void expectClean(String name, Map<String, String> files) {
      test(name, () {
        final tree = _tree();
        files.forEach(tree.write);
        expect(tree.readers().reach('test/a_test.dart').recorded, isEmpty);
        expect(tree.problems(), isEmpty);
      });
    }

    expectClean('an import cycle', {
      'test/a_test.dart': "import 'cycle_a.dart';\nvoid main() {}",
      'test/cycle_a.dart': "import 'cycle_b.dart';",
      'test/cycle_b.dart': "import 'cycle_a.dart';",
    });
    expectClean('a comment', {
      'test/a_test.dart': '// See README.md and doc/x.md.\nvoid main() {}',
    });
    expectClean('a directive inside a string', {
      'test/a_test.dart':
          'const text = "import \'gone.dart\'; export \'gone2.dart\';";\n'
          'void main() {}',
    });
    expectClean('a walk of a temp directory', {
      'test/a_test.dart':
          "void main() { Directory.systemTemp.createTempSync('x').listSync(); "
          "Process.runSync('find', ['/tmp']); }",
    });
    expectClean('an external package', {
      'test/a_test.dart': "import 'package:path/path.dart';\nvoid main() {}",
    });
    expectClean('a name that no script matches', {
      'test/a_test.dart': "void main() { File('data.json'); }",
    });

    test('a generated path outside the file universe', () {
      final tree = _tree()
        ..write(
          'test/a_test.dart',
          "void main() { Process.runSync('dart', ['.dart_tool/gen/reader.dart']); }",
        )
        ..writeUntracked(
          '.dart_tool/gen/reader.dart',
          "final d = File('README.md');",
        );
      expect(tree.readers().reach('test/a_test.dart').recorded, isEmpty);
    });

    test('git tokens in a file that does not mention git', () {
      final tree = _tree()
        ..write('test/a_test.dart', "void main() { run('checkout', 'show'); }");
      expect(tree.readers().reach('test/a_test.dart').recorded, isEmpty);
    });
  });

  group('the file universe', () {
    test('lists untracked files, drops ignored paths and broken links', () {
      final tree = _tree();
      final git = Process.runSync('git', [
        'init',
        '--quiet',
      ], workingDirectory: tree.root.path);
      expect(git.exitCode, 0, reason: '${git.stderr}');
      tree
        ..write('.gitignore', 'ignored/\n')
        ..write('test/a_test.dart', 'void main() {}')
        ..writeUntracked('ignored/x.dart', 'const x = 1;');
      try {
        Link(
          p.join(tree.root.path, 'dangling'),
        ).createSync(p.join(tree.root.path, 'missing'));
        Link(p.join(tree.root.path, 'loop')).createSync('loop');
        Link(
          p.join(tree.root.path, 'dirlink'),
        ).createSync(p.join(tree.root.path, 'test'));
      } on FileSystemException {
        markTestSkipped('This host cannot create symbolic links.');
        return;
      }
      expect(repositoryFiles(root: tree.root.path), {
        '.gitignore',
        'test/a_test.dart',
      });
    });

    test('reads package names from pubspecs, shallowest first', () {
      final tree = _tree()
        ..write('pubspec.yaml', 'name: llamadart\n')
        ..write('packages/x/pubspec.yaml', 'name: x_pkg\n')
        ..write('example/y/pubspec.yaml', 'name: llamadart\n');
      expect(workspacePackageRoots(tree.files, root: tree.root.path), {
        'llamadart': 'lib',
        'x_pkg': 'packages/x/lib',
      });
    });
  });

  group('readerProblems', () {
    const suite = 'test/a_test.dart';
    const helper = 'tool/reader.dart';

    _Tree readerTree() => _tree()
      ..write(suite, "import '../tool/reader.dart';\nvoid main() {}")
      ..write(helper, "final a = File('a.md');");

    test('accepts a listed suite and an exempt suite with its evidence', () {
      final tree = readerTree();
      expect(tree.problems(inventory: {suite}), isEmpty);
      expect(
        tree.problems(
          suites: {
            suite: _exempt({helper: '.md'}),
          },
        ),
        isEmpty,
      );
    });

    test('reports a reader removed from the inventory', () {
      final tree = readerTree();
      expect(tree.problems(inventory: {suite}), isEmpty);
      expect(tree.problems(), [
        allOf(contains(suite), contains('$helper: .md')),
      ]);
    });

    test('reports a suite that is both listed and exempt', () {
      final tree = readerTree();
      expect(
        tree.problems(
          inventory: {suite},
          suites: {
            suite: _exempt({helper: '.md'}),
          },
        ),
        [contains('listed in the inventory and exempt')],
      );
    });

    test('reports an exempt helper that gains a README read', () {
      final tree = readerTree();
      final exempt = {
        suite: _exempt({helper: '.md'}),
      };
      tree.write(helper, "final a = File('a.md'); final b = File('README');");
      expect(tree.problems(suites: exempt), [
        allOf(contains('evidence changed'), contains('.md | README')),
      ]);
    });

    test('reports a helper with no evidence that gains a README read', () {
      final tree = _tree()
        ..write(suite, "import '../tool/reader.dart';\nvoid main() {}")
        ..write(helper, "final a = File('a.json');")
        ..write('test/b_test.dart', "import '../tool/reader.dart';");
      expect(tree.problems(), isEmpty);
      tree.write(helper, "final a = File('README');");
      expect(tree.problems(), [contains(suite), contains('test/b_test.dart')]);
    });

    test('reports an exempt suite whose evidence gained a file', () {
      final tree = readerTree();
      final exempt = {
        suite: _exempt({helper: '.md'}),
      };
      tree
        ..write(helper, "import 'more.dart'; final a = File('a.md');")
        ..write('tool/more.dart', "final c = Directory('doc');");
      expect(tree.problems(suites: exempt), [
        allOf(contains('evidence changed'), contains('tool/more.dart')),
      ]);
    });

    test('reports renamed and deleted evidence files', () {
      final tree = readerTree();
      final exempt = {
        suite: _exempt({helper: '.md'}),
      };
      tree
        ..write('tool/renamed.dart', "final a = File('a.md');")
        ..write(suite, "import '../tool/renamed.dart';")
        ..delete(helper);
      expect(tree.problems(suites: exempt), [
        allOf(contains('evidence changed'), contains('renamed.dart')),
      ]);
      tree
        ..write(suite, "import '../tool/missing.dart';")
        ..delete('tool/renamed.dart');
      expect(tree.problems(suites: exempt), [
        allOf(contains('evidence changed'), contains('unresolved')),
      ]);
    });

    group('helper exemptions', () {
      Map<String, Exemption> helpers([String tokens = 'listSync']) => {
        'lib/walk.dart': _exempt({'lib/walk.dart': tokens}),
      };

      _Tree walkTree() => _tree()
        ..write(suite, "import '../lib/walk.dart';\nvoid main() {}")
        ..write('lib/walk.dart', 'void w() { Directory.current.listSync(); }');

      test('stop a helper counting as evidence while its tokens hold', () {
        final tree = walkTree();
        expect(tree.problems(), [contains(suite)]);
        expect(tree.problems(helpers: helpers()), isEmpty);
      });

      test('report a helper that gains a README read', () {
        final tree = walkTree()
          ..write(
            'lib/walk.dart',
            "void w() { Directory.current.listSync(); File('README'); }",
          );
        expect(tree.problems(helpers: helpers()), [
          allOf(
            contains('helper lib/walk.dart'),
            contains('README | listSync'),
          ),
        ]);
      });

      test('report a renamed or deleted helper', () {
        final tree = walkTree()
          ..write('lib/walk2.dart', 'const x = 1;')
          ..write(suite, "import '../lib/walk2.dart';\nvoid main() {}")
          ..delete('lib/walk.dart');
        expect(tree.problems(helpers: helpers()), [contains('no such file')]);
      });

      test('report a helper no suite reaches any more', () {
        final tree = walkTree()..write(suite, 'void main() {}');
        expect(tree.problems(helpers: helpers()), [
          contains('no suite reaches it'),
        ]);
      });

      test('report a helper that names no Markdown any more', () {
        final tree = walkTree()..write('lib/walk.dart', 'void w() {}');
        expect(
          tree.problems(helpers: helpers()),
          contains(contains('names no Markdown')),
        );
      });

      test('leave a newly reachable reader in the suite evidence', () {
        final tree = walkTree()
          ..write('test/b_test.dart', "import '../tool/new_reader.dart';")
          ..write('tool/new_reader.dart', "final a = File('README.md');");
        expect(tree.problems(helpers: helpers()), [
          allOf(contains('test/b_test.dart'), contains('new_reader.dart')),
        ]);
      });
    });

    test('reports an exemption behind a gate the suite lacks', () {
      final tree = readerTree();
      expect(
        tree.problems(
          suites: {
            suite: _exempt({helper: '.md'}, gate: 'local-only'),
          },
        ),
        [contains('local-only tag')],
      );
      tree.write(
        suite,
        "@Tags(['e2e', 'local-only'])\nlibrary;\n"
        "import '../tool/reader.dart';\nvoid main() {}",
      );
      expect(
        tree.problems(
          suites: {
            suite: _exempt({helper: '.md'}, gate: 'local-only'),
          },
        ),
        isEmpty,
      );
    });

    test('reports an exemption with no evidence or no reason', () {
      final tree = _tree()..write(suite, 'void main() {}');
      expect(tree.problems(suites: {suite: _exempt({})}), [
        contains('records no evidence'),
      ]);
      final readerSuite = readerTree();
      expect(
        readerSuite.problems(
          suites: {
            suite: _exempt({helper: '.md'}, reason: ' '),
          },
        ),
        [contains('no reason')],
      );
    });

    test('reports an exemption for a file that is not a suite', () {
      final tree = readerTree();
      expect(
        tree.problems(
          inventory: {suite},
          suites: {
            'test/gone_test.dart': _exempt({helper: '.md'}),
          },
        ),
        [contains('not a root test suite')],
      );
    });

    test('compares the recorded tokens, not only their presence', () {
      final tree = readerTree();
      expect(
        tree.problems(
          suites: {
            suite: _exempt({helper: '.md | README'}),
          },
        ),
        [contains('evidence changed')],
      );
    });
  });
}
