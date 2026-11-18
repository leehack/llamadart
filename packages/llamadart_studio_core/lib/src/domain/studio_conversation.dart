import 'package:meta/meta.dart';

import 'studio_message.dart';
import 'studio_preset.dart';

/// Persistent Studio conversation supporting non-destructive message branching,
/// pinning, search, and per-session prompt/schema overrides.
@immutable
class StudioConversation {
  /// Creates a [StudioConversation].
  const StudioConversation({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.pinned = false,
    this.systemPrompt = defaultSystemPrompt,
    this.presetId = 'concise_assistant',
    this.jsonSchema,
    this.nodes = const <StudioMessage>[],
    this.selectedChildByParent = const <String, String>{},
  });

  /// Default system instruction for fresh conversations.
  static const String defaultSystemPrompt =
      'You are a concise, accurate local AI assistant running on llamadart. '
      'Lead with the answer, avoid filler, and format code clearly.';

  /// Parent key used in [selectedChildByParent] for root-level messages.
  static const String rootParentKey = '__root__';

  /// Unique conversation identifier.
  final String id;

  /// User-visible conversation title.
  final String title;

  /// Creation timestamp (UTC).
  final DateTime createdAt;

  /// Last-modified timestamp (UTC).
  final DateTime updatedAt;

  /// Whether this conversation is pinned to the top of the sidebar.
  final bool pinned;

  /// Session-level system prompt.
  final String systemPrompt;

  /// Active [StudioPreset.id] associated with this session, if any.
  final String? presetId;

  /// Optional JSON Schema string enforcing structured JSON replies.
  final String? jsonSchema;

  /// Complete set of message nodes across all branches in chronological order.
  final List<StudioMessage> nodes;

  /// Selected child message ID per parent key ([rootParentKey] for roots).
  final Map<String, String> selectedChildByParent;

  /// Creates an empty conversation initialized from an optional [preset].
  factory StudioConversation.create({
    required String id,
    DateTime? now,
    StudioPreset? preset,
    String title = 'New session',
  }) {
    final timestamp = (now ?? DateTime.now()).toUtc();
    final effectivePreset = preset ?? StudioPreset.builtInPresets.first;
    return StudioConversation(
      id: id,
      title: title,
      createdAt: timestamp,
      updatedAt: timestamp,
      systemPrompt: effectivePreset.systemPrompt,
      presetId: effectivePreset.id,
      jsonSchema: effectivePreset.jsonSchema,
    );
  }

  /// Linear sequence of messages along the currently selected branch.
  List<StudioMessage> get activeBranch {
    if (nodes.isEmpty) {
      return const <StudioMessage>[];
    }
    final byId = <String, StudioMessage>{
      for (final node in nodes) node.id: node,
    };
    final childrenByParent = <String, List<StudioMessage>>{};
    for (final node in nodes) {
      final key = node.parentId ?? rootParentKey;
      (childrenByParent[key] ??= <StudioMessage>[]).add(node);
    }

    final branch = <StudioMessage>[];
    final visited = <String>{};
    var parentKey = rootParentKey;

    while (true) {
      final children = childrenByParent[parentKey];
      if (children == null || children.isEmpty) {
        break;
      }
      final preferredId = selectedChildByParent[parentKey];
      final chosen = preferredId != null && byId[preferredId] != null
          ? children.firstWhere(
              (child) => child.id == preferredId,
              orElse: () => children.last,
            )
          : children.last;
      if (!visited.add(chosen.id)) {
        break;
      }
      branch.add(chosen);
      parentKey = chosen.id;
    }

    return List<StudioMessage>.unmodifiable(branch);
  }

  /// Returns all sibling message IDs sharing the same parent as [messageId].
  List<String> siblingIdsOf(String messageId) {
    final target = findNode(messageId);
    if (target == null) {
      return const <String>[];
    }
    final parentId = target.parentId;
    return nodes
        .where((node) => node.parentId == parentId)
        .map((node) => node.id)
        .toList(growable: false);
  }

  /// Looks up a [StudioMessage] node by [messageId], or `null` if missing.
  StudioMessage? findNode(String messageId) {
    for (final node in nodes) {
      if (node.id == messageId) {
        return node;
      }
    }
    return null;
  }

  /// Returns active branch messages strictly preceding [messageId].
  List<StudioMessage> prefixBefore(String messageId) {
    final target = findNode(messageId);
    if (target == null) {
      return activeBranch;
    }
    final byId = <String, StudioMessage>{
      for (final node in nodes) node.id: node,
    };
    final reversed = <StudioMessage>[];
    var cursor = target.parentId;
    final visited = <String>{};
    while (cursor != null && visited.add(cursor)) {
      final ancestor = byId[cursor];
      if (ancestor == null) {
        break;
      }
      reversed.add(ancestor);
      cursor = ancestor.parentId;
    }
    return reversed.reversed.toList(growable: false);
  }

  /// Appends [message] to the tail of [activeBranch] and selects it.
  StudioConversation appendToActiveBranch(
    StudioMessage message, {
    DateTime? now,
  }) {
    final branch = activeBranch;
    final parentId = branch.isEmpty ? null : branch.last.id;
    return appendChild(parentId: parentId, message: message, now: now);
  }

  /// Appends [message] under [parentId] (creating a sibling branch when
  /// [parentId] already has children) and marks [message] as active.
  StudioConversation appendChild({
    required String? parentId,
    required StudioMessage message,
    DateTime? now,
  }) {
    final linked = message.copyWith(parentId: parentId);
    final parentKey = parentId ?? rootParentKey;
    final nextSelected = <String, String>{
      ...selectedChildByParent,
      parentKey: linked.id,
    };
    final autoTitle = _deriveTitleIfDefault(linked);
    return copyWith(
      title: autoTitle,
      updatedAt: (now ?? linked.createdAt).toUtc(),
      nodes: <StudioMessage>[...nodes, linked],
      selectedChildByParent: nextSelected,
    );
  }

