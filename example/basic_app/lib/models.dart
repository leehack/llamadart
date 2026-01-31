/// Roles for CLI chat messages.
enum CliRole {
  /// Message from the user.
  user,

  /// Message from the AI assistant.
  assistant
}

/// A message in the CLI chat conversation.
class CliMessage {
  /// The text content of the message.
  final String text;

  /// The role of the sender.
  final CliRole role;

  /// Creates a new CLI message.
  CliMessage({required this.text, required this.role});
}
