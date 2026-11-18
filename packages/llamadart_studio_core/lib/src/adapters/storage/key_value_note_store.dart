import 'dart:convert';
import 'dart:typed_data';

import 'package:synchronized/synchronized.dart';

import '../../domain/studio_note.dart';
import '../../ports/key_value_store.dart';
import '../../ports/note_store.dart';

/// Cross-platform [StudioNoteStore] backed by per-note keys in [KeyValueStore].
///
/// Automatically migrates legacy `'studio.playground.notes.v1'` blobs on first
/// load and deletes the legacy monolithic key.
class KeyValueNoteStore implements StudioNoteStore {
  /// Creates a [KeyValueNoteStore].
  KeyValueNoteStore(this._kv);

  static const String _indexKey = 'studio.notes.index.v1';
  static const String _itemPrefix = 'studio.notes.item.';

  final KeyValueStore _kv;
  final Lock _lock = Lock();

  @override
  Future<List<StudioNote>> loadAll() async {
    final rawIndex = await _kv.readString(_indexKey);
    if (rawIndex != null && rawIndex.isNotEmpty) {
      // A damaged index must not prevent startup or legacy-note recovery.
      final ids = await _readIdsUnlocked();
      final loaded = <StudioNote>[];
      for (final id in ids) {
        final raw = await _kv.readString('$_itemPrefix$id');
        if (raw == null || raw.isEmpty) {
          continue;
        }
        try {
          final decoded = jsonDecode(raw);
          if (decoded is Map<String, Object?>) {
            loaded.add(StudioNote.fromJson(decoded));
          }
        } catch (_) {
          // Skip malformed entries rather than losing the entire vault.
        }
      }
      if (loaded.isNotEmpty) {
        return loaded;
      }
    }

    // Check and migrate legacy monolithic key if present.
    final legacyRaw = await _kv.readString(
      StudioNoteStore.legacyNotesStorageKey,
    );
    if (legacyRaw != null && legacyRaw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(legacyRaw);
        if (decoded is List) {
          final migrated = decoded
              .whereType<Map<String, Object?>>()
              .map(StudioNote.fromJson)
              .toList(growable: false);
          if (migrated.isNotEmpty) {
            await saveAll(migrated);
            await _kv.remove(StudioNoteStore.legacyNotesStorageKey);
            return migrated;
          }
        }
      } catch (_) {
        // Ignore corrupt legacy JSON.
      }
    }
    return const <StudioNote>[];
  }

  @override
  Future<StudioNote> save(
    StudioNote note, {
    Uint8List? imageBytes,
    Uint8List? audioWavBytes,
    bool clearImage = false,
    bool clearAudio = false,
  }) {
    return _lock.synchronized(() async {
      final updated = _applyInlineMedia(
        note,
        imageBytes: imageBytes,
        audioWavBytes: audioWavBytes,
        clearImage: clearImage,
        clearAudio: clearAudio,
      );
      await _kv.writeString(
        '$_itemPrefix${updated.id}',
        jsonEncode(updated.toJson()),
      );
      final ids = await _readIdsUnlocked();
      if (!ids.contains(updated.id)) {
        ids.insert(0, updated.id);
        await _kv.writeString(_indexKey, jsonEncode(ids));
      }
      return updated;
    });
  }

  @override
  Future<List<StudioNote>> saveAll(List<StudioNote> notes) {
    return _lock.synchronized(() async {
      final nextIds = <String>[];
      for (final note in notes) {
        nextIds.add(note.id);
        await _kv.writeString(
          '$_itemPrefix${note.id}',
          jsonEncode(note.toJson()),
        );
      }
      final prevIds = await _readIdsUnlocked();
      for (final staleId in prevIds) {
        if (!nextIds.contains(staleId)) {
          await _kv.remove('$_itemPrefix$staleId');
        }
      }
      await _kv.writeString(_indexKey, jsonEncode(nextIds));
      return List<StudioNote>.unmodifiable(notes);
    });
  }

  @override
  Future<void> delete(String noteId) {
    return _lock.synchronized(() async {
      final ids = await _readIdsUnlocked()
        ..remove(noteId);
      await _kv.writeString(_indexKey, jsonEncode(ids));
      await _kv.remove('$_itemPrefix$noteId');
    });
  }

  @override
  Future<Uint8List?> readImageBytes(StudioNote note) async {
    final b64 = note.imageBase64;
    if (b64 == null || b64.isEmpty) {
      return null;
    }
    try {
      return base64Decode(b64);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<Uint8List?> readAudioBytes(StudioNote note) async {
    final b64 = note.audioBase64;
    if (b64 == null || b64.isEmpty) {
      return null;
    }
    try {
      return base64Decode(b64);
    } catch (_) {
      return null;
    }
  }

  Future<List<String>> _readIdsUnlocked() async {
    final raw = await _kv.readString(_indexKey);
    if (raw == null || raw.isEmpty) {
      return <String>[];
    }
    try {
      return (jsonDecode(raw) as List<Object?>).whereType<String>().toList();
    } catch (_) {
      return <String>[];
    }
  }

  static StudioNote _applyInlineMedia(
    StudioNote note, {
    Uint8List? imageBytes,
    Uint8List? audioWavBytes,
    required bool clearImage,
    required bool clearAudio,
  }) {
    var result = note;
    if (clearImage) {
      result = result.copyWith(clearImage: true);
    } else if (imageBytes != null && imageBytes.isNotEmpty) {
      result = result.copyWith(imageBase64: base64Encode(imageBytes));
    }
    if (clearAudio) {
      result = result.copyWith(clearAudio: true);
    } else if (audioWavBytes != null && audioWavBytes.isNotEmpty) {
      result = result.copyWith(audioBase64: base64Encode(audioWavBytes));
    }
    return result;
  }
}

/// No-op in-memory [StudioNoteStore] used when no backing store is supplied.
class EphemeralNoteStore implements StudioNoteStore {
  final List<StudioNote> _notes = <StudioNote>[];

  @override
  Future<List<StudioNote>> loadAll() async =>
      List<StudioNote>.unmodifiable(_notes);

  @override
  Future<StudioNote> save(
    StudioNote note, {
    Uint8List? imageBytes,
    Uint8List? audioWavBytes,
    bool clearImage = false,
    bool clearAudio = false,
  }) async {
    final updated = KeyValueNoteStore._applyInlineMedia(
      note,
      imageBytes: imageBytes,
      audioWavBytes: audioWavBytes,
      clearImage: clearImage,
      clearAudio: clearAudio,
    );
    final idx = _notes.indexWhere((StudioNote n) => n.id == updated.id);
    if (idx >= 0) {
      _notes[idx] = updated;
    } else {
      _notes.insert(0, updated);
    }
    return updated;
  }

  @override
  Future<List<StudioNote>> saveAll(List<StudioNote> notes) async {
    _notes
      ..clear()
      ..addAll(notes);
    return List<StudioNote>.unmodifiable(_notes);
  }

  @override
  Future<void> delete(String noteId) async {
    _notes.removeWhere((StudioNote n) => n.id == noteId);
  }

  @override
  Future<Uint8List?> readImageBytes(StudioNote note) async {
    final b64 = note.imageBase64;
    if (b64 == null || b64.isEmpty) {
      return null;
    }
    try {
      return base64Decode(b64);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<Uint8List?> readAudioBytes(StudioNote note) async {
    final b64 = note.audioBase64;
    if (b64 == null || b64.isEmpty) {
      return null;
    }
    try {
      return base64Decode(b64);
    } catch (_) {
      return null;
    }
  }
}
