/// Incrementally exposes ordinary assistant text while withholding tool-call
/// protocol markers for final validation.
class AssistantTextStream {
  static const List<String> _protocolMarkers = <String>[
    '<tool_call',
    '</tool_call',
  ];

  String _pending = '';
  bool _ordinaryTextConfirmed = false;
  bool _protocolDetected = false;
  bool _discarded = false;
  bool _hasVisibleDraft = false;

  /// Whether any ordinary assistant text is currently visible to the caller.
  bool get hasVisibleDraft => _hasVisibleDraft;

  /// Adds one generated text [delta].
  ///
  /// [onText] receives text as soon as it cannot be a split protocol marker.
  /// If a marker appears after ordinary prose, [onReset] asks the presentation
  /// layer to remove that invalid mixed draft before the response is retried.
  void add(
    String delta, {
    required void Function(String text) onText,
    required void Function() onReset,
  }) {
    if (delta.isEmpty || _protocolDetected || _discarded) {
      return;
    }

    _pending += delta;
    if (_protocolMarkers.any(_pending.contains)) {
      _protocolDetected = true;
      _pending = '';
      if (_hasVisibleDraft) {
        onReset();
        _hasVisibleDraft = false;
      }
      return;
    }

    if (!_ordinaryTextConfirmed) {
      final candidate = _pending.trimLeft();
      if (candidate.isEmpty ||
          _protocolMarkers.any((marker) => marker.startsWith(candidate))) {
        return;
      }
      _ordinaryTextConfirmed = true;
    }

    final safeLength = _safeEmissionLength(_pending);
    if (safeLength == 0) {
      return;
    }
    final text = _pending.substring(0, safeLength);
    _pending = _pending.substring(safeLength);
    onText(text);
    _hasVisibleDraft = true;
  }

  /// Flushes the remaining text after the complete response is known to be a
  /// normal assistant answer.
  void finish({required void Function(String text) onText}) {
    if (_protocolDetected || _discarded || _pending.isEmpty) {
      return;
    }
    final text = _pending;
    _pending = '';
    onText(text);
    _hasVisibleDraft = true;
  }

  /// Removes any visible partial answer and prevents further output.
  void discard({required void Function() onReset}) {
    if (_discarded) {
      return;
    }
    _discarded = true;
    _pending = '';
    if (_hasVisibleDraft) {
      onReset();
      _hasVisibleDraft = false;
    }
  }

  int _safeEmissionLength(String value) {
    var heldSuffixLength = 0;
    for (final marker in _protocolMarkers) {
      final maxLength = value.length < marker.length
          ? value.length
          : marker.length - 1;
      for (var length = maxLength; length > heldSuffixLength; length--) {
        if (marker.startsWith(value.substring(value.length - length))) {
          heldSuffixLength = length;
          break;
        }
      }
    }
    return value.length - heldSuffixLength;
  }
}
