import 'dart:async';

import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

import 'studio_test_fakes.dart';

void main() {
  test(
    'disposing repeated active chats detaches streams and prevents late saves',
    () async {
      final kv = InMemoryKeyValueStore();
      final backing = KeyValueConversationStore(kv);
      final shell = StudioShellController(keyValueStore: kv);
      await shell.initialize();
      addTearDown(shell.dispose);
      for (var cycle = 0; cycle < 30; cycle++) {
        final inference = _ControlledInference();
        final chat = ChatWorkspaceController(
          conversationStore: backing,
          inferencePort: inference,
          shellController: shell,
        );
        await chat.initialize();
        final pending = chat.sendMessage('turn $cycle');
        await inference.entered.future;
        inference.events.add(const StudioTextDeltaEvent('partial'));
        await Future<void>.delayed(Duration.zero);
        await chat.dispose();
        expect(inference.cancelled, isTrue);
        expect(inference.events.hasListener, isFalse);
        inference.events.add(const StudioTextDeltaEvent('late answer'));
        await inference.events.close();
        await pending;
        final saved = (await backing.loadAll()).single;
        expect(
          saved.nodes.where((n) => n.role == StudioRole.assistant),
          isEmpty,
        );
        await inference.dispose();
      }
    },
  );
}

class _ControlledInference extends FakeInferencePort {
  final entered = Completer<void>();
  final events = StreamController<StudioTurnEvent>();
  bool cancelled = false;

  @override
  Stream<StudioTurnEvent> streamTurn(StudioTurnRequest request) {
    entered.complete();
    return events.stream;
  }

  @override
  void cancelGeneration() => cancelled = true;
}
