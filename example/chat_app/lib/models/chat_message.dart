import 'package:llamadart/llamadart.dart';

import '../utils/text_sanitizer.dart';

class ChatMessage {
  final String text;
  final bool isUser;
  final bool isInfo; // Non-conversation informational message
  final DateTime timestamp;
  final List<LlamaContentPart>? parts;
  final List<String> debugBadges;
  final LlamaChatRole? role;
  int? tokenCount; // Cache token count for sliding window optimization

  /// This response's contribution to the runtime context counter.
  int? generatedTokenCount;

  ChatMessage({
    required String text,
    required this.isUser,
    this.isInfo = false,
    this.parts,
    this.debugBadges = const [],
    this.role,
    DateTime? timestamp,
    this.tokenCount,
    this.generatedTokenCount,
  }) : text = sanitizeForTextLayout(text),
       timestamp = timestamp ?? DateTime.now();

  /// Derived property to check if this message is a tool call.
  bool get isToolCall {
    // 1. Explicit tool call part (best)
    if (parts?.any((p) => p is LlamaToolCallContent) ?? false) return true;

    // 2. Assistant role with JSON content (streaming or legacy fallback)
    if (role == LlamaChatRole.assistant) {
      final trimmed = text.trim();
      return trimmed.startsWith('{') || trimmed.startsWith('[{');
    }

    return false;
  }

  /// Whether this assistant message came from the speech-to-text workflow.
  bool get isTranscription => debugBadges.contains('Transcription');

  /// Derived property to get thinking content if present.
  String? get thinkingText {
    final thinkingPart = parts?.whereType<LlamaThinkingContent>().firstOrNull;
    final thinking = thinkingPart?.thinking;
    if (thinking == null) {
      return null;
    }
    return sanitizeForTextLayout(thinking);
  }

  ChatMessage copyWith({
    String? text,
    bool? isUser,
    bool? isInfo,
    List<LlamaContentPart>? parts,
    List<String>? debugBadges,
    LlamaChatRole? role,
    DateTime? timestamp,
    int? tokenCount,
    int? generatedTokenCount,
  }) {
    return ChatMessage(
      text: text ?? this.text,
      isUser: isUser ?? this.isUser,
      isInfo: isInfo ?? this.isInfo,
      parts: parts ?? this.parts,
      debugBadges: debugBadges ?? this.debugBadges,
      role: role ?? this.role,
      timestamp: timestamp ?? this.timestamp,
      tokenCount: tokenCount ?? this.tokenCount,
      generatedTokenCount: generatedTokenCount ?? this.generatedTokenCount,
    );
  }
}
