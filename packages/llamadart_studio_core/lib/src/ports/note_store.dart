import 'dart:typed_data';

import '../domain/studio_note.dart';

/// Persistence port for [StudioNote] records and their multimodal attachments.
///
/// Native hosts use `FileNoteStore` (atomic per-note `.json` files + off-heap
/// binary media under `note_media/<id>/`), while Web and unit tests fall back
/// to `KeyValueNoteStore`.
abstract interface class StudioNoteStore {
  /// Legacy single-key note blob migrated automatically on first load.
  static const String legacyNotesStorageKey = 'studio.playground.notes.v1';

  /// Loads all persisted notes in display order.
  Future<List<StudioNote>> loadAll();

  /// Persists a single [note] (optionally writing or clearing binary media) and
  /// returns the canonical stored [StudioNote] (with off-heap paths populated
  /// on native hosts).
  Future<StudioNote> save(
    StudioNote note, {
    Uint8List? imageBytes,
    Uint8List? audioWavBytes,
    bool clearImage = false,
    bool clearAudio = false,
  });

  /// Persists the full ordered [notes] collection and returns canonical notes.
  Future<List<StudioNote>> saveAll(List<StudioNote> notes);

  /// Deletes [noteId] and any associated off-heap media files.
  Future<void> delete(String noteId);

  /// Reads raw image bytes for [note] from off-heap disk or inline base64.
  Future<Uint8List?> readImageBytes(StudioNote note);

  /// Reads raw WAV audio bytes for [note] from off-heap disk or inline base64.
  Future<Uint8List?> readAudioBytes(StudioNote note);
}
