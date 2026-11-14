import 'dart:async';

import 'package:llamadart/llamadart.dart';
import 'package:meta/meta.dart';

import '../../domain/studio_conversation.dart';
import '../../domain/studio_message.dart';
import '../../domain/studio_preset.dart';
import '../../ports/conversation_store.dart';
import '../../ports/inference_port.dart';
import '../../ports/studio_context_ports.dart';
import '../../reactive/state_store.dart';
import '../../services/conversation_codec.dart';

part 'chat_workspace_state.dart';

/// Manages durable chat sessions, non-destructive message branching/editing,
/// multimodal attachments, prompt presets, export/import, and isolated 60fps
/// streaming turns.
class ChatWorkspaceController {
  /// Creates a [ChatWorkspaceController].
  ChatWorkspaceController({
    required StudioConversationStore conversationStore,
    required StudioInferencePort inferencePort,
    required StudioSettingsWriter shellController,
    StudioMcpToolProvider? mcpManager,
    StudioSkillContextProvider? skillRegistry,
    Future<bool> Function()? ensureModelReady,
    String? Function()? workspaceInstructionsProvider,
  }) : _conversations = conversationStore,
       _inference = inferencePort,
       _shell = shellController,
       _mcp = mcpManager,
       _skills = skillRegistry,
       _ensureModelReady = ensureModelReady,
       _workspaceInstructionsProvider = workspaceInstructionsProvider;

  final StudioConversationStore _conversations;
  final StudioInferencePort _inference;
  final StudioSettingsWriter _shell;
  final StudioMcpToolProvider? _mcp;
  final StudioSkillContextProvider? _skills;
  final Future<bool> Function()? _ensureModelReady;
  final String? Function()? _workspaceInstructionsProvider;

  final StateStore<ChatWorkspaceState> _store = StateStore<ChatWorkspaceState>(
    const ChatWorkspaceState(),
  );
  final StateStore<ActiveTurnStreamState> _activeStreamStore =
      StateStore<ActiveTurnStreamState>(ActiveTurnStreamState.idle);

  /// Maximum `AGENTS.md` characters injected when `includeWorkspaceContextInChat` is enabled.
  static const int maxChatWorkspaceContextChars = 3600;

  static const Duration _streamPublishInterval = Duration(milliseconds: 40);

  int _idCounter = 0;
  int _turnEpoch = 0;
  bool _awaitingModel = false;
  final Set<String> _deletedConversationIds = <String>{};
  Timer? _streamFlushTimer;
  ActiveTurnStreamState? _pendingStreamState;
  DateTime? _lastStreamEmitAt;

  /// Structural conversation/composer store.
  ReadOnlyStore<ChatWorkspaceState> get store => _store;

  /// Current structural state snapshot.
  ChatWorkspaceState get state => _store.state;

  /// High-frequency streaming store subscribed ONLY by the active turn widget.
  ReadOnlyStore<ActiveTurnStreamState> get activeStreamStore =>
      _activeStreamStore;

  /// Loads persisted conversations or seeds an initial empty conversation.
  Future<void> initialize() async {
    final loaded = await _conversations.loadAll();
    if (loaded.isEmpty) {
      final initial = _buildNewConversation();
      await _conversations.save(initial);
      _store.set(
        ChatWorkspaceState(
          conversations: <StudioConversation>[initial],
          activeConversationId: initial.id,
        ),
      );
      return;
    }
    _store.set(
      ChatWorkspaceState(
        conversations: loaded,
        activeConversationId: loaded.first.id,
      ),
    );
  }

