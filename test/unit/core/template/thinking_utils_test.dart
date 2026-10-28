import 'package:llamadart/src/core/models/chat/chat_template_result.dart';
import 'package:llamadart/src/core/template/thinking_utils.dart';
import 'package:test/test.dart';

void main() {
  test('extractThinking separates reasoning and content', () {
    final result = extractThinking('<think>Reason</think>Answer');
    expect(result.reasoning, 'Reason');
    expect(result.content, 'Answer');
  });

  test('extractThinking strips multiple think blocks', () {
    final result = extractThinking(
      '<think>first</think>A<think>second</think>B',
    );
    expect(result.content, 'AB');
    expect(result.reasoning, 'first\nsecond');
  });

  test('extractThinking preserves whitespace between stripped blocks', () {
    final result = extractThinking(
      'Hello<think>x</think> world<think>y</think>!',
    );
    expect(result.content, 'Hello world!');
    expect(result.reasoning, 'x\ny');
  });

  test('extractThinking handles pre-opened reasoning', () {
    final result = extractThinking('\nI am thinking\n</think>\nHello!');

    expect(result.content, 'Hello!');
    expect(result.reasoning, 'I am thinking');
  });

  test('extractThinking handles open reasoning without an end tag', () {
    final result = extractThinking('<think>\nStill thinking');

    expect(result.content, '');
    expect(result.reasoning, 'Still thinking');
  });

  test('extractThinking treats forced-open output as reasoning', () {
    final result = extractThinking('Still thinking', thinkingForcedOpen: true);

    expect(result.content, '');
    expect(result.reasoning, 'Still thinking');
  });

  test('extractThinking unescapes reasoning unless told not to', () {
    for (final (text, forced) in const [
      (r'a\nb', true),
      (r'a\rb</think>c', false),
      (r'<think>a\nb', false),
      (r'x</think>y<think>a\nb</think>', false),
      (r'<think>x</think>y<think>a\nb</think>', false),
    ]) {
      final reasoning = extractThinking(
        text,
        thinkingForcedOpen: forced,
      ).reasoning!;
      final literal = extractThinking(
        text,
        thinkingForcedOpen: forced,
        unescape: false,
      ).reasoning!;
      expect(reasoning, isNot(contains('\\')), reason: text);
      expect(literal, contains(r'a\'), reason: text);
      expect(
        literal.replaceAll(r'\n', '\n').replaceAll(r'\r', '\r'),
        reasoning,
      );
    }
  });

  test('isThinkingForcedOpen detects trailing think tag', () {
    expect(isThinkingForcedOpen('<think>\n'), isTrue);
    expect(isThinkingForcedOpen('hello'), isFalse);
  });

  group('extractForcedOpenThoughtVerbatim', () {
    test('splits at the first end tag and keeps both parts as generated', () {
      expect(
        extractForcedOpenThoughtVerbatim(
          r' <think>Plan \n x. </think> A</think>B<think>X</think>C ',
        ),
        (
          reasoning: r'<think>Plan \n x.',
          content: 'A</think>B<think>X</think>C',
        ),
      );
    });

    test('keeps a thought that never ends as reasoning', () {
      expect(extractForcedOpenThoughtVerbatim(r'Plan \n more'), (
        reasoning: r'Plan \n more',
        content: '',
      ));
    });

    test('reports an empty thought as no reasoning', () {
      expect(extractForcedOpenThoughtVerbatim(' </think>Sure'), (
        reasoning: null,
        content: 'Sure',
      ));
      expect(extractForcedOpenThoughtVerbatim(''), (
        reasoning: null,
        content: '',
      ));
    });

    test('uses the given end tag', () {
      expect(extractForcedOpenThoughtVerbatim('Plan[/T]Sure', endTag: '[/T]'), (
        reasoning: 'Plan',
        content: 'Sure',
      ));
    });

    test('drops the start of an end tag that ends an unended thought', () {
      expect(extractForcedOpenThoughtVerbatim('Plan it </thi'), (
        reasoning: 'Plan it',
        content: '',
      ));
      expect(extractForcedOpenThoughtVerbatim('Plan.</think>Ans </thi'), (
        reasoning: 'Plan.',
        content: 'Ans </thi',
      ));
    });

    test('ends the thought at a content opening that comes first', () {
      const openings = ['<tool_call>'];
      expect(
        extractForcedOpenThoughtVerbatim(
          'Plan <tool_call>x</tool_call></think>A',
          contentOpenings: openings,
        ),
        (reasoning: 'Plan', content: '<tool_call>x</tool_call></think>A'),
      );
      expect(
        extractForcedOpenThoughtVerbatim(
          'Plan</think><tool_call>x</tool_call>',
          contentOpenings: openings,
        ),
        (reasoning: 'Plan', content: '<tool_call>x</tool_call>'),
      );
      expect(
        extractForcedOpenThoughtVerbatim(
          'Plan <tool',
          contentOpenings: openings,
        ),
        (reasoning: 'Plan', content: ''),
      );
    });
  });

  group('withoutTrailingTagPrefix', () {
    test('drops the longest ending that starts one of the tags', () {
      expect(withoutTrailingTagPrefix('a </thi', ['</think>']), 'a ');
      expect(
        withoutTrailingTagPrefix('a <', ['<tool_call>', '</think>']),
        'a ',
      );
      expect(
        withoutTrailingTagPrefix('a <tool', ['</think>', '<tool_call>']),
        'a ',
      );
      // Both `a` and `aba` start the tag.
      expect(withoutTrailingTagPrefix('x aba', ['abab']), 'x ');
    });

    test('keeps a whole tag and text that ends no tag', () {
      expect(
        withoutTrailingTagPrefix('a </think>', ['</think>']),
        'a </think>',
      );
      expect(withoutTrailingTagPrefix('x < y', ['</think>']), 'x < y');
      expect(withoutTrailingTagPrefix('', ['</think>']), '');
    });
  });

  group('isThinkingForcedClosed', () {
    test('is true for a prompt that ends with an empty thought', () {
      for (final prompt in [
        'assistant\n<think>\n\n</think>\n\n',
        '<｜Assistant｜><think></think>',
        'ai<|START_THINKING|> <|END_THINKING|>',
      ]) {
        expect(
          isThinkingForcedClosed(
            prompt,
            startTag: prompt.contains('START')
                ? '<|START_THINKING|>'
                : '<think>',
            endTag: prompt.contains('START') ? '<|END_THINKING|>' : '</think>',
          ),
          isTrue,
          reason: prompt,
        );
      }
    });

    test('is false without an empty thought at the end', () {
      for (final prompt in [
        'assistant\n',
        'assistant\n<think>\n',
        '<|Bot|></think>',
        '<think>Plan</think>',
        '<think></think>Answer',
      ]) {
        expect(isThinkingForcedClosed(prompt), isFalse, reason: prompt);
      }
    });
  });

  group('withThinkingForcedClosed', () {
    test('marks only the result it is given, and only when closed', () {
      LlamaChatTemplateResult result() =>
          LlamaChatTemplateResult(prompt: 'assistant\n<think></think>\n');
      final marked = withThinkingForcedClosed(result(), closed: true);
      expect(thinkingForcedClosedOf(marked), isTrue);
      expect(
        thinkingForcedClosedOf(
          withThinkingForcedClosed(result(), closed: false),
        ),
        isFalse,
      );
      expect(thinkingForcedClosedOf(result()), isFalse);
    });
  });

  group('withThoughtClosedForThinkingOff', () {
    test('marks only the result it is given, and only when closed', () {
      LlamaChatTemplateResult result() =>
          LlamaChatTemplateResult(prompt: 'assistant\n<think></think>\n');
      final marked = withThoughtClosedForThinkingOff(result(), closed: true);
      expect(thoughtClosedForThinkingOffOf(marked), isTrue);
      expect(thinkingForcedClosedOf(marked), isFalse);
      expect(
        thoughtClosedForThinkingOffOf(
          withThoughtClosedForThinkingOff(result(), closed: false),
        ),
        isFalse,
      );
      expect(thoughtClosedForThinkingOffOf(result()), isFalse);
    });
  });

  group('withThoughtMarksOf', () {
    test('copies each thought mark of the source', () {
      LlamaChatTemplateResult result() =>
          LlamaChatTemplateResult(prompt: 'assistant\n<think></think>\n');
      for (final templateClosed in const [false, true]) {
        for (final handlerClosed in const [false, true]) {
          final source = withThoughtClosedForThinkingOff(
            withThinkingForcedClosed(result(), closed: templateClosed),
            closed: handlerClosed,
          );
          final copy = withThoughtMarksOf(result(), source);
          final reason = '$templateClosed $handlerClosed';
          expect(thinkingForcedClosedOf(copy), templateClosed, reason: reason);
          expect(
            thoughtClosedForThinkingOffOf(copy),
            handlerClosed,
            reason: reason,
          );
        }
      }
    });
  });

  group('withTemplateOpenedThought', () {
    LlamaChatTemplateResult result(String prompt, {bool forcedOpen = false}) =>
        LlamaChatTemplateResult(
          prompt: prompt,
          format: 0,
          grammar: 'root ::= "x"',
          thinkingForcedOpen: forcedOpen,
        );

    test('forces open a thought that ends the prompt in the start tag', () {
      final opened = withTemplateOpenedThought(
        result('look[THINK]\n'),
        startTag: '[THINK]',
      );
      expect(opened.prompt, 'look[THINK]\n');
      expect(opened.grammar, 'root ::= "x"');
      expect(opened.thinkingForcedOpen, isTrue);
    });

    test('leaves a prompt that does not end in the start tag', () {
      for (final prompt in ['look<think>', 'look[THINK][/THINK]']) {
        expect(
          withTemplateOpenedThought(
            result(prompt),
            startTag: '[THINK]',
          ).thinkingForcedOpen,
          isFalse,
        );
      }
    });

    test('keeps a thought the handler already tracks', () {
      final tracked = result('look', forcedOpen: true);
      expect(withTemplateOpenedThought(tracked, startTag: '<think>'), tracked);
    });
  });

  group('effectiveEnableThinking', () {
    test('a boolean enable_thinking kwarg overrides the flag', () {
      expect(effectiveEnableThinking(false, {'enable_thinking': true}), isTrue);
      expect(
        effectiveEnableThinking(true, {'enable_thinking': false}),
        isFalse,
      );
    });

    test('a boolean thinking kwarg applies without enable_thinking', () {
      expect(effectiveEnableThinking(false, {'thinking': true}), isTrue);
      expect(effectiveEnableThinking(true, {'thinking': false}), isFalse);
      expect(
        effectiveEnableThinking(false, {
          'enable_thinking': 'yes',
          'thinking': true,
        }),
        isTrue,
      );
    });

    test('enable_thinking wins over a conflicting thinking kwarg', () {
      expect(
        effectiveEnableThinking(true, {
          'enable_thinking': false,
          'thinking': true,
        }),
        isFalse,
      );
    });

    test('non-boolean values and absent kwargs keep the flag', () {
      for (final value in <Object?>['true', 'false', 1, 0, null, [], {}]) {
        for (final flag in [true, false]) {
          expect(
            effectiveEnableThinking(flag, {
              'enable_thinking': value,
              'thinking': value,
            }),
            flag,
            reason: '$value',
          );
        }
      }
      expect(effectiveEnableThinking(true, null), isTrue);
      expect(effectiveEnableThinking(false, const {}), isFalse);
    });
  });
}
