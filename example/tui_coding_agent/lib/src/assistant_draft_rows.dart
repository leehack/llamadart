/// Tracks streamed assistant and reasoning rows for one in-progress round.
class AssistantDraftRows {
  final List<int> _assistantRows = <int>[];

  /// Row currently receiving ordinary assistant text.
  int? activeAssistantRow;

  /// Row currently receiving reasoning text.
  int? activeThinkingRow;

  /// Records a new ordinary assistant row.
  void startAssistantRow(int index) {
    activeAssistantRow = index;
    activeThinkingRow = null;
    _assistantRows.add(index);
  }

  /// Records a new reasoning row.
  void startThinkingRow(int index) {
    activeThinkingRow = index;
    activeAssistantRow = null;
  }

  /// Marks the current reasoning segment complete before answer text starts.
  void finishThinkingRow() {
    activeThinkingRow = null;
  }

  /// Returns every ordinary draft row in descending index order and clears the
  /// active round state.
  List<int> takeRowsForReset() {
    final rows = _assistantRows.toList(growable: false)
      ..sort((a, b) => b.compareTo(a));
    commit();
    return rows;
  }

  /// Commits visible rows and clears the active round state.
  void commit() {
    _assistantRows.clear();
    activeAssistantRow = null;
    activeThinkingRow = null;
  }
}
