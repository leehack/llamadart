@TestOn('vm')
library;

import 'package:test/test.dart';

import '../../../tool/testing/verify_release_docs_versions.dart';

void main() {
  const bridgeCore =
      '- Keep the default WebGPU bridge assets at `v1` (unchanged from 0.1.0).\n';
  const bridgeDocs =
      '- Keep default WebGPU bridge assets at `v1` (unchanged from 0.1.0).\n';

  test('accepts identical sections and the prescribed bridge wording', () {
    expect(
      docsChangelogDriftProblems(
        {'0.2.0': '- Fix a.\n$bridgeCore', 'Unreleased': '\n'},
        {'0.2.0': '- Fix a.\n$bridgeDocs', 'Unreleased': '\n'},
      ),
      isEmpty,
    );
  });

  test('flags a retained release whose bullets differ', () {
    final problems = docsChangelogDriftProblems(
      {'0.2.0': '- Fix a.\n', '0.1.0': '- Old.\n'},
      {'0.2.0': '- Fix a, tightened.\n', '0.1.0': '- Old.\n'},
    );

    expect(problems, hasLength(1));
    expect(problems.single, contains('`## 0.2.0` differs from CHANGELOG.md'));
  });

  test('flags a differing bridge line that is not the article change', () {
    expect(
      docsChangelogDriftProblems(
        {'0.2.0': bridgeCore},
        {'0.2.0': bridgeDocs.replaceAll('v1', 'v2')},
      ),
      hasLength(1),
    );
  });

  test('ignores Unreleased and sections only one file has', () {
    expect(
      docsChangelogDriftProblems(
        {'Unreleased': '- A.\n', '0.1.0': '- Old.\n'},
        {'Unreleased': '- B.\n'},
      ),
      isEmpty,
    );
    expect(
      docsChangelogDriftProblems({'0.1.0': '- Old.\n'}, {'0.2.0': '- New.\n'}),
      isEmpty,
    );
  });

  test('accepts a `*` bridge bullet in the core changelog', () {
    expect(
      docsChangelogDriftProblems(
        {'0.2.0': '* ${bridgeCore.substring(2)}'},
        {'0.2.0': bridgeDocs},
      ),
      isEmpty,
    );
  });

  test('strips "the" and the marker only on the bridge line', () {
    expect(
      docsChangelogDriftProblems(
        {'0.2.0': '* Fix the default WebGPU path.\n'},
        {'0.2.0': '- Fix default WebGPU path.\n'},
      ),
      hasLength(1),
    );
    expect(
      docsChangelogDriftProblems(
        {'0.2.0': '- Fix a.\n* Other.\n'},
        {'0.2.0': '- Fix a.\n- Other.\n'},
      ),
      hasLength(1),
    );
  });

  test('ignores trailing whitespace and blank lines', () {
    expect(
      docsChangelogDriftProblems(
        {'0.2.0': '- Fix a.\n\n\n'},
        {'0.2.0': '- Fix a.'},
      ),
      isEmpty,
    );
  });

  test('names the first differing line and a whitespace-only difference', () {
    final problems = docsChangelogDriftProblems(
      {'0.2.0': '- Fix a.\n- Fix  b.\n'},
      {'0.2.0': '- Fix a.\n- Fix b.\n'},
    );

    expect(problems, hasLength(1));
    expect(
      problems.single,
      allOf(
        contains('only in whitespace'),
        contains('first differing line 2'),
        contains('`- Fix  b.`'),
      ),
    );
    expect(
      docsChangelogDriftProblems(
        {'0.2.0': '- Fix a.\n'},
        {'0.2.0': '- Fix c.\n'},
      ).single,
      allOf(contains('in content'), contains('first differing line 1')),
    );
  });

  test('requires the prescribed bridge wording on the docs page', () {
    for (final docsLine in [
      '* Keep default WebGPU bridge assets at `v1` (unchanged from 0.1.0).\n',
      bridgeCore,
    ]) {
      final problems = docsChangelogDriftProblems(
        {'0.2.0': bridgeCore},
        {'0.2.0': docsLine},
      );

      expect(problems, hasLength(1), reason: docsLine);
      expect(problems.single, contains('bridge line must read'));
    }
    expect(docsChangelogDriftProblems({}, {'0.2.0': bridgeCore}), hasLength(1));
    expect(docsChangelogDriftProblems({}, {'Unreleased': bridgeCore}), isEmpty);
  });
}
