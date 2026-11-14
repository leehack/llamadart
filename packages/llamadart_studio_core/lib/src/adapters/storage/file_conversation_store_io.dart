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
    p.join(directoryPath, 'attachments', _sanitizeFileSegment(conversationId)),
  );

  File _conversationFile(String id) =>
      File(p.join(_conversationsDir.path, '${_sanitizeFileSegment(id)}.json'));

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
          loaded.add(StudioConversation.fromJson(map));
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
      final dir = _conversationsDir;
      await dir.create(recursive: true);
      final target = _conversationFile(conversation.id);
      final temp = File('${target.path}.tmp');
      final encoded = const JsonEncoder.withIndent(
        '  ',
      ).convert(conversation.toJson(includeInlineAttachmentBytes: false));
      await temp.writeAsString(encoded, flush: true);
      await temp.rename(target.path);
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
    if (attachment.localPath != null && attachment.localPath!.isNotEmpty) {
      return attachment;
    }
    final bytes = attachment.bytes;
    if (bytes == null || bytes.isEmpty) {
      return attachment;
    }
    return _lock.synchronized(() async {
      final attDir = _attachmentsDirFor(conversationId);
      await attDir.create(recursive: true);
      final safeName = _sanitizeFileSegment(attachment.name);
      final filename = '${_sanitizeFileSegment(attachment.id)}_$safeName';
      final file = File(p.join(attDir.path, filename));
      await file.writeAsBytes(bytes, flush: true);
      return StudioAttachment(
        id: attachment.id,
        kind: attachment.kind,
        name: attachment.name,
        mimeType: attachment.mimeType,
        localPath: file.path,
        sizeBytes: bytes.length,
      );
    });
  }

  static String _sanitizeFileSegment(String input) {
    final sanitized = input.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    return sanitized.isEmpty ? 'item' : sanitized;
  }
}
