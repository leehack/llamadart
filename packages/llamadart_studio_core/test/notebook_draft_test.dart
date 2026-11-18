import 'dart:async';
import 'dart:typed_data';

import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

import 'studio_test_fakes.dart';

void main() {
  late RecoverableNoteStore noteStore;
  late NotebookController controller;

  setUp(() async {
    noteStore = RecoverableNoteStore();
    controller = NotebookController(
      storagePort: FakeStudioStoragePort(),
      embeddingPort: MockNoteAndDecisionPlaygroundPort(),
      noteStore: noteStore,
      isWeb: false,
      isMobile: false,
    );
    await controller.initialize();
  });
  tearDown(() => controller.dispose());

  test('failed saves retain editable text and expose retry state', () async {
    final note = controller.state.selectedNote!;
    const draft = NotebookDraft(
      title: 'New title',
      content: 'Unsaved work',
      tags: 'first, unfinished ',
      transcript: 'Words to keep',
    );
    controller.retainDraft(note.id, draft);
    noteStore.fail = true;

    expect(await controller.saveDraft(note.id), isFalse);
    expect(controller.state.drafts[note.id], same(draft));
    expect(controller.state.draftSaveErrors[note.id], contains('disk full'));
    expect(controller.state.selectedNote!.content, note.content);

    controller.selectNote(controller.state.notes.last.id);
    controller.selectNote(note.id);
    expect(controller.state.drafts[note.id]!.content, 'Unsaved work');
    noteStore.fail = false;
    expect(await controller.saveDraft(note.id), isTrue);
    expect(controller.state.drafts, isEmpty);
    expect(controller.state.draftSaveErrors, isEmpty);
    expect(controller.state.selectedNote!.content, 'Unsaved work');
    expect(controller.state.selectedNote!.transcript, 'Words to keep');
    expect(controller.state.selectedNote!.tags, <String>[
      'first',
      'unfinished',
    ]);
  });

  test(
    'edits during delayed saves survive and queued retry saves newest text',
    () async {
      final id = controller.state.selectedNote!.id;
      controller.retainDraft(
        id,
        const NotebookDraft(
          title: 'A',
          content: 'first',
          tags: '',
          transcript: '',
        ),
      );
      noteStore.pending = Completer<void>();
      final first = controller.saveDraft(id);
      await Future<void>.delayed(Duration.zero);
      controller.retainDraft(
        id,
        const NotebookDraft(
          title: 'A',
          content: 'second',
          tags: '',
          transcript: '',
        ),
      );
      final second = controller.saveDraft(id);
      noteStore.pending!.complete();
      expect(await first, isTrue);
      expect(await second, isTrue);
      expect(controller.state.selectedNote!.content, 'second');
      expect(controller.state.drafts, isEmpty);
      expect(
        (await noteStore.loadAll()).firstWhere((note) => note.id == id).content,
        'second',
      );
    },
  );
}

class RecoverableNoteStore extends EphemeralNoteStore {
  bool fail = false;
  Completer<void>? pending;

  @override
  Future<StudioNote> save(
    StudioNote note, {
    Uint8List? imageBytes,
    Uint8List? audioWavBytes,
    bool clearImage = false,
    bool clearAudio = false,
  }) async {
    await pending?.future;
    if (fail) throw StateError('disk full');
    return super.save(
      note,
      imageBytes: imageBytes,
      audioWavBytes: audioWavBytes,
      clearImage: clearImage,
      clearAudio: clearAudio,
    );
  }
}