  /// Replaces a node in [nodes] matching [messageId] with [updater].
  StudioConversation updateNode(
    String messageId,
    StudioMessage Function(StudioMessage existing) updater, {
    DateTime? now,
  }) {
    var changed = false;
    final updatedNodes = nodes
        .map((node) {
          if (node.id != messageId) {
            return node;
          }
          changed = true;
          return updater(node);
        })
        .toList(growable: false);
    if (!changed) {
      return this;
    }
    return copyWith(
      nodes: updatedNodes,
      updatedAt: (now ?? DateTime.now()).toUtc(),
    );
  }

  /// Switches the active sibling branch to [messageId].
  StudioConversation selectBranch(String messageId) {
    final target = findNode(messageId);
    if (target == null) {
      return this;
    }
    final parentKey = target.parentId ?? rootParentKey;
    return copyWith(
      selectedChildByParent: <String, String>{
        ...selectedChildByParent,
        parentKey: target.id,
      },
    );
  }

  /// Preview snippet for the sidebar conversation list.
  String get previewSnippet {
    final branch = activeBranch;
    if (branch.isEmpty) {
      return 'No messages yet';
    }
    final last = branch.last.text.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (last.isEmpty) {
      return branch.last.attachments.isNotEmpty
          ? 'Attached ${branch.last.attachments.first.name}'
          : 'Thinking...';
    }
    return last.length <= 72 ? last : '${last.substring(0, 72)}...';
  }

  /// Whether [query] matches the conversation title or any message text.
  bool matchesQuery(String query) {
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) {
      return true;
    }
    if (title.toLowerCase().contains(normalized)) {
      return true;
    }
    for (final node in nodes) {
      if (node.text.toLowerCase().contains(normalized)) {
        return true;
      }
    }
    return false;
  }

  String _deriveTitleIfDefault(StudioMessage added) {
    final isDefault = title == 'New session' || title.trim().isEmpty;
    if (!isDefault || added.role != StudioRole.user) {
      return title;
    }
    final cleaned = added.text.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (cleaned.isEmpty) {
      if (added.attachments.isNotEmpty) {
        return added.attachments.first.name;
      }
      return title;
    }
    return cleaned.length <= 42 ? cleaned : '${cleaned.substring(0, 42)}...';
  }

  /// Returns a copy with selectively updated fields.
  StudioConversation copyWith({
    String? id,
    String? title,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool? pinned,
    String? systemPrompt,
    String? presetId,
    bool clearPresetId = false,
    String? jsonSchema,
    bool clearJsonSchema = false,
    List<StudioMessage>? nodes,
    Map<String, String>? selectedChildByParent,
  }) {
    return StudioConversation(
      id: id ?? this.id,
      title: title ?? this.title,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      pinned: pinned ?? this.pinned,
      systemPrompt: systemPrompt ?? this.systemPrompt,
      presetId: clearPresetId ? null : (presetId ?? this.presetId),
      jsonSchema: clearJsonSchema ? null : (jsonSchema ?? this.jsonSchema),
      nodes: nodes ?? this.nodes,
      selectedChildByParent:
          selectedChildByParent ?? this.selectedChildByParent,
    );
  }

  /// Serializes this conversation and all message branches to JSON.
  Map<String, Object?> toJson({bool includeInlineAttachmentBytes = true}) {
    return <String, Object?>{
      'schemaVersion': 1,
      'id': id,
      'title': title,
      'createdAt': createdAt.toUtc().toIso8601String(),
      'updatedAt': updatedAt.toUtc().toIso8601String(),
      'pinned': pinned,
      'systemPrompt': systemPrompt,
      if (presetId != null) 'presetId': presetId,
      if (jsonSchema != null) 'jsonSchema': jsonSchema,
      'nodes': nodes
          .map(
            (node) => node.toJson(
              includeInlineAttachmentBytes: includeInlineAttachmentBytes,
            ),
          )
          .toList(growable: false),
      'selectedChildByParent': selectedChildByParent,
    };
  }

  /// Restores a [StudioConversation] from JSON.
  factory StudioConversation.fromJson(Map<String, Object?> json) {
    final rawNodes = json['nodes'];
    final nodes = rawNodes is List
        ? rawNodes
              .whereType<Map<Object?, Object?>>()
              .map(
                (entry) =>
                    StudioMessage.fromJson(Map<String, Object?>.from(entry)),
              )
              .toList(growable: false)
        : const <StudioMessage>[];
    final rawSelected = json['selectedChildByParent'];
    final selected = rawSelected is Map
        ? <String, String>{
            for (final MapEntry(:key, :value) in rawSelected.entries)
              if (key is String && value is String) key: value,
          }
        : const <String, String>{};
    final now = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    return StudioConversation(
      id: (json['id'] as String?) ?? 'conv',
      title: (json['title'] as String?) ?? 'Untitled session',
      createdAt:
          DateTime.tryParse((json['createdAt'] as String?) ?? '')?.toUtc() ??
          now,
      updatedAt:
          DateTime.tryParse((json['updatedAt'] as String?) ?? '')?.toUtc() ??
          now,
      pinned: (json['pinned'] as bool?) ?? false,
      systemPrompt: (json['systemPrompt'] as String?) ?? defaultSystemPrompt,
      presetId: json['presetId'] as String?,
      jsonSchema: json['jsonSchema'] as String?,
      nodes: nodes,
      selectedChildByParent: selected,
    );
  }
}
