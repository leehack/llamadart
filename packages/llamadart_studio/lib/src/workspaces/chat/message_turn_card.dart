// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

import '../../app/platform_file_helper.dart';
import '../../app/studio_dependencies.dart';
import '../../app/studio_theme.dart';
import '../../widgets/code_syntax_highlighter.dart';
import '../../widgets/store_widgets.dart';
import '../../widgets/studio_motion.dart';

part 'message_turn_widgets.dart';

/// Renders a committed [StudioMessage] node with non-destructive `< 1 / 2 >`
/// branch navigation, inline user editing, expandable reasoning, tool cards,
/// and turn telemetry.
class MessageTurnCard extends StatefulWidget {
  /// Creates a [MessageTurnCard].
  const MessageTurnCard({
    super.key,
    required this.message,
    required this.siblingIds,
    this.isLastTurn = false,
    this.structuredJsonValid,
  });

  /// Message node to render.
  final StudioMessage message;

  /// Sibling message IDs sharing the same `parentId`.
  final List<String> siblingIds;

  /// Whether this node is the last committed turn in the active branch.
  final bool isLastTurn;

  /// Optional JSON schema validation badge for the latest turn.
  final bool? structuredJsonValid;

  @override
  State<MessageTurnCard> createState() => _MessageTurnCardState();
}

class _MessageTurnCardState extends State<MessageTurnCard> {
  bool _isEditing = false;
  late final TextEditingController _editController;

  @override
  void initState() {
    super.initState();
    _editController = TextEditingController(text: widget.message.text);
  }

