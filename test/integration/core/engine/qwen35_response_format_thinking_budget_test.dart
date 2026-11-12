@TestOn('vm')
@Tags(['local-only'])
@Timeout(Duration(minutes: 10))
library;

import 'dart:convert';
import 'dart:io';

import 'package:llamadart/llamadart.dart';
import 'package:test/test.dart';

void main() {
  final model = Platform.environment['LLAMADART_QWEN35_MODEL'];
  test(
    'Qwen3.5 returns schema JSON after a thinking budget closes the thought',
    skip: model == null
        ? 'Set LLAMADART_QWEN35_MODEL to Qwen3.5-0.8B-Q4_K_M.gguf.'
        : null,
    () async {
      final engine = LlamaEngine(LlamaBackend());
      addTearDown(engine.dispose);
      await engine.loadModel(
        model!,
        modelParams: const ModelParams(
          contextSize: 4096,
          numberOfThreads: 2,
          numberOfThreadsBatch: 2,
        ),
      );
      const messages = [
        LlamaChatMessage.fromText(
          role: LlamaChatRole.user,
          text: 'Give the capital of France as JSON {"city": ...}.',
        ),
      ];
      const responseFormat = {
        'type': 'json_schema',
        'json_schema': {
          'schema': {
            'type': 'object',
            'properties': {
              'city': {'type': 'string'},
            },
            'required': ['city'],
            'additionalProperties': false,
          },
        },
      };
      final template = await engine.chatTemplate(
        messages,
        enableThinking: true,
        responseFormat: responseFormat,
      );
      expect(template.format, ChatFormat.qwen3CoderXml.index);
      expect(template.thinkingForcedOpen, isTrue);

      for (final maxTokens in [0, 1, 4, 16, 64]) {
        final chunks = await engine
            .create(
              messages,
              params: GenerationParams(
                maxTokens: 256,
                temp: 0,
                seed: 42,
                thinkingBudget: ThinkingBudget(maxTokens: maxTokens),
              ),
              enableThinking: true,
              responseFormat: responseFormat,
            )
            .toList();
        final content = chunks
            .map((chunk) => chunk.choices.first.delta.content ?? '')
            .join();
        expect(jsonDecode(content), {
          'city': isA<String>(),
        }, reason: 'thinking budget $maxTokens returned: $content');
        expect(chunks.last.choices.first.finishReason, 'stop');
      }
    },
  );
}
