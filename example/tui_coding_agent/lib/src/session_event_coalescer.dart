import 'dart:async';

import 'session_event.dart';

/// Batches high-frequency transcript deltas into bounded presentation frames.
class SessionEventCoalescer {
  /// Creates a coalescer that delivers batches to [onBatch].
  SessionEventCoalescer({
    required this.onBatch,
    this.frameInterval = const Duration(milliseconds: 33),
  });

  /// Presentation callback invoked in original event order.
  final void Function(List<SessionEvent> events) onBatch;

  /// Minimum interval between timer-driven stream updates.
  final Duration frameInterval;

  final List<_PendingDelta> _pending = <_PendingDelta>[];
  Timer? _timer;
  bool _disposed = false;

  /// Queues [event], coalescing consecutive answer or thinking deltas.
  void add(SessionEvent event) {
    if (_disposed) {
      return;
    }
    if (!_isStreamDelta(event.type)) {
      final batch = _takePending()..add(event);
      onBatch(List<SessionEvent>.unmodifiable(batch));
      return;
    }

    final last = _pending.isEmpty ? null : _pending.last;
    if (last != null && last.type == event.type) {
      last.text.write(event.message);
    } else {
      _pending.add(_PendingDelta(event.type, event.message));
    }
    _timer ??= Timer(frameInterval, flush);
  }

  /// Immediately delivers pending deltas, if any.
  void flush() {
    if (_disposed) {
      return;
    }
    final batch = _takePending();
    if (batch.isNotEmpty) {
      onBatch(List<SessionEvent>.unmodifiable(batch));
    }
  }

  /// Cancels the timer and drops pending presentation-only updates.
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _pending.clear();
  }

  List<SessionEvent> _takePending() {
    _timer?.cancel();
    _timer = null;
    final events = <SessionEvent>[
      for (final pending in _pending)
        pending.type == SessionEventType.thinkingToken
            ? SessionEvent.thinkingToken(pending.text.toString())
            : SessionEvent.assistantToken(pending.text.toString()),
    ];
    _pending.clear();
    return events;
  }

  bool _isStreamDelta(SessionEventType type) {
    return type == SessionEventType.assistantToken ||
        type == SessionEventType.thinkingToken;
  }
}

class _PendingDelta {
  _PendingDelta(this.type, String text) {
    this.text.write(text);
  }

  final SessionEventType type;
  final StringBuffer text = StringBuffer();
}
