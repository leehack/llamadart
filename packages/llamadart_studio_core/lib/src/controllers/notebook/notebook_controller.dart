import 'dart:async';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../../adapters/curated_studio_model_catalog.dart';
import '../../adapters/storage/key_value_note_store.dart';
import '../../domain/studio_message.dart';
import '../../domain/studio_model_descriptor.dart';
import '../../domain/studio_note.dart';
import '../../domain/studio_settings.dart';
import '../../ports/inference_port.dart';
import '../../ports/key_value_store.dart';
import '../../ports/model_storage_port.dart';
import '../../ports/note_store.dart';
import '../../ports/playground_port.dart';
import '../../ports/speech_port.dart';
import '../../ports/studio_context_ports.dart';
import '../../reactive/state_store.dart';
import '../../services/studio_error_formatter.dart';
import '../lab_model_coordinator.dart';

part 'notebook_state.dart';
part 'notebook_rag_workflows.dart';

/// Coordinates Studio's Multimodal Notebook (`StudioWorkspace.notes`) and
/// Semantic Note Vault (note CRUD, multimodal embeddings, Stage-2 reranking,
/// local voice-note ASR transcription, and grounded RAG Q&A).
///
/// Depends strictly on segregated ports ([StudioEmbeddingPort], optional
/// [StudioRerankerPort], optional [StudioSttPort], optional [StudioInferencePort],
/// and read-only [StudioSettingsReader]).
class NotebookController {
  /// Creates a [NotebookController].
  NotebookController({
    required StudioModelStoragePort storagePort,
    required StudioEmbeddingPort embeddingPort,
    StudioRerankerPort? rerankerPort,
    LabModelCoordinator? labModels,
    StudioNoteStore? noteStore,
    KeyValueStore? keyValueStore,
    StudioInferencePort? inferencePort,
    StudioSettingsReader? shellController,
    StudioSttPort? sttPort,
    StudioModelCatalog modelCatalog = const CuratedStudioModelCatalog(),
    Future<bool> Function()? ensureChatModelReady,
    required this.isWeb,
    required this.isMobile,
  }) : _storage = storagePort,
       _embedding = embeddingPort,
       _reranker =
           rerankerPort ??
           (embeddingPort is StudioRerankerPort
               ? embeddingPort as StudioRerankerPort
               : null),
       _labModels =
           labModels ??
           LabModelCoordinator(
             storagePort: storagePort,
             modelLoader: embeddingPort,
             embeddingPort: embeddingPort,
             modelCatalog: modelCatalog,
             isWeb: isWeb,
             isMobile: isMobile,
           ),
       _ownsLabModels = labModels == null,
       _noteStore =
           noteStore ??
           (keyValueStore != null
               ? KeyValueNoteStore(keyValueStore)
               : EphemeralNoteStore()),
       _inference = inferencePort,
       _shell = shellController,
       _stt = sttPort,
       _catalog = modelCatalog,
       _ensureChatModelReady = ensureChatModelReady;

  final StudioModelStoragePort _storage;
  final StudioEmbeddingPort _embedding;
  final StudioRerankerPort? _reranker;
  final LabModelCoordinator _labModels;
  final bool _ownsLabModels;
  final StudioNoteStore _noteStore;
  final StudioInferencePort? _inference;
  final StudioSettingsReader? _shell;
  final StudioSttPort? _stt;
  final StudioModelCatalog _catalog;
  final Future<bool> Function()? _ensureChatModelReady;

  bool _sttLoadedOnce = false;
  int _idCounter = 0;

  /// Whether running on WebGPU.
  final bool isWeb;

  /// Whether running on iOS/Android.
  final bool isMobile;

  final StateStore<NotebookState> _store = StateStore<NotebookState>(
    const NotebookState(),
  );

  /// Reactive Multimodal Notebook state store.
  ReadOnlyStore<NotebookState> get store => _store;

  /// Current Notebook state snapshot.
  NotebookState get state => _store.state;

  /// Shared [LabModelCoordinator] for dedicated embedding/reranker models.
  LabModelCoordinator get labModels => _labModels;

  /// Backing [StudioNoteStore] (off-heap `FileNoteStore` on native hosts).
  StudioNoteStore get noteStore => _noteStore;

  /// Sorted dedicated embedding models supported for Multimodal Notebook.
  List<StudioModelDescriptor> get availableEmbedders =>
      _labModels.availableModelsForSpecialty(StudioModelSpecialty.embedding);

  /// Reads raw image bytes for [note] from off-heap storage or inline base64.
  Future<Uint8List?> readNoteImageBytes(StudioNote note) =>
      _noteStore.readImageBytes(note);