  /// Creates and selects a new conversation, optionally applying [preset].
  Future<StudioConversation> createConversation({StudioPreset? preset}) async {
    final chosen = preset ?? _presetById(_store.state.activePresetId);
    final created = _buildNewConversation(preset: chosen);
    await _conversations.save(created);
    _store.update(
      (ChatWorkspaceState s) => s.copyWith(
        conversations: <StudioConversation>[created, ...s.conversations],
        activeConversationId: created.id,
        activePresetId: chosen.id,
        pendingAttachments: const <StudioAttachment>[],
        clearLastTurnError: true,
        clearStructuredJsonValid: true,
      ),
    );
    return created;
  }

  /// Selects an existing conversation by [conversationId].
  void selectConversation(String conversationId) {
    _store.update(
      (ChatWorkspaceState s) => s.copyWith(
        activeConversationId: conversationId,
        pendingAttachments: const <StudioAttachment>[],
        clearLastTurnError: true,
      ),
    );
  }

  /// Updates sidebar search filter text.
  void setSearchQuery(String query) {
    _store.update((ChatWorkspaceState s) => s.copyWith(searchQuery: query));
  }

  /// Renames a conversation.
  Future<void> renameConversation(String conversationId, String title) async {
    final trimmed = title.trim();
    if (trimmed.isEmpty) {
      return;
    }
    await _mutateConversation(
      conversationId,
      (StudioConversation c) =>
          c.copyWith(title: trimmed, updatedAt: DateTime.now()),
    );
  }

  /// Pins or unpins a conversation.
  Future<void> togglePinConversation(String conversationId) async {
    await _mutateConversation(
      conversationId,
      (StudioConversation c) => c.copyWith(pinned: !c.pinned),
    );
  }

  /// Deletes a conversation (creating a fresh one if it was the last).
  Future<void> deleteConversation(String conversationId) async {
    _deletedConversationIds.add(conversationId);
    try {
      await _conversations.delete(conversationId);
    } catch (_) {
      _deletedConversationIds.remove(conversationId);
      rethrow;
    }
    final remaining = _store.state.conversations
        .where((StudioConversation c) => c.id != conversationId)
        .toList();
    if (remaining.isEmpty) {
      final fresh = _buildNewConversation();
      await _conversations.save(fresh);
      _store.update(
        (ChatWorkspaceState s) => s.copyWith(
          conversations: <StudioConversation>[fresh],
          activeConversationId: fresh.id,
        ),
      );
      return;
    }
    final nextActive = _store.state.activeConversationId == conversationId
        ? remaining.first.id
        : _store.state.activeConversationId;
    _store.update(
      (ChatWorkspaceState s) => s.copyWith(
        conversations: remaining,
        activeConversationId: nextActive,
      ),
    );
  }

  /// Applies a [StudioPreset] to the active conversation and tuning settings.
  Future<void> applyPreset(StudioPreset preset) async {
    _store.update(
      (ChatWorkspaceState s) => s.copyWith(activePresetId: preset.id),
    );
    final active = _store.state.activeConversation;
    if (active != null) {
      await _mutateConversation(
        active.id,
        (StudioConversation c) => c.copyWith(
          presetId: preset.id,
          systemPrompt: preset.systemPrompt,
          jsonSchema: preset.jsonSchema,
          clearJsonSchema: preset.jsonSchema == null,
          updatedAt: DateTime.now(),
        ),
      );
    }
    await _shell.updateSettings(
      (s) => s.copyWith(
        temperature: preset.temperature,
        thinkingEnabled: preset.thinkingEnabled,
        toolsEnabled: preset.toolsEnabled,
      ),
    );
  }

  /// Updates the active conversation's custom system prompt or JSON Schema.
  Future<void> updateActivePromptConfig({
    String? systemPrompt,
    String? jsonSchema,
    bool clearJsonSchema = false,
  }) async {
    final active = _store.state.activeConversation;
    if (active == null) {
      return;
    }
    await _mutateConversation(
      active.id,
      (StudioConversation c) => c.copyWith(
        systemPrompt: systemPrompt ?? c.systemPrompt,
        jsonSchema: jsonSchema,
        clearJsonSchema: clearJsonSchema,
        updatedAt: DateTime.now(),
      ),
    );
  }

