import 'package:llamadart_tui_coding_agent/src/text_tool_call_parser.dart';
import 'package:test/test.dart';

void main() {
  group('TextToolCallParser', () {
    late TextToolCallParser parser;

    setUp(() {
      parser = TextToolCallParser(
        knownToolNames: <String>{'read', 'write', 'edit', 'bash'},
      );
    });

    test('parses one standalone JSON call', () {
      final result = parser.parse(
        '  <tool_call>\n'
        '{"name":"bash","arguments":{"command":"git status"}}\n'
        '</tool_call>  ',
      );

      expect(result.hasToolCallEnvelope, isTrue);
      expect(result.hasError, isFalse);
      expect(result.call?.name, 'bash');
      expect(result.call?.arguments, <String, dynamic>{
        'command': 'git status',
      });
    });

    test('preserves literal protocol tags inside JSON strings', () {
      final result = parser.parse(
        '<tool_call>'
        r'{"name":"write","arguments":{"path":"tags.txt",'
        r'"content":"before <tool_call>middle</tool_call> after"}}'
        '</tool_call>',
      );

      expect(result.hasError, isFalse);
      expect(
        result.call?.arguments['content'],
        'before <tool_call>middle</tool_call> after',
      );
    });

    test('tracks escapes while scanning literal closing tags', () {
      final result = parser.parse(
        '<tool_call>'
        r'{"name":"write","arguments":{"path":"tags.txt",'
        r'"content":"const tag = \"</tool_call>\"; C:\\tmp"}}'
        '</tool_call>',
      );

      expect(result.hasError, isFalse);
      expect(
        result.call?.arguments['content'],
        r'const tag = "</tool_call>"; C:\tmp',
      );
    });

    test('leaves normal assistant text alone', () {
      final result = parser.parse(
        'I inspected the project and found no issue.',
      );

      expect(result.hasToolCallEnvelope, isFalse);
      expect(result.call, isNull);
      expect(result.error, isNull);
    });

    test('rejects prose or fences around an envelope', () {
      for (final content in <String>[
        'I will read it:\n'
            '<tool_call>{"name":"read","arguments":{}}</tool_call>',
        '```xml\n'
            '<tool_call>{"name":"read","arguments":{}}</tool_call>\n'
            '```',
      ]) {
        final result = parser.parse(content);

        expect(result.hasToolCallEnvelope, isTrue, reason: content);
        expect(result.call, isNull, reason: content);
        expect(result.error, contains('entire response'), reason: content);
      }
    });

    test('rejects malformed and incomplete envelopes', () {
      final malformed = parser.parse(
        '<tool_call>{"name":"read","arguments":}</tool_call>',
      );
      final incomplete = parser.parse(
        '<tool_call>{"name":"read","arguments":{}}',
      );
      final closingOnly = parser.parse('</tool_call>');

      expect(malformed.call, isNull);
      expect(malformed.error, contains('valid JSON'));
      expect(incomplete.call, isNull);
      expect(incomplete.error, contains('Incomplete'));
      expect(closingOnly.call, isNull);
      expect(closingOnly.error, contains('entire response'));
    });

    test('rejects unknown tools', () {
      final result = parser.parse(
        '<tool_call>{"name":"unknown","arguments":{}}</tool_call>',
      );

      expect(result.call, isNull);
      expect(result.error, 'Unknown tool "unknown".');
    });

    test('rejects sibling and nested calls', () {
      final sibling = parser.parse(
        '<tool_call>{"name":"read","arguments":{}}</tool_call>'
        '<tool_call>{"name":"read","arguments":{}}</tool_call>',
      );
      final nested = parser.parse(
        '<tool_call>{"name":"read","arguments":{}'
        '<tool_call>}</tool_call></tool_call>',
      );

      expect(sibling.call, isNull);
      expect(sibling.error, contains('Only one'));
      expect(nested.call, isNull);
      expect(nested.error, contains('Only one'));
    });

    test('rejects aliases, shorthand, Qwen XML, and JSON lists', () {
      final payloads = <String>[
        'read',
        '<function=read><parameter=path>x</parameter></function>',
        '{"tool":"read","arguments":{}}',
        '{"function":{"name":"read","arguments":{}}}',
        '[{"name":"read","arguments":{}}]',
      ];

      for (final payload in payloads) {
        final result = parser.parse('<tool_call>$payload</tool_call>');

        expect(result.call, isNull, reason: payload);
        expect(result.error, isNotNull, reason: payload);
      }
    });

    test('requires exact name and arguments fields', () {
      final payloads = <String>[
        '{"name":"read"}',
        '{"name":"read","arguments":null}',
        '{"name":"read","arguments":"{}"}',
        '{"name":"read","arguments":{},"id":"call_1"}',
        '{"name":1,"arguments":{}}',
      ];

      for (final payload in payloads) {
        final result = parser.parse('<tool_call>$payload</tool_call>');

        expect(result.call, isNull, reason: payload);
        expect(result.error, isNotNull, reason: payload);
      }
    });
  });
}
