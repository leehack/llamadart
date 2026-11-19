@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../../tool/release/pr_changelog.dart';

Future<ProcessResult> _validate(String? body) async {
  final temp = Directory.systemTemp.createTempSync('clpre-pr-event-');
  try {
    final event = File('${temp.path}/event.json')
      ..writeAsStringSync(
        jsonEncode({
          'pull_request': {'body': body},
        }),
      );
    return await Process.run(
      Platform.resolvedExecutable,
      ['tool/release/pr_changelog.dart', '--event'],
      environment: {'GITHUB_EVENT_PATH': event.path},
    );
  } finally {
    temp.deleteSync(recursive: true);
  }
}

const _template = '''
## Summary

## Changelog

<!-- Use one of these forms:
- Document the new behavior.
N/A: Updates tests for the existing behavior.
-->

## Test Plan
''';

void main() {
  test('preserves Markdown from the landed body', () {
    const message = '''
Improve setup (#9)

## Changelog
- [core] Update the `--setup` [guide](https://example.org).
- [packages/genkit_llamadart] Add package instructions.
''';
    final section = parsePrChangelog(landedPrBody(message));
    expect(section.bullets, [
      (
        target: 'core',
        text: 'Update the `--setup` [guide](https://example.org).',
      ),
      (target: 'packages/genkit_llamadart', text: 'Add package instructions.'),
    ]);
    expect(
      () => parsePrChangelog(landedPrBody('$message\nFree prose.')),
      throwsFormatException,
    );
  });

  final valid = {
    'multiple bullets, core and package scopes': '''
## Changelog
- Document setup.
- [core] Explain the `--version` option.
- [packages/genkit_llamadart] Update Genkit setup.
- [packages/llamadart_model_store] Document the cache.
- [packages/llamadart_llama_cpp_flutter] Document the pin.
- [packages/llamadart_litert_lm_flutter] Document the pin.
- [packages/llamadart_stable_diffusion_flutter] Document the pin.
- [Guide](https://example.org/guide) includes setup instructions.
''',
    'specific N/A': '## Changelog\n\nN/A: Updates release tooling tests.',
    'CRLF and ATX end': '## Changelog\r\n- One.\r\n# Summary\r\nText.',
    'lone CR line endings': '## Changelog\r- One.\r# Summary\rText.',
    'examples outside the section': '''
## Summary
```markdown
## Changelog
- Example.
```
> ## Changelog
<!--
## Changelog
-->
## Changelog
- Actual.
''',
    'quoted guidance cannot hide the live heading':
        '> <!--\n\n## Changelog\n- Visible note.',
    'standalone guidance': '''
## Changelog
<!-- How to fill in this section:
## Changelog
- Example.
-->
- Preserve `<!-- literal -->`.
''',
  };
  for (final entry in valid.entries) {
    test('event accepts ${entry.key}', () async {
      final result = await _validate(entry.value);
      expect(result.exitCode, 0, reason: '${result.stderr}');
    });
  }

  test('keeps visible combining marks and emoji selectors intact', () async {
    const text = '한글, cafe\u0301, and ✈\ufe0f.';
    final body = '## Changelog\n- $text';
    expect((await _validate(body)).exitCode, 0);
    expect(parsePrChangelog(body).bullets.single.text, text);
    expect(parsePrChangelog('## Changelog\nN/A: $text').reason, text);
  });

  for (final codePoint in [
    0x034f,
    0xfe0f,
    0x3164,
    0x115f,
    0xffa0,
    0x2800,
    0xe0100,
  ]) {
    for (final prefix in ['- ', 'N/A: ']) {
      test(
        'event rejects invisible U+${codePoint.toRadixString(16)} in $prefix',
        () async {
          final character = String.fromCharCode(codePoint);
          for (final text in [character, '** $character \u2060 **']) {
            final body = '## Changelog\n$prefix$text';
            expect((await _validate(body)).exitCode, 1);
            expect(() => parsePrChangelog(body), throwsFormatException);
          }
        },
      );
    }
  }

  group('release input metadata', () {
    final previous = 'a' * 40;
    final through = 'b' * 40;
    final digest = 'c' * 64;
    final receipt =
        '## Release notes input\n\nPrevious-tag: v0.20.2+1@$previous\nThrough: $through\nInput-SHA256: $digest\n';
    final examples = [
      '~~~md\n$receipt~~~\n',
      '<!--\n$receipt-->\n',
      receipt.split('\n').map((line) => '> $line').join('\n'),
      '- Old receipt:\n${receipt.split('\n').map((line) => '  $line').join('\n')}',
    ];
    test('ignores quoted, fenced, nested and commented examples', () {
      final landed =
          'Prepare release (#123)\n\n${examples.join('\n')}\n$receipt';
      expect(parseReleaseNotesInput(landed), (
        previousTag: 'v0.20.2+1',
        previousSha: previous,
        through: through,
        inputSha256: digest,
      ));
      for (final example in examples) {
        expect(() => parseReleaseNotesInput(example), throwsFormatException);
      }
    });
    test('requires one real receipt with exactly three well-formed fields', () {
      for (final bad in [
        '$receipt\n$receipt',
        '$receipt\nThrough: $through\n',
        '$receipt\nReviewed: Yes\n',
        receipt.replaceFirst('v0.20.2+1', 'v0.20.2-dev'),
        receipt.replaceFirst('Through: $through\n', ''),
        receipt.replaceFirst(digest, digest.toUpperCase()),
        receipt.replaceFirst('Previous-tag:', 'Previous-tag :'),
      ]) {
        expect(() => parseReleaseNotesInput(bad), throwsFormatException);
      }
    });
    test('requires a unique SHA and specific text in each review entry', () {
      const heading = '## Release notes review';
      expect(
        parseReleaseNotesReview(
          '$receipt\n$heading\n- $through Combined with the setup entry.',
        ),
        {through: 'Combined with the setup entry.'},
      );
      for (final bad in [
        '$heading\n- $through Acknowledged',
        '$heading\n- $through \u034f',
        '$heading\n- ${through.substring(1)} Combined with the setup entry.',
        '$heading\n- $through Reworded the setup entry.\n- $through Merged elsewhere.',
        '$heading\n- $through Reworded the setup entry.\n$heading\n- $previous Merged elsewhere.',
      ]) {
        expect(() => parseReleaseNotesReview(bad), throwsFormatException);
      }
    });
  });

  final invalid = <String, String?>{
    'missing section': '## Summary\n- Something changed.',
    'null body': null,
    'untouched template': _template,
    'duplicate section': '## Changelog\n- One\n## Changelog\n- Two',
    'fenced heading': '```md\n## Changelog\n- Example.\n```',
    'tilde fenced heading': '~~~~\n~~~\n## Changelog\n- Example.\n~~~~',
    'quoted heading': '> ## Changelog\n> - Example.',
    'commented heading': '<!--\n## Changelog\n- Example.\n-->',
    'heading nested in a list': '- Example:\n  ## Changelog\n- Text.',
    'indented code heading': '    ## Changelog\n- Example.',
    'fenced content': '## Changelog\n```\n- Example.\n```',
    'wrong level': '### Changelog\n- Text.',
    'wrong case': '## ChangeLog\n- Text.',
    'wrong bullet': '## Changelog\n* Text.',
    'indented bullet': '## Changelog\n - Text.',
    'empty bullet': '## Changelog\n- ',
    'checkbox': '## Changelog\n- [ ] To do',
    'checked box': '## Changelog\n- [X] Done',
    'continued bullet': '## Changelog\n- First line\n  second line',
    'comment-only bullet': '## Changelog\n- <!-- template value -->',
    'same-line comment': '## Changelog\n- A note. <!-- guidance -->',
    'unclosed guidance comment': '## Changelog\n- A note.\n<!-- guidance',
    'markup-only bullet': '## Changelog\n- ** **',
    'format-only bullet': '## Changelog\n- **\u2060\u200D**',
    'placeholder bullet': '## Changelog\n- TBD',
    'placeholder reason': '## Changelog\nN/A: <specific reason>',
    'bare N/A': '## Changelog\nN/A',
    'bulleted N/A': '## Changelog\n- N/A: Only tests.',
    'mixed N/A': '## Changelog\n- One\nN/A: Only tests.',
    'unknown package': '## Changelog\n- [packages/unknown] Detail.',
    'package without text': '## Changelog\n- [packages/genkit_llamadart] ',
    'malformed package marker':
        '## Changelog\n- [packages/genkit_llamadart]Detail.',
    'ordinary text resembling a trailer':
        '## Changelog\n- One.\n\nSigned-off-by: Example',
  };
  for (final entry in invalid.entries) {
    test('event rejects ${entry.key}', () async {
      final result = await _validate(entry.value);
      expect(result.exitCode, 1, reason: '${result.stderr}');
      expect(result.stderr, contains('Changelog'));
    });
  }
}
