part of 'chat_workspace_controller.dart';

/// Isolated high-frequency state emitted at token-streaming cadence so only the
/// active assistant message bubble rebuilds at 60fps.
@immutable
class ActiveTurnStreamState {
  /// Creates an [ActiveTurnStreamState].
  const ActiveTurnStreamState({
    this.isGenerating = false,
    this.conversationId,
    this.parentMessageId,
    this.text = '',
    this.thinkingText = '',
    this.toolInvocations = const <StudioToolInvocation>[],
    this.tokensGenerated = 0,
    this.elapsedMs = 0,
    this.statusLabel,
  });

  /// Idle constant state.
  static const ActiveTurnStreamState idle = ActiveTurnStreamState();

  /// Whether a generation stream is currently active.
  final bool isGenerating;

  /// Conversation receiving the active turn.
  final String? conversationId;

  /// Parent user message ID of the streaming assistant turn.
  final String? parentMessageId;

  /// Accumulated assistant text so far.
  final String text;

  /// Accumulated reasoning/thinking text so far.
  final String thinkingText;

  /// Live tool calls and results during this turn.
  final List<StudioToolInvocation> toolInvocations;

  /// Live token counter.
  final int tokensGenerated;

  /// Elapsed milliseconds since turn started.
  final int elapsedMs;

  /// Optional status label while warming up / loading a model before first token.
  final String? statusLabel;

  /// Live throughput estimate in tokens/sec.
  double get liveTokensPerSecond =>
      elapsedMs <= 0 ? 0 : (tokensGenerated * 1000.0) / elapsedMs;
}

/// Structural state for the Chat workspace (conversations, search, attachments,
/// presets)—kept separate from [ActiveTurnStreamState] for zero-jank UI.
@immutable
class ChatWorkspaceState {
  /// Creates a [ChatWorkspaceState].
  const ChatWorkspaceState({
    this.conversations = const <StudioConversation>[],
    this.activeConversationId,
    this.searchQuery = '',
    this.pendingAttachments = const <StudioAttachment>[],
    this.composerDraft,
    this.activePresetId = 'general_assistant',
    this.lastTurnError,
    this.lastStructuredJsonValid,
  });

  /// Saved conversations ordered by `updatedAt` descending.
  final List<StudioConversation> conversations;

  /// Currently open conversation ID.
  final String? activeConversationId;

  /// Sidebar conversation search query.
  final String searchQuery;

  /// Staged image/audio attachments in the composer.
  final List<StudioAttachment> pendingAttachments;

  /// Optional staged prompt text seeded from Notes/Coding/MCP workflows.
  final String? composerDraft;

  /// Selected built-in [StudioPreset] ID.
  final String activePresetId;

  /// Optional error banner from the most recent turn.
  final String? lastTurnError;

  /// Schema validation outcome from the most recent JSON-schema turn.
  final bool? lastStructuredJsonValid;

  /// Currently active [StudioConversation], or `null`.
  StudioConversation? get activeConversation {
    final target = activeConversationId;
    if (target == null) {
      return conversations.firstOrNull;
    }
    for (final conv in conversations) {
      if (conv.id == target) {
        return conv;
      }
    }
    return conversations.firstOrNull;
  }

  /// Filtered conversation list matching [searchQuery] (pinned first).
  List<StudioConversation> get filteredConversations {
    final matched = conversations
        .where((StudioConversation c) => c.matchesQuery(searchQuery))
        .toList();
    matched.sort((StudioConversation a, StudioConversation b) {
      if (a.pinned != b.pinned) {
        return a.pinned ? -1 : 1;
      }
      return b.updatedAt.compareTo(a.updatedAt);
    });
    return matched;
  }

  /// Returns an updated copy of [ChatWorkspaceState].
  ChatWorkspaceState copyWith({
    List<StudioConversation>? conversations,
    String? activeConversationId,
    bool clearActiveConversationId = false,
    String? searchQuery,
    List<StudioAttachment>? pendingAttachments,
    String? composerDraft,
    bool clearComposerDraft = false,
    String? activePresetId,
    String? lastTurnError,
    bool clearLastTurnError = false,
    bool? lastStructuredJsonValid,
    bool clearStructuredJsonValid = false,
  }) {
    return ChatWorkspaceState(
      conversations: conversations ?? this.conversations,
      activeConversationId: clearActiveConversationId
          ? null
          : (activeConversationId ?? this.activeConversationId),
      searchQuery: searchQuery ?? this.searchQuery,
      pendingAttachments: pendingAttachments ?? this.pendingAttachments,
      composerDraft: clearComposerDraft
          ? null
          : (composerDraft ?? this.composerDraft),
      activePresetId: activePresetId ?? this.activePresetId,
      lastTurnError: clearLastTurnError
          ? null
          : (lastTurnError ?? this.lastTurnError),
      lastStructuredJsonValid: clearStructuredJsonValid
          ? null
          : (lastStructuredJsonValid ?? this.lastStructuredJsonValid),
    );
  }
}
