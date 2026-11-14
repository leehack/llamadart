import 'dart:convert';
import 'dart:typed_data';

import '../../domain/studio_conversation.dart';
import '../../domain/studio_message.dart';
import '../../ports/conversation_store.dart';
import '../../ports/key_value_store.dart';

/// Platform-agnostic [StudioConversationStore] backed by any [KeyValueStore]
/// (used on Web, Jaspr browser targets, and unit tests).
class KeyValueConversationStore implements StudioConversationStore {
  /// Creates a [KeyValueConversationStore].
  KeyValueConversationStore(this._store);

  static const String _indexKey = 'studio.conversations.index.v1';
  static String _itemKey(String id) => 'studio.conversations.item.$id';

  final KeyValueStore _store;

  @override
  Future<List<StudioConversation>> loadAll() async {
    final rawIndex = await _store.readString(_indexKey);
    if (rawIndex == null || rawIndex.isEmpty) {
      return const <StudioConversation>[];
    }
    final List<Object?> ids;
    try {
      ids = jsonDecode(rawIndex) as List<Object?>;
    } catch (_) {
      return const <StudioConversation>[];
    }
    final conversations = <StudioConversation>[];
    for (final rawId in ids) {
      if (rawId is! String) {
        continue;
      }
      final rawItem = await _store.readString(_itemKey(rawId));
      if (rawItem == null || rawItem.isEmpty) {
        continue;
      }
      try {
        final map = jsonDecode(rawItem) as Map<String, Object?>;
        conversations.add(StudioConversation.fromJson(map));
      } catch (_) {
        // Skip corrupted entries rather than failing startup.
      }
    }
    conversations.sort(
      (StudioConversation a, StudioConversation b) =>
          b.updatedAt.compareTo(a.updatedAt),
    );
    return conversations;
  }

  @override
  Future<void> save(StudioConversation conversation) async {
    await _store.writeString(
      _itemKey(conversation.id),
      jsonEncode(conversation.toJson()),
    );
    final ids = await _readIds();
    if (!ids.contains(conversation.id)) {
      ids.add(conversation.id);
      await _store.writeString(_indexKey, jsonEncode(ids));
    }
  }

  @override
  Future<Uint8List?> readAttachmentBytes(StudioAttachment attachment) async {
    return attachment.bytes;
  }

  @override
  Future<void> delete(String id) async {
    await _store.remove(_itemKey(id));
    final ids = await _readIds();
    if (ids.remove(id)) {
      await _store.writeString(_indexKey, jsonEncode(ids));
    }
  }

  @override
  Future<void> clearAll() async {
    final ids = await _readIds();
    for (final id in ids) {
      await _store.remove(_itemKey(id));
    }
    await _store.remove(_indexKey);
  }

  @override
  Future<StudioAttachment> persistAttachment({
    required String conversationId,
    required StudioAttachment attachment,
  }) async {
    return attachment;
  }

  Future<List<String>> _readIds() async {
    final raw = await _store.readString(_indexKey);
    if (raw == null || raw.isEmpty) {
      return <String>[];
    }
    try {
      final decoded = jsonDecode(raw) as List<Object?>;
      return decoded.whereType<String>().toList();
    } catch (_) {
      return <String>[];
    }
  }
}
