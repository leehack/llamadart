import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

import 'studio_test_fakes.dart';

void main() {
  late Directory root;
  late _FailingNoteStore notes;
  late FakeStudioStoragePort storage;
  late FakeInferencePort inference;
  late _BlockingEmbeddings embeddings;
  late NotebookController notebook;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('studio_notes_recovery_');
    notes = _FailingNoteStore(
      createDefaultNoteStore(
        fallbackKeyValueStore: InMemoryKeyValueStore(),
        directoryPath: root.path,
      ),
    );
    await notes.save(_note('Previously saved content'));
    storage = FakeStudioStoragePort();
    inference = FakeInferencePort();
    embeddings = _BlockingEmbeddings();
    notebook = NotebookController(
      storagePort: storage,
      embeddingPort: embeddings,
      noteStore: notes,
      inferencePort: inference,
      isWeb: false,
      isMobile: false,
    );
    await notebook.initialize();
  });
  tearDown(() async {
    await notebook.dispose();
    await inference.dispose();
    await storage.dispose();
    await root.delete(recursive: true);
  });

  test(
    'disk-full save keeps draft and durable content until retry and reopen',
    () async {
      const draft = NotebookDraft(
        title: 'Release notes',
        content: 'Unpublished edits 한국어 🦙',
        tags: 'release, local',
        transcript: '',
      );
      notebook.retainDraft('release', draft);
      notes.failure = 'save';
      expect(await notebook.saveDraft('release'), isFalse);
      expect(notebook.state.drafts['release'], same(draft));
      expect(
        notebook.state.draftSaveErrors['release'],
        contains('No space left'),
      );
      expect(notebook.state.notes.single.content, 'Previously saved content');
      expect(
        (await notes.delegate.loadAll()).single.content,
        'Previously saved content',
      );
      notes.failure = null;
      expect(await notebook.saveDraft('release'), isTrue);
      expect(notebook.state.drafts, isEmpty);
      final reopened = createDefaultNoteStore(
        fallbackKeyValueStore: InMemoryKeyValueStore(),
        directoryPath: root.path,
      );
      expect((await reopened.loadAll()).single.content, draft.content);
    },
  );

  test(
    'failed delete retains selected note and draft for a successful retry',
    () async {
      const draft = NotebookDraft(
        title: 'Release',
        content: 'Keep me',
        tags: '',
        transcript: '',
      );
      notebook.retainDraft('release', draft);
      notes.failure = 'delete';
      await expectLater(
        notebook.deleteNote('release'),
        throwsA(isA<FileSystemException>()),
      );
      expect(notebook.state.notes.single.id, 'release');
      expect(notebook.state.selectedNoteId, 'release');
      expect(notebook.state.drafts['release'], same(draft));
      expect((await notes.delegate.loadAll()).single.id, 'release');
      notes.failure = null;
      await notebook.deleteNote('release');
      expect(notebook.state.notes, isEmpty);
      expect(notebook.state.drafts, isEmpty);
      expect(await notes.delegate.loadAll(), isEmpty);
    },
  );

  test(
    'index persistence failure leaves last committed state and blocks Q&A',
    () async {
      notes.failure = 'saveAll';
      await notebook.indexNotes();
      expect(notebook.state.errorMessage, contains('No space left'));
      expect(notebook.state.isEvaluating, isFalse);
      expect(notebook.state.indexedNoteCount, 0);
      await notebook.askNotebook('What is the release plan?');
      expect(notebook.state.isAnsweringNotebook, isFalse);
      expect(notebook.state.errorMessage, contains('No space left'));
      expect(notebook.state.notebookAnswerSources, isEmpty);
      expect(inference.lastRequest, isNull);
      notes.failure = null;
      await notebook.askNotebook('What is the release plan?');
      expect(notebook.state.errorMessage, isNull);
      expect(inference.lastRequest, isNotNull);
      expect(notebook.state.indexedNoteCount, 1);
    },
  );

  test(
    'failed retrieval does not generate an answer from the selected note',
    () async {
      notes.failure = 'saveAll';
      await notebook.askNotebook('What is the release plan?');
      expect(notebook.state.isAnsweringNotebook, isFalse);
      expect(notebook.state.errorMessage, contains('No space left'));
      expect(inference.lastRequest, isNull);
      expect(notebook.state.notebookAnswerSources, isEmpty);
    },
  );

  for (final search in <bool>[false, true]) {
    for (final delete in <bool>[false, true]) {
      test(
        '${search ? 'search' : 'indexing'} cannot overwrite a concurrent ${delete ? 'delete' : 'edit'}',
        () async {
          embeddings.pending = Completer<void>();
          final indexing = search
              ? notebook.searchNotes('release').then((_) {})
              : notebook.indexNotes();
          await embeddings.started.future;
          final mutation = delete
              ? notebook.deleteNote('release')
              : notebook.updateNote('release', content: 'Newly committed edit');
          await Future<void>.delayed(Duration.zero);
          embeddings.pending!.complete();
          await Future.wait(<Future<void>>[indexing, mutation]);
          expect(notebook.state.errorMessage, isNull);
          final restored = await notes.delegate.loadAll();
          if (delete) {
            expect(notebook.state.notes, isEmpty);
            expect(restored, isEmpty);
          } else {
            expect(notebook.state.notes.single.content, 'Newly committed edit');
            expect(restored.single.content, 'Newly committed edit');
            expect(restored.single.isIndexed, isFalse);
          }
        },
      );
    }
  }

  test(
    'edited notes cannot reuse stale source text in a Chat grounding prompt',
    () async {
      await notebook.searchNotes('release');
      await notebook.updateNote('release', content: 'Newly committed edit');
      final prompt = notebook.buildRagChatPrompt('What changed?');
      expect(prompt, contains('Newly committed edit'));
      expect(prompt, isNot(contains('Previously saved content')));
    },
  );

  test('failed bulk audit keeps last durable note state', () async {
    notes.failure = 'saveAll';
    await expectLater(
      notebook.applyAuditedNotes(<StudioNote>[_note('Uncommitted audit')]),
      throwsA(isA<FileSystemException>()),
    );
    expect(notebook.state.notes.single.content, 'Previously saved content');
    expect(
      (await notes.delegate.loadAll()).single.content,
      'Previously saved content',
    );
  });

  test(
    'interrupted atomic write and corrupt index preserve saved notes on reopen',
    () async {
      final noteFile = File('${root.path}/notes/release.json');
      final previous = await noteFile.readAsString();
      await Directory('${noteFile.path}.tmp').create();
      await expectLater(
        notes.delegate.save(_note('Must not replace committed data')),
        throwsA(isA<FileSystemException>()),
      );
      expect(await noteFile.readAsString(), previous);
      await Directory('${noteFile.path}.tmp').delete();
      await File('${noteFile.path}.tmp').writeAsString('{interrupted');
      final corrupt = File('${root.path}/notes/corrupt.json');
      await corrupt.writeAsString('{malformed');
      await File(
        '${root.path}/notes/_order.json',
      ).writeAsString('{malformed index');
      final reopened = createDefaultNoteStore(
        fallbackKeyValueStore: InMemoryKeyValueStore(),
        directoryPath: root.path,
      );
      final restored = await reopened.loadAll();
      expect(restored.single.id, 'release');
      expect(restored.single.content, 'Previously saved content');
      expect(await corrupt.readAsString(), '{malformed');
      expect(await File('${noteFile.path}.tmp').readAsString(), '{interrupted');
    },
  );
}

