import 'package:llamadart/src/core/engine/chat_completion_stream_parser.dart';
import 'package:llamadart/src/core/models/chat/chat_template_result.dart';
import 'package:test/test.dart';

void main() {
  group('ChatCompletionStreamParser', () {
    test('streams plain content chunks and a final stop chunk', () async {
      final chunks = await ChatCompletionStreamParser.parse(
        tokenStream: Stream.fromIterable(['hel', 'lo']),
        templateResult: const LlamaChatTemplateResult(prompt: 'prompt'),
        parseToolCallsEnabled: false,
        enableThinking: true,
        modelName: 'test-model',
        completionId: '123',
      ).toList();

      final content = chunks
          .map((chunk) => chunk.choices.single.delta.content ?? '')
          .join();

      expect(content, 'hello');
      expect(chunks.last.choices.single.finishReason, 'stop');
      expect(chunks.last.model, 'test-model');
    });
  });
}
