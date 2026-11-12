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
}
