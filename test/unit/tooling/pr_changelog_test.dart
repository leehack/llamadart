@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import '../../../tool/release/pr_changelog.dart';

Future<ProcessResult> _validate(String? body) async {
  final temp = Directory.systemTemp.createTempSync('clact2-pr-event-');
  try {
    final payload = File('${temp.path}/event.json')
      ..writeAsStringSync(
        jsonEncode({
          'pull_request': {'body': body},
        }),
      );
    return await Process.run(
      Platform.resolvedExecutable,
      ['tool/release/pr_changelog.dart', '--event'],
      environment: {'GITHUB_EVENT_PATH': payload.path},
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
  final workflow =
      loadYaml(File('.github/workflows/pr_changelog.yml').readAsStringSync())
          as YamlMap;
  final pullRequest = workflow['on']['pull_request'] as YamlMap;
  final jobs = workflow['jobs'] as YamlMap;
  final verify = jobs['release-prep'] as YamlMap;

  test('the PR workflow keeps body edits separate from heavy CI', () {
    expect(pullRequest['branches'], ['main']);
    expect(pullRequest['types'], [
      'opened',
      'reopened',
      'synchronize',
      'edited',
      'ready_for_review',
      'labeled',
      'unlabeled',
    ]);
    final steps = jobs['changelog']['steps'] as YamlList;
    final checkout = steps.first as YamlMap;
    expect(
      checkout['with']['ref'],
      r'${{ github.event.pull_request.base.sha }}',
    );
    expect(checkout['with']['persist-credentials'], isFalse);
    final validate = steps.cast<YamlMap>().singleWhere(
      (step) => step['run'] == 'dart tool/release/pr_changelog.dart --event',
    );
    expect(validate['if'], isNull);
    expect(validate['continue-on-error'], isNull);
    expect(
      File('.github/workflows/ci.yml').readAsStringSync(),
      isNot(contains('- edited')),
    );
  });

  test(
    'the named prep job routes by identity even after body validation fails',
    () {
      expect(verify['name'], 'Verify release prep');
      expect(verify['needs'], 'changelog');
      expect(
        (verify['if'] as String).replaceAll(RegExp(r'\s+'), ' '),
        "!cancelled() && (github.event.label.name == 'release-prep' || "
        '(github.event.pull_request.head.repo.full_name == github.repository && '
        "(contains(github.event.pull_request.labels.*.name, 'release-prep') || "
        "startsWith(github.event.pull_request.head.ref, 'release/'))))",
      );
    },
  );

  test(
    'the named prep job fails invalid descriptions before checkout',
    () async {
      final step = (verify['steps'] as YamlList).first as YamlMap;
      expect(step['if'], isNull);
      expect(step['continue-on-error'], isNull);
      expect(step['shell'], 'bash');
      expect(step['env']['CHANGELOG_RESULT'], r'${{ needs.changelog.result }}');
      Future<ProcessResult> gate(String result) => Process.run(
        'bash',
        ['-e', '-c', step['run'] as String],
        environment: {'CHANGELOG_RESULT': result},
      );

      final valid = File(
        'test/fixtures/release_prep/pr_2114_description.md',
      ).readAsStringSync();
      for (final body in [null, '', _template, valid]) {
        final upstream = await _validate(body);
        expect(upstream.exitCode, body == valid ? 0 : 1);
        final result = await gate(
          upstream.exitCode == 0 ? 'success' : 'failure',
        );
        expect(result.exitCode, upstream.exitCode, reason: '${result.stderr}');
        if (upstream.exitCode != 0) {
          expect(result.stderr, contains('PR changelog validation'));
        }
      }
      expect((await gate('skipped')).exitCode, 1);
    },
    skip: Platform.isWindows ? 'Runs the Bash workflow step.' : false,
  );

  test('both selected docs validation paths enforce protected changelogs', () {
    final ci = loadYaml(File('.github/workflows/ci.yml').readAsStringSync());
    final jobs = ci['jobs'] as YamlMap;
    for (final name in ['analyze', 'docs-versions']) {
      final steps = (jobs[name] as Map)['steps'] as List;
      expect(
        steps.where(
          (step) =>
              step['run'] ==
                  'dart run tool/testing/check_released_changelog_sections.dart' &&
              step['if'] == null &&
              step['continue-on-error'] != true,
        ),
        hasLength(1),
        reason: name,
      );
    }
  });

  test(
    'native sync validates the generated body before opening or editing a PR',
    () {
      final workflow = File(
        '.github/workflows/sync_native_bindings.yml',
      ).readAsStringSync();
      final generate = workflow.indexOf(
        'sync_native_release_pins.py changelog-section',
      );
      final validate = workflow.indexOf(
        r'dart tool/release/pr_changelog.dart --body "${body_file}"',
      );
      expect(generate, greaterThanOrEqualTo(0));
      expect(validate, greaterThan(generate));
      expect(validate, lessThan(workflow.indexOf('gh pr edit', generate)));
      expect(validate, lessThan(workflow.indexOf('gh pr create', generate)));
    },
  );

  test('the PR template requires an authored changelog entry', () {
    final body = File('.github/pull_request_template.md').readAsStringSync();
    expect(
      body.indexOf('## Changelog'),
      greaterThan(body.indexOf('## Summary')),
    );
    expect(
      body.indexOf('## Changelog'),
      lessThan(body.indexOf('## Production-readiness scope')),
    );
    expect(() => parsePrChangelog(body), throwsFormatException);
    final filled = body.replaceFirst(
      '## Changelog',
      '## Changelog\n\nN/A: Changes maintainer tooling.',
    );
    expect(parsePrChangelog(filled).reason, 'Changes maintainer tooling.');
  });

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

  group('landed changelog wraps', () {
    for (final width in [70, 71, 72]) {
      test('adjacent dash after $width scalars', () {
        final body = '## Changelog\n- ${'a' * (width - 2)}\n- Second.';
        expect(parsePrChangelog(body).bullets, hasLength(2));
        if (width == 70) {
          expect(parseLandedPrChangelog(body).bullets, hasLength(2));
        } else {
          expect(() => parseLandedPrChangelog(body), throwsFormatException);
        }
      });
    }

    test('counts an astral character as one scalar', () {
      final first = '🚀${'a' * 67}';
      final section = parseLandedPrChangelog('## Changelog\n- $first\n- Two.');
      expect(section.bullets.map((bullet) => bullet.text), [first, 'Two.']);
    });

    test('checks the physical tail before a genuine scoped bullet', () {
      final first = 'a' * 70;
      final section = parseLandedPrChangelog(
        '## Changelog\n- $first\nContinued.\n'
        '- [packages/genkit_llamadart] Explain the new option.',
      );
      expect(section.bullets, [
        (target: 'core', text: '$first Continued.'),
        (target: 'packages/genkit_llamadart', text: 'Explain the new option.'),
      ]);
    });

    test('keeps an overlong word whole and checks its following boundary', () {
      final word = 'a' * 79;
      final body = '## Changelog\n- Keep\n$word\n';
      expect(
        parseLandedPrChangelog('${body}whole.').bullets.single.text,
        'Keep $word whole.',
      );
      expect(
        () => parseLandedPrChangelog('$body- Maybe another entry.'),
        throwsFormatException,
      );
    });

    test('unwraps a long N/A and preserves original outside rows', () {
      final first = 'a' * 66;
      const before = 'This reverts commit 0123456789abcdef.  ';
      const after = 'Keep outside  spacing.  ';
      final body =
          '$before\n## Changelog\nN/A: $first\n'
          'continues here.\n\n## Summary\n$after';
      final section = parseLandedPrChangelog(body);
      expect(section.reason, '$first continues here.');
      expect(section.bullets, isEmpty);
      expect(section.outsideLines, [before, '## Summary', after]);
      expect(() => parsePrChangelog(body), throwsFormatException);
    });

    test('preserves interior spacing in single-line entries', () {
      const body =
          '## Changelog\n- Keep  double spaces.\n'
          '- Preserve\tinterior tabs.\n';
      expect(
        parseLandedPrChangelog(body).bullets,
        parsePrChangelog(body).bullets,
      );
    });

    test('keeps a verbatim over-width bullet as a single line', () {
      final body = '## Changelog\n- Keep ${'a' * 74}.\n- Separate bullet.';
      expect(
        parseLandedPrChangelog(body).bullets,
        parsePrChangelog(body).bullets,
      );
    });

    test('blank rows separate even bullets at the wrap limit', () {
      final body = '## Changelog\n- ${'a' * 70}\n\n';
      expect(
        parseLandedPrChangelog('$body- A separate bullet.').bullets,
        hasLength(2),
      );
      expect(
        () => parseLandedPrChangelog('${body}Unattached prose.'),
        throwsFormatException,
      );
    });

    for (final boundary in [
      '## Summary',
      '### Summary',
      '<!-- guidance -->',
      '> Example',
      '```md\nExample\n```',
      '+ Other list syntax',
      '1. Ordered example',
      '---------',
    ]) {
      test('declines a wrap-compatible structural row $boundary', () {
        expect(
          () =>
              parseLandedPrChangelog('## Changelog\n- ${'a' * 70}\n$boundary'),
          throwsFormatException,
        );
      });
    }

    test('declines continuations without the exact greedy rows', () {
      for (final (first, continuation) in [
        ('a' * 68, 'b still fits on the preceding row.'),
        ('a' * 70, ' leading indentation.'),
        ('a' * 70, 'double  spaces.'),
        ('a' * 70, '${'a' * 70} multiple words.'),
        ('a' * 70, '<!-- guidance -->\nContinued.'),
      ]) {
        expect(
          () => parseLandedPrChangelog('## Changelog\n- $first\n$continuation'),
          throwsFormatException,
        );
      }
    });

    test('the PR event still rejects a manually wrapped description', () async {
      final body = '## Changelog\n- ${'a' * 70}\nManual continuation.';
      expect(parseLandedPrChangelog(body).bullets, hasLength(1));
      expect(() => parsePrChangelog(body), throwsFormatException);
      expect((await _validate(body)).exitCode, 1);
    });
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
    test("reads GitHub's default squash rewrap of a real prep description", () {
      String fixture(String name) =>
          File('test/fixtures/release_prep/$name').readAsStringSync();
      final description = fixture('pr_2114_description.md');
      final landed =
          'Prepare llamadart 0.20.3 release (#2114)\n\n'
          '${fixture('pr_2114_github_squash_body.txt')}';
      expect(landed, contains('\nInput-SHA256:\na6fcb06a8dee8c18'));
      expect(
        const LineSplitter().convert(landed).map((line) => line.runes.length),
        everyElement(lessThanOrEqualTo(72)),
      );
      expect(
        parseReleaseNotesInput(landed),
        parseReleaseNotesInput(description),
      );
      final reviews = parseReleaseNotesReview(description);
      expect(reviews, hasLength(2));
      expect(parseReleaseNotesReview(landed), reviews);
    });
    test('joins only the lines a rewrap can split', () {
      const heading = '## Release notes review';
      final wrapped = receipt.replaceFirst('Input-SHA256: ', 'Input-SHA256:\n');
      expect(parseReleaseNotesInput(wrapped), parseReleaseNotesInput(receipt));
      final longTag = receipt.replaceFirst('v0.20.2+1', 'v0.20.2+${'1' * 25}');
      expect(
        parseReleaseNotesInput(
          longTag.replaceFirst('Previous-tag: ', 'Previous-tag:\n'),
        ),
        parseReleaseNotesInput(longTag),
      );
      expect(
        parseReleaseNotesReview(
          '$heading\n- $through Combined with\nthe setup entry.\n\n- $previous Reworded.',
        ),
        {through: 'Combined with the setup entry.', previous: 'Reworded.'},
      );
      for (final bad in [
        receipt.replaceFirst('Input-SHA256: ', 'Input-SHA256:\n\n'),
        receipt.replaceFirst('Input-SHA256: ', 'Input-SHA256:\n '),
        receipt.replaceFirst('Input-SHA256: $digest', 'Input-SHA256:'),
        receipt.replaceFirst('Through: ', 'Input-SHA256:\nThrough: '),
        receipt.replaceFirst(
          digest,
          '${digest.substring(0, 32)}\n${digest.substring(32)}',
        ),
      ]) {
        expect(() => parseReleaseNotesInput(bad), throwsFormatException);
      }
      for (final bad in [
        '$heading\nthe setup entry.\n- $through Combined with',
        '$heading\n- $through Combined with\n\nthe setup entry.',
        '$heading\n- $through Combined with\n- the setup entry.',
        '$heading\n- $through Combined with\n- ${previous.substring(1)} Reworded.',
        '$heading\n- $through Combined with\n  the setup entry.',
        '$heading\n- $through Combined with\n the setup entry.',
      ]) {
        expect(() => parseReleaseNotesReview(bad), throwsFormatException);
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
