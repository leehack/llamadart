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

  test('isThinkingForcedOpen detects trailing think tag', () {
    expect(isThinkingForcedOpen('<think>\n'), isTrue);
    expect(isThinkingForcedOpen('hello'), isFalse);
  });
}
