import 'package:llamadart/llamadart.dart';

import '../models/chat_message.dart';

/// Creates and restores [ChatSession] instances from UI message state.
class ChatSessionService {
  const ChatSessionService();

  ChatSession createSession({
    required LlamaEngine engine,
    required int contextSize,
    String? systemPrompt,
  }) {
    return ChatSession(
      engine,
      maxContextTokens: contextSize > 0 ? contextSize : null,
      systemPrompt: systemPrompt,
    );
  }

  ChatSession rebuildFromMessages({
    required LlamaEngine engine,
    required int contextSize,
    String? systemPrompt,
    required Iterable<ChatMessage> messages,
  }) {
    final session = createSession(
      engine: engine,
      contextSize: contextSize,
      systemPrompt: systemPrompt,
    );

    for (final message in messages) {
      final serialized = toLlamaChatMessage(message);
      if (serialized != null) {
        session.addMessage(serialized);
      }
    }

    return session;
  }

  LlamaChatMessage? toLlamaChatMessage(ChatMessage message) {
    if (message.isInfo) {
      return null;
    }

    final role =
        message.role ??
        (message.isUser ? LlamaChatRole.user : LlamaChatRole.assistant);
    // Tool results are mirrored onto the assistant tool-call message so the UI
    // can render a call and its result together; only the tool-role message may
    // carry them back into the prompt.
    final storedParts = message.parts
        ?.where(
          (part) =>
              role == LlamaChatRole.tool || part is! LlamaToolResultContent,
        )
        .toList(growable: false);
    final parts = storedParts != null && storedParts.isNotEmpty
        ? List<LlamaContentPart>.from(storedParts)
        : <LlamaContentPart>[
            if (message.text.trim().isNotEmpty) LlamaTextContent(message.text),
          ];

    if (parts.isEmpty) {
      return null;
    }

    return LlamaChatMessage.withContent(role: role, content: parts);
  }
}
