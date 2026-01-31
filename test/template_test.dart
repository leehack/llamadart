import 'dart:io';
import 'package:test/test.dart';
import 'package:llamadart/llamadart.dart';
import 'test_helper.dart';

void main() async {
  late File modelFile;
  late LlamaService service;

  setUpAll(() async {
    modelFile = await TestHelper.getTestModel();
    service = LlamaService();
    await service.init(
      modelFile.path,
      modelParams: const ModelParams(contextSize: 2048),
    );
  });

  tearDownAll(() async {
    await service.dispose();
  });

  group('Chat Template Support', () {
    test('applyChatTemplate returns result with stop sequences', () async {
      final messages = [const LlamaChatMessage(role: 'user', content: 'Hello')];

      final result = await service.applyChatTemplate(messages);
      expect(result.prompt, isNotEmpty);
      // For stories15M.gguf which has no template, it uses native fallback (ChatML)
      // and should at least have one stop sequence if we successfully detected EOT or im_end
      print('Detected Stop Sequences: ${result.stopSequences}');
      expect(
        result.stopSequences,
        isNotEmpty,
        reason: "Should have at least one stop sequence (fallback or detected)",
      );
    });

    test('chat method handles streaming and auto-stops', () async {
      final messages = [
        const LlamaChatMessage(role: 'user', content: 'Say "stop"'),
      ];

      final stream = service.chat(
        messages,
        params: const GenerationParams(maxTokens: 50),
      );

      final buffer = StringBuffer();
      await for (final token in stream) {
        buffer.write(token);
        // If the library is working correctly, it should not emit stop markers like <|im_end|>
        expect(token, isNot(contains('<|im_end|>')));
        expect(token, isNot(contains('<|eot_id|>')));
      }

      expect(buffer.toString(), isNotEmpty);
      print('Chat Response: "${buffer.toString()}"');
    });

    test('chat history works correctly', () async {
      // For this tiny 15M model which doesn't know templates,
      // we test history by manually concatenating to see if the engine
      // can still process a sequence of events.
      final history = [
        const LlamaChatMessage(
          role: 'user',
          content: 'Once upon a time, there was a dog named Buddy.',
        ),
        const LlamaChatMessage(
          role: 'assistant',
          content: 'Buddy was a happy dog.',
        ),
        const LlamaChatMessage(
          role: 'user',
          content: 'What was the dog\'s name?',
        ),
      ];

      // Use a very simple "template" that this model might understand better (just plain text)
      final prompt =
          "${history.map((m) => "${m.role}: ${m.content}").join("\n")}\nassistant:";

      final response = await service.generate(prompt).join();
      expect(response.toLowerCase(), contains('buddy'));
    });
  });
}
