import 'dart:convert';

/// Holds only bytes that could still complete a caller stop sequence.
///
/// Matching UTF-8 bytes avoids decoding incomplete token pieces. A completed
/// marker and everything after it are suppressed, even within the same piece.
class StopSequenceBuffer {
  /// Creates a per-generation buffer, ignoring empty and duplicate markers.
  StopSequenceBuffer(List<String> stops)
    : _stops = stops
          .where((stop) => stop.isNotEmpty)
          .toSet()
          .map(utf8.encode)
          .toList(growable: false);

  final List<List<int>> _stops;
  final List<int> _pending = [];

  /// Whether a complete marker has been consumed.
  bool get isStopped => _isStopped;
  bool _isStopped = false;

  /// Consumes a token piece and returns bytes safe to expose immediately.
  List<int> add(List<int> bytes) {
    if (_isStopped) return const [];
    if (_stops.isEmpty) return bytes;
    _pending.addAll(bytes);

    // Scan in output order so the earliest complete marker wins, independent
    // of caller list order. Partial suffixes are withheld until the next piece.
    var safeLength = _pending.length;
    for (var start = 0; start < _pending.length; start++) {
      for (final stop in _stops) {
        var matched = 0;
        while (matched < stop.length &&
            start + matched < _pending.length &&
            _pending[start + matched] == stop[matched]) {
          matched++;
        }
        if (matched == stop.length) {
          final visible = _pending.sublist(0, start);
          _pending.clear();
          _isStopped = true;
          return visible;
        }
        if (start + matched == _pending.length && start < safeLength) {
          safeLength = start;
        }
      }
    }
    final visible = _pending.sublist(0, safeLength);
    _pending.removeRange(0, safeLength);
    return visible;
  }

  /// Releases an unfinished marker prefix when generation ends without a match.
  List<int> finish() {
    final remaining = _pending.toList();
    _pending.clear();
    return remaining;
  }
}
