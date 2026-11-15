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
  }) : _rootDir = Directory(p.absolute(rootDirectory.path)),
       _notesDir = Directory(p.absolute(rootDirectory.path, 'notes')),
       _mediaDir = Directory(p.absolute(rootDirectory.path, 'note_media')),
       _fallbackStore = fallbackStore;

  static const String _orderFileName = '_order.json';
  static const Set<String> _mediaFileNames = <String>{
    'image.png',
    'image.jpg',
    'image.webp',
    'image.gif',
    'audio.wav',
  };

  final Directory _rootDir;
  final Directory _notesDir;
  final Directory _mediaDir;
  final KeyValueStore? _fallbackStore;
  final Lock _writeLock = Lock();

  @override
  Future<List<StudioNote>> loadAll() async {
    await _prepareNotesDirectory();

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
          _validatedNoteId(note.id);
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
      for (final note in notes) {
        _validatedNoteId(note.id);
      }
      await _prepareNotesDirectory();
      final storedList = <StudioNote>[];
      final keepSafeIds = <String>{};
      final nextOrder = <String>[];

      for (final note in notes) {
        final stored = await _offloadMediaAndWriteJsonUnlocked(note);
        storedList.add(stored);
        keepSafeIds.add(_validatedNoteId(stored.id));
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
        if (!_isValidNoteId(stem)) continue;
        if (!keepSafeIds.contains(stem)) {
          await entity.delete();
          final staleMedia = Directory(p.join(_mediaDir.path, stem));
          await _removeUnreferencedMedia(staleMedia);
        }
      }

      await _writeOrderIdsUnlocked(nextOrder);
      return List<StudioNote>.unmodifiable(storedList);
    });
  }

  @override
  Future<void> delete(String noteId) {
    return _writeLock.synchronized(() async {
      final safeId = _validatedNoteId(noteId);
      await _prepareNotesDirectory();
      final order = await _readOrderIds()
        ..remove(noteId);
      // Order is advisory: a crash before note deletion still reloads the note.
      // A failed order write must not delete the authoritative JSON or media.
      await _writeOrderIdsUnlocked(order);
      final file = File(p.join(_notesDir.path, '$safeId.json'));
      if (await file.exists()) {
        await file.delete();
      }
      final mediaSubdir = Directory(p.join(_mediaDir.path, safeId));
      await _removeUnreferencedMedia(mediaSubdir);
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
    final safeId = _validatedNoteId(note.id);
    await _prepareNotesDirectory();
    final noteMediaDir = Directory(p.join(_mediaDir.path, safeId));
    await _checkMediaDirectory(noteMediaDir);

    var updated = note;
    Directory? revision;
    var committed = false;
    Future<File> newMediaFile(String name) async {
      await _checkMediaDirectory(noteMediaDir, create: true);
      revision ??= await noteMediaDir.createTemp('revision_');
      return File(p.join(revision!.path, name));
    }

    try {
      // 1. Handle image attachment off-heap lifecycle.
      if (clearImage) {
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
          final ext = _imageExtensionForMime(updated.imageMimeType);
          // Old metadata keeps its immutable files until the new JSON commits.
          final imgFile = await newMediaFile('image.$ext');
          await imgFile.writeAsBytes(effectiveImg, flush: true);
          updated = updated.copyWith(
            imageLocalPath: imgFile.path,
            clearImageBase64: true,
          );
        }
      }

      // 2. Handle audio WAV attachment off-heap lifecycle.
      if (clearAudio) {
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
          final wavFile = await newMediaFile('audio.wav');
          await wavFile.writeAsBytes(effectiveAudio, flush: true);
          updated = updated.copyWith(
            audioLocalPath: wavFile.path,
            clearAudioBase64: true,
          );
        }
      }

      // 3. Atomic write (.tmp + rename) without inline base64 blobs.
      await _validateManagedMedia(updated, noteMediaDir);
      final target = File(p.join(_notesDir.path, '$safeId.json'));
      final temp = File('${target.path}.tmp');
      await _rejectFileLink(temp);
      await temp.writeAsString(
        const JsonEncoder.withIndent(
          '  ',
        ).convert(updated.toJson(includeInlineMedia: false)),
        flush: true,
      );
      await temp.rename(target.path);
      committed = true;
      await _removeUnreferencedMedia(noteMediaDir, note: updated);
      return updated;
    } finally {
      if (!committed && revision != null) {
        try {
          await _collectRevision(revision!, <String>{});
        } on FileSystemException {
          // A later committed save also collects interrupted revisions.
        }
      }
    }
  }

  Future<void> _prepareNotesDirectory() async {
    await _rootDir.create(recursive: true);
    await _checkChildDirectory(_rootDir, _notesDir, create: true);
  }

  Future<bool> _checkChildDirectory(
    Directory parent,
    Directory child, {
    bool create = false,
  }) async {
    var type = await FileSystemEntity.type(child.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      if (!create) return false;
      await child.create();
      type = await FileSystemEntity.type(child.path, followLinks: false);
    }
    final canonicalParent = await parent.resolveSymbolicLinks();
    final canonicalRoot = await _rootDir.resolveSymbolicLinks();
    if (type != FileSystemEntityType.directory) {
      throw FileSystemException(
        'Note store directory must not be a link',
        child.path,
      );
    }
    final canonicalChild = await child.resolveSymbolicLinks();
    if (!p.equals(
          canonicalChild,
          p.join(canonicalParent, p.basename(child.path)),
        ) ||
        !p.isWithin(canonicalRoot, canonicalChild)) {
      throw FileSystemException(
        'Note store directory escapes its owned parent',
        child.path,
      );
    }
    return true;
  }

  Future<bool> _checkMediaDirectory(
    Directory dir, {
    bool create = false,
  }) async {
    _validatedNoteId(p.basename(dir.path));
    if (!await _checkChildDirectory(_rootDir, _mediaDir, create: create)) {
      return false;
    }
    return _checkChildDirectory(_mediaDir, dir, create: create);
  }

  Future<void> _validateManagedMedia(StudioNote note, Directory dir) async {
    final managedRoot = p.normalize(p.absolute(_mediaDir.path));
    final canonicalManagedRoot = await _canonicalPath(managedRoot);
    final canonicalDir = await _canonicalPath(dir.path);
    for (final path in <String?>[note.imageLocalPath, note.audioLocalPath]) {
      if (path == null || path.isEmpty) continue;
      final absolute = p.normalize(p.absolute(path));
      final canonical = await _canonicalPath(absolute);
      if (!p.isWithin(managedRoot, absolute) &&
          !p.isWithin(canonicalManagedRoot, canonical)) {
        continue;
      }
      final relative = p.split(p.relative(canonical, from: canonicalDir));
      final recognized =
          (relative.length == 1 ||
              (relative.length == 2 && _isRevisionName(relative.first))) &&
          _mediaFileNames.contains(relative.last);
      if (!p.isWithin(canonicalDir, canonical) ||
          !recognized ||
          !await _checkMediaDirectory(dir)) {
        throw FileSystemException('Invalid managed note media reference', path);
      }
      if (relative.length == 2) {
        await _checkChildDirectory(
          dir,
          Directory(p.join(dir.path, relative.first)),
        );
      }
      final file = File(absolute);
      if (await FileSystemEntity.type(absolute, followLinks: false) !=
              FileSystemEntityType.file ||
          !p.equals(
            await file.resolveSymbolicLinks(),
            p.join(await dir.resolveSymbolicLinks(), p.joinAll(relative)),
          )) {
        throw FileSystemException(
          'Managed note media is missing or unsafe',
          path,
        );
      }
    }
  }

  Future<String> _canonicalPath(String path) async {
    var existing = p.normalize(p.absolute(path));
    final missing = <String>[];
    while (await FileSystemEntity.type(existing, followLinks: false) ==
        FileSystemEntityType.notFound) {
      missing.insert(0, p.basename(existing));
      final parent = p.dirname(existing);
      if (parent == existing) {
        throw FileSystemException('No existing path ancestor', path);
      }
      existing = parent;
    }
    return p.joinAll(<String>[
      await File(existing).resolveSymbolicLinks(),
      ...missing,
    ]);
  }

  Future<void> _removeUnreferencedMedia(
    Directory dir, {
    StudioNote? note,
  }) async {
    // Only recognized media is ours. Unknown entries and links are preserved.
    try {
      if (!await _checkMediaDirectory(dir)) return;
      final retained = <String>{};
      for (final path in <String?>[
        note?.imageLocalPath,
        note?.audioLocalPath,
      ]) {
        if (path != null && await File(path).exists()) {
          retained.add(await File(path).resolveSymbolicLinks());
        }
      }
      await _collectRecognizedFiles(dir, retained);
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is Directory && _isRevisionName(p.basename(entity.path))) {
          await _collectRevision(entity, retained);
        }
      }
      if (await dir.list(followLinks: false).isEmpty) await dir.delete();
    } on FileSystemException {
      // Cleanup is retryable; the metadata commit already succeeded.
    }
  }

  Future<void> _collectRevision(
    Directory revision,
    Set<String> retained,
  ) async {
    final parent = revision.parent;
    if (!_isRevisionName(p.basename(revision.path)) ||
        !await _checkMediaDirectory(parent) ||
        !await _checkChildDirectory(parent, revision)) {
      return;
    }
    await _collectRecognizedFiles(revision, retained);
    if (await revision.list(followLinks: false).isEmpty) {
      await revision.delete();
    }
  }

  Future<void> _collectRecognizedFiles(
    Directory dir,
    Set<String> retained,
  ) async {
    for (final name in _mediaFileNames) {
      final file = File(p.join(dir.path, name));
      if (await FileSystemEntity.type(file.path, followLinks: false) ==
              FileSystemEntityType.file &&
          !retained.contains(await file.resolveSymbolicLinks())) {
        await file.delete();
      }
    }
  }

  static bool _isRevisionName(String name) =>
      RegExp(r'^revision_[a-zA-Z0-9]+$').hasMatch(name);

  static Future<void> _rejectFileLink(File file) async {
    if (await FileSystemEntity.type(file.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw FileSystemException(
        'Note store staging file must not be a link',
        file.path,
      );
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
    await _prepareNotesDirectory();
    final target = File(p.join(_notesDir.path, _orderFileName));
    final temp = File('${target.path}.tmp');
    await _rejectFileLink(temp);
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

  static bool _isValidNoteId(String id) =>
      id.isNotEmpty &&
      id != '.' &&
      id != '..' &&
      id != '_order' &&
      RegExp(r'^[a-zA-Z0-9._-]+$').hasMatch(id);

  static String _validatedNoteId(String raw) {
    if (!_isValidNoteId(raw)) {
      throw ArgumentError.value(
        raw,
        'noteId',
        'Must be one non-reserved filename component',
      );
    }
    return raw;
  }
}
