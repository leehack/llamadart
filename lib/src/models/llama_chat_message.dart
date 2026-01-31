/// A message in a chat conversation history.
class LlamaChatMessage {
  /// The role of the message sender (e.g., 'user', 'assistant', 'system').
  final String role;

  /// The text content of the message.
  final String content;

  /// Creates a message with a role and content.
  const LlamaChatMessage({required this.role, required this.content});
}