  /// Reads raw WAV audio bytes for [note] from off-heap storage or inline base64.
  Future<Uint8List?> readNoteAudioBytes(StudioNote note) =>
      _noteStore.readAudioBytes(note);

  /// Restores persisted Semantic Note Vault notes or seeds starter notes on
  /// first launch.
  Future<void> initialize() async {
    var loaded = await _noteStore.loadAll();
    if (loaded.isEmpty) {
      loaded = await _noteStore.saveAll(StudioNote.starterNotes());
    }
    final initialSelected = loaded.firstOrNull?.id;
    _store.update(
      (NotebookState s) => s.copyWith(
        notes: loaded,
        selectedNoteId: initialSelected,
        relatedNotes: initialSelected == null
            ? const <NoteSearchHit>[]
            : _computeRelatedNotes(loaded, initialSelected),
      ),
    );
  }

  /// Downloads and loads a dedicated auxiliary model (e.g. EmbeddingGemma 2)
  /// and mirrors any failure onto [NotebookState.errorMessage].
  Future<void> loadLabModel(StudioModelDescriptor descriptor) async {
    _store.update((NotebookState s) => s.copyWith(clearErrorMessage: true));
    try {
      await _labModels.loadLabModel(descriptor);
    } catch (error) {
      _store.update(
        (NotebookState s) =>
            s.copyWith(errorMessage: humanizeStudioError(error)),
      );
    }
  }

  /// Cancels an active embedder or ASR model download when one is running.
  void cancelModelLoad() {
    final loadingStt = _store.state.loadingModel;
    if (loadingStt != null) {
      _storage.cancelDownload(loadingStt.id);
      return;
    }
    _labModels.cancelModelLoad();
  }

  /// Selects a note in the Vault editor and updates its related note suggestions.
  void selectNote(String? noteId) {
    _store.update(
      (NotebookState s) => s.copyWith(
        selectedNoteId: noteId,
        clearSelectedNoteId: noteId == null,
        relatedNotes: noteId == null
            ? const <NoteSearchHit>[]
            : _computeRelatedNotes(s.notes, noteId),
      ),
    );
  }

  /// Updates the current note search query string.
  void setNoteSearchQuery(String query) {
    _store.update((NotebookState s) => s.copyWith(noteSearchQuery: query));
  }

  /// Enables or disables automatic Stage-2 cross-encoder reranking for note
  /// searches.
  void setRerankVaultHits(bool enabled) {
    _store.update((NotebookState s) => s.copyWith(rerankVaultHits: enabled));
  }

  /// Creates a new note in the Multimodal Notebook and selects it.
  Future<StudioNote> createNote({
    String title = 'New Note',
    String content = '',
    List<String> tags = const <String>[],
    bool pinned = false,
    StudioNoteSourceKind sourceKind = StudioNoteSourceKind.text,
    String? sourceFileName,
    Uint8List? imageBytes,
    String? imageMimeType,
    Uint8List? audioWavBytes,
    int? audioDurationMs,
    String? transcript,
  }) async {
    final now = DateTime.now();
    _idCounter++;
    final draft = StudioNote(
      id: 'note_${now.microsecondsSinceEpoch}_$_idCounter',
      title: title.trim().isEmpty ? 'Untitled Note' : title.trim(),
      content: content,
      tags: tags,
      pinned: pinned,
      sourceKind: sourceKind,
      sourceFileName: sourceFileName,
      imageMimeType: imageMimeType,
      audioDurationMs: audioDurationMs,
      transcript: transcript,
      createdAt: now,
      updatedAt: now,
    );
    final created = await _noteStore.save(
      draft,
      imageBytes: imageBytes,
      audioWavBytes: audioWavBytes,
    );
    final nextNotes = <StudioNote>[created, ..._store.state.notes];
    _store.update(
      (NotebookState s) => s.copyWith(
        notes: nextNotes,
        selectedNoteId: created.id,
        relatedNotes: const <NoteSearchHit>[],
      ),
    );
    return created;
  }

