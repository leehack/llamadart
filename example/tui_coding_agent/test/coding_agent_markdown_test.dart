import 'package:llamadart_tui_coding_agent/src/coding_agent_markdown.dart';
import 'package:nocterm/nocterm.dart';
import 'package:test/test.dart';

void main() {
  test('renders compact Markdown blocks without spacer rows', () async {
    await testNocterm('compact coding agent Markdown', (tester) async {
      await tester.pumpComponent(
        const CodingAgentMarkdownText(
          data: '''
## Result

Use `value` below.

- one
- two

```dart
final value = 1;
```
''',
        ),
      );

      final state = tester.terminalState;
      final heading = state.findText('## Result').single;
      final paragraph = state.findText('Use value below.').single;
      final firstItem = state.findText('• one').single;
      final secondItem = state.findText('• two').single;
      final code = state.findText('final value = 1;').single;

      expect(paragraph.y, heading.y + 1);
      expect(firstItem.y, paragraph.y + 1);
      expect(secondItem.y, firstItem.y + 1);
      expect(code.y, secondItem.y + 1);
      expect(tester.renderToString(), isNot(contains('```')));

      final inline = state.findText('value').first;
      expect(
        state.getCellAt(inline.x, inline.y)?.style.backgroundColor,
        const Color.fromRGB(0, 0, 102),
      );
    });
  });

  test('keeps links, ordered lists, task lists, and tables readable', () async {
    await testNocterm('extended compact Markdown', (tester) async {
      await tester.pumpComponent(
        const CodingAgentMarkdownText(
          data: '''
1. first
2. second

- [x] done

[docs](https://example.com)

| Name | Value |
| --- | --- |
| mode | fast |
''',
        ),
      );

      final rendered = tester.renderToString();
      expect(rendered, contains('1. first'));
      expect(rendered, contains('2. second'));
      expect(rendered, contains('[x] done'));
      expect(rendered, contains('docs [https://example.com]'));
      expect(rendered, contains('│ Name │ Value │'));
      expect(rendered, contains('│ mode │ fast  │'));
    });
  });

  test('syntax-highlights a labelled Dart fence', () async {
    await testNocterm('Dart syntax highlighting', (tester) async {
      await tester.pumpComponent(
        const CodingAgentMarkdownText(
          data: '''
```dart
final message = "hello";
if (message.length == 42) { // comment
  print(message);
}
```
''',
        ),
      );

      final state = tester.terminalState;
      final keyword = state.findText('final').single;
      final string = state.findText('"hello"').single;
      final number = state.findText('42').single;
      final comment = state.findText('// comment').single;

      expect(
        state.getCellAt(keyword.x, keyword.y)?.style.color,
        Colors.brightMagenta,
      );
      expect(
        state.getCellAt(keyword.x, keyword.y)?.style.fontWeight,
        FontWeight.bold,
      );
      expect(
        state.getCellAt(string.x, string.y)?.style.color,
        Colors.brightGreen,
      );
      expect(
        state.getCellAt(number.x, number.y)?.style.color,
        Colors.brightYellow,
      );
      expect(
        state.getCellAt(comment.x, comment.y)?.style.color,
        Colors.brightBlack,
      );
      expect(
        state.getCellAt(comment.x, comment.y)?.style.fontStyle,
        FontStyle.italic,
      );
    });
  });

  test('supports common fence aliases and unlabelled JSON', () async {
    await testNocterm('syntax language resolution', (tester) async {
      await tester.pumpComponent(
        const CodingAgentMarkdownText(
          data: r'''
```sh
if [ -n "$HOME" ]; then
  echo "ready"
fi
```
```
{"enabled": true, "count": 2}
```
''',
        ),
      );

      final state = tester.terminalState;
      final shellKeyword = state.findText('if').single;
      final shellString = state.findText('"ready"').single;
      final jsonKey = state.findText('"enabled"').single;
      final jsonLiteral = state.findText('true').single;
      final jsonNumber = state.findText('2').single;

      expect(
        state.getCellAt(shellKeyword.x, shellKeyword.y)?.style.color,
        Colors.brightMagenta,
      );
      expect(
        state.getCellAt(shellString.x, shellString.y)?.style.color,
        Colors.brightGreen,
      );
      expect(
        state.getCellAt(jsonKey.x, jsonKey.y)?.style.color,
        Colors.brightBlue,
      );
      expect(
        state.getCellAt(jsonLiteral.x, jsonLiteral.y)?.style.color,
        Colors.brightMagenta,
      );
      expect(
        state.getCellAt(jsonNumber.x, jsonNumber.y)?.style.color,
        Colors.brightYellow,
      );
    });
  });

  test('code background fills internal blank lines edge to edge', () async {
    await testNocterm('solid code background', (tester) async {
      await tester.pumpComponent(
        const CodingAgentMarkdownText(
          data: '''
```dart
final first = 1;

final second = 2;
```
''',
        ),
      );

      final state = tester.terminalState;
      final first = state.findText('final first').single;
      final second = state.findText('final second').single;
      expect(second.y, first.y + 2);

      for (var x = 0; x < state.size.width; x++) {
        expect(
          state.getCellAt(x, first.y + 1)?.style.backgroundColor,
          const Color.fromRGB(0, 0, 102),
          reason: 'blank code row should be filled at column $x',
        );
      }
    }, size: const Size(40, 8));
  });

  test('renders thinking with a distinct subdued style', () async {
    await testNocterm('coding agent thinking Markdown', (tester) async {
      await tester.pumpComponent(
        const CodingAgentMarkdownText(
          data: 'Inspect **carefully**.',
          thinking: true,
        ),
      );

      final inspect = tester.terminalState.findText('Inspect').single;
      final cell = tester.terminalState.getCellAt(inspect.x, inspect.y);
      expect(cell?.style.color, const Color.fromRGB(170, 170, 170));
      expect(cell?.style.fontStyle, FontStyle.italic);
    });
  });

  test(
    'renders and highlights an incomplete streamed fence at narrow width',
    () async {
      await testNocterm('incremental fenced code Markdown', (tester) async {
        await tester.pumpComponent(
          const CodingAgentMarkdownText(data: '```dart\nfinal partial = true;'),
        );

        var rendered = tester.renderToString();
        expect(rendered, contains('final partial = true;'));
        expect(rendered, isNot(contains('```')));
        var keyword = tester.terminalState.findText('final').single;
        expect(
          tester.terminalState.getCellAt(keyword.x, keyword.y)?.style.color,
          Colors.brightMagenta,
        );

        await tester.pumpComponent(
          const CodingAgentMarkdownText(
            data:
                '```dart\nfinal longValue = "abcdefghijklmnopqrstuvwxyz";\n```',
          ),
        );

        rendered = tester.renderToString();
        expect(rendered, contains('final longValue'));
        expect(rendered, isNot(contains('```')));
        keyword = tester.terminalState.findText('final').single;
        expect(
          tester.terminalState.getCellAt(keyword.x, keyword.y)?.style.color,
          Colors.brightMagenta,
        );
      }, size: const Size(40, 10));
    },
  );
}
