import 'package:llamadart_tui_coding_agent/src/assistant_draft_rows.dart';
import 'package:test/test.dart';

void main() {
  test('reset removes every assistant segment around interleaved thinking', () {
    final rows = AssistantDraftRows();
    final transcript = <String>[];

    transcript.add('answer one');
    rows.startAssistantRow(0);
    transcript.add('thinking');
    rows.startThinkingRow(1);
    transcript.add('answer two');
    rows.startAssistantRow(2);

    final removals = rows.takeRowsForReset();
    for (final index in removals) {
      transcript.removeAt(index);
    }

    expect(removals, [2, 0]);
    expect(transcript, ['thinking']);
    expect(rows.activeAssistantRow, isNull);
    expect(rows.activeThinkingRow, isNull);
  });

  test('commit retains rows and starts the next round cleanly', () {
    final rows = AssistantDraftRows()..startAssistantRow(3);

    rows.commit();

    expect(rows.takeRowsForReset(), isEmpty);
    expect(rows.activeAssistantRow, isNull);
  });
}
