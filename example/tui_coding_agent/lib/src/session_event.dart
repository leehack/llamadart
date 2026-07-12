/// Kind of update emitted by a coding-agent session.
enum SessionEventType {
  /// Session lifecycle or readiness update.
  status,

  /// Incremental ordinary assistant text ready for display.
  assistantToken,

  /// Incremental reasoning text emitted separately from the final answer.
  thinkingToken,

  /// Removes a streamed assistant draft that became a tool-call attempt.
  assistantDraftReset,

  /// Tool invocation selected by the model.
  toolCall,

  /// Result returned by a tool invocation.
  toolResult,

  /// Recoverable cancellation or safety warning.
  warning,

  /// Request-ending error.
  error,
}

/// A typed update emitted while a coding-agent request runs.
class SessionEvent {
  /// Event category.
  final SessionEventType type;

  /// Human-readable event payload.
  final String message;

  /// Creates an event with [type] and [message].
  const SessionEvent(this.type, this.message);

  /// Creates a lifecycle [SessionEventType.status] event.
  factory SessionEvent.status(String message) {
    return SessionEvent(SessionEventType.status, message);
  }

  /// Creates an [SessionEventType.assistantToken] event.
  factory SessionEvent.assistantToken(String message) {
    return SessionEvent(SessionEventType.assistantToken, message);
  }

  /// Creates an incremental [SessionEventType.thinkingToken] event.
  factory SessionEvent.thinkingToken(String message) {
    return SessionEvent(SessionEventType.thinkingToken, message);
  }

  /// Creates an [SessionEventType.assistantDraftReset] event.
  factory SessionEvent.assistantDraftReset() {
    return const SessionEvent(SessionEventType.assistantDraftReset, '');
  }

  /// Creates a [SessionEventType.toolCall] event.
  factory SessionEvent.toolCall(String message) {
    return SessionEvent(SessionEventType.toolCall, message);
  }

  /// Creates a [SessionEventType.toolResult] event.
  factory SessionEvent.toolResult(String message) {
    return SessionEvent(SessionEventType.toolResult, message);
  }

  /// Creates a [SessionEventType.warning] event.
  factory SessionEvent.warning(String message) {
    return SessionEvent(SessionEventType.warning, message);
  }

  /// Creates a [SessionEventType.error] event.
  factory SessionEvent.error(String message) {
    return SessionEvent(SessionEventType.error, message);
  }
}
