import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_chat_example/models/chat_message.dart';
import 'package:llamadart_chat_example/models/chat_settings.dart';
import 'package:llamadart_chat_example/services/conversation_state_service.dart';

void main() {
  const service = ConversationStateService();

  group('ConversationStateService', () {
    test('issues distinct conversation IDs for the same clock reading', () {
      final now = DateTime.fromMillisecondsSinceEpoch(1760000000000);

      final first = service.newConversationId(now: now);
      final second = service.newConversationId(now: now);
      final earlier = service.newConversationId(
        now: now.subtract(const Duration(seconds: 1)),
      );

      expect(<String>{first, second, earlier}, hasLength(3));
      expect(int.parse(second), greaterThan(int.parse(first)));
      expect(int.parse(earlier), greaterThan(int.parse(second)));
    });

    test('builds title from first user message', () {
      final title = service.deriveConversationTitle(
        messages: <ChatMessage>[
          ChatMessage(text: 'hello world', isUser: true),
          ChatMessage(text: 'assistant', isUser: false),
        ],
        fallback: 'New conversation',
      );

      expect(title, 'hello world');
    });

    test('creates and snapshots conversation state', () {
      final initial = service.createEmptyConversation(
        id: '1',
        settings: const ChatSettings(),
        now: DateTime(2026),
      );

      final snapshot = service.buildSnapshot(
        existing: initial,
        messages: <ChatMessage>[
          ChatMessage(text: 'user question', isUser: true),
        ],
        settings: const ChatSettings(maxTokens: 1024),
        currentTokens: 12,
        isPruning: false,
        touchUpdatedAt: true,
        now: DateTime(2027),
      );

      expect(snapshot.title, 'user question');
      expect(snapshot.currentTokens, 12);
      expect(snapshot.settings.maxTokens, 1024);
      expect(snapshot.updatedAt, DateTime(2027));
    });
  });
}
