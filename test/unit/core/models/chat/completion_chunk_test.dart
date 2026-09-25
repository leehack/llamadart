import 'package:llamadart/src/core/models/chat/completion_chunk.dart';
import 'package:llamadart/src/core/models/inference/generation_usage.dart';
import 'package:test/test.dart';

void main() {
  test('LlamaCompletionChunk can parse and serialize JSON', () {
    final chunk = LlamaCompletionChunk.fromJson({
      'id': 'abc',
      'object': 'chat.completion.chunk',
      'created': 1,
      'model': 'test-model',
      'choices': [
        {
          'index': 0,
          'delta': {'content': 'hi'},
        },
      ],
    });

    expect(chunk.choices, hasLength(1));
    expect(chunk.choices.first.delta.content, 'hi');
    expect(chunk.toJson()['id'], 'abc');
  });

  test('LlamaCompletionChunk omits usage when it has none', () {
    final chunk = LlamaCompletionChunk(
      id: 'abc',
      object: 'chat.completion.chunk',
      created: 1,
      model: 'test-model',
      choices: const [],
    );

    expect(chunk.toJson().containsKey('usage'), isFalse);
    expect(LlamaCompletionChunk.fromJson(chunk.toJson()).usage, isNull);
  });

  test('LlamaCompletionChunk round-trips usage through JSON', () {
    final chunk = LlamaCompletionChunk(
      id: 'abc',
      object: 'chat.completion.chunk',
      created: 1,
      model: 'test-model',
      choices: const [],
      usage: const LlamaGenerationUsage(
        promptTokens: 4,
        completionTokens: 2,
        duration: Duration(milliseconds: 3),
      ),
    );

    final json = chunk.toJson();
    expect(json['usage'], {
      'prompt_tokens': 4,
      'completion_tokens': 2,
      'total_tokens': 6,
      'duration_ms': 3.0,
    });
    final usage = LlamaCompletionChunk.fromJson(json).usage!;
    expect(usage.promptTokens, 4);
    expect(usage.completionTokens, 2);
  });
}
