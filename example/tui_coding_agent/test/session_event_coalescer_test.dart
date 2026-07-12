import 'dart:async';

import 'package:llamadart_tui_coding_agent/src/session_event.dart';
import 'package:llamadart_tui_coding_agent/src/session_event_coalescer.dart';
import 'package:test/test.dart';

void main() {
  test('coalesces a synthetic long token stream into one frame', () {
    final batches = <List<SessionEvent>>[];
    final coalescer = SessionEventCoalescer(
      frameInterval: const Duration(minutes: 1),
      onBatch: batches.add,
    );
    addTearDown(coalescer.dispose);

    for (var index = 0; index < 1000; index++) {
      coalescer.add(SessionEvent.assistantToken('x'));
    }
    expect(batches, isEmpty);
    coalescer.flush();

    expect(batches, hasLength(1));
    expect(batches.single, hasLength(1));
    expect(batches.single.single.message, hasLength(1000));
  });

  test('flushes ordered deltas with the next non-stream event', () {
    final batches = <List<SessionEvent>>[];
    final coalescer = SessionEventCoalescer(
      onBatch: batches.add,
      frameInterval: const Duration(minutes: 1),
    );
    addTearDown(coalescer.dispose);

    coalescer
      ..add(SessionEvent.thinkingToken('plan'))
      ..add(SessionEvent.assistantToken('answer '))
      ..add(SessionEvent.assistantToken('now'))
      ..add(SessionEvent.toolCall('read: file.dart'));

    expect(batches, hasLength(1));
    expect(batches.single.map((event) => event.type), [
      SessionEventType.thinkingToken,
      SessionEventType.assistantToken,
      SessionEventType.toolCall,
    ]);
    expect(batches.single[1].message, 'answer now');
  });

  test('delivers pending stream deltas on the frame timer', () async {
    final delivered = Completer<List<SessionEvent>>();
    final coalescer = SessionEventCoalescer(
      frameInterval: const Duration(milliseconds: 5),
      onBatch: delivered.complete,
    );
    addTearDown(coalescer.dispose);

    coalescer
      ..add(SessionEvent.thinkingToken('plan'))
      ..add(SessionEvent.thinkingToken(' first'));

    final batch = await delivered.future.timeout(const Duration(seconds: 1));
    expect(batch, hasLength(1));
    expect(batch.single.type, SessionEventType.thinkingToken);
    expect(batch.single.message, 'plan first');
  });
}
