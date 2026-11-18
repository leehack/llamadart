import 'dart:convert';
import 'dart:io';

import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'temporary symlinks cannot redirect an atomic save',
    () async {
      final root = await Directory.systemTemp.createTemp('studio_save_link_');
      addTearDown(() => root.delete(recursive: true));
      final marker = await File(
        '${root.path}/precious.txt',
      ).writeAsString('preserve');
      final conversations = await Directory(
        '${root.path}/conversations',
      ).create();
      final link = Link('${conversations.path}/healthy.json.tmp');
      await link.create(marker.path);
      final store = createDefaultConversationStore(
        fallbackKeyValueStore: InMemoryKeyValueStore(),
        directoryPath: root.path,
      );
      await store.save(StudioConversation.create(id: 'healthy'));
      expect(await marker.readAsString(), 'preserve');
      expect(await link.target(), marker.path);
      expect((await store.loadAll()).single.id, 'healthy');
      expect((await conversations.list().toList()).length, 2);
    },
    skip: Platform.isWindows
        ? 'Creating symlinks requires a Windows privilege'
        : false,
  );

  test('unsafe conversation IDs fail before storage mutation', () async {
    final directory = await Directory.systemTemp.createTemp('studio_chat_ids_');
    addTearDown(() => directory.delete(recursive: true));
    final store = createDefaultConversationStore(
      fallbackKeyValueStore: InMemoryKeyValueStore(),
      directoryPath: directory.path,
    );
    for (final id in ['', '.', '..', '../escape', 'a/b', 'a?b']) {
      await expectLater(
        store.save(StudioConversation.create(id: id)),
        throwsArgumentError,
      );
      await expectLater(store.delete(id), throwsArgumentError);
    }
    expect(await directory.list().toList(), isEmpty);
  });

  test(
    'malformed persisted IDs cannot delete the Studio storage root',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'studio_bad_chat_',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final marker = await File(
        '${directory.path}/unrelated.txt',
      ).writeAsString('preserve');
      await Directory('${directory.path}/attachments').create();
      await Directory('${directory.path}/conversations').create();
      await File(
        '${directory.path}/conversations/damaged.json',
      ).writeAsString(jsonEncode(StudioConversation.create(id: '..').toJson()));
      final store = createDefaultConversationStore(
        fallbackKeyValueStore: InMemoryKeyValueStore(),
        directoryPath: directory.path,
      );
      Object? failure;
      try {
        await store.delete('..');
      } catch (error) {
        failure = error;
      }
      expect(await marker.exists(), isTrue);
      expect(failure, isA<ArgumentError>());
      expect(await marker.readAsString(), 'preserve');
      expect(await store.loadAll(), isEmpty);
      await store.save(StudioConversation.create(id: 'healthy'));
      expect((await store.loadAll()).single.id, 'healthy');
    },
  );
}
