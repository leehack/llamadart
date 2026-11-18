import 'dart:typed_data';

import '../domain/studio_conversation.dart';
import '../domain/studio_message.dart';

/// Durable persistence contract for Studio conversations and media attachments.
abstract interface class StudioConversationStore {
  /// Loads all saved conversations ordered by `updatedAt` descending.
  Future<List<StudioConversation>> loadAll();

  /// Persists [conversation] atomically.
  Future<void> save(StudioConversation conversation);

  /// Reads inline or persisted media bytes for a portable export.
  /// Returns `null` when the media is unavailable.
  Future<Uint8List?> readAttachmentBytes(StudioAttachment attachment);

  /// Deletes the conversation with [id] and any owned attachments.
  Future<void> delete(String id);

  /// Clears all saved conversations.
  Future<void> clearAll();

  /// Persists raw attachment bytes off-heap when supported (returning an
  /// updated [StudioAttachment] with `localPath` populated on native IO).
  Future<StudioAttachment> persistAttachment({
    required String conversationId,
    required StudioAttachment attachment,
  });
}
