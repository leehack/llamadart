import 'package:llamadart_tui_coding_agent/src/assistant_text_stream.dart';
import 'package:test/test.dart';

void main() {
  test('streams ordinary text while retaining split-marker lookbehind', () {
    final stream = AssistantTextStream();
    final output = <String>[];
    var resets = 0;

    stream.add('Hello <to', onText: output.add, onReset: () => resets++);
    expect(output.join(), 'Hello ');

    stream.add('day', onText: output.add, onReset: () => resets++);
    stream.finish(onText: output.add);

    expect(output, ['Hello ', '<today']);
    expect(resets, 0);
  });

  test('withholds a tool-call marker split across deltas', () {
    final stream = AssistantTextStream();
    final output = <String>[];
    var resets = 0;

    stream.add('  <tool_', onText: output.add, onReset: () => resets++);
    stream.add('call>{}', onText: output.add, onReset: () => resets++);
    stream.finish(onText: output.add);

    expect(output, isEmpty);
    expect(resets, 0);
    expect(stream.hasVisibleDraft, isFalse);
  });

  test('resets ordinary prose when a later tool marker appears', () {
    final stream = AssistantTextStream();
    final output = <String>[];
    var resets = 0;

    stream.add('I will inspect. ', onText: output.add, onReset: () => resets++);
    stream.add('<tool_call>', onText: output.add, onReset: () => resets++);

    expect(output.join(), 'I will inspect. ');
    expect(resets, 1);
    expect(stream.hasVisibleDraft, isFalse);
  });

  test('flushes an incomplete marker prefix for a normal final answer', () {
    final stream = AssistantTextStream();
    final output = <String>[];

    stream.add('<tool_cal', onText: output.add, onReset: () {});
    expect(output, isEmpty);

    stream.finish(onText: output.add);

    expect(output.single, '<tool_cal');
  });

  test('discard resets a visible partial answer exactly once', () {
    final stream = AssistantTextStream();
    final output = <String>[];
    var resets = 0;

    stream.add('partial answer', onText: output.add, onReset: () => resets++);
    stream.discard(onReset: () => resets++);
    stream.discard(onReset: () => resets++);

    expect(output.single, 'partial answer');
    expect(resets, 1);
    expect(stream.hasVisibleDraft, isFalse);
  });
}
