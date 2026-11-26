import 'package:llamadart/src/core/models/chat/completion_chunk.dart';
import 'package:llamadart/src/core/models/inference/generation_usage.dart';
import 'package:llamadart/src/core/models/inference/next_token_scores.dart';
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

  test('LlamaCompletionChunk parses an OpenAI include_usage chunk', () {
    final chunk = LlamaCompletionChunk.fromJson({
      'id': 'chatcmpl-1',
      'object': 'chat.completion.chunk',
      'created': 1,
      'model': 'm',
      'choices': <Object>[],
      'usage': {'prompt_tokens': 3, 'completion_tokens': 2, 'total_tokens': 5},
    });

    expect(chunk.usage!.promptTokens, 3);
    expect(chunk.usage!.completionTokens, 2);
    expect(chunk.usage!.duration, isNull);
  });

  group('LlamaFinishReason', () {
    test('maps every finish_reason wire value', () {
      expect(LlamaFinishReason.fromWireValue('stop'), LlamaFinishReason.stop);
      expect(
        LlamaFinishReason.fromWireValue('length'),
        LlamaFinishReason.length,
      );
      expect(
        LlamaFinishReason.fromWireValue('tool_calls'),
        LlamaFinishReason.toolCalls,
      );
      expect(LlamaFinishReason.values.map((reason) => reason.wireValue), [
        'stop',
        'length',
        'tool_calls',
      ]);
    });

    test('returns null for a missing or unknown value', () {
      expect(LlamaFinishReason.fromWireValue(null), isNull);
      expect(LlamaFinishReason.fromWireValue('content_filter'), isNull);
    });
  });

  group('LlamaCompletionChunkExtension', () {
    LlamaCompletionChunk chunk(List<Map<String, Object?>> choices) =>
        LlamaCompletionChunk.fromJson({
          'id': 'c',
          'object': 'chat.completion.chunk',
          'created': 1,
          'model': 'm',
          'choices': choices,
        });

    test('reads the deltas of the first choice', () {
      final value = chunk([
        {
          'index': 0,
          'delta': {
            'content': 'hi',
            'thinking': 'hmm',
            'tool_calls': [
              {
                'index': 0,
                'id': 'call_0',
                'function': {'name': 'f', 'arguments': '{'},
              },
            ],
          },
          'finish_reason': 'tool_calls',
        },
        {
          'index': 1,
          'delta': {'content': 'other'},
          'finish_reason': 'stop',
        },
      ]);

      expect(value.text, 'hi');
      expect(value.thinking, 'hmm');
      expect(value.toolCalls.single.function!.name, 'f');
      expect(value.finishReason, LlamaFinishReason.toolCalls);
    });

    test('returns empty values for an empty delta', () {
      final value = chunk([
        {'index': 0, 'delta': <String, Object?>{}},
      ]);

      expect(value.text, isEmpty);
      expect(value.thinking, isEmpty);
      expect(value.toolCalls, isEmpty);
      expect(value.finishReason, isNull);
    });

    test('returns empty values for a chunk without choices', () {
      final value = chunk([]);

      expect(value.text, isEmpty);
      expect(value.thinking, isEmpty);
      expect(value.toolCalls, isEmpty);
      expect(value.finishReason, isNull);
    });

    test('leaves an unknown finish_reason untyped', () {
      final value = chunk([
        {
          'index': 0,
          'delta': <String, Object?>{},
          'finish_reason': 'content_filter',
        },
      ]);

      expect(value.finishReason, isNull);
      expect(value.choices.single.finishReason, 'content_filter');
    });
  });

  test('LlamaCompletionChunkChoice writes logprobs as OpenAI content', () {
    final choice = LlamaCompletionChunkChoice(
      index: 0,
      delta: LlamaCompletionChunkDelta(content: 'é'),
      logprobs: [
        LlamaGeneratedTokenLogprobs(
          sampled: LlamaTokenLogprob(
            token: 3,
            bytes: const [0xC3],
            logprob: -0.25,
          ),
          top: [
            LlamaTokenLogprob(token: 4, bytes: const [0x61], logprob: -2),
          ],
        ),
      ],
    );

    final json = choice.toJson();
    final content = (json['logprobs'] as Map<String, dynamic>)['content'];
    expect(content, [
      {
        'token': '�',
        'id': 3,
        'logprob': -0.25,
        'bytes': [0xC3],
        'top_logprobs': [
          {
            'token': 'a',
            'id': 4,
            'logprob': -2.0,
            'bytes': [0x61],
          },
        ],
      },
    ]);
    final decoded = LlamaCompletionChunkChoice.fromJson(json).logprobs!.single;
    expect(decoded.sampled.token, 3);
    expect(decoded.top.single.bytes, [0x61]);
  });

  test('LlamaCompletionChunkChoice omits logprobs when it has none', () {
    final choice = LlamaCompletionChunkChoice(
      index: 0,
      delta: LlamaCompletionChunkDelta(content: 'a'),
    );

    expect(choice.toJson().containsKey('logprobs'), isFalse);
    expect(
      LlamaCompletionChunkChoice.fromJson(choice.toJson()).logprobs,
      isNull,
    );
  });
}
