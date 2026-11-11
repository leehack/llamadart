import 'package:llamadart/llamadart.dart';

import '../models/chat_message.dart';

/// Creates and restores [ChatSession] instances from UI message state.
class ChatSessionService {
  const ChatSessionService();

  static const String omittedImageMarker = '[image omitted]';
  static const String omittedAudioMarker = '[audio omitted]';

  ChatSession createSession({
    required LlamaEngine engine,
    required int contextSize,
    int enforcedContextSize = 0,
    String? systemPrompt,
  }) {
    return ChatSession(
      engine,
      maxContextTokens: _trimBudget(contextSize, enforcedContextSize),
      systemPrompt: systemPrompt,
    );
  }

  /// Trimming must budget for the context the runtime enforces, which can be
  /// smaller than the requested size (for example LiteRT-LM Web executors).
  static int? _trimBudget(int contextSize, int enforcedContextSize) {
    if (enforcedContextSize > 0 &&
        (contextSize <= 0 || contextSize > enforcedContextSize)) {
      return enforcedContextSize;
    }
    return contextSize > 0 ? contextSize : null;
  }

  ChatSession rebuildFromMessages({
    required LlamaEngine engine,
    required int contextSize,
    int enforcedContextSize = 0,
    String? systemPrompt,
    required Iterable<ChatMessage> messages,
    bool acceptsImages = true,
    bool acceptsAudio = true,
  }) {
    final session = createSession(
      engine: engine,
      contextSize: contextSize,
      enforcedContextSize: enforcedContextSize,
      systemPrompt: systemPrompt,
    );

    for (final message in messages) {
      final serialized = toLlamaChatMessage(
        message,
        acceptsImages: acceptsImages,
        acceptsAudio: acceptsAudio,
      );
      if (serialized != null) {
        session.addMessage(serialized);
      }
    }

    return session;
  }

  LlamaChatMessage? toLlamaChatMessage(
    ChatMessage message, {
    bool acceptsImages = true,
    bool acceptsAudio = true,
  }) {
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
    // Media the runtime cannot accept becomes a text marker rather than being
    // dropped, so media-only turns stay non-empty and roles keep alternating
    // for strict chat templates.
    final parts = storedParts != null && storedParts.isNotEmpty
        ? <LlamaContentPart>[
            for (final part in storedParts)
              if (part is LlamaImageContent && !acceptsImages)
                const LlamaTextContent(omittedImageMarker)
              else if (part is LlamaAudioContent && !acceptsAudio)
                const LlamaTextContent(omittedAudioMarker)
              else
                part,
          ]
        : <LlamaContentPart>[
            if (message.text.trim().isNotEmpty) LlamaTextContent(message.text),
          ];

    if (parts.isEmpty) {
      return null;
    }

    return LlamaChatMessage.withContent(role: role, content: parts);
  }
}
