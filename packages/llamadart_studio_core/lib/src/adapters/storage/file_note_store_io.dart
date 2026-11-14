import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:synchronized/synchronized.dart';

import '../../domain/studio_note.dart';
import '../../ports/key_value_store.dart';
import '../../ports/note_store.dart';
import 'key_value_note_store.dart';

/// Native `dart:io` factory returning a [FileNoteStore] when [directoryPath] is
/// provided.
StudioNoteStore createPlatformNoteStore({
  required KeyValueStore fallbackKeyValueStore,
  String? directoryPath,
}) {
  if (directoryPath == null || directoryPath.trim().isEmpty) {
    return KeyValueNoteStore(fallbackKeyValueStore);
  }
  return FileNoteStore(
    rootDirectory: Directory(directoryPath),
    fallbackStore: fallbackKeyValueStore,
  );
}

/// Durable file-backed [StudioNoteStore] storing each note as an atomic `.json`
/// file and offloading image/WAV attachments to `note_media/<noteId>/` so
/// `SharedPreferences` and the Dart heap stay lean.
class FileNoteStore implements StudioNoteStore {
  /// Creates a [FileNoteStore].
  FileNoteStore({
    required Directory rootDirectory,
    KeyValueStore? fallbackStore,
  }) : _notesDir = Directory(p.join(rootDirectory.path, 'notes')),
       _mediaDir = Directory(p.join(rootDirectory.path, 'note_media')),
       _fallbackStore = fallbackStore;

  static const String _orderFileName = '_order.json';

  final Directory _notesDir;
  final Directory _mediaDir;
  final KeyValueStore? _fallbackStore;
  final Lock _writeLock = Lock();