  /// Stages an image or audio attachment in the composer.
  void addPendingAttachment(StudioAttachment attachment) {
    _store.update(
      (ChatWorkspaceState s) => s.copyWith(
        pendingAttachments: <StudioAttachment>[
          ...s.pendingAttachments,
          attachment,
        ],
      ),
    );
  }

  /// Removes a staged composer attachment by [attachmentId].
  void removePendingAttachment(String attachmentId) {
    _store.update(
      (ChatWorkspaceState s) => s.copyWith(
        pendingAttachments: s.pendingAttachments
            .where((StudioAttachment a) => a.id != attachmentId)
            .toList(growable: false),
      ),
    );
  }

  /// Stages or clears a draft prompt in the Chat composer (used when sending
  /// Semantic Vault notes or MCP resources into Chat).
  void setComposerDraft(String? draft) {
    _store.update(
      (ChatWorkspaceState s) => draft == null || draft.isEmpty
          ? s.copyWith(clearComposerDraft: true)
          : s.copyWith(composerDraft: draft),
    );
  }

  /// Switches the active branch at [messageId] (`< 1 / 2 >` sibling selector).
  Future<void> selectSiblingBranch(String messageId) async {
    final active = _store.state.activeConversation;
    if (active == null) {
      return;
    }
    await _mutateConversation(
      active.id,
      (StudioConversation c) => c.selectBranch(messageId),
    );
  }

  /// Sends a new user message on the active conversation branch and streams
  /// the assistant response.
  Future<void> sendMessage(String rawText) async {
    if (_activeStreamStore.state.isGenerating) {
      return;
    }
    final text = rawText.trim();
    final staged = _store.state.pendingAttachments;
    if (text.isEmpty && staged.isEmpty) {
      return;
    }

    final active =
        _store.state.activeConversation ?? await createConversation();
    final branch = active.activeBranch;
    final parentId = branch.isEmpty ? null : branch.last.id;

    final persistedAttachments = <StudioAttachment>[];
    for (final att in staged) {
      persistedAttachments.add(
        await _conversations.persistAttachment(
          conversationId: active.id,
          attachment: att,
        ),
      );
    }

    final userMsg = StudioMessage(
      id: _nextId('usr'),
      parentId: parentId,
      role: StudioRole.user,
      text: text,
      attachments: persistedAttachments,
      createdAt: DateTime.now(),
    );

    var updatedConv = active.appendChild(parentId: parentId, message: userMsg);
    if (branch.isEmpty && text.isNotEmpty) {
      updatedConv = updatedConv.copyWith(title: _deriveTitle(text));
    }
    await _saveAndPublish(
      updatedConv,
      clearAttachments: true,
      clearErrors: true,
    );

    await _executeAssistantTurn(updatedConv, parentUserMessage: userMsg);
  }

  /// Non-destructively edits an existing user message by creating a sibling
  /// branch from its `parentId` and generating a fresh assistant response.
  Future<void> editUserMessageAndBranch({
    required String originalMessageId,
    required String editedText,
  }) async {
    if (_activeStreamStore.state.isGenerating) {
      return;
    }
    final active = _store.state.activeConversation;
    if (active == null) {
      return;
    }
    final original = active.findNode(originalMessageId);
    if (original == null || original.role != StudioRole.user) {
      return;
    }

    final branchedUser = StudioMessage(
      id: _nextId('usr'),
      parentId: original.parentId,
      role: StudioRole.user,
      text: editedText.trim(),
      attachments: original.attachments,
      createdAt: DateTime.now(),
    );
    final updatedConv = active.appendChild(
      parentId: original.parentId,
      message: branchedUser,
    );
    await _saveAndPublish(updatedConv, clearErrors: true);
    await _executeAssistantTurn(updatedConv, parentUserMessage: branchedUser);
  }

