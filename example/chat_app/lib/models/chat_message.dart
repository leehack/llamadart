class ChatMessage {
  final String text;
  final bool isUser;
  final DateTime timestamp;
  int? tokenCount; // Cache token count for sliding window optimization

  ChatMessage({
    required this.text,
    required this.isUser,
    DateTime? timestamp,
    this.tokenCount,
  }) : timestamp = timestamp ?? DateTime.now();

  ChatMessage copyWith({
    String? text,
    bool? isUser,
    DateTime? timestamp,
    int? tokenCount,
  }) {
    return ChatMessage(
      text: text ?? this.text,
      isUser: isUser ?? this.isUser,
      timestamp: timestamp ?? this.timestamp,
      tokenCount: tokenCount ?? this.tokenCount,
    );
  }
}