  /// Updates an existing note, invalidating its cached vector if content or
  /// media changed.
  Future<void> updateNote(
    String noteId, {
    String? title,
    String? content,
    List<String>? tags,
    bool? pinned,
    Uint8List? imageBytes,
    String? imageMimeType,
    bool clearImage = false,
    Uint8List? audioWavBytes,
    int? audioDurationMs,
    bool clearAudio = false,
    String? transcript,
    bool clearTranscript = false,
  }) async {
    StudioNote? existing;
    for (final n in _store.state.notes) {
      if (n.id == noteId) {
        existing = n;
        break;
      }
    }
    if (existing == null) {
      return;
    }

    final nextTitle = title ?? existing.title;
    final nextContent = content ?? existing.content;
    final nextTranscript = clearTranscript
        ? null
        : (transcript ?? existing.transcript);
    final mediaMutated =
        clearImage ||
        clearAudio ||
        (imageBytes != null && imageBytes.isNotEmpty) ||
        (audioWavBytes != null && audioWavBytes.isNotEmpty);
    final contentChanged =
        nextTitle != existing.title ||
        nextContent != existing.content ||
        nextTranscript != existing.transcript ||
        mediaMutated;

    final draft = existing.copyWith(
      title: nextTitle,
      content: nextContent,
      tags: tags ?? existing.tags,
      pinned: pinned ?? existing.pinned,
      imageMimeType: clearImage
          ? null
          : (imageMimeType ?? existing.imageMimeType),
      clearImage: clearImage,
      audioDurationMs: clearAudio
          ? null
          : (audioDurationMs ?? existing.audioDurationMs),
      clearAudio: clearAudio,
      transcript: nextTranscript,
      clearTranscript: clearTranscript,
      updatedAt: DateTime.now(),
      clearEmbedding: contentChanged,
    );

    final saved = await _noteStore.save(
      draft,
      imageBytes: imageBytes,
      audioWavBytes: audioWavBytes,
      clearImage: clearImage,
      clearAudio: clearAudio,
    );

    final nextNotes = _store.state.notes
        .map((StudioNote n) => n.id == noteId ? saved : n)
        .toList(growable: false);

    _store.update(
      (NotebookState s) => s.copyWith(
        notes: nextNotes,
        relatedNotes: s.selectedNoteId == null
            ? const <NoteSearchHit>[]
            : _computeRelatedNotes(nextNotes, s.selectedNoteId!),
      ),
    );
  }

  /// Replaces the note list after an external workflow (such as System-1 batch
  /// note auditing) mutates tags/metadata and optionally persists the updates.
  Future<void> applyAuditedNotes(
    List<StudioNote> updatedNotes, {
    bool persist = true,
  }) async {
    final normalized = List<StudioNote>.unmodifiable(updatedNotes);
    final selectedId = _store.state.selectedNoteId;
    _store.update(
      (NotebookState s) => s.copyWith(
        notes: normalized,
        relatedNotes: selectedId == null
            ? const <NoteSearchHit>[]
            : _computeRelatedNotes(normalized, selectedId),
      ),
    );
    if (persist) {
      await _persistNotes(normalized);
    }
  }

  /// Transcribes an audio note using Studio's local ASR model (e.g.
  /// `Qwen3-ASR 0.6B` or `Moonshine Tiny`) and stores the transcript onto the note.
  Future<String?> transcribeAudioNote(String noteId) async {
    final stt = _stt;
    if (stt == null) {
      _store.update(
        (NotebookState s) => s.copyWith(
          errorMessage: 'Speech transcription service is unavailable.',
        ),
      );
      return null;
    }
    StudioNote? target;
    for (final n in _store.state.notes) {
      if (n.id == noteId) {
        target = n;
        break;
      }
    }
    if (target == null || !target.hasAudio) {
      return null;
    }

    _store.update(
      (NotebookState s) =>
          s.copyWith(isTranscribingNote: true, clearErrorMessage: true),
    );
    try {
      if (!_sttLoadedOnce) {
        final candidates =
            <StudioModelDescriptor>[
              ..._storage.discoveredLocalModels.where(
                (StudioModelDescriptor m) =>
                    m.supportsSpeechToText &&
                    m.isSupportedOn(isWeb: isWeb, isMobile: isMobile),
              ),
              ..._catalog
                  .forCategory(
                    StudioModelCategory.speech,
                    isWeb: isWeb,
                    isMobile: isMobile,
                  )
                  .where((StudioModelDescriptor m) => m.supportsSpeechToText),
            ]..sort((StudioModelDescriptor a, StudioModelDescriptor b) {
              final aScore = a.specialty == StudioModelSpecialty.qwen3Asr
                  ? 1
                  : 0;
              final bScore = b.specialty == StudioModelSpecialty.qwen3Asr
                  ? 1
                  : 0;
              return bScore.compareTo(aScore);
            });

        StudioModelDescriptor? chosen;
        for (final c in candidates) {
          if (await _storage.isCached(c, isWeb: isWeb)) {
            chosen = c;
            break;
          }
        }
        chosen ??= candidates.firstOrNull;
        if (chosen == null) {
          throw StateError(
            'No Speech-to-Text model available for this platform.',
          );
        }
        _store.update((NotebookState s) => s.copyWith(loadingModel: chosen));
        final assets = await _storage.ensureDownloaded(chosen, isWeb: isWeb);
        await stt.loadSttModel(assets: assets, isWeb: isWeb);
        _sttLoadedOnce = true;
        _store.update((NotebookState s) => s.copyWith(clearLoadingModel: true));
      }

      final audioBytes = await _noteStore.readAudioBytes(target);
      final result = await stt.transcribe(
        audioBytes: audioBytes,
        audioFilePath: target.audioLocalPath,
        contextPrompt: target.title,
      );
      final transcript = result.text.trim();
      await updateNote(noteId, transcript: transcript);
      _store.update((NotebookState s) => s.copyWith(isTranscribingNote: false));
      return transcript;
    } catch (error) {
      _store.update(
        (NotebookState s) => s.copyWith(
          clearLoadingModel: true,
          isTranscribingNote: false,
          errorMessage: humanizeStudioError(error),
        ),
      );
      return null;
    }
  }

