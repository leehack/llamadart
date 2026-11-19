import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../../tool/release/pr_changelog.dart';

Future<ProcessResult> _validate(String? body) async {
  final temp = Directory.systemTemp.createTempSync('cps-pr-event-');
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
  test(
    'preserves Markdown and removes only recognized terminal Git trailers',
    () {
      const message = '''
Improve setup (#9)

## Changelog
- [core] Update the `--setup` [guide](https://example.org).
- [packages/genkit_llamadart] Add package instructions.

Signed-off-by: Example <example@example.invalid>
Co-authored-by: Example <example@example.invalid>
''';
      final trailers = message.substring(message.indexOf('Signed-off-by:'));
      final section = parsePrChangelog(landedPrBody(message, trailers));
      expect(section.bullets, [
        (
          target: 'core',
          text: 'Update the `--setup` [guide](https://example.org).',
        ),
        (
          target: 'packages/genkit_llamadart',
          text: 'Add package instructions.',
        ),
      ]);
      expect(
        () => parsePrChangelog(landedPrBody(message, '')),
        throwsFormatException,
      );
      expect(
        () => parsePrChangelog(
          landedPrBody(
            message.replaceFirst(
              'Signed-off-by:',
              'Free prose.\n\nSigned-off-by:',
            ),
            trailers,
          ),
        ),
        throwsFormatException,
      );
    },
  );

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

  final invalid = <String, String?>{
    'missing section': '## Summary\n- Something changed.',
    'null body': null,
    'untouched template': _template,
    'duplicate section': '## Changelog\n- One\n## Changelog\n- Two',
    'fenced heading': '```md\n## Changelog\n- Example.\n```',
    'tilde fenced heading': '~~~~\n~~~\n## Changelog\n- Example.\n~~~~',
    'quoted heading': '> ## Changelog\n> - Example.',
    'commented heading': '<!--\n## Changelog\n- Example.\n-->',
    'heading nested in a list': '- Example:\n  ## Changelog\n  - Text.',
    'indented code heading': '    ## Changelog\n    - Example.',
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
    'markup-only bullet': '## Changelog\n- ** **',
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
