import 'package:llamadart/src/core/models/inference/generation_params.dart';
import 'package:test/test.dart';

void main() {
  test('GenerationParams copyWith updates selected fields', () {
    const params = GenerationParams(temp: 0.5, maxTokens: 10);
    final updated = params.copyWith(
      topK: 12,
      minP: 0.05,
      grammarRoot: 'main',
      grammarLazy: true,
      speculativeDecoding: true,
      reusePromptPrefix: false,
      streamBatchTokenThreshold: 4,
      streamBatchByteThreshold: 256,
      grammarTriggers: [
        const GenerationGrammarTrigger(type: 0, value: '<tool_call>'),
      ],
      preservedTokens: const ['<tool_call>'],
    );

    expect(updated.temp, 0.5);
    expect(updated.maxTokens, 10);
    expect(updated.topK, 12);
    expect(updated.minP, 0.05);
    expect(updated.grammarRoot, 'main');
    expect(updated.grammarLazy, isTrue);
    expect(updated.speculativeDecoding, isTrue);
    expect(updated.reusePromptPrefix, isFalse);
    expect(updated.streamBatchTokenThreshold, 4);
    expect(updated.streamBatchByteThreshold, 256);
    expect(updated.grammarTriggers, hasLength(1));
    expect(updated.preservedTokens, const ['<tool_call>']);
  });

  test('GenerationParams defaults minP to zero', () {
    const params = GenerationParams();

    expect(params.minP, 0.0);
    expect(params.speculativeDecoding, isFalse);
  });

  test('GenerationParams defaults stream batching thresholds', () {
    const params = GenerationParams();

    expect(params.reusePromptPrefix, isTrue);
    expect(params.streamBatchTokenThreshold, 8);
    expect(params.streamBatchByteThreshold, 512);
  });
}
