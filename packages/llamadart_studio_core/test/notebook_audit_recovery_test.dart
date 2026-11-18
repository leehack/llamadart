import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

import 'studio_test_fakes.dart';

void main() {
  test(
    'held System-1 audit preserves concurrent note mutations and applies only fresh tags',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'studio_audit_recovery_',
      );
      final notes = createDefaultNoteStore(
        fallbackKeyValueStore: InMemoryKeyValueStore(),
        directoryPath: root.path,
      );
      final storage = FakeStudioStoragePort();
      final port = _HeldDecisionPort();
      final notebook = NotebookController(
        storagePort: storage,
        embeddingPort: port,
        noteStore: notes,
        isWeb: false,
        isMobile: false,
      );
      final playground = PlaygroundWorkspaceController(
        storagePort: storage,
        playgroundPort: port,
        notesProvider: () => notebook.state.notes,
        onNotesUpdated: notebook.applyAuditedNotes,
        isWeb: false,
        isMobile: false,
      );
      addTearDown(() async {
        if (!port.release.isCompleted) port.release.complete();
        await playground.dispose();
        await notebook.dispose();
        await storage.dispose();
        await root.delete(recursive: true);
      });
      final now = DateTime.utc(2026, 11, 15);
      StudioNote note(String id) => StudioNote(
        id: id,
        title: id,
        content: 'Original $id content',
        tags: const <String>['user-tag'],
        createdAt: now,
        updatedAt: now,
      );
      await notes.save(
        note('media'),
        imageBytes: Uint8List.fromList(<int>[1, 2, 3]),
        audioWavBytes: Uint8List.fromList(<int>[4, 5, 6]),
      );
      await notes.save(note('delete'));
      await notes.save(note('stable'));
      await notes.save(note('user_tags'));
      await notes.save(note('same_time_text'));
      await notes.save(
        note('same_time_media'),
        imageBytes: Uint8List.fromList(<int>[21, 22, 23]),
      );
      await notebook.initialize();
      final auditing = playground.auditVaultNotes();
      await port.started.future;
      await notebook.indexNotes();
      expect(notebook.state.errorMessage, isNull);
      final stableBefore = notebook.state.notes.firstWhere(
        (n) => n.id == 'stable',
      );
      expect(stableBefore.isIndexed, isTrue);
      final restoredText = notebook.state.notes
          .firstWhere((n) => n.id == 'same_time_text')
          .copyWith(
            content: 'Changed text with original timestamp',
            clearEmbedding: true,
          );
      final restoredMedia = notebook.state.notes
          .firstWhere((n) => n.id == 'same_time_media')
          .copyWith(clearEmbedding: true);
      final sameTimeImage = Uint8List.fromList(<int>[31, 32, 33]);
      await notes.save(restoredText);
      await notes.save(restoredMedia, imageBytes: sameTimeImage);
      await notebook.initialize();

      final image = Uint8List.fromList(<int>[11, 12, 13]);
      final audio = Uint8List.fromList(<int>[14, 15, 16]);
      await notebook.updateNote(
        'media',
        title: 'Edited title',
        content: 'Edited content',
        transcript: 'Edited transcript',
        tags: const <String>['edited-user-tag'],
        pinned: true,
        imageBytes: image,
        audioWavBytes: audio,
      );
      final mediaBefore = notebook.state.notes.firstWhere(
        (n) => n.id == 'media',
      );
      await notebook.updateNote(
        'user_tags',
        tags: const <String>['replacement-user-tag'],
      );
      await notebook.deleteNote('delete');
      final created = await notebook.createNote(
        title: 'Created during audit',
        content: 'Keep new content',
      );
      const draft = NotebookDraft(
        title: 'Unsaved',
        content: 'Keep draft',
        tags: '',
        transcript: '',
      );
      notebook.retainDraft('media', draft);
      final idsBefore = notebook.state.notes.map((n) => n.id).toList();
      final selectedBefore = notebook.state.selectedNoteId;

      port.release.complete();
      final results = await auditing;
      expect(playground.state.errorMessage, isNull);
      expect(results, hasLength(6));
      expect(notebook.state.notes.map((n) => n.id), idsBefore);
      expect(notebook.state.selectedNoteId, selectedBefore);
      expect(notebook.state.drafts['media'], same(draft));
      final media = notebook.state.notes.firstWhere((n) => n.id == 'media');
      expect(media.toJson(), mediaBefore.toJson());
      expect(await notes.readImageBytes(media), image);
      expect(await notes.readAudioBytes(media), audio);
      expect(await File(mediaBefore.imageLocalPath!).exists(), isTrue);
      expect(await File(mediaBefore.audioLocalPath!).exists(), isTrue);
      expect(
        notebook.state.notes.firstWhere((n) => n.id == 'user_tags').tags,
        <String>['replacement-user-tag'],
      );
      final sameTimeText = notebook.state.notes.firstWhere(
        (n) => n.id == 'same_time_text',
      );
      expect(sameTimeText.content, 'Changed text with original timestamp');
      expect(sameTimeText.updatedAt, now);
      expect(sameTimeText.tags, <String>['user-tag']);
      final sameTimeMedia = notebook.state.notes.firstWhere(
        (n) => n.id == 'same_time_media',
      );
      expect(sameTimeMedia.updatedAt, now);
      expect(sameTimeMedia.tags, <String>['user-tag']);
      expect(await notes.readImageBytes(sameTimeMedia), sameTimeImage);
      final stable = notebook.state.notes.firstWhere((n) => n.id == 'stable');
      expect(
        stable.tags,
        containsAll(<String>['user-tag', 'architecture', 'action-item']),
      );
      expect(stable.updatedAt, stableBefore.updatedAt);
      expect(stable.embedding, stableBefore.embedding);
      expect(stable.embeddingModelId, stableBefore.embeddingModelId);

      final reopened = createDefaultNoteStore(
        fallbackKeyValueStore: InMemoryKeyValueStore(),
        directoryPath: root.path,
      );
      final restored = await reopened.loadAll();
      expect(restored.map((n) => n.id), idsBefore);
      expect(restored.any((n) => n.id == 'delete'), isFalse);
      expect(
        restored.firstWhere((n) => n.id == created.id).content,
        'Keep new content',
      );
      final savedMedia = restored.firstWhere((n) => n.id == 'media');
      expect(savedMedia.toJson(), mediaBefore.toJson());
      expect(await reopened.readImageBytes(savedMedia), image);
      expect(await reopened.readAudioBytes(savedMedia), audio);
      expect(restored.firstWhere((n) => n.id == 'stable').tags, stable.tags);
      expect(
        restored.firstWhere((n) => n.id == 'same_time_text').toJson(),
        sameTimeText.toJson(),
      );
      final savedSameTimeMedia = restored.firstWhere(
        (n) => n.id == 'same_time_media',
      );
      expect(savedSameTimeMedia.toJson(), sameTimeMedia.toJson());
      expect(await reopened.readImageBytes(savedSameTimeMedia), sameTimeImage);
    },
  );
}

class _HeldDecisionPort extends MockNoteAndDecisionPlaygroundPort {
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();

  @override
  Future<SystemOneBatchEvaluation> evaluateSystemOneBatch({
    required Object state,
    required List<SystemOneQuestionSpec> questions,
  }) async {
    if (!started.isCompleted) {
      started.complete();
      await release.future;
    }
    return super.evaluateSystemOneBatch(state: state, questions: questions);
  }
}