  /// Non-destructively regenerates an assistant message as a new sibling branch
  /// under the same user prompt.
  Future<void> regenerateAssistantMessage(String assistantMessageId) async {
    if (_activeStreamStore.state.isGenerating) {
      return;
    }
    final active = _store.state.activeConversation;
    if (active == null) {
      return;
    }
    final target = active.findNode(assistantMessageId);
    final targetParentId = target?.parentId;
    if (target == null || targetParentId == null) {
      return;
    }
    final parentUser = active.findNode(targetParentId);
    if (parentUser == null) {
      return;
    }

    // Ensure the branch up to parentUser is selected, then stream a new child.
    final aligned = active.selectBranch(parentUser.id);
    await _saveAndPublish(aligned, clearErrors: true);
    await _executeAssistantTurn(aligned, parentUserMessage: parentUser);
  }

  /// Stops the active streaming generation, keeping any partial output.
  void stopGeneration() {
    _inference.cancelGeneration();
    if (_awaitingModel) {
      _turnEpoch++;
      _awaitingModel = false;
      _resetStreamThrottle();
      _activeStreamStore.set(ActiveTurnStreamState.idle);
    }
  }

  /// Exports the active conversation to Markdown.
  String exportActiveAsMarkdown() {
    final active = _store.state.activeConversation;
    if (active == null) {
      return '';
    }
    return const StudioConversationCodec().encodeMarkdown(active);
  }

  /// Exports the active conversation tree to pretty JSON.
  Future<String> exportActiveAsJson() async {
    final active = _store.state.activeConversation;
    if (active == null) {
      return '{}';
    }
    final nodes = <StudioMessage>[];
    for (final node in active.nodes) {
      final attachments = <StudioAttachment>[];
      for (final attachment in node.attachments) {
        final bytes = await _conversations.readAttachmentBytes(attachment);
        attachments.add(
          StudioAttachment(
            id: attachment.id,
            kind: attachment.kind,
            name: attachment.name,
            mimeType: attachment.mimeType,
            bytes: bytes,
            sizeBytes: bytes?.length,
          ),
        );
      }
      nodes.add(node.copyWith(attachments: attachments));
    }
    return const StudioConversationCodec().encodeJson(
      active.copyWith(nodes: nodes),
    );
  }

  /// Imports a JSON-encoded conversation into the workspace.
  Future<StudioConversation> importFromJson(String jsonSource) async {
    final parsed = const StudioConversationCodec().decodeJson(jsonSource);
    final importedId = _nextId('conv');
    final nodes = <StudioMessage>[];
    for (final node in parsed.nodes) {
      final attachments = <StudioAttachment>[];
      for (final attachment in node.attachments) {
        attachments.add(
          await _conversations.persistAttachment(
            conversationId: importedId,
            attachment: attachment,
          ),
        );
      }
      nodes.add(node.copyWith(attachments: attachments));
    }
    final imported = parsed.copyWith(
      id: importedId,
      nodes: nodes,
      updatedAt: DateTime.now(),
    );
    await _conversations.save(imported);
    _store.update(
      (ChatWorkspaceState s) => s.copyWith(
        conversations: <StudioConversation>[imported, ...s.conversations],
        activeConversationId: imported.id,
      ),
    );
    return imported;
  }

