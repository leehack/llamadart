import 'dart:io';
import 'dart:typed_data';

import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

void main() {
  for (final hasInlineBytes in [true, false]) {
    test(
      'picked media survives source deletion (bytes: $hasInlineBytes)',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'studio_picked_media_',
        );
        addTearDown(() => root.delete(recursive: true));
        final original = await File(
          '${root.path}/picked.png',
        ).writeAsBytes([1, 2, 3]);
        StudioConversationStore createStore() => createDefaultConversationStore(
          fallbackKeyValueStore: InMemoryKeyValueStore(),
          directoryPath: '${root.path}/store',
        );
        final store = createStore();
        final media = await store.persistAttachment(
          conversationId: 'chat',
          attachment: StudioAttachment(
            id: 'picked',
            kind: StudioAttachmentKind.image,
            name: 'picked.png',
            localPath: original.path,
            bytes: hasInlineBytes ? Uint8List.fromList([1, 2, 3]) : null,
          ),
        );
        await store.save(
          StudioConversation.create(id: 'chat').appendToActiveBranch(
            StudioMessage(
              id: 'user',
              role: StudioRole.user,
              text: 'image',
              createdAt: DateTime.now(),
              attachments: [media],
            ),
          ),
        );
        await original.delete();
        final cold = createStore();
        final reopened =
            (await cold.loadAll()).single.nodes.single.attachments.single;
        expect(reopened.bytes, isNull);
        expect(await cold.readAttachmentBytes(reopened), [1, 2, 3]);
        expect(
          (await store.persistAttachment(
            conversationId: 'chat',
            attachment: media,
          )).localPath,
          media.localPath,
        );
      },
    );
  }

  test('colliding sanitized attachment names remain independent', () async {
    final root = await Directory.systemTemp.createTemp('studio_media_names_');
    addTearDown(() => root.delete(recursive: true));
    final store = createDefaultConversationStore(
      fallbackKeyValueStore: InMemoryKeyValueStore(),
      directoryPath: root.path,
    );
    Future<StudioAttachment> persist(String id, int value) =>
        store.persistAttachment(
          conversationId: 'chat',
          attachment: StudioAttachment(
            id: id,
            kind: StudioAttachmentKind.image,
            name: 'image.png',
            bytes: Uint8List.fromList([value]),
          ),
        );
    final first = await persist('a/b', 1);
    final second = await persist('a?b', 2);
    expect(await store.readAttachmentBytes(first), [1]);
    expect(await store.readAttachmentBytes(second), [2]);
    expect(first.localPath, isNot(second.localPath));
  });

  test('missing picked media fails before saving a broken reference', () async {
    final root = await Directory.systemTemp.createTemp('studio_missing_media_');
    addTearDown(() => root.delete(recursive: true));
    final store = createDefaultConversationStore(
      fallbackKeyValueStore: InMemoryKeyValueStore(),
      directoryPath: root.path,
    );
    await expectLater(
      store.persistAttachment(
        conversationId: 'chat',
        attachment: StudioAttachment(
          id: 'missing',
          kind: StudioAttachmentKind.image,
          name: 'image.png',
          localPath: '${root.path}/missing.png',
        ),
      ),
      throwsStateError,
    );
    expect(await store.loadAll(), isEmpty);
  });
}