  @override
  void didUpdateWidget(covariant MessageTurnCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.message.id != widget.message.id && !_isEditing) {
      _editController.text = widget.message.text;
    }
  }

  @override
  void dispose() {
    _editController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = StudioPalette.of(context);
    final deps = StudioScope.of(context);
    final msg = widget.message;
    final isUser = msg.role == StudioRole.user;

    final currentBranchIndex = widget.siblingIds.indexOf(msg.id);
    final hasBranches = widget.siblingIds.length > 1 && currentBranchIndex >= 0;

    return FadeSlideEntry(
      child: Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isUser
              ? palette.surfaceElevated.withValues(alpha: 0.72)
              : palette.surfaceElevated,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: msg.isError
                ? palette.danger.withValues(alpha: 0.6)
                : (isUser ? palette.borderSubtle : palette.borderStrong),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            LayoutBuilder(
              builder:
                  (BuildContext context, BoxConstraints headerConstraints) {
                    final identityRow = Row(
                      children: <Widget>[
                        Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            color: isUser
                                ? palette.accentMuted
                                : palette.teal.withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(7),
                          ),
                          child: Icon(
                            isUser
                                ? Icons.person_outline_rounded
                                : Icons.auto_awesome,
                            size: 14,
                            color: isUser ? palette.accent : palette.teal,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          flex: 0,
                          child: Text(
                            isUser ? 'You' : 'llamadart',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                              color: palette.textPrimary,
                            ),
                          ),
                        ),
                        if (msg.metrics?.modelName != null) ...<Widget>[
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              msg.metrics!.modelName!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                color: palette.textMuted,
                                fontFamilyFallback:
                                    StudioTheme.monoFontFallback,
                              ),
                            ),
                          ),
                        ],
                      ],
                    );

                    final actionsRow = Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        if (hasBranches)
                          _BranchPaginator(
                            currentIndex: currentBranchIndex,
                            total: widget.siblingIds.length,
                            onPrevious: currentBranchIndex > 0
                                ? () => deps.chatController.selectSiblingBranch(
                                    widget.siblingIds[currentBranchIndex - 1],
                                  )
                                : null,
                            onNext:
                                currentBranchIndex <
                                    widget.siblingIds.length - 1
                                ? () => deps.chatController.selectSiblingBranch(
                                    widget.siblingIds[currentBranchIndex + 1],
                                  )
                                : null,
                          ),
                        if (isUser && !_isEditing)
                          IconButton(
                            key: Key('edit_msg_${msg.id}'),
                            tooltip: 'Edit & branch',
                            visualDensity: VisualDensity.compact,
                            onPressed: () {
                              setState(() {
                                _editController.text = msg.text;
                                _isEditing = true;
                              });
                            },
                            icon: Icon(
                              Icons.edit_outlined,
                              size: 15,
                              color: palette.textSecondary,
                            ),
                          ),
                        if (!isUser)
                          IconButton(
                            key: Key('regen_msg_${msg.id}'),
                            tooltip: 'Regenerate in new branch',
                            visualDensity: VisualDensity.compact,
                            onPressed: () => deps.chatController
                                .regenerateAssistantMessage(msg.id),
                            icon: Icon(
                              Icons.refresh_rounded,
                              size: 16,
                              color: palette.textSecondary,
                            ),
                          ),
                        IconButton(
                          tooltip: 'Copy text',
                          visualDensity: VisualDensity.compact,
                          onPressed: () async {
                            await Clipboard.setData(
                              ClipboardData(text: msg.text),
                            );
                            if (context.mounted) {
                              ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                                const SnackBar(
                                  content: Text('Copied message to clipboard'),
                                ),
                              );
                            }
                          },
                          icon: Icon(
                            Icons.copy_rounded,
                            size: 15,
                            color: palette.textSecondary,
                          ),
                        ),
                      ],
                    );

                    final shouldWrap =
                        headerConstraints.maxWidth <
                        (hasBranches ? 340.0 : 250.0);
                    if (shouldWrap) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          identityRow,
                          const SizedBox(height: 2),
                          Align(
                            alignment: Alignment.centerRight,
                            child: actionsRow,
                          ),
                        ],
                      );
                    }

                    return Row(
                      children: <Widget>[
                        Expanded(child: identityRow),
                        const SizedBox(width: 4),
                        actionsRow,
                      ],
                    );
                  },
            ),
            if (msg.attachments.isNotEmpty) ...<Widget>[
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: msg.attachments
                    .map((StudioAttachment a) => _AttachmentChip(attachment: a))
                    .toList(),
              ),
            ],
            if (msg.hasThinking) ...<Widget>[
              const SizedBox(height: 10),
              _ThinkingDisclosureCard(
                thinkingText: msg.thinkingText!,
                durationMs: msg.thinkingDurationMs,
                initiallyExpanded: msg.text.trim().isEmpty,
              ),
            ],
            if (msg.hasToolCalls) ...<Widget>[
              const SizedBox(height: 10),
              for (final call in msg.toolCalls)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _ToolInvocationCard(invocation: call),
                ),
            ],
            const SizedBox(height: 10),
            if (_isEditing)
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  TextField(
                    key: Key('edit_input_${msg.id}'),
                    controller: _editController,
                    autofocus: true,
                    maxLines: 5,
                    minLines: 2,
                    style: const TextStyle(fontSize: 13.5),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    alignment: WrapAlignment.end,
                    children: <Widget>[
                      TextButton(
                        onPressed: () => setState(() => _isEditing = false),
                        child: const Text('Cancel'),
                      ),
                      FilledButton.icon(
                        key: Key('submit_edit_${msg.id}'),
                        onPressed: () async {
                          final edited = _editController.text.trim();
                          if (edited.isEmpty) {
                            return;
                          }
                          setState(() => _isEditing = false);
                          await deps.chatController.editUserMessageAndBranch(
                            originalMessageId: msg.id,
                            editedText: edited,
                          );
                        },
                        icon: const Icon(Icons.call_split_rounded, size: 15),
                        label: const Text('Branch & Send'),
                      ),
                    ],
                  ),
                ],
              )
            else if (msg.text.isNotEmpty) ...<Widget>[
              _MarkdownMessageBody(text: msg.text, isError: msg.isError),
              if (msg.isError &&
                  msg.text.toLowerCase().contains('model hub')) ...<Widget>[
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.tonalIcon(
                    key: Key('error_open_model_hub_${msg.id}'),
                    onPressed: () => deps.shellController.selectWorkspace(
                      StudioWorkspace.models,
                    ),
                    icon: const Icon(Icons.hub_outlined, size: 15),
                    label: const Text('Open Model Hub'),
                  ),
                ),
              ],
            ] else if (!isUser && msg.hasThinking)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: palette.amber.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: palette.amber.withValues(alpha: 0.35),
                  ),
                ),
                child: Row(
                  children: <Widget>[
                    Icon(
                      Icons.info_outline_rounded,
                      size: 15,
                      color: palette.amber,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Generation stopped before emitting a final response. Click Regenerate (↻) or raise Max Tokens in Sampling.',
                        style: TextStyle(
                          fontSize: 12,
                          color: palette.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            if (!isUser && msg.metrics != null) ...<Widget>[
              const SizedBox(height: 12),
              _TurnTelemetryBar(
                metrics: msg.metrics!,
                structuredJsonValid: widget.isLastTurn
                    ? widget.structuredJsonValid
                    : null,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Isolated 60fps streaming assistant turn card subscribed exclusively to
/// `ChatWorkspaceController.activeStreamStore`.
class ActiveStreamingTurnCard extends StatelessWidget {
  /// Creates an [ActiveStreamingTurnCard].
  const ActiveStreamingTurnCard({super.key, required this.conversationId});

  /// Active conversation ID being viewed.
  final String conversationId;

  @override
  Widget build(BuildContext context) {
    final deps = StudioScope.of(context);
    final palette = StudioPalette.of(context);

    return StoreBuilder<ActiveTurnStreamState>(
      store: deps.chatController.activeStreamStore,
      builder: (BuildContext context, ActiveTurnStreamState streamState) {
        if (!streamState.isGenerating ||
            streamState.conversationId != conversationId) {
          return const SizedBox.shrink();
        }

        return RepaintBoundary(
          child: Container(
            margin: const EdgeInsets.only(bottom: 14),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: palette.surfaceElevated,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: palette.accent.withValues(alpha: 0.65)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    StatusPulseDot(color: palette.accent, pulsing: true),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'llamadart · Streaming',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: palette.textPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      flex: 0,
                      child: StudioPillBadge(
                        label:
                            '${streamState.liveTokensPerSecond.toStringAsFixed(1)} tok/s · ${streamState.tokensGenerated} tok',
                        foreground: palette.teal,
                        monospace: true,
                      ),
                    ),
                  ],
                ),
                if (streamState.thinkingText.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 10),
                  _ThinkingDisclosureCard(
                    thinkingText: streamState.thinkingText,
                    initiallyExpanded: true,
                    isStreaming: streamState.text.isEmpty,
                  ),
                ],
                if (streamState.toolInvocations.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 10),
                  for (final call in streamState.toolInvocations)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _ToolInvocationCard(invocation: call),
                    ),
                ],
                const SizedBox(height: 10),
                if (streamState.text.isEmpty &&
                    streamState.thinkingText.isEmpty &&
                    streamState.toolInvocations.isEmpty)
                  Row(
                    children: <Widget>[
                      Flexible(
                        child: Text(
                          streamState.statusLabel ?? 'Evaluating prompt...',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            color: palette.textMuted,
                          ),
                        ),
                      ),
                      const StreamingCursor(),
                    ],
                  )
                else
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      if (streamState.text.isNotEmpty)
                        _MarkdownMessageBody(
                          text: streamState.text,
                          isStreaming: true,
                        ),
                      const Padding(
                        padding: EdgeInsets.only(top: 4),
                        child: StreamingCursor(),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _BranchPaginator extends StatelessWidget {
  const _BranchPaginator({
    required this.currentIndex,
    required this.total,
    this.onPrevious,
    this.onNext,
  });

  final int currentIndex;
  final int total;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    final palette = StudioPalette.of(context);
    return Container(
      margin: const EdgeInsets.only(right: 6),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: palette.canvas,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: palette.borderSubtle),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          InkWell(
            onTap: onPrevious,
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: Icon(
                Icons.chevron_left_rounded,
                size: 15,
                color: onPrevious != null
                    ? palette.textPrimary
                    : palette.textMuted,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              '${currentIndex + 1} / $total',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: palette.textSecondary,
                fontFamilyFallback: StudioTheme.monoFontFallback,
              ),
            ),
          ),
          InkWell(
            onTap: onNext,
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: Icon(
                Icons.chevron_right_rounded,
                size: 15,
                color: onNext != null ? palette.textPrimary : palette.textMuted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