  Future<void> _executeAssistantTurn(
    StudioConversation conversation, {
    required StudioMessage parentUserMessage,
  }) async {
    final turnEpoch = ++_turnEpoch;
    final historyUpToUser = <StudioMessage>[];
    for (final msg in conversation.activeBranch) {
      historyUpToUser.add(msg);
      if (msg.id == parentUserMessage.id) {
        break;
      }
    }

    final turnWatch = Stopwatch()..start();
    final textBuf = StringBuffer();
    final thinkingBuf = StringBuffer();
    final toolCalls = <StudioToolInvocation>[];
    var tokens = 0;
    StudioTurnResult? finalResult;

    final needsAutoLoad =
        !_inference.runtimeStore.state.isReady && _ensureModelReady != null;
    _activeStreamStore.set(
      ActiveTurnStreamState(
        isGenerating: true,
        conversationId: conversation.id,
        parentMessageId: parentUserMessage.id,
        statusLabel: needsAutoLoad ? 'Loading local model...' : null,
      ),
    );

    try {
      if (needsAutoLoad) {
        _awaitingModel = true;
        await _ensureModelReady();
        if (turnEpoch != _turnEpoch) {
          return;
        }
        _awaitingModel = false;
        _activeStreamStore.set(
          ActiveTurnStreamState(
            isGenerating: true,
            conversationId: conversation.id,
            parentMessageId: parentUserMessage.id,
          ),
        );
      }

      final settings = _shell.currentSettings;
      final extraSkills = _skills?.buildActiveSkillsSystemContext() ?? '';
      var workspaceNotes = settings.includeWorkspaceContextInChat
          ? (_workspaceInstructionsProvider?.call()?.trim() ?? '')
          : '';
      if (workspaceNotes.length > maxChatWorkspaceContextChars) {
        workspaceNotes =
            '${workspaceNotes.substring(0, maxChatWorkspaceContextChars).trimRight()}\n\n'
            '[... workspace instructions truncated for fast Chat prompt evaluation ...]';
      }
      final combinedContext = <String>[
        if (workspaceNotes.isNotEmpty) workspaceNotes,
        if (extraSkills.isNotEmpty) extraSkills,
      ].join('\n\n');
      final extraMcpTools = settings.enableMcpInChat
          ? (_mcp?.buildActiveToolDefinitions() ?? const <ToolDefinition>[])
          : const <ToolDefinition>[];
      final stream = _inference.streamTurn(
        StudioTurnRequest(
          history: historyUpToUser,
          settings: settings,
          systemPrompt: conversation.systemPrompt,
          extraSystemContext: combinedContext,
          jsonSchema: conversation.jsonSchema,
          extraTools: extraMcpTools,
        ),
      );

      final streamDone = Completer<void>();
      var streamFinished = false;
      late final StreamSubscription<StudioTurnEvent> streamSub;
      streamSub = stream.listen(
        (StudioTurnEvent event) {
          switch (event) {
            case StudioTextDeltaEvent(:final delta):
              textBuf.write(delta);
              tokens++;
              _publishStream(
                conversationId: conversation.id,
                parentMessageId: parentUserMessage.id,
                text: textBuf.toString(),
                thinkingText: thinkingBuf.toString(),
                toolCalls: toolCalls,
                tokens: tokens,
                elapsedMs: turnWatch.elapsedMilliseconds,
              );
            case StudioThinkingDeltaEvent(:final delta):
              thinkingBuf.write(delta);
              tokens++;
              _publishStream(
                conversationId: conversation.id,
                parentMessageId: parentUserMessage.id,
                text: textBuf.toString(),
                thinkingText: thinkingBuf.toString(),
                toolCalls: toolCalls,
                tokens: tokens,
                elapsedMs: turnWatch.elapsedMilliseconds,
              );
            case StudioToolInvocationEvent(:final invocation):
              final existingIdx = toolCalls.indexWhere(
                (StudioToolInvocation item) => item.id == invocation.id,
              );
              if (existingIdx >= 0) {
                toolCalls[existingIdx] = invocation;
              } else {
                toolCalls.add(invocation);
              }
              _publishStream(
                conversationId: conversation.id,
                parentMessageId: parentUserMessage.id,
                text: textBuf.toString(),
                thinkingText: thinkingBuf.toString(),
                toolCalls: toolCalls,
                tokens: tokens,
                elapsedMs: turnWatch.elapsedMilliseconds,
                immediate: true,
              );
            case StudioTurnCompletedEvent(:final result):
              finalResult = result;
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          streamFinished = true;
          if (!streamDone.isCompleted) {
            streamDone.completeError(error, stackTrace);
          }
        },
        onDone: () {
          streamFinished = true;
          if (!streamDone.isCompleted) {
            streamDone.complete();
          }
        },
        cancelOnError: true,
      );
      try {
        await streamDone.future;
      } finally {
        if (!streamFinished) {
          await streamSub.cancel();
        }
      }

      turnWatch.stop();
      final assistantMsg = StudioMessage(
        id: _nextId('ast'),
        parentId: parentUserMessage.id,
        role: StudioRole.assistant,
        text: finalResult?.text ?? textBuf.toString(),
        thinkingText:
            finalResult?.thinkingText ??
            (thinkingBuf.isEmpty ? null : thinkingBuf.toString()),
        thinkingDurationMs: finalResult?.thinkingDurationMs,
        toolCalls: finalResult?.toolInvocations ?? toolCalls,
        metrics:
            finalResult?.metrics ??
            StudioTurnMetrics(
              generatedTokens: tokens,
              elapsedMs: turnWatch.elapsedMilliseconds,
              decodeElapsedMs: turnWatch.elapsedMilliseconds,
            ),
        createdAt: DateTime.now(),
      );

      final latestConv = _findConversation(conversation.id);
      if (latestConv == null) {
        return;
      }
      final committed = latestConv.appendChild(
        parentId: parentUserMessage.id,
        message: assistantMsg,
      );
      await _saveAndPublish(
        committed,
        structuredJsonValid: finalResult?.structuredJsonValid,
        lastError: finalResult?.structuredJsonError == null
            ? null
            : _humanizeError(finalResult!.structuredJsonError!),
      );
    } catch (error) {
      if (turnEpoch != _turnEpoch) {
        return;
      }
      turnWatch.stop();
      final partialText = textBuf.toString();
      final cleanError = _humanizeError(error);
      final assistantErrMsg = StudioMessage(
        id: _nextId('ast_err'),
        parentId: parentUserMessage.id,
        role: StudioRole.assistant,
        text: partialText.isNotEmpty ? partialText : cleanError,
        thinkingText: thinkingBuf.isEmpty ? null : thinkingBuf.toString(),
        toolCalls: toolCalls,
        isError: partialText.isEmpty,
        createdAt: DateTime.now(),
      );
      final latestConv = _findConversation(conversation.id);
      if (latestConv == null) {
        return;
      }
      final committed = latestConv.appendChild(
        parentId: parentUserMessage.id,
        message: assistantErrMsg,
      );
      await _saveAndPublish(committed, lastError: cleanError);
    } finally {
      if (turnEpoch == _turnEpoch) {
        _awaitingModel = false;
        _resetStreamThrottle();
        _activeStreamStore.set(ActiveTurnStreamState.idle);
      }
    }
  }

  void _publishStream({
    required String conversationId,
    required String parentMessageId,
    required String text,
    required String thinkingText,
    required List<StudioToolInvocation> toolCalls,
    required int tokens,
    required int elapsedMs,
    bool immediate = false,
  }) {
    final next = ActiveTurnStreamState(
      isGenerating: true,
      conversationId: conversationId,
      parentMessageId: parentMessageId,
      text: text,
      thinkingText: thinkingText,
      toolInvocations: List<StudioToolInvocation>.unmodifiable(toolCalls),
      tokensGenerated: tokens,
      elapsedMs: elapsedMs,
    );
    final now = DateTime.now();
    if (immediate ||
        _lastStreamEmitAt == null ||
        now.difference(_lastStreamEmitAt!) >= _streamPublishInterval) {
      _streamFlushTimer?.cancel();
      _streamFlushTimer = null;
      _pendingStreamState = null;
      _lastStreamEmitAt = now;
      _activeStreamStore.set(next);
      return;
    }
    _pendingStreamState = next;
    _streamFlushTimer ??= Timer(
      _streamPublishInterval - now.difference(_lastStreamEmitAt!),
      () {
        _streamFlushTimer = null;
        final pending = _pendingStreamState;
        _pendingStreamState = null;
        if (pending != null) {
          _lastStreamEmitAt = DateTime.now();
          _activeStreamStore.set(pending);
        }
      },
    );
  }

  void _resetStreamThrottle() {
    _streamFlushTimer?.cancel();
    _streamFlushTimer = null;
    _pendingStreamState = null;
    _lastStreamEmitAt = null;
  }

  static String _humanizeError(Object error) {
    var message = error.toString().trim();
    final prefixPattern = RegExp(
      r'^(Llama[A-Za-z]*Exception|StateError|ArgumentError|FormatException|Exception):\s*',
    );
    while (prefixPattern.hasMatch(message)) {
      message = message.replaceFirst(prefixPattern, '').trim();
    }
    return message.isEmpty ? 'Inference failed unexpectedly.' : message;
  }

  StudioConversation _buildNewConversation({StudioPreset? preset}) {
    final effectivePreset = preset ?? StudioPreset.builtInPresets.first;
    final now = DateTime.now();
    return StudioConversation(
      id: _nextId('conv'),
      title: 'New session',
      createdAt: now,
      updatedAt: now,
      presetId: effectivePreset.id,
      systemPrompt: effectivePreset.systemPrompt,
      jsonSchema: effectivePreset.jsonSchema,
    );
  }

  StudioPreset _presetById(String id) {
    for (final preset in StudioPreset.builtInPresets) {
      if (preset.id == id) {
        return preset;
      }
    }
    return StudioPreset.builtInPresets.first;
  }

  StudioConversation? _findConversation(String id) {
    for (final conv in _store.state.conversations) {
      if (conv.id == id) {
        return conv;
      }
    }
    return null;
  }

  Future<void> _mutateConversation(
    String id,
    StudioConversation Function(StudioConversation current) fn,
  ) async {
    final existing = _findConversation(id);
    if (existing == null) {
      return;
    }
    final updated = fn(existing);
    await _saveAndPublish(updated);
  }

  Future<void> _saveAndPublish(
    StudioConversation updated, {
    bool clearAttachments = false,
    bool clearErrors = false,
    String? lastError,
    bool? structuredJsonValid,
  }) async {
    if (_deletedConversationIds.contains(updated.id)) {
      return;
    }
    await _conversations.save(updated);
    // Deletion can start while the persistence write is in flight.
    if (_deletedConversationIds.contains(updated.id)) {
      await _conversations.delete(updated.id);
      return;
    }
    _store.update((ChatWorkspaceState s) {
      final list = <StudioConversation>[
        updated,
        for (final conv in s.conversations)
          if (conv.id != updated.id) conv,
      ];
      return s.copyWith(
        conversations: list,
        pendingAttachments: clearAttachments
            ? const <StudioAttachment>[]
            : null,
        clearComposerDraft: clearAttachments,
        clearLastTurnError: clearErrors && lastError == null,
        lastTurnError: lastError,
        clearStructuredJsonValid: clearErrors && structuredJsonValid == null,
        lastStructuredJsonValid: structuredJsonValid,
      );
    });
  }

  String _nextId(String prefix) {
    _idCounter++;
    return '${prefix}_${DateTime.now().microsecondsSinceEpoch}_$_idCounter';
  }

  static String _deriveTitle(String firstMessage) {
    final singleLine = firstMessage.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (singleLine.length <= 44) {
      return singleLine;
    }
    return '${singleLine.substring(0, 41)}...';
  }

  /// Disposes both structural and streaming stores.
  Future<void> dispose() async {
    _resetStreamThrottle();
    await _store.dispose();
    await _activeStreamStore.dispose();
  }
}
