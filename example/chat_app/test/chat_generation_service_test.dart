import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_chat_example/models/chat_settings.dart';
import 'package:llamadart_chat_example/services/chat_generation_service.dart';

void main() {
  const service = ChatGenerationService();

  group('ChatGenerationService', () {
    test('builds generation params from settings', () {
      const settings = ChatSettings(
        maxTokens: 1234,
        temperature: 0.4,
        topK: 7,
        topP: 0.8,
        minP: 0.2,
        penalty: 1.3,
      );

      final params = service.buildParams(settings);

      expect(params.maxTokens, 1234);
      expect(params.temp, 0.4);
      expect(params.topK, 7);
      expect(params.topP, 0.8);
      expect(params.minP, 0.2);
      expect(params.penalty, 1.3);
      expect(params.stopSequences, isEmpty);
    });

    test('omits unsupported minP/penalty for litert models', () {
      const defaults = GenerationParams();
      const settings = ChatSettings(
        modelPath: '/models/gemma.litertlm',
        maxTokens: 1234,
        temperature: 0.4,
        topK: 7,
        topP: 0.8,
        minP: 0.2,
        penalty: 1.3,
      );

      final params = service.buildParams(settings);

      // Supported options are still forwarded.
      expect(params.maxTokens, 1234);
      expect(params.temp, 0.4);
      expect(params.topK, 7);
      expect(params.topP, 0.8);
      // minP/penalty fall back to defaults so the LiteRT-LM backend does not
      // reject the request with an UnsupportedError.
      expect(params.minP, defaults.minP);
      expect(params.penalty, defaults.penalty);
    });

    test('accumulates stream updates and metrics', () async {
      final updates = <GenerationStreamUpdate>[];
      final result = await service.consumeStream(
        stream: Stream<LlamaCompletionChunk>.fromIterable(
          <LlamaCompletionChunk>[
            _chunk(content: 'Hel', thinking: 'a'),
            _chunk(content: 'lo', thinking: 'b'),
          ],
        ),
        thinkingEnabled: true,
        uiNotifyIntervalMs: -1,
        cleanResponse: (value) => value,
        shouldContinue: () => true,
        onUpdate: updates.add,
      );

      expect(result.fullResponse, 'Hello');
      expect(result.fullThinking, 'ab');
      expect(result.generatedTokens, 2);
      expect(result.firstTokenLatencyMs, isNotNull);
      expect(result.elapsedMs, greaterThanOrEqualTo(0));
      expect(result.decodeElapsedMs, greaterThanOrEqualTo(0));
      expect(updates.length, greaterThanOrEqualTo(2));
      expect(updates.last.cleanText, 'Hello');
      expect(updates.last.fullThinking, 'ab');
      expect(updates.last.shouldNotify, isTrue);
    });

    test('smooths large streamed chunks and flushes final text', () async {
      final longChunk = List<String>.filled(260, 'x').join();
      final updates = <GenerationStreamUpdate>[];

      final result = await service.consumeStream(
        stream: Stream<LlamaCompletionChunk>.fromIterable(
          <LlamaCompletionChunk>[_chunk(content: longChunk)],
        ),
        thinkingEnabled: false,
        uiNotifyIntervalMs: -1,
        cleanResponse: (value) => value,
        shouldContinue: () => true,
        onUpdate: updates.add,
      );

      expect(result.fullResponse, longChunk);
      expect(updates.length, greaterThanOrEqualTo(2));
      expect(updates.first.cleanText.length, lessThan(longChunk.length));
      expect(updates.last.cleanText, longChunk);
      expect(updates.last.shouldNotify, isTrue);
    });
  });
}

LlamaCompletionChunk _chunk({String? content, String? thinking}) {
  return LlamaCompletionChunk(
    id: 'id',
    object: 'chat.completion.chunk',
    created: 1,
    model: 'mock',
    choices: <LlamaCompletionChunkChoice>[
      LlamaCompletionChunkChoice(
        index: 0,
        delta: LlamaCompletionChunkDelta(content: content, thinking: thinking),
      ),
    ],
  );
}
