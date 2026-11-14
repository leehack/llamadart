import 'dart:async';

import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

import 'studio_test_fakes.dart';

class _PausedInference extends FakeInferencePort {
  final Completer<void> entered = Completer<void>();
  final Completer<void> finish = Completer<void>();
  bool fail = false;

  @override
  Stream<StudioTurnEvent> streamTurn(StudioTurnRequest request) async* {
    entered.complete();
    await finish.future;
    if (fail) {
      throw StateError('Generation failed');
    }
    yield const StudioTextDeltaEvent('Completed answer');
  }
}

void main() {
  late KeyValueConversationStore backing;
  late StudioShellController shell;
  late _PausedInference inference;
  late ChatWorkspaceController chat;

  setUp(() async {
    final kv = InMemoryKeyValueStore();
    backing = KeyValueConversationStore(kv);
    shell = StudioShellController(keyValueStore: kv);
    inference = _PausedInference();
    chat = ChatWorkspaceController(
      conversationStore: backing,
      inferencePort: inference,
      shellController: shell,
    );
    await shell.initialize();
    await chat.initialize();
  });

  tearDown(() async {
    await chat.dispose();
    await shell.dispose();
    await inference.dispose();
  });

  test(
    'background completion preserves selection and stores the answer',
    () async {
      final firstId = chat.state.activeConversationId!;
      final second = await chat.createConversation();
      chat.selectConversation(firstId);
      final pending = chat.sendMessage('Hello');
      await inference.entered.future;
      chat.selectConversation(second.id);
      inference.finish.complete();
      await pending;

      expect(chat.state.activeConversationId, second.id);
      final first = (await backing.loadAll()).singleWhere(
        (c) => c.id == firstId,
      );
      expect(first.activeBranch.last.text, 'Completed answer');
    },
  );

  test(
    'renaming and pinning an inactive conversation preserve selection',
    () async {
      final firstId = chat.state.activeConversationId!;
      final second = await chat.createConversation();
      await chat.renameConversation(firstId, 'Renamed');
      expect(chat.state.activeConversationId, second.id);
      await chat.togglePinConversation(firstId);
      expect(chat.state.activeConversationId, second.id);
      final first = (await backing.loadAll()).singleWhere(
        (c) => c.id == firstId,
      );
      expect(first.title, 'Renamed');
      expect(first.pinned, isTrue);
    },
  );

  for (final fail in <bool>[false, true]) {
    test('deleted generating session stays deleted (failure=$fail)', () async {
      final deletedId = chat.state.activeConversationId!;
      inference.fail = fail;
      final pending = chat.sendMessage('Hello');
      await inference.entered.future;
      await chat.deleteConversation(deletedId);
      final replacementId = chat.state.activeConversationId;
      inference.finish.complete();
      await pending;

      expect(chat.state.activeConversationId, replacementId);
      expect(chat.state.conversations.any((c) => c.id == deletedId), isFalse);
      expect((await backing.loadAll()).any((c) => c.id == deletedId), isFalse);
      expect(chat.activeStreamStore.state.isGenerating, isFalse);
    });
  }
}