StudioNote _note(String content) => StudioNote(
  id: 'release',
  title: 'Release notes',
  content: content,
  createdAt: DateTime.utc(2026, 11, 15),
  updatedAt: DateTime.utc(2026, 11, 15),
);

class _FailingNoteStore implements StudioNoteStore {
  _FailingNoteStore(this.delegate);
  final StudioNoteStore delegate;
  String? failure;
  void _check(String operation) {
    if (failure == operation) {
      throw const FileSystemException(
        'No space left on device',
        '',
        OSError('No space left on device', 28),
      );
    }
  }

  @override
  Future<List<StudioNote>> loadAll() => delegate.loadAll();
  @override
  Future<StudioNote> save(
    StudioNote note, {
    Uint8List? imageBytes,
    Uint8List? audioWavBytes,
    bool clearImage = false,
    bool clearAudio = false,
  }) {
    _check('save');
    return delegate.save(
      note,
      imageBytes: imageBytes,
      audioWavBytes: audioWavBytes,
      clearImage: clearImage,
      clearAudio: clearAudio,
    );
  }

  @override
  Future<List<StudioNote>> saveAll(List<StudioNote> notes) {
    _check('saveAll');
    return delegate.saveAll(notes);
  }

  @override
  Future<void> delete(String noteId) {
    _check('delete');
    return delegate.delete(noteId);
  }

  @override
  Future<Uint8List?> readImageBytes(StudioNote note) =>
      delegate.readImageBytes(note);
  @override
  Future<Uint8List?> readAudioBytes(StudioNote note) =>
      delegate.readAudioBytes(note);
}

class _BlockingEmbeddings extends DummyPlaygroundPort {
  final Completer<void> started = Completer<void>();
  Completer<void>? pending;
  @override
  Future<EmbeddedPassageResult> embedDocuments(
    List<String> documents, {
    List<String?>? titles,
  }) async {
    if (!started.isCompleted) started.complete();
    await pending?.future;
    return super.embedDocuments(documents, titles: titles);
  }
}
