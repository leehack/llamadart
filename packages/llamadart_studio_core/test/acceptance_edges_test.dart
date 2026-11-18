import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

import 'studio_test_fakes.dart';

void main() {
  test('malformed note index leaves unindexed note data intact', () async {
    final kv = InMemoryKeyValueStore();
    await kv.writeString('studio.notes.index.v1', '{broken');
    await kv.writeString('studio.notes.item.orphan', '{preserve this payload');
    expect(await KeyValueNoteStore(kv).loadAll(), isEmpty);
    expect(await kv.readString('studio.notes.index.v1'), '{broken');
    expect(
      await kv.readString('studio.notes.item.orphan'),
      '{preserve this payload',
    );
  });

  test(
    'native notes and media survive reopening and corrupt sibling files',
    () async {
      final root = await Directory.systemTemp.createTemp('studio_edge_notes_');
      addTearDown(() => root.delete(recursive: true));
      final kv = InMemoryKeyValueStore();
      StudioNoteStore open() => createDefaultNoteStore(
        fallbackKeyValueStore: kv,
        directoryPath: root.path,
      );
      final now = DateTime.utc(2026, 11, 14);
      final note = StudioNote(
        id: 'n1',
        title: '한국어 🦙',
        content: 'Saved content',
        createdAt: now,
        updatedAt: now,
      );
      final wav = Uint8List.fromList(<int>[82, 73, 70, 70, 1, 2]);
      await open().save(note, audioWavBytes: wav);
      await File('${root.path}/notes/corrupt.json').writeAsString('{broken');
      final reopened = open();
      final notes = await reopened.loadAll();
      expect(notes, hasLength(1));
      expect(notes.single.title, note.title);
      expect(await reopened.readAudioBytes(notes.single), wav);
      await reopened.delete(note.id);
      expect(await open().loadAll(), isEmpty);
    },
  );

  test('malformed note index recovers legacy notes on restart', () async {
    final kv = InMemoryKeyValueStore();
    final now = DateTime.utc(2026, 11, 14);
    final note = StudioNote(
      id: 'legacy',
      title: 'Recover me',
      content: 'Durable',
      createdAt: now,
      updatedAt: now,
    );
    await kv.writeString('studio.notes.index.v1', '{broken');
    await kv.writeString(
      StudioNoteStore.legacyNotesStorageKey,
      jsonEncode(<Object>[note.toJson()]),
    );
    final notes = await KeyValueNoteStore(kv).loadAll();
    expect(notes.map((StudioNote n) => n.id), <String>['legacy']);
    expect(await kv.readString(StudioNoteStore.legacyNotesStorageKey), isNull);
    expect((await KeyValueNoteStore(kv).loadAll()).single.content, 'Durable');
  });

  test('unsupported image load resets busy state and can be retried', () async {
    final port = _UnsupportedThenReadyImagePort();
    final storage = FakeStudioStoragePort();
    final controller = ImageWorkspaceController(
      storagePort: storage,
      imagePort: port,
      isWeb: false,
      isMobile: false,
    );
    addTearDown(() async {
      await controller.dispose();
      await storage.dispose();
    });
    final descriptor = CuratedModelCatalog.models.firstWhere(
      (StudioModelDescriptor d) => d.category == StudioModelCategory.image,
    );
    await controller.loadModel(descriptor);
    expect(controller.state.errorMessage, contains('unavailable'));
    expect(controller.state.isLoadingModel, isFalse);
    expect(controller.state.loadingModel, isNull);
    expect(controller.state.activeModel, isNull);
    port.supported = true;
    await controller.loadModel(descriptor);
    expect(controller.state.activeModel?.id, descriptor.id);
    expect(controller.state.errorMessage, isNull);
  });
}

class _UnsupportedThenReadyImagePort extends CountingMockImagePort {
  bool supported = false;
  @override
  Future<ImageGenerationCapabilities> loadModel({
    required ResolvedModelAssets assets,
    ComputeDevice device = ComputeDevice.auto,
  }) async {
    if (!supported) {
      throw LlamaUnsupportedException(
        'Image runtime unavailable on this host.',
      );
    }
    return const ImageGenerationCapabilities(isSupported: true);
  }
}
