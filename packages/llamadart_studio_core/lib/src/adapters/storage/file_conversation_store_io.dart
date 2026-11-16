import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:synchronized/synchronized.dart';

import '../../domain/studio_conversation.dart';
import '../../domain/studio_message.dart';
import '../../ports/conversation_store.dart';
import '../../ports/key_value_store.dart';
import 'key_value_conversation_store.dart';

/// Native `dart:io` factory creating [FileConversationStore] when
/// [directoryPath] is provided.
StudioConversationStore createPlatformConversationStore({
  required KeyValueStore fallbackKeyValueStore,
  String? directoryPath,
}) {
  if (directoryPath == null || directoryPath.trim().isEmpty) {
    return KeyValueConversationStore(fallbackKeyValueStore);
  }
  return FileConversationStore(directoryPath: directoryPath);
}

/// Atomic file-backed [StudioConversationStore] storing each conversation as
/// `<dir>/conversations/<id>.json` and flushing media attachments off-heap into
/// `<dir>/attachments/<conversationId>/`.
class FileConversationStore implements StudioConversationStore {
  /// Creates a [FileConversationStore] rooted at [directoryPath].
  FileConversationStore({required this.directoryPath});

  /// Root Studio storage directory path.
  final String directoryPath;

  final Lock _lock = Lock();

  Directory get _conversationsDir =>
      Directory(p.join(directoryPath, 'conversations'));

  Directory _attachmentsDirFor(String conversationId) => Directory(
    p.join(
      directoryPath,
      'attachments',
      _validatedConversationId(conversationId),
    ),
  );

  File _conversationFile(String id) => File(
    p.join(_conversationsDir.path, '${_validatedConversationId(id)}.json'),
  );

  @override
  Future<List<StudioConversation>> loadAll() {
    return _lock.synchronized(() async {
      final dir = _conversationsDir;
      if (!await dir.exists()) {
        return const <StudioConversation>[];
      }
      final loaded = <StudioConversation>[];
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File || !entity.path.endsWith('.json')) {
          continue;
        }
        try {
          final raw = await entity.readAsString();
          final map = jsonDecode(raw) as Map<String, Object?>;
          final conversation = StudioConversation.fromJson(map);
          _validatedConversationId(conversation.id);
          loaded.add(conversation);
        } catch (error, stackTrace) {
          // Ignore unreadable/partial files without breaking startup.
          developer.log(
            'Skipped unreadable conversation file: ${entity.path}',
            name: 'llamadart_studio_core.FileConversationStore',
            error: error,
            stackTrace: stackTrace,
          );
        }
      }
      loaded.sort(
        (StudioConversation a, StudioConversation b) =>
            b.updatedAt.compareTo(a.updatedAt),
      );
      return loaded;
    });
  }

  @override
  Future<void> save(StudioConversation conversation) {
    return _lock.synchronized(() async {
      _validatedConversationId(conversation.id);
      final dir = _conversationsDir;
      await dir.create(recursive: true);
      final target = _conversationFile(conversation.id);
      final encoded = const JsonEncoder.withIndent(
        '  ',
      ).convert(conversation.toJson(includeInlineAttachmentBytes: false));
      // A private, newly allocated directory prevents a stale temporary
      // symlink from redirecting writes outside the conversation store.
      final staging = await dir.createTemp('.save-');
      try {
        final temp = File(p.join(staging.path, 'conversation.json'));
        await temp.writeAsString(encoded, flush: true);
        await temp.rename(target.path);
      } finally {
        await staging.delete(recursive: true);
      }
    });
  }

  @override
  Future<Uint8List?> readAttachmentBytes(StudioAttachment attachment) async {
    if (attachment.bytes != null) {
      return attachment.bytes;
    }
    final path = attachment.localPath;
    if (path == null || path.isEmpty) {
      return null;
    }
    try {
      return await File(path).readAsBytes();
    } on FileSystemException {
      return null;
    }
  }

  @override
  Future<void> delete(String id) {
    return _lock.synchronized(() async {
      final file = _conversationFile(id);
      if (await file.exists()) {
        await file.delete();
      }
      final attDir = _attachmentsDirFor(id);
      if (await attDir.exists()) {
        await attDir.delete(recursive: true);
      }
    });
  }

  @override
  Future<void> clearAll() {
    return _lock.synchronized(() async {
      if (await _conversationsDir.exists()) {
        await _conversationsDir.delete(recursive: true);
      }
      final allAttachments = Directory(p.join(directoryPath, 'attachments'));
      if (await allAttachments.exists()) {
        await allAttachments.delete(recursive: true);
      }
    });
  }

  @override
  Future<StudioAttachment> persistAttachment({
    required String conversationId,
    required StudioAttachment attachment,
  }) async {
    _validatedConversationId(conversationId);
    return _lock.synchronized(() async {
      final attDir = _attachmentsDirFor(conversationId);
      await attDir.create(recursive: true);
      final existingPath = attachment.localPath;
      if (attachment.bytes == null && existingPath != null) {
        try {
          final ownedRoot = await attDir.resolveSymbolicLinks();
          final existing = await File(existingPath).resolveSymbolicLinks();
          if (p.isWithin(ownedRoot, existing)) return attachment;
        } on FileSystemException {
          // Read below reports a missing source without saving a broken link.
        }
      }
      final bytes = await readAttachmentBytes(attachment);
      if (bytes == null) {
        throw StateError('This attachment is unavailable. Choose it again.');
      }
      // Unique directories also prevent sanitized names or stale symlinks from
      // overwriting another attachment.
      final owned = await attDir.createTemp('media-');
      try {
        final file = File(
          p.join(owned.path, _sanitizeFileSegment(attachment.name)),
        );
        await file.writeAsBytes(bytes, flush: true);
        return StudioAttachment(
          id: attachment.id,
          kind: attachment.kind,
          name: attachment.name,
          mimeType: attachment.mimeType,
          localPath: file.path,
          sizeBytes: bytes.length,
        );
      } catch (_) {
        await owned.delete(recursive: true);
        rethrow;
      }
    });
  }

  static String _sanitizeFileSegment(String input) {
    final sanitized = input.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    return sanitized.isEmpty ? 'item' : sanitized;
  }

  static String _validatedConversationId(String id) {
    if (id.isEmpty ||
        id == '.' ||
        id == '..' ||
        !RegExp(r'^[a-zA-Z0-9._-]+$').hasMatch(id)) {
      throw ArgumentError.value(
        id,
        'conversationId',
        'Invalid conversation ID',
      );
    }
    return id;
  }
}