  /// Indexes notes if needed, retrieves top relevant sources via semantic
  /// search (+ optional reranker), and streams a grounded NotebookLM-style
  /// answer directly inside the Notebook workspace.
  Future<void> askNotebook(String rawQuestion, {int topK = 4}) =>
      _askNotebookImpl(rawQuestion, topK: topK);

  /// Cancels an active Notebook Q&A streaming response.
  void cancelNotebookAnswer() {
    _inference?.cancelGeneration();
  }

  /// Deletes a note from the Vault.
  Future<void> deleteNote(String noteId) async {
    final nextNotes = _store.state.notes
        .where((StudioNote n) => n.id != noteId)
        .toList(growable: false);
    final nextSelected = _store.state.selectedNoteId == noteId
        ? nextNotes.firstOrNull?.id
        : _store.state.selectedNoteId;
    final nextHits = _store.state.noteSearchHits
        .where((NoteSearchHit h) => h.note.id != noteId)
        .toList(growable: false);

    _store.update(
      (NotebookState s) => s.copyWith(
        notes: nextNotes,
        selectedNoteId: nextSelected,
        clearSelectedNoteId: nextSelected == null,
        noteSearchHits: nextHits,
        relatedNotes: nextSelected == null
            ? const <NoteSearchHit>[]
            : _computeRelatedNotes(nextNotes, nextSelected),
      ),
    );
    await _noteStore.delete(noteId);
  }

  /// Indexes all unindexed notes (or every note when [forceReindex] is true or
  /// the loaded embedding model changed) and updates related-note links.
  Future<void> indexNotes({bool forceReindex = false}) =>
      _indexNotesImpl(forceReindex: forceReindex);

  /// Searches all notes semantically against [query], auto-indexing unindexed
  /// notes first and optionally running a Stage-2 cross-encoder rerank pass.
  Future<List<NoteSearchHit>> searchNotes(
    String query, {
    int topK = 5,
    bool? rerank,
  }) => _searchNotesImpl(query, topK: topK, rerank: rerank);

  /// Formats [hits] (or the current search hits / selected note) as a grounded
  /// RAG prompt ready to drop into Studio's Chat workspace.
  String buildRagChatPrompt(String question, {List<NoteSearchHit>? hits}) =>
      _buildRagChatPromptImpl(question, hits: hits);

  static List<NoteSearchHit> _computeRelatedNotes(
    List<StudioNote> notes,
    String targetNoteId, {
    int limit = 3,
  }) {
    StudioNote? target;
    for (final n in notes) {
      if (n.id == targetNoteId) {
        target = n;
        break;
      }
    }
    if (target == null || !target.isIndexed) {
      return const <NoteSearchHit>[];
    }
    final hits =
        <NoteSearchHit>[
          for (final other in notes)
            if (other.id != targetNoteId && other.isIndexed)
              NoteSearchHit(
                note: other,
                cosineScore: StudioNote.cosineSimilarity(
                  target.embedding!,
                  other.embedding!,
                ),
              ),
        ]..sort(
          (NoteSearchHit a, NoteSearchHit b) =>
              b.cosineScore.compareTo(a.cosineScore),
        );
    return hits.take(limit).toList(growable: false);
  }

  Future<void> _persistNotes(List<StudioNote> notes) async {
    await _noteStore.saveAll(notes);
  }

  /// Disposes internal reactive state (and owned [LabModelCoordinator] if
  /// not shared externally).
  Future<void> dispose() async {
    if (_ownsLabModels) {
      await _labModels.dispose();
    }
    await _store.dispose();
  }
}
