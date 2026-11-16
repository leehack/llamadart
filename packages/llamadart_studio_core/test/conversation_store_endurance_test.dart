import 'dart:convert';

import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'concurrent saves and deletions survive reopening the chat index',
    () async {
      final kv = InMemoryKeyValueStore();
      final store = KeyValueConversationStore(kv);
      await Future.wait([
        for (var i = 0; i < 100; i++)
          store.save(StudioConversation.create(id: 'chat-$i')),
      ]);
      expect(await KeyValueConversationStore(kv).loadAll(), hasLength(100));
      await Future.wait([
        for (var i = 0; i < 50; i++) store.delete('chat-$i'),
        for (var i = 100; i < 150; i++)
          store.save(StudioConversation.create(id: 'chat-$i')),
      ]);
      final reopened = await KeyValueConversationStore(kv).loadAll();
      expect(reopened.map((c) => c.id).toSet(), {
        for (var i = 50; i < 150; i++) 'chat-$i',
      });
      await store.clearAll();
      expect(await KeyValueConversationStore(kv).loadAll(), isEmpty);
    },
  );

  test('one corrupt chat does not hide healthy conversations', () async {
    final kv = InMemoryKeyValueStore();
    final store = KeyValueConversationStore(kv);
    await store.save(StudioConversation.create(id: 'healthy'));
    await store.save(StudioConversation.create(id: 'damaged'));
    await kv.writeString('studio.conversations.item.damaged', '{truncated');
    expect((await store.loadAll()).single.id, 'healthy');
    expect(
      jsonDecode((await kv.readString('studio.conversations.index.v1'))!),
      contains('damaged'),
    );
  });
}