  @override
  Future<List<StudioNote>> loadAll() async {
    if (!await _notesDir.exists()) {
      await _notesDir.create(recursive: true);
    }

    final notesById = <String, StudioNote>{};
    await for (final entity in _notesDir.list(followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.json')) {
        continue;
      }
      if (p.basename(entity.path) == _orderFileName) {
        continue;
      }
      try {
        final raw = await entity.readAsString();
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, Object?>) {
          var note = StudioNote.fromJson(decoded);
          // Migrate any lingering inline base64 payloads inside JSON to disk.
          if ((note.imageBase64 != null && note.imageBase64!.isNotEmpty) ||
              (note.audioBase64 != null && note.audioBase64!.isNotEmpty)) {
            note = await _offloadMediaAndWriteJsonUnlocked(note);
          }
          notesById[note.id] = note;
        }
      } catch (error, stackTrace) {
        // Skip corrupt note file cleanly rather than failing startup.
        developer.log(
          'Skipped unreadable note file: ${entity.path}',
          name: 'llamadart_studio_core.FileNoteStore',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }

    if (notesById.isEmpty && _fallbackStore != null) {
      final fallback = KeyValueNoteStore(_fallbackStore);
      final migrated = await fallback.loadAll();
      if (migrated.isNotEmpty) {
        final saved = await saveAll(migrated);
        await _fallbackStore.remove(StudioNoteStore.legacyNotesStorageKey);
        return saved;
      }
    }

    if (notesById.isEmpty) {
      return const <StudioNote>[];
    }

    final orderedIds = await _readOrderIds();
    final ordered = <StudioNote>[];
    final seen = <String>{};
    for (final id in orderedIds) {
      final found = notesById[id];
      if (found != null && seen.add(id)) {
        ordered.add(found);
      }
    }
    final remaining =
        notesById.values
            .where((StudioNote n) => !seen.contains(n.id))
            .toList(growable: false)
          ..sort(
            (StudioNote a, StudioNote b) => b.updatedAt.compareTo(a.updatedAt),
          );
    ordered.addAll(remaining);
    return List<StudioNote>.unmodifiable(ordered);
  }

  @override
  Future<StudioNote> save(
    StudioNote note, {
    Uint8List? imageBytes,
    Uint8List? audioWavBytes,
    bool clearImage = false,
    bool clearAudio = false,
  }) {
    return _writeLock.synchronized(() async {
      final stored = await _offloadMediaAndWriteJsonUnlocked(
        note,
        imageBytes: imageBytes,
        audioWavBytes: audioWavBytes,
        clearImage: clearImage,
        clearAudio: clearAudio,
      );
      final order = await _readOrderIds();
      if (!order.contains(stored.id)) {
        order.insert(0, stored.id);
        await _writeOrderIdsUnlocked(order);
      }
      return stored;
    });
  }

  @override
  Future<List<StudioNote>> saveAll(List<StudioNote> notes) {
    return _writeLock.synchronized(() async {
      if (!await _notesDir.exists()) {
        await _notesDir.create(recursive: true);
      }
      final storedList = <StudioNote>[];
      final keepSafeIds = <String>{};
      final nextOrder = <String>[];

      for (final note in notes) {
        final stored = await _offloadMediaAndWriteJsonUnlocked(note);
        storedList.add(stored);
        keepSafeIds.add(_sanitizeFileName(stored.id));
        nextOrder.add(stored.id);
      }

      // Remove deleted note JSON files and orphaned note_media subdirectories.
      await for (final entity in _notesDir.list(followLinks: false)) {
        if (entity is! File || !entity.path.endsWith('.json')) {
          continue;
        }
        final base = p.basename(entity.path);
        if (base == _orderFileName) {
          continue;
        }
        final stem = base.substring(0, base.length - 5);
        if (!keepSafeIds.contains(stem)) {
          await entity.delete();
          final staleMedia = Directory(p.join(_mediaDir.path, stem));
          if (await staleMedia.exists()) {
            await staleMedia.delete(recursive: true);
          }
        }
      }

      await _writeOrderIdsUnlocked(nextOrder);
      return List<StudioNote>.unmodifiable(storedList);
    });
  }

  @override
  Future<void> delete(String noteId) {
    return _writeLock.synchronized(() async {
      final safeId = _sanitizeFileName(noteId);
      final file = File(p.join(_notesDir.path, '$safeId.json'));
      if (await file.exists()) {
        await file.delete();
      }
      final mediaSubdir = Directory(p.join(_mediaDir.path, safeId));
      if (await mediaSubdir.exists()) {
        await mediaSubdir.delete(recursive: true);
      }
      final order = await _readOrderIds()
        ..remove(noteId);
      await _writeOrderIdsUnlocked(order);
    });
  }

  @override
  Future<Uint8List?> readImageBytes(StudioNote note) async {
    final path = note.imageLocalPath;
    if (path != null && path.isNotEmpty) {
      final file = File(path);
      if (await file.exists()) {
        try {
          return await file.readAsBytes();
        } catch (_) {}
      }
    }
    final b64 = note.imageBase64;
    if (b64 != null && b64.isNotEmpty) {
      try {
        return base64Decode(b64);
      } catch (_) {}
    }
    return null;
  }

  @override
  Future<Uint8List?> readAudioBytes(StudioNote note) async {
    final path = note.audioLocalPath;
    if (path != null && path.isNotEmpty) {
      final file = File(path);
      if (await file.exists()) {
        try {
          return await file.readAsBytes();
        } catch (_) {}
      }
    }
    final b64 = note.audioBase64;
    if (b64 != null && b64.isNotEmpty) {
      try {
        return base64Decode(b64);
      } catch (_) {}
    }
    return null;
  }

  Future<StudioNote> _offloadMediaAndWriteJsonUnlocked(
    StudioNote note, {
    Uint8List? imageBytes,
    Uint8List? audioWavBytes,
    bool clearImage = false,
    bool clearAudio = false,
  }) async {
    if (!await _notesDir.exists()) {
      await _notesDir.create(recursive: true);
    }
    final safeId = _sanitizeFileName(note.id);
    final noteMediaDir = Directory(p.join(_mediaDir.path, safeId));

    var updated = note;

    // 1. Handle image attachment off-heap lifecycle.
    if (clearImage) {
      await _deleteFilesWithPrefix(noteMediaDir, 'image.');
      updated = updated.copyWith(clearImage: true);
    } else {
      Uint8List? effectiveImg = imageBytes;
      if ((effectiveImg == null || effectiveImg.isEmpty) &&
          updated.imageBase64 != null &&
          updated.imageBase64!.isNotEmpty) {
        try {
          effectiveImg = base64Decode(updated.imageBase64!);
        } catch (_) {
          effectiveImg = null;
        }
      }
      if (effectiveImg != null && effectiveImg.isNotEmpty) {
        if (!await noteMediaDir.exists()) {
          await noteMediaDir.create(recursive: true);
        }
        await _deleteFilesWithPrefix(noteMediaDir, 'image.');
        final ext = _imageExtensionForMime(updated.imageMimeType);
        final imgFile = File(p.join(noteMediaDir.path, 'image.$ext'));
        await imgFile.writeAsBytes(effectiveImg, flush: true);
        updated = updated.copyWith(
          imageLocalPath: imgFile.path,
          clearImageBase64: true,
        );
      }
    }

    // 2. Handle audio WAV attachment off-heap lifecycle.
    if (clearAudio) {
      final wavFile = File(p.join(noteMediaDir.path, 'audio.wav'));
      if (await wavFile.exists()) {
        await wavFile.delete();
      }
      updated = updated.copyWith(clearAudio: true);
    } else {
      Uint8List? effectiveAudio = audioWavBytes;
      if ((effectiveAudio == null || effectiveAudio.isEmpty) &&
          updated.audioBase64 != null &&
          updated.audioBase64!.isNotEmpty) {
        try {
          effectiveAudio = base64Decode(updated.audioBase64!);
        } catch (_) {
          effectiveAudio = null;
        }
      }
      if (effectiveAudio != null && effectiveAudio.isNotEmpty) {
        if (!await noteMediaDir.exists()) {
          await noteMediaDir.create(recursive: true);
        }
        final wavFile = File(p.join(noteMediaDir.path, 'audio.wav'));
        await wavFile.writeAsBytes(effectiveAudio, flush: true);
        updated = updated.copyWith(
          audioLocalPath: wavFile.path,
          clearAudioBase64: true,
        );
      }
    }

    // Clean up empty media directory if all media was cleared.
    if (await noteMediaDir.exists()) {
      final hasRemaining = !(await noteMediaDir.list().isEmpty);
      if (!hasRemaining) {
        await noteMediaDir.delete();
      }
    }

    // 3. Atomic write (.tmp + rename) without inline base64 blobs.
    final target = File(p.join(_notesDir.path, '$safeId.json'));
    final temp = File('${target.path}.tmp');
    await temp.writeAsString(
      const JsonEncoder.withIndent(
        '  ',
      ).convert(updated.toJson(includeInlineMedia: false)),
      flush: true,
    );
    await temp.rename(target.path);
    return updated;
  }

  Future<void> _deleteFilesWithPrefix(Directory dir, String prefix) async {
    if (!await dir.exists()) {
      return;
    }
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is File && p.basename(entity.path).startsWith(prefix)) {
        await entity.delete();
      }
    }
  }

  Future<List<String>> _readOrderIds() async {
    final orderFile = File(p.join(_notesDir.path, _orderFileName));
    if (!await orderFile.exists()) {
      return <String>[];
    }
    try {
      final raw = await orderFile.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.whereType<String>().toList();
      }
    } catch (_) {}
    return <String>[];
  }

  Future<void> _writeOrderIdsUnlocked(List<String> ids) async {
    if (!await _notesDir.exists()) {
      await _notesDir.create(recursive: true);
    }
    final target = File(p.join(_notesDir.path, _orderFileName));
    final temp = File('${target.path}.tmp');
    await temp.writeAsString(jsonEncode(ids), flush: true);
    await temp.rename(target.path);
  }

  static String _imageExtensionForMime(String? mime) {
    final lower = (mime ?? '').toLowerCase();
    if (lower.contains('jpeg') || lower.contains('jpg')) {
      return 'jpg';
    }
    if (lower.contains('webp')) {
      return 'webp';
    }
    if (lower.contains('gif')) {
      return 'gif';
    }
    return 'png';
  }

  static String _sanitizeFileName(String raw) {
    return raw.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
  }
}
