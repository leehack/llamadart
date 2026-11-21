import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/core/template/resolved_thinking_budget.dart';
import 'package:test/test.dart';

import '../../../support/raw_tool_schema_fixture.dart';

void main() {
  final qwenXml = ChatFormat.qwen3CoderXml.index;
  final noPrefix = ChatFormat.hermes.index;

  group('ChatTemplateEngine.resolveThinkingBudget', () {
    test('fills tags and closes a Qwen3-Coder XML thought with a newline', () {
      final tags = ChatTemplateEngine.thinkingTagsFor(qwenXml);
      final resolved = ChatTemplateEngine.resolveThinkingBudget(
        qwenXml,
        const ThinkingBudget(maxTokens: 8),
      );

      expect(resolved.maxTokens, 8);
      expect(resolved, isA<ResolvedThinkingBudget>());
      expect((resolved as ResolvedThinkingBudget).naturalEndTags, [
        '\n</think>',
        '</think>',
        '<tool_call>',
      ]);
      expect(resolved.replayEndIndexFor(const GenerationParams()), isNull);
      expect(
        ChatTemplateEngine.resolveThinkingBudget(qwenXml, resolved),
        same(resolved),
      );
      expect(resolved.startTag, tags.startTag);
      expect(resolved.endTag, tags.endTag);
      expect(resolved.forcedMessage, '\n');
    });

    test('appends the prefix to a caller forced message', () {
      final resolved = ChatTemplateEngine.resolveThinkingBudget(
        qwenXml,
        const ThinkingBudget(maxTokens: 8, forcedMessage: 'Out of budget.'),
      );

      expect(resolved.forcedMessage, 'Out of budget.\n');
    });

    test('adds no prefix for a format without one', () {
      final resolved = ChatTemplateEngine.resolveThinkingBudget(
        noPrefix,
        const ThinkingBudget(maxTokens: 8),
      );

      expect(resolved.forcedMessage, isNull);
    });

    test('keeps a caller forced message for a format without a prefix', () {
      final resolved = ChatTemplateEngine.resolveThinkingBudget(
        noPrefix,
        const ThinkingBudget(maxTokens: 8, forcedMessage: 'Stop.'),
      );

      expect(resolved.forcedMessage, 'Stop.');
    });

    test('leaves a caller end tag and its forced message as given', () {
      final resolved = ChatTemplateEngine.resolveThinkingBudget(
        qwenXml,
        const ThinkingBudget(
          maxTokens: 8,
          startTag: '<a>',
          endTag: '</a>',
          forcedMessage: 'Stop.',
        ),
      );

      expect(resolved.startTag, '<a>');
      expect(resolved.endTag, '</a>');
      expect(resolved.forcedMessage, 'Stop.');
    });

    test(
      'an explicit canonical end stays single and a start-only override does not',
      () {
        final explicit = ChatTemplateEngine.resolveThinkingBudget(
          qwenXml,
          const ThinkingBudget(
            maxTokens: 8,
            endTag: '</think>',
            forcedMessage: 'Done',
          ),
        );
        expect(explicit, isNot(isA<ResolvedThinkingBudget>()));
        expect(explicit.forcedMessage, 'Done');
        final resolved =
            ChatTemplateEngine.resolveThinkingBudget(
                  qwenXml,
                  const ThinkingBudget(maxTokens: 8, startTag: '<custom>'),
                )
                as ResolvedThinkingBudget;
        expect(resolved.startTag, '<custom>');
        expect(resolved.naturalEndTags.last, '<tool_call>');
      },
    );

    test('adds no prefix when the backend does not render the prompt', () {
      final resolved = ChatTemplateEngine.resolveThinkingBudget(
        qwenXml,
        const ThinkingBudget(maxTokens: 8),
        rendersPrompt: false,
      );

      expect(resolved.forcedMessage, isNull);
      expect(resolved, isNot(isA<ResolvedThinkingBudget>()));
    });

    test('takes the generic tags for an index past the end of ChatFormat', () {
      final resolved = ChatTemplateEngine.resolveThinkingBudget(
        ChatFormat.values.length,
        const ThinkingBudget(maxTokens: 8),
      );

      expect(resolved.startTag, '<think>');
      expect(resolved.endTag, '</think>');
      expect(resolved.forcedMessage, isNull);
      expect(ChatTemplateEngine.thinkingTagsFor(ChatFormat.values.length), (
        startTag: '<think>',
        endTag: '</think>',
      ));
    });

    test('throws RangeError for a negative index', () {
      expect(
        () => ChatTemplateEngine.resolveThinkingBudget(
          -1,
          const ThinkingBudget(maxTokens: 8),
        ),
        throwsRangeError,
      );
      expect(() => ChatTemplateEngine.thinkingTagsFor(-1), throwsRangeError);
    });
  });

  group('ChatTemplateEngine.parse', () {
    test('parses past the end of ChatFormat with the generic handler', () {
      const incompleteCall = '{"tool_call": {"name": "inspect"';

      expect(
        () => ChatTemplateEngine.parse(
          ChatFormat.generic.index,
          incompleteCall,
          tools: [rawSchemaTool()],
        ),
        throwsA(isA<LlamaInferenceException>()),
      );
      expect(
        () => ChatTemplateEngine.parse(
          ChatFormat.values.length,
          incompleteCall,
          tools: [rawSchemaTool()],
        ),
        throwsA(isA<LlamaInferenceException>()),
      );
    });
  });
}
