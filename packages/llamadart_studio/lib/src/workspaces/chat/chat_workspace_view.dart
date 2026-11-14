import 'dart:async';

import 'package:file_picker/file_picker.dart';
// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

import '../../app/studio_dependencies.dart';
import '../../app/studio_theme.dart';
import '../../widgets/store_widgets.dart';
import '../../widgets/studio_motion.dart';
import 'message_turn_card.dart';
import 'multimodal_composer.dart';

/// Primary Chat & Multimodal Studio workspace view.
class ChatWorkspaceView extends StatefulWidget {
  /// Creates a [ChatWorkspaceView].
  const ChatWorkspaceView({super.key});

  @override
  State<ChatWorkspaceView> createState() => _ChatWorkspaceViewState();
}

class _ChatWorkspaceViewState extends State<ChatWorkspaceView> {
  final ScrollController _scrollController = ScrollController();

  StudioDependencies? _deps;
  StreamSubscription<ChatWorkspaceState>? _chatSub;
  StreamSubscription<ActiveTurnStreamState>? _streamSub;

  bool _stickToBottom = true;
  bool _showJumpToBottom = false;
  bool _isProgrammaticScroll = false;
  bool _scrollFrameScheduled = false;
  double? _lastMaxScrollExtent;

  String? _lastConversationId;
  int _lastBranchLength = 0;
  bool _wasGenerating = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextDeps = StudioScope.of(context);
    if (identical(_deps, nextDeps)) {
      return;
    }
    _chatSub?.cancel();
    _streamSub?.cancel();
    _deps = nextDeps;

    final initialConv = nextDeps.chatController.state.activeConversation;
    _lastConversationId = initialConv?.id;
    _lastBranchLength = initialConv?.activeBranch.length ?? 0;
    _wasGenerating =
        nextDeps.chatController.activeStreamStore.state.isGenerating;

