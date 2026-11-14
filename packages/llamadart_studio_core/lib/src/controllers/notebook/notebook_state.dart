part of 'notebook_controller.dart';

/// Immutable state for the Multimodal Notebook (`StudioWorkspace.notes`) and
/// Semantic Note Vault.
@immutable
class NotebookState {
  /// Creates a [NotebookState].
  const NotebookState({
    this.notes = const <StudioNote>[],
    this.selectedNoteId,
    this.noteSearchQuery = '',
    this.noteSearchHits = const <NoteSearchHit>[],
    this.relatedNotes = const <NoteSearchHit>[],
    this.rerankVaultHits = false,
    this.lastSearchElapsedMs,
    this.notebookQuestion = '',
    this.notebookAnswerText = '',
    this.isAnsweringNotebook = false,
    this.isTranscribingNote = false,
    this.notebookAnswerSources = const <NoteSearchHit>[],
    this.notebookAnswerElapsedMs,
    this.isEvaluating = false,
    this.loadingModel,
    this.errorMessage,
  });

  /// Local Multimodal Notebook entries.
  final List<StudioNote> notes;

  /// Currently selected note ID in the Notebook editor.
  final String? selectedNoteId;

  /// Active semantic search query across [notes].
  final String noteSearchQuery;

  /// Ranked note matches returned by semantic + optional cross-encoder search.
  final List<NoteSearchHit> noteSearchHits;

  /// Automatically computed semantic neighbors for [selectedNote].
  final List<NoteSearchHit> relatedNotes;

  /// Whether Notebook searches run a second cross-encoder rerank stage.
  final bool rerankVaultHits;

  /// Wall-clock latency of the most recent semantic search pass.
  final int? lastSearchElapsedMs;

  /// Last Notebook Q&A question asked by the user.
  final String notebookQuestion;

  /// Grounded streaming/completed Notebook Q&A response.
  final String notebookAnswerText;

  /// Whether Notebook Q&A is actively streaming from the local model.
  final bool isAnsweringNotebook;

  /// Whether an audio note is currently being transcribed by local ASR.
  final bool isTranscribingNote;

  /// Cited note hits used to ground [notebookAnswerText].
  final List<NoteSearchHit> notebookAnswerSources;

  /// Wall-clock duration of the completed Notebook Q&A turn.
  final int? notebookAnswerElapsedMs;

  /// Whether indexing or semantic search is currently running.
  final bool isEvaluating;

  /// Speech-to-Text model currently downloading/loading for note transcription.
  final StudioModelDescriptor? loadingModel;

  /// Optional error banner message.
  final String? errorMessage;

  /// Whether any notebook indexing, search, transcription, or model download
  /// is currently running.
  bool get isBusy => isEvaluating || isTranscribingNote || loadingModel != null;

  /// Currently selected [StudioNote], or the first note if present.
  StudioNote? get selectedNote {
    final target = selectedNoteId;
    if (target != null) {
      for (final note in notes) {
        if (note.id == target) {
          return note;
        }
      }
    }
    return notes.firstOrNull;
  }

  /// Notes ordered with pinned items first, then most recently updated.
  List<StudioNote> get orderedNotes {
    final copy = notes.toList();
    copy.sort((StudioNote a, StudioNote b) {
      if (a.pinned != b.pinned) {
        return a.pinned ? -1 : 1;
      }
      return b.updatedAt.compareTo(a.updatedAt);
    });
    return copy;
  }

  /// Number of notes holding a cached vector embedding.
  int get indexedNoteCount => notes.where((StudioNote n) => n.isIndexed).length;

  /// Number of notes indexed with multimodal vectors (`EmbeddingGemma 2`).
  int get multimodalIndexedNoteCount => notes
      .where((StudioNote n) => n.isIndexed && n.isMultimodalIndexed)
      .length;

  /// Returns an updated copy of [NotebookState].
  NotebookState copyWith({
    List<StudioNote>? notes,
    String? selectedNoteId,
    bool clearSelectedNoteId = false,
    String? noteSearchQuery,
    List<NoteSearchHit>? noteSearchHits,
    List<NoteSearchHit>? relatedNotes,
    bool? rerankVaultHits,
    int? lastSearchElapsedMs,
    String? notebookQuestion,
    String? notebookAnswerText,
    bool? isAnsweringNotebook,
    bool? isTranscribingNote,
    List<NoteSearchHit>? notebookAnswerSources,
    int? notebookAnswerElapsedMs,
    bool? isEvaluating,
    StudioModelDescriptor? loadingModel,
    bool clearLoadingModel = false,
    String? errorMessage,
    bool clearErrorMessage = false,
  }) {
    return NotebookState(
      notes: notes ?? this.notes,
      selectedNoteId: clearSelectedNoteId
          ? null
          : (selectedNoteId ?? this.selectedNoteId),
      noteSearchQuery: noteSearchQuery ?? this.noteSearchQuery,
      noteSearchHits: noteSearchHits ?? this.noteSearchHits,
      relatedNotes: relatedNotes ?? this.relatedNotes,
      rerankVaultHits: rerankVaultHits ?? this.rerankVaultHits,
      lastSearchElapsedMs: lastSearchElapsedMs ?? this.lastSearchElapsedMs,
      notebookQuestion: notebookQuestion ?? this.notebookQuestion,
      notebookAnswerText: notebookAnswerText ?? this.notebookAnswerText,
      isAnsweringNotebook: isAnsweringNotebook ?? this.isAnsweringNotebook,
      isTranscribingNote: isTranscribingNote ?? this.isTranscribingNote,
      notebookAnswerSources:
          notebookAnswerSources ?? this.notebookAnswerSources,
      notebookAnswerElapsedMs:
          notebookAnswerElapsedMs ?? this.notebookAnswerElapsedMs,
      isEvaluating: isEvaluating ?? this.isEvaluating,
      loadingModel: clearLoadingModel
          ? null
          : (loadingModel ?? this.loadingModel),
      errorMessage: clearErrorMessage
          ? null
          : (errorMessage ?? this.errorMessage),
    );
  }
}
