import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_chat_example/services/assistant_output_service.dart';

void main() {
  const service = AssistantOutputService();

  group('AssistantOutputService', () {
    test('normalizes think-tagged output into text and thinking', () {
      final normalized = service.normalizeAssistantOutput(
        streamedContent: '<think>plan first</think>Final answer.',
        streamedThinking: '',
        toolsEnabled: false,
        detectedChatFormat: ChatFormat.generic,
        cleanResponse: (response) => response.trim(),
      );

      expect(normalized.text, 'Final answer.');
      expect(normalized.thinking, 'plan first');
    });

    test('parses function-gemma tool-call text for display', () {
      final calls = service.parseToolCallsForDisplay(
        streamedContent:
            '<start_function_call>call getWeather{city:<escape>London<escape>}<end_function_call>',
        detectedChatFormat: ChatFormat.functionGemma,
      );

      expect(calls, hasLength(1));
      expect(calls.first.name, 'getWeather');
      expect(calls.first.arguments, <String, dynamic>{'city': 'London'});
    });

    test('normalizes Gemma 4 channel reasoning into text and thinking', () {
      final normalized = service.normalizeAssistantOutput(
        streamedContent: '<|channel>thought\nplan first<channel|>Final answer.',
        streamedThinking: '',
        toolsEnabled: false,
        detectedChatFormat: ChatFormat.gemma4,
        cleanResponse: (response) => response.trim(),
      );

      expect(normalized.text, 'Final answer.');
      expect(normalized.thinking, 'plan first');
    });

    test('builds debug badges from normalized output state', () {
      final badges = service.buildAssistantDebugBadges(
        detectedChatFormat: ChatFormat.generic,
        hadRawThinkingTags: true,
        hadThinkingStream: false,
        finalThinking: 'reasoning',
        finalText: '{}',
      );

      expect(
        badges,
        containsAll(<String>['fmt:generic', 'think:tag-parse', 'content:json']),
      );
    });
  });
}