    _chatSub = nextDeps.chatController.store.stream.listen(_onChatStateChanged);
    _streamSub = nextDeps.chatController.activeStreamStore.stream.listen(
      _onStreamStateChanged,
    );
    _schedulePinToBottom();
  }

  void _onChatStateChanged(ChatWorkspaceState chatState) {
    final conv = chatState.activeConversation;
    final convId = conv?.id;
    final branch = conv?.activeBranch ?? const <StudioMessage>[];

    if (convId != _lastConversationId) {
      _lastConversationId = convId;
      _lastBranchLength = branch.length;
      _lastMaxScrollExtent = null;
      _setStickyState(stick: true, showJump: false);
      _schedulePinToBottom();
      return;
    }

    if (branch.length != _lastBranchLength) {
      final grew = branch.length > _lastBranchLength;
      _lastBranchLength = branch.length;
      if (grew && branch.isNotEmpty && branch.last.role == StudioRole.user) {
        // User just submitted a message or edited a branch: always follow down.
        _setStickyState(stick: true, showJump: false);
        _schedulePinToBottom();
      } else if (_stickToBottom) {
        _schedulePinToBottom();
      }
    }
  }

  void _onStreamStateChanged(ActiveTurnStreamState streamState) {
    final startedGenerating = !_wasGenerating && streamState.isGenerating;
    _wasGenerating = streamState.isGenerating;
    if (startedGenerating) {
      _setStickyState(stick: true, showJump: false);
      _schedulePinToBottom();
      return;
    }
    if (streamState.isGenerating && _stickToBottom) {
      _schedulePinToBottom();
    }
  }

  void _setStickyState({required bool stick, required bool showJump}) {
    _stickToBottom = stick;
    if (_showJumpToBottom != showJump && mounted) {
      setState(() {
        _showJumpToBottom = showJump;
      });
    } else {
      _showJumpToBottom = showJump;
    }
  }

  void _schedulePinToBottom() {
    if (_scrollFrameScheduled || !mounted) {
      return;
    }
    _scrollFrameScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollFrameScheduled = false;
      if (!mounted || !_stickToBottom || !_scrollController.hasClients) {
        return;
      }
      final target = _scrollController.position.maxScrollExtent;
      _lastMaxScrollExtent = target;
      if ((target - _scrollController.offset).abs() > 0.5) {
        _isProgrammaticScroll = true;
        try {
          _scrollController.jumpTo(target);
        } finally {
          _isProgrammaticScroll = false;
        }
      }
    });
  }

  Future<void> _jumpToBottomAnimated() async {
    _setStickyState(stick: true, showJump: false);
    if (!_scrollController.hasClients) {
      return;
    }
    final target = _scrollController.position.maxScrollExtent;
    _isProgrammaticScroll = true;
    try {
      await _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
      );
    } finally {
      _isProgrammaticScroll = false;
    }
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (notification.depth != 0) {
      // Ignore nested scrollables (e.g., _ThinkingDisclosureCard or code blocks).
      return false;
    }
    if (notification is ScrollMetricsNotification) {
      final nextMax = notification.metrics.maxScrollExtent;
      if (_lastMaxScrollExtent != null &&
          (nextMax - _lastMaxScrollExtent!).abs() < 0.5) {
        return false;
      }
      _lastMaxScrollExtent = nextMax;
      if (_stickToBottom &&
          (_deps?.chatController.activeStreamStore.state.isGenerating ??
              false)) {
        _schedulePinToBottom();
      }
      return false;
    }
    if (notification is ScrollUpdateNotification && !_isProgrammaticScroll) {
      final metrics = notification.metrics;
      final distanceFromBottom = (metrics.maxScrollExtent - metrics.pixels)
          .clamp(0.0, double.infinity);
      final nearBottom = distanceFromBottom <= 72.0;
      _setStickyState(stick: nearBottom, showJump: distanceFromBottom > 110.0);
    }
    return false;
  }

  @override
  void dispose() {
    _chatSub?.cancel();
    _streamSub?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final deps = StudioScope.of(context);
    final palette = StudioPalette.of(context);

    return StoreBuilder<ChatWorkspaceState>(
      store: deps.chatController.store,
      builder: (BuildContext context, ChatWorkspaceState chatState) {
        final activeConv = chatState.activeConversation;
        final branch = activeConv?.activeBranch ?? const <StudioMessage>[];
        final topError = chatState.lastTurnError;
        final duplicateInlineError =
            topError != null &&
            branch.isNotEmpty &&
            branch.last.isError &&
            branch.last.text.trim() == topError.trim();

        return Column(
          children: <Widget>[
            if (topError != null && !duplicateInlineError)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                color: palette.danger.withValues(alpha: 0.14),
                child: Row(
                  children: <Widget>[
                    Icon(
                      Icons.error_outline_rounded,
                      size: 16,
                      color: palette.danger,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        topError,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: palette.danger),
                      ),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 880),
                  child: branch.isEmpty
                      ? _EmptyChatHero(
                          conversationId: activeConv?.id,
                          activePresetId: chatState.activePresetId,
                        )
                      : Stack(
                          children: <Widget>[
                            NotificationListener<ScrollNotification>(
                              onNotification: _handleScrollNotification,
                              child: ListView(
                                key: const Key('chat_message_scroll_view'),
                                controller: _scrollController,
                                padding: const EdgeInsets.fromLTRB(
                                  20,
                                  20,
                                  20,
                                  16,
                                ),
                                children: <Widget>[
                                  for (var i = 0; i < branch.length; i++)
                                    MessageTurnCard(
                                      key: ValueKey<String>(branch[i].id),
                                      message: branch[i],
                                      siblingIds:
                                          activeConv?.siblingIdsOf(
                                            branch[i].id,
                                          ) ??
                                          const <String>[],
                                      isLastTurn: i == branch.length - 1,
                                      structuredJsonValid:
                                          chatState.lastStructuredJsonValid,
                                    ),
                                  if (activeConv != null)
                                    ActiveStreamingTurnCard(
                                      conversationId: activeConv.id,
                                    ),
                                ],
                              ),
                            ),
                            if (_showJumpToBottom)
                              Positioned(
                                bottom: 12,
                                left: 0,
                                right: 0,
                                child: Center(
                                  child: Material(
                                    color: palette.surfaceElevated,
                                    elevation: 4,
                                    shadowColor: Colors.black.withValues(
                                      alpha: 0.35,
                                    ),
                                    borderRadius: BorderRadius.circular(999),
                                    child: InkWell(
                                      key: const Key(
                                        'chat_jump_to_bottom_button',
                                      ),
                                      borderRadius: BorderRadius.circular(999),
                                      onTap: _jumpToBottomAnimated,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                          vertical: 6,
                                        ),
                                        decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(
                                            999,
                                          ),
                                          border: Border.all(
                                            color: palette.accent.withValues(
                                              alpha: 0.55,
                                            ),
                                          ),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: <Widget>[
                                            Icon(
                                              Icons.arrow_downward_rounded,
                                              size: 14,
                                              color: palette.accent,
                                            ),
                                            const SizedBox(width: 6),
                                            Text(
                                              'Jump to latest',
                                              style: TextStyle(
                                                fontSize: 11.5,
                                                fontWeight: FontWeight.w600,
                                                color: palette.textPrimary,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                ),
              ),
            ),
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 880),
                child: const Padding(
                  padding: EdgeInsets.fromLTRB(20, 6, 20, 16),
                  child: MultimodalComposer(),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _EmptyChatHero extends StatelessWidget {
  const _EmptyChatHero({
    required this.conversationId,
    required this.activePresetId,
  });

  final String? conversationId;
  final String activePresetId;

  Future<void> _scanLocalFolder(
    BuildContext context,
    StudioDependencies deps,
  ) async {
    if (deps.isWeb) {
      return;
    }
    final picked = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Select Folder Containing .gguf / .litertlm Models',
    );
    if (picked != null && picked.trim().isNotEmpty) {
      await deps.modelHubController.addCustomModelDirectory(picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = StudioPalette.of(context);
    final deps = StudioScope.of(context);

    return StoreBuilder<StudioRuntimeSnapshot>(
      store: deps.modelHubController.runtimeStore,
      builder: (BuildContext context, StudioRuntimeSnapshot runtime) {
        return StoreBuilder<ModelHubState>(
          store: deps.modelHubController.store,
          builder: (BuildContext context, ModelHubState hubState) {
            final installed = deps.modelHubController.installedChatModels();
            final best = deps.modelHubController.bestAutoLoadChatModel();
            final starter =
                CuratedModelCatalog.byId('qwen3.5-0.8b-q4-k-m') ??
                CuratedModelCatalog.forCategory(
                  StudioModelCategory.chat,
                  isWeb: deps.isWeb,
                  isMobile: deps.isMobile,
                ).firstOrNull;
            final starterProgress = starter == null
                ? null
                : hubState.downloadsByModelId[starter.id];
            final starterDownloading = starterProgress?.isActive ?? false;
            final needsFirstModel =
                !runtime.isReady && installed.isEmpty && starter != null;
            final canRunPrompts = runtime.isReady || installed.isNotEmpty;

            return ListView(
              padding: const EdgeInsets.fromLTRB(24, 28, 24, 16),
              children: <Widget>[
                if (!runtime.isReady)
                  Container(
                    key: needsFirstModel
                        ? const Key('chat_starter_setup_card')
                        : const Key('chat_model_ready_card'),
                    margin: const EdgeInsets.only(bottom: 22),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: palette.surfaceElevated,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: palette.accent.withValues(alpha: 0.5),
                      ),
                    ),
                    child: LayoutBuilder(
                      builder: (BuildContext context, BoxConstraints bannerBox) {
                        final stackBanner = bannerBox.maxWidth < 760;
                        final actionButtons = Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          alignment: stackBanner
                              ? WrapAlignment.start
                              : WrapAlignment.end,
                          children: <Widget>[
                            if (needsFirstModel &&
                                !runtime.isLoading &&
                                !starterDownloading)
                              FilledButton.icon(
                                key: const Key('chat_download_starter_button'),
                                onPressed: () => unawaited(
                                  deps.modelHubController.activateChatModel(
                                    starter,
                                  ),
                                ),
                                icon: const Icon(
                                  Icons.download_for_offline_outlined,
                                  size: 16,
                                ),
                                label: Text(
                                  'Download ${starter.name} · ${starter.sizeLabel(isWeb: deps.isWeb)}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              )
                            else if (starterDownloading)
                              OutlinedButton.icon(
                                onPressed: () => deps.modelHubController
                                    .cancelDownload(starter!.id),
                                icon: const Icon(Icons.close_rounded, size: 15),
                                label: const Text('Cancel Download'),
                              )
                            else if (best != null && !runtime.isLoading)
                              FilledButton.icon(
                                key: const Key('hero_quick_load_model_button'),
                                onPressed: () => unawaited(
                                  deps.modelHubController.activateChatModel(
                                    best,
                                  ),
                                ),
                                icon: const Icon(Icons.bolt_rounded, size: 16),
                                label: Text(
                                  'Load ${best.name}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            if (needsFirstModel && !deps.isWeb)
                              OutlinedButton.icon(
                                key: const Key('chat_scan_folder_button'),
                                onPressed: () =>
                                    _scanLocalFolder(context, deps),
                                icon: const Icon(
                                  Icons.folder_open_rounded,
                                  size: 16,
                                ),
                                label: const Text('Scan Folder'),
                              ),
                            FilledButton.tonalIcon(
                              key: const Key('hero_open_model_hub_button'),
                              onPressed: () => deps.shellController
                                  .selectWorkspace(StudioWorkspace.models),
                              icon: const Icon(
                                Icons.arrow_forward_rounded,
                                size: 16,
                              ),
                              label: const Text('Model Hub'),
                            ),
                          ],
                        );

                        final copyBlock = Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              starterDownloading
                                  ? 'Downloading ${starter!.name}...'
                                  : (runtime.isLoading
                                        ? (runtime.statusMessage ??
                                              'Loading local model weights...')
                                        : (installed.isNotEmpty
                                              ? '${installed.length} local chat ${installed.length == 1 ? 'model' : 'models'} ready'
                                              : 'Set Up Your First Local Model')),
                              style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w700,
                                color: palette.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              starterDownloading
                                  ? '${starterProgress?.statusLabel ?? starterProgress?.stage.name ?? 'Downloading'} · ${((starterProgress?.fraction ?? 0.0) * 100).toStringAsFixed(0)}%'
                                  : (installed.isNotEmpty
                                        ? 'Send any message to auto-load ${best?.name ?? 'a cached model'}, or switch models in the top bar.'
                                        : 'Download the compact ${starter?.name ?? 'starter'} (${starter?.sizeLabel(isWeb: deps.isWeb) ?? '~755 MB'}) with vision, tools & reasoning, or scan an existing local model folder.'),
                              style: TextStyle(
                                fontSize: 12,
                                color: palette.textSecondary,
                              ),
                            ),
                            if (starterDownloading) ...<Widget>[
                              const SizedBox(height: 8),
                              LinearProgressIndicator(
                                value: starterProgress?.fraction,
                                minHeight: 5,
                                borderRadius: BorderRadius.circular(999),
                              ),
                            ],
                          ],
                        );

                        if (stackBanner) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Icon(
                                    runtime.isLoading || starterDownloading
                                        ? Icons.downloading_rounded
                                        : Icons.hub_outlined,
                                    color: palette.accent,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(child: copyBlock),
                                ],
                              ),
                              const SizedBox(height: 12),
                              actionButtons,
                            ],
                          );
                        }
                        return Row(
                          children: <Widget>[
                            Icon(
                              runtime.isLoading || starterDownloading
                                  ? Icons.downloading_rounded
                                  : Icons.hub_outlined,
                              color: palette.accent,
                            ),
                            const SizedBox(width: 12),
                            Expanded(child: copyBlock),
                            const SizedBox(width: 12),
                            ConstrainedBox(
                              constraints: BoxConstraints(
                                maxWidth: bannerBox.maxWidth * 0.5,
                              ),
                              child: actionButtons,
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                FadeSlideEntry(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'Local Multimodal Intelligence',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.4,
                          color: palette.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        canRunPrompts
                            ? 'Choose a capability preset below or type directly in the composer. Edit any prompt later to branch non-destructively.'
                            : 'Select a capability preset below to pre-configure system instructions & tools, or download a starter model above.',
                        style: TextStyle(
                          fontSize: 13.5,
                          color: palette.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 18),
                      LayoutBuilder(
                        builder: (BuildContext context, BoxConstraints constraints) {
                          final twoCols = constraints.maxWidth >= 540;
                          return Wrap(
                            spacing: 12,
                            runSpacing: 12,
                            children: StudioPreset.builtInPresets.map((
                              StudioPreset preset,
                            ) {
                              final cardWidth = twoCols
                                  ? (constraints.maxWidth - 12) / 2
                                  : constraints.maxWidth;
                              final selected = preset.id == activePresetId;
                              return SizedBox(
                                width: cardWidth,
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(14),
                                  onTap: () =>
                                      deps.chatController.applyPreset(preset),
                                  child: Container(
                                    padding: const EdgeInsets.all(14),
                                    decoration: BoxDecoration(
                                      color: selected
                                          ? palette.accentMuted
                                          : palette.surfaceElevated,
                                      borderRadius: BorderRadius.circular(14),
                                      border: Border.all(
                                        color: selected
                                            ? palette.accent
                                            : palette.borderSubtle,
                                      ),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: <Widget>[
                                        Row(
                                          children: <Widget>[
                                            Expanded(
                                              child: Text(
                                                preset.name,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  fontSize: 13.5,
                                                  fontWeight: FontWeight.w700,
                                                  color: palette.textPrimary,
                                                ),
                                              ),
                                            ),
                                            if (preset
                                                .toolsEnabled) ...<Widget>[
                                              const SizedBox(width: 6),
                                              StudioPillBadge(
                                                label: 'Tools',
                                                foreground: palette.teal,
                                              ),
                                            ],
                                            if (preset.jsonSchema !=
                                                null) ...<Widget>[
                                              const SizedBox(width: 6),
                                              StudioPillBadge(
                                                label: 'JSON',
                                                foreground: palette.accent,
                                                monospace: true,
                                              ),
                                            ],
                                          ],
                                        ),
                                        const SizedBox(height: 5),
                                        Text(
                                          preset.description,
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: palette.textSecondary,
                                          ),
                                        ),
                                        if (preset.starterPrompt !=
                                            null) ...<Widget>[
                                          const SizedBox(height: 10),
                                          Align(
                                            alignment: Alignment.centerRight,
                                            child: TextButton.icon(
                                              style: TextButton.styleFrom(
                                                visualDensity:
                                                    VisualDensity.compact,
                                              ),
                                              onPressed: canRunPrompts
                                                  ? () async {
                                                      await deps.chatController
                                                          .applyPreset(preset);
                                                      await deps.chatController
                                                          .sendMessage(
                                                            preset
                                                                .starterPrompt!,
                                                          );
                                                    }
                                                  : null,
                                              icon: Icon(
                                                canRunPrompts
                                                    ? Icons.play_arrow_rounded
                                                    : Icons.lock_clock_outlined,
                                                size: 15,
                                              ),
                                              label: Text(
                                                canRunPrompts
                                                    ? 'Run starter prompt'
                                                    : 'Download model to run',
                                                style: const TextStyle(
                                                  fontSize: 11.5,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            }).toList(),
                          );
                        },
                      ),
                      if (conversationId != null) ...<Widget>[
                        const SizedBox(height: 16),
                        ActiveStreamingTurnCard(
                          conversationId: conversationId!,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
