import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:pasteboard/pasteboard.dart';

import '../../app/studio_dependencies.dart';
import '../../app/studio_theme.dart';
import '../../widgets/store_widgets.dart';
import '../../widgets/studio_motion.dart';

/// Multimodal chat composer supporting `Enter` to send, `Shift+Enter` for
/// newline, file-picked image/audio attachments, and clipboard image paste.
class MultimodalComposer extends StatefulWidget {
  /// Creates a [MultimodalComposer].
  const MultimodalComposer({super.key});

  @override
  State<MultimodalComposer> createState() => _MultimodalComposerState();
}

class _MultimodalComposerState extends State<MultimodalComposer> {
  final TextEditingController _controller = TextEditingController();
  late final FocusNode _focusNode;
  int _attachmentSeq = 0;
  String? _lastAppliedDraft;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode(onKeyEvent: _handleKeyEvent);
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter &&
        !HardwareKeyboard.instance.isShiftPressed) {
      _submit();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _submit() async {
    final deps = StudioScope.of(context);
    if (deps.chatController.activeStreamStore.state.isGenerating) {
      return;
    }
    final text = _controller.text;
    final hasAttachments =
        deps.chatController.state.pendingAttachments.isNotEmpty;
    if (text.trim().isEmpty && !hasAttachments) {
      return;
    }
    _lastAppliedDraft = null;
    _controller.clear();
    await deps.chatController.sendMessage(text);
  }

  Future<void> _pickImage() async {
    final deps = StudioScope.of(context);
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
    );
    final picked = result?.files.firstOrNull;
    if (picked == null) {
      return;
    }
    _attachmentSeq++;
    deps.chatController.addPendingAttachment(
      StudioAttachment(
        id: 'att_img_${DateTime.now().microsecondsSinceEpoch}_$_attachmentSeq',
        kind: StudioAttachmentKind.image,
        name: picked.name,
        localPath: deps.isWeb ? null : picked.path,
        bytes: picked.bytes,
        sizeBytes: picked.size,
      ),
    );
  }

  Future<void> _pickAudio() async {
    final deps = StudioScope.of(context);
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>['wav', 'mp3', 'm4a', 'flac', 'ogg'],
      withData: true,
    );
    final picked = result?.files.firstOrNull;
    if (picked == null) {
      return;
    }
    _attachmentSeq++;
    deps.chatController.addPendingAttachment(
      StudioAttachment(
        id: 'att_aud_${DateTime.now().microsecondsSinceEpoch}_$_attachmentSeq',
        kind: StudioAttachmentKind.audio,
        name: picked.name,
        localPath: deps.isWeb ? null : picked.path,
        bytes: picked.bytes,
        sizeBytes: picked.size,
      ),
    );
  }

  Future<void> _pasteClipboardImage() async {
    final deps = StudioScope.of(context);
    try {
      final bytes = await Pasteboard.image;
      if (bytes == null || bytes.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            const SnackBar(content: Text('No image found on clipboard')),
          );
        }
        return;
      }
      _attachmentSeq++;
      deps.chatController.addPendingAttachment(
        StudioAttachment(
          id: 'att_clip_${DateTime.now().microsecondsSinceEpoch}_$_attachmentSeq',
          kind: StudioAttachmentKind.image,
          name: 'clipboard_$_attachmentSeq.png',
          mimeType: 'image/png',
          bytes: bytes,
          sizeBytes: bytes.length,
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(
            content: Text('Clipboard image paste is unavailable on this host'),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = StudioPalette.of(context);
    final deps = StudioScope.of(context);

    return StoreBuilder<ChatWorkspaceState>(
      store: deps.chatController.store,
      builder: (BuildContext context, ChatWorkspaceState chatState) {
        final incomingDraft = chatState.composerDraft;
        if (incomingDraft != null &&
            incomingDraft.isNotEmpty &&
            incomingDraft != _lastAppliedDraft) {
          _lastAppliedDraft = incomingDraft;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) {
              return;
            }
            _controller
              ..text = incomingDraft
              ..selection = TextSelection.collapsed(
                offset: incomingDraft.length,
              );
          });
        }
        return StoreBuilder<StudioShellState>(
          store: deps.shellController.store,
          builder: (BuildContext context, StudioShellState shellState) {
            return StoreBuilder<StudioRuntimeSnapshot>(
              store: deps.modelHubController.runtimeStore,
              builder: (BuildContext context, StudioRuntimeSnapshot runtime) {
                return StoreSelector<ActiveTurnStreamState, bool>(
                  store: deps.chatController.activeStreamStore,
                  selector: (ActiveTurnStreamState s) => s.isGenerating,
                  builder: (BuildContext context, bool isGenerating) {
                    final hasSchema =
                        (chatState.activeConversation?.jsonSchema ?? '')
                            .trim()
                            .isNotEmpty;
                    final loadedModel = runtime.activeDescriptor;
                    final hasImageAttachment = chatState.pendingAttachments.any(
                      (StudioAttachment a) =>
                          a.kind == StudioAttachmentKind.image,
                    );
                    final hasAudioAttachment = chatState.pendingAttachments.any(
                      (StudioAttachment a) =>
                          a.kind == StudioAttachmentKind.audio,
                    );
                    String? modalityWarning;
                    if (runtime.isReady && loadedModel != null) {
                      if (hasImageAttachment && !loadedModel.supportsVision) {
                        modalityWarning = 'Loaded model lacks Vision projector — switch to Gemma 4 or Qwen3-VL in Model Hub';
                      } else if (hasAudioAttachment &&
                          !loadedModel.supportsAudio) {
                        modalityWarning = 'Loaded model lacks Audio input — switch to Gemma 4 E2B/E4B or Speech workspace';
                      }
                    }

                    return Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: palette.surfaceElevated,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: palette.borderStrong),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          if (modalityWarning != null)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: InkWell(
                                key: const Key('composer_modality_warning'),
                                borderRadius: BorderRadius.circular(8),
                                onTap: () => deps.shellController
                                    .selectWorkspace(StudioWorkspace.models),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 6,
                                  ),
                                  decoration: BoxDecoration(
                                    color: palette.amber.withValues(
                                      alpha: 0.14,
                                    ),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: palette.amber.withValues(
                                        alpha: 0.4,
                                      ),
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: <Widget>[
                                      Icon(
                                        Icons.info_outline_rounded,
                                        size: 14,
                                        color: palette.amber,
                                      ),
                                      const SizedBox(width: 6),
                                      Flexible(
                                        child: Text(
                                          modalityWarning,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 11.5,
                                            color: palette.textPrimary,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          AnimatedSize(
                            duration: const Duration(milliseconds: 180),
                            child: chatState.pendingAttachments.isEmpty
                                ? const SizedBox.shrink()
                                : Padding(
                                    padding: const EdgeInsets.only(bottom: 10),
                                    child: LayoutBuilder(
                                      builder:
                                          (
                                            BuildContext context,
                                            BoxConstraints chipBox,
                                          ) {
                                            final maxLabelWidth = math.min(
                                              200.0,
                                              math.max(
                                                80.0,
                                                chipBox.maxWidth - 88.0,
                                              ),
                                            );
                                            return Wrap(
                                              spacing: 8,
                                              runSpacing: 8,
                                              children: chatState.pendingAttachments.map((
                                                StudioAttachment att,
                                              ) {
                                                return Chip(
                                                  avatar: Icon(
                                                    att.kind ==
                                                            StudioAttachmentKind
                                                                .image
                                                        ? Icons.image_outlined
                                                        : Icons
                                                              .graphic_eq_rounded,
                                                    size: 15,
                                                    color: palette.accent,
                                                  ),
                                                  label: ConstrainedBox(
                                                    constraints: BoxConstraints(
                                                      maxWidth: maxLabelWidth,
                                                    ),
                                                    child: Text(
                                                      att.name,
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: const TextStyle(
                                                        fontSize: 12,
                                                      ),
                                                    ),
                                                  ),
                                                  onDeleted: () => deps
                                                      .chatController
                                                      .removePendingAttachment(
                                                        att.id,
                                                      ),
                                                );
                                              }).toList(),
                                            );
                                          },
                                    ),
                                  ),
                          ),
                          TextField(
                            key: const Key('chat_composer_input'),
                            controller: _controller,
                            focusNode: _focusNode,
                            minLines: 1,
                            maxLines: 6,
                            style: TextStyle(
                              fontSize: 14,
                              color: palette.textPrimary,
                              height: 1.45,
                            ),
                            decoration: InputDecoration(
                              hintText: 'Message llamadart Studio (Enter to send, Shift+Enter for newline)...',
                              hintStyle: TextStyle(color: palette.textMuted),
                              filled: false,
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 6,
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          LayoutBuilder(
                            builder:
                                (
                                  BuildContext context,
                                  BoxConstraints toolbarBox,
                                ) {
                                  final actionButton = isGenerating
                                      ? FilledButton.tonalIcon(
                                          key: const Key('chat_stop_button'),
                                          onPressed: deps
                                              .chatController
                                              .stopGeneration,
                                          icon: Icon(
                                            Icons.stop_circle_outlined,
                                            size: 17,
                                            color: palette.danger,
                                          ),
                                          label: Text(
                                            'Stop',
                                            style: TextStyle(
                                              color: palette.danger,
                                            ),
                                          ),
                                        )
                                      : FilledButton.icon(
                                          key: const Key('chat_send_button'),
                                          onPressed: _submit,
                                          icon: const Icon(
                                            Icons.arrow_upward_rounded,
                                            size: 17,
                                          ),
                                          label: const Text('Send'),
                                        );

                                  final iconActions = <Widget>[
                                    IconButton(
                                      tooltip: 'Attach image (Vision)',
                                      visualDensity: VisualDensity.compact,
                                      onPressed: isGenerating
                                          ? null
                                          : _pickImage,
                                      icon: Icon(
                                        Icons.add_photo_alternate_outlined,
                                        size: 19,
                                        color: palette.textSecondary,
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: 'Attach audio clip',
                                      visualDensity: VisualDensity.compact,
                                      onPressed: isGenerating
                                          ? null
                                          : _pickAudio,
                                      icon: Icon(
                                        Icons.audiotrack_outlined,
                                        size: 19,
                                        color: palette.textSecondary,
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: 'Paste image from clipboard',
                                      visualDensity: VisualDensity.compact,
                                      onPressed: isGenerating
                                          ? null
                                          : _pasteClipboardImage,
                                      icon: Icon(
                                        Icons.content_paste_go_rounded,
                                        size: 18,
                                        color: palette.textSecondary,
                                      ),
                                    ),
                                  ];

                                  final thinkingOn =
                                      shellState.settings.thinkingEnabled;
                                  final toolsOn =
                                      shellState.settings.toolsEnabled;
                                  final statusPills = <Widget>[
                                    Tooltip(
                                      message: thinkingOn
                                          ? 'Reasoning active — tap to disable'
                                          : 'Reasoning off — tap to enable',
                                      child: InkWell(
                                        key: const Key(
                                          'composer_toggle_think_chip',
                                        ),
                                        borderRadius: BorderRadius.circular(7),
                                        onTap: () =>
                                            deps.shellController.updateSettings(
                                              (StudioSettings s) => s.copyWith(
                                                thinkingEnabled:
                                                    !s.thinkingEnabled,
                                              ),
                                            ),
                                        child: StudioPillBadge(
                                          label: 'Think',
                                          icon: Icons.psychology_outlined,
                                          foreground: thinkingOn
                                              ? palette.amber
                                              : palette.textMuted,
                                          borderColor: thinkingOn
                                              ? palette.amber.withValues(
                                                  alpha: 0.45,
                                                )
                                              : palette.borderSubtle,
                                        ),
                                      ),
                                    ),
                                    Tooltip(
                                      message: toolsOn
                                          ? 'Local tool calling active — tap to disable'
                                          : 'Tool calling off — tap to enable',
                                      child: InkWell(
                                        key: const Key(
                                          'composer_toggle_tools_chip',
                                        ),
                                        borderRadius: BorderRadius.circular(7),
                                        onTap: () =>
                                            deps.shellController.updateSettings(
                                              (StudioSettings s) => s.copyWith(
                                                toolsEnabled: !s.toolsEnabled,
                                              ),
                                            ),
                                        child: StudioPillBadge(
                                          label: 'Tools',
                                          icon: Icons.handyman_outlined,
                                          foreground: toolsOn
                                              ? palette.teal
                                              : palette.textMuted,
                                          borderColor: toolsOn
                                              ? palette.teal.withValues(
                                                  alpha: 0.45,
                                                )
                                              : palette.borderSubtle,
                                        ),
                                      ),
                                    ),
                                    if (hasSchema)
                                      StudioPillBadge(
                                        label: 'JSON Schema',
                                        foreground: palette.accent,
                                        monospace: true,
                                      ),
                                  ];

                                  if (toolbarBox.maxWidth < 460) {
                                    return Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: <Widget>[
                                        if (statusPills.isNotEmpty)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              bottom: 6,
                                            ),
                                            child: Wrap(
                                              spacing: 6,
                                              runSpacing: 6,
                                              children: statusPills,
                                            ),
                                          ),
                                        Row(
                                          children: <Widget>[
                                            ...iconActions,
                                            const Spacer(),
                                            actionButton,
                                          ],
                                        ),
                                      ],
                                    );
                                  }

                                  return Row(
                                    children: <Widget>[
                                      Expanded(
                                        child: SingleChildScrollView(
                                          scrollDirection: Axis.horizontal,
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: <Widget>[
                                              ...iconActions,
                                              const SizedBox(width: 6),
                                              for (final pill in statusPills)
                                                Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                        right: 6,
                                                      ),
                                                  child: pill,
                                                ),
                                            ],
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      actionButton,
                                    ],
                                  );
                                },
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }
}
