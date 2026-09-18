import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_chat_example/models/chat_message.dart';
import 'package:llamadart_chat_example/services/chat_session_service.dart';

import 'mocks.dart';

void main() {
  const service = ChatSessionService();

  group('ChatSessionService', () {
    test('serializes chat message with text when parts are absent', () {
      final serialized = service.toLlamaChatMessage(
        ChatMessage(text: 'hello', isUser: true),
      );

      expect(serialized, isNotNull);
      expect(serialized!.role, LlamaChatRole.user);
      expect(
        serialized.parts.whereType<LlamaTextContent>().first.text,
        'hello',
      );
    });

    test('keeps mirrored tool results out of the assistant turn', () {
      const call = LlamaToolCallContent(
        id: 'call_1',
        name: 'getWeather',
        arguments: {'city': 'Seoul'},
        rawJson: '{"city":"Seoul"}',
      );
      const result = LlamaToolResultContent(
        id: 'call_1',
        name: 'getWeather',
        result: {'city': 'Seoul', 'simulated': true},
      );

      final assistant = service.toLlamaChatMessage(
        ChatMessage(
          text: '',
          isUser: false,
          parts: const <LlamaContentPart>[call, result],
        ),
      );
      expect(assistant, isNotNull);
      expect(assistant!.role, LlamaChatRole.assistant);
      expect(assistant.parts.whereType<LlamaToolCallContent>(), hasLength(1));
      expect(assistant.parts.whereType<LlamaToolResultContent>(), isEmpty);

      final toolMessage = service.toLlamaChatMessage(
        ChatMessage(
          text: '',
          isUser: false,
          role: LlamaChatRole.tool,
          parts: const <LlamaContentPart>[result],
        ),
      );
      expect(toolMessage, isNotNull);
      expect(toolMessage!.role, LlamaChatRole.tool);
      expect(
        toolMessage.parts.whereType<LlamaToolResultContent>(),
        hasLength(1),
      );
    });

    test('ignores informational messages during serialization', () {
      final serialized = service.toLlamaChatMessage(
        ChatMessage(text: 'info', isUser: false, isInfo: true),
      );

      expect(serialized, isNull);
    });

    test('rebuilds session from conversation messages', () {
      final engine = MockLlamaEngine()..initialized = true;
      final session = service.rebuildFromMessages(
        engine: engine,
        contextSize: 4096,
        systemPrompt: 'system',
        messages: <ChatMessage>[
          ChatMessage(text: 'hello', isUser: true),
          ChatMessage(text: 'world', isUser: false),
          ChatMessage(text: 'info', isUser: false, isInfo: true),
        ],
      );

      expect(session.history, hasLength(2));
      expect(session.history.first.role, LlamaChatRole.user);
      expect(session.history.last.role, LlamaChatRole.assistant);
    });
  });
}
