import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:llamadart/llamadart.dart';
import 'package:provider/provider.dart';
import 'package:super_clipboard/super_clipboard.dart';

import '../providers/chat_provider.dart';
import '../services/clipboard_attachment_service.dart';
import 'tool_declarations_dialog.dart';

class ChatInput extends StatefulWidget {
  final VoidCallback onSend;
  final TextEditingController controller;
  final FocusNode focusNode;

  const ChatInput({
    super.key,
    required this.onSend,
    required this.controller,
    required this.focusNode,
  });

  @override
  State<ChatInput> createState() => _ChatInputState();
}

class _ChatInputState extends State<ChatInput> {
  final ClipboardAttachmentService _clipboardAttachments =
      ClipboardAttachmentService();
  bool _hasDraftText = false;

  @override
  void initState() {
    super.initState();
    _hasDraftText = widget.controller.text.trim().isNotEmpty;
    widget.controller.addListener(_onTextChanged);
    ClipboardEvents.instance?.registerPasteEventListener(_onWebPasteEvent);
  }

  @override
  void didUpdateWidget(covariant ChatInput oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onTextChanged);
      widget.controller.addListener(_onTextChanged);
      _onTextChanged();
    }
  }

  @override
  void dispose() {
    ClipboardEvents.instance?.unregisterPasteEventListener(_onWebPasteEvent);
    widget.controller.removeListener(_onTextChanged);
    super.dispose();
  }

  void _onTextChanged() {
    final hasText = widget.controller.text.trim().isNotEmpty;
    if (hasText == _hasDraftText || !mounted) return;

    setState(() {
      _hasDraftText = hasText;
    });
  }

  bool _supportsDesktopShortcuts(TargetPlatform platform) {
    return platform == TargetPlatform.macOS ||
        platform == TargetPlatform.windows ||
        platform == TargetPlatform.linux;
  }

  bool _allowsImage(ChatProvider provider) {
    return provider.supportsVision ||
        (provider.canAttachMedia &&
            !provider.supportsVision &&
            !provider.supportsAudio);
  }

  Future<void> _onWebPasteEvent(ClipboardReadEvent event) async {
    if (!mounted || !widget.focusNode.hasFocus) {
      return;
    }
    final provider = context.read<ChatProvider>();
    if (!provider.canAttachMedia) {
      return;
    }

    try {
      final reader = await event.getClipboardReader();
      final content = await _clipboardAttachments.read(
        reader,
        allowImage: _allowsImage(provider),
        allowAudio: provider.supportsAudio,
      );
      await _handlePasteContent(provider, content, allowTextFallback: true);
    } catch (error) {
      _showClipboardError(error);
    }
  }

  Future<void> _pasteFromSystemClipboard(
    ChatProvider provider, {
    required bool allowTextFallback,
    required bool showUnsupportedMessage,
  }) async {
    try {
      final content = await _clipboardAttachments.readSystemClipboard(
        allowImage: _allowsImage(provider),
        allowAudio: provider.supportsAudio,
      );
      if (!mounted) {
        return;
      }
      if (content == null) {
        if (showUnsupportedMessage) {
          _showMessage('Clipboard access is not available on this platform.');
        }
        return;
      }
      final handled = await _handlePasteContent(
        provider,
        content,
        allowTextFallback: allowTextFallback,
      );
      if (!handled && showUnsupportedMessage) {
        _showMessage('Clipboard has no supported image or audio attachment.');
      }
    } catch (error) {
      _showClipboardError(error);
    }
  }

  Future<bool> _handlePasteContent(
    ChatProvider provider,
    ClipboardPasteContent content, {
    required bool allowTextFallback,
  }) async {
    final attachment = content.attachment;
    if (attachment != null) {
      switch (attachment.kind) {
        case ClipboardAttachmentKind.image:
          return provider.stageImageAttachment(attachment.bytes);
        case ClipboardAttachmentKind.audio:
          return provider.stageAudioAttachment(attachment.bytes);
      }
    }

    final text = content.plainText;
    if (allowTextFallback && text != null) {
      _insertTextAtSelection(text);
      return true;
    }
    return false;
  }

  void _insertTextAtSelection(String text) {
    final value = widget.controller.value;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    final nextText = value.text.replaceRange(
      selection.start,
      selection.end,
      text,
    );
    widget.controller.value = value.copyWith(
      text: nextText,
      selection: TextSelection.collapsed(offset: selection.start + text.length),
      composing: TextRange.empty,
    );
  }

  void _showClipboardError(Object error) {
    if (!mounted) {
      return;
    }
    final message = error is ClipboardAttachmentException
        ? error.message
        : 'Couldn\'t read the clipboard attachment.';
    _showMessage(message);
  }

  void _showMessage(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ChatProvider>(
      builder: (context, provider, _) {
        final isGenerating = provider.isGenerating;
        final isReady = provider.isReady;
        final stagedParts = provider.stagedParts;
        final hasAttachments = stagedParts.isNotEmpty;
        final canSubmit =
            !isGenerating && isReady && (_hasDraftText || hasAttachments);
        final sendActionLabel = isGenerating
            ? 'Stop generation'
            : 'Send message';
        final colorScheme = Theme.of(context).colorScheme;
        final platform = Theme.of(context).platform;
        final width = MediaQuery.sizeOf(context).width;
        final isDesktop = width >= 900;
        final useDesktopShortcuts =
            isDesktop && _supportsDesktopShortcuts(platform);
        final usesMetaPaste =
            platform == TargetPlatform.macOS || platform == TargetPlatform.iOS;
        final safeBottom = MediaQuery.paddingOf(context).bottom;
        final shortcutBindings = <ShortcutActivator, VoidCallback>{
          const SingleActivator(
            LogicalKeyboardKey.enter,
            control: true,
            includeRepeats: false,
          ): () {
            if (canSubmit) {
              widget.onSend();
            }
          },
          const SingleActivator(
            LogicalKeyboardKey.enter,
            meta: true,
            includeRepeats: false,
          ): () {
            if (canSubmit) {
              widget.onSend();
            }
          },
          if (!kIsWeb && provider.canAttachMedia) ...{
            if (usesMetaPaste)
              const SingleActivator(
                LogicalKeyboardKey.keyV,
                meta: true,
                includeRepeats: false,
              ): () => unawaited(
                _pasteFromSystemClipboard(
                  provider,
                  allowTextFallback: true,
                  showUnsupportedMessage: false,
                ),
              ),
            if (!usesMetaPaste)
              const SingleActivator(
                LogicalKeyboardKey.keyV,
                control: true,
                includeRepeats: false,
              ): () => unawaited(
                _pasteFromSystemClipboard(
                  provider,
                  allowTextFallback: true,
                  showUnsupportedMessage: false,
                ),
              ),
          },
        };

        return Container(
          padding: EdgeInsets.fromLTRB(
            isDesktop ? 22 : 12,
            10,
            isDesktop ? 22 : 12,
            (isDesktop ? 14 : 10) + safeBottom,
          ),
          child: Align(
            alignment: Alignment.bottomCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 920),
              child: Container(
                padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(isDesktop ? 20 : 18),
                  border: Border.all(
                    color: colorScheme.outlineVariant.withValues(alpha: 0.5),
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (provider.toolsEnabled) ...[
                      _buildFunctionCallingRow(context, provider),
                      const SizedBox(height: 10),
                    ],
                    if (hasAttachments)
                      _buildStagedPartsStrip(context, provider, stagedParts),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        if (provider.canAttachMedia)
                          _buildAttachmentMenu(context, provider),
                        Expanded(
                          child: CallbackShortcuts(
                            bindings: shortcutBindings,
                            child: TextField(
                              controller: widget.controller,
                              focusNode: widget.focusNode,
                              enabled: isReady,
                              maxLines: 6,
                              minLines: 1,
                              textCapitalization: TextCapitalization.sentences,
                              textInputAction: useDesktopShortcuts
                                  ? TextInputAction.newline
                                  : TextInputAction.send,
                              onSubmitted: (_) {
                                if (!useDesktopShortcuts && canSubmit) {
                                  widget.onSend();
                                }
                              },
                              decoration: const InputDecoration(
                                hintText: 'Ask anything…',
                                border: InputBorder.none,
                                contentPadding: EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 12,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 180),
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: isGenerating
                                ? colorScheme.errorContainer
                                : canSubmit
                                ? colorScheme.primary
                                : colorScheme.surfaceContainerHighest,
                            shape: BoxShape.circle,
                          ),
                          child: IconButton(
                            tooltip: sendActionLabel,
                            onPressed: isGenerating
                                ? () => provider.stopGeneration()
                                : (canSubmit ? widget.onSend : null),
                            icon: isGenerating
                                ? Icon(
                                    Icons.stop_rounded,
                                    color: colorScheme.onErrorContainer,
                                    semanticLabel: kIsWeb
                                        ? null
                                        : sendActionLabel,
                                  )
                                : Icon(
                                    Icons.arrow_upward_rounded,
                                    color: canSubmit
                                        ? colorScheme.onPrimary
                                        : colorScheme.onSurfaceVariant,
                                    semanticLabel: kIsWeb
                                        ? null
                                        : sendActionLabel,
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildStagedPartsStrip(
    BuildContext context,
    ChatProvider provider,
    List<LlamaContentPart> stagedParts,
  ) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      height: 84,
      margin: const EdgeInsets.only(bottom: 12),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: stagedParts.length,
        separatorBuilder: (context, index) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final part = stagedParts[index];
          return Stack(
            children: [
              Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: colorScheme.outlineVariant),
                ),
                clipBehavior: Clip.antiAlias,
                child: _buildPartPreview(part),
              ),
              Positioned(
                top: 2,
                right: 2,
                child: IconButton.filledTonal(
                  style: IconButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.all(2),
                    minimumSize: const Size(24, 24),
                  ),
                  onPressed: () => provider.removeStagedPart(index),
                  icon: const Icon(
                    Icons.close_rounded,
                    size: 14,
                    semanticLabel: kIsWeb ? null : 'Remove attachment',
                  ),
                  tooltip: 'Remove attachment',
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildFunctionCallingRow(BuildContext context, ChatProvider provider) {
    final colorScheme = Theme.of(context).colorScheme;
    final canUseTemplateTools = provider.templateSupportsTools;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colorScheme.surface.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: 0.4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Function calling',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                ),
              ),
              TextButton(
                onPressed: () => showToolDeclarationsDialog(context, provider),
                child: const Text('Edit'),
              ),
              Switch.adaptive(
                value: provider.toolsEnabled,
                onChanged: canUseTemplateTools
                    ? (value) => provider.updateToolsEnabled(value)
                    : null,
              ),
            ],
          ),
          Text(
            provider.toolsEnabled
                ? '${provider.declaredToolCount} declaration(s) loaded'
                : 'Disabled',
            style: TextStyle(
              fontSize: 11,
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.92),
            ),
          ),
          if (!canUseTemplateTools)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                'This model template does not support tools.',
                style: TextStyle(
                  fontSize: 11,
                  color: colorScheme.error,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          if (provider.toolDeclarationsError != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                provider.toolDeclarationsError!,
                style: TextStyle(
                  fontSize: 11,
                  color: colorScheme.error,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildAttachmentMenu(BuildContext context, ChatProvider provider) {
    final colorScheme = Theme.of(context).colorScheme;
    final showFallbackImage =
        provider.canAttachMedia &&
        !provider.supportsVision &&
        !provider.supportsAudio;

    return PopupMenuButton<String>(
      icon: Icon(
        Icons.add_circle_outline_rounded,
        color: colorScheme.primary,
        semanticLabel: kIsWeb ? null : 'Add attachment',
      ),
      tooltip: 'Add attachment',
      onSelected: (value) {
        if (value == 'paste') {
          unawaited(
            _pasteFromSystemClipboard(
              provider,
              allowTextFallback: false,
              showUnsupportedMessage: true,
            ),
          );
        } else if (value == 'image') {
          provider.pickImage();
        } else if (value == 'audio') {
          provider.pickAudio();
        }
      },
      itemBuilder: (context) => [
        const PopupMenuItem(
          value: 'paste',
          child: Row(
            children: [
              Icon(Icons.content_paste_rounded),
              SizedBox(width: 12),
              Expanded(child: Text('Paste attachment')),
            ],
          ),
        ),
        if (provider.supportsVision || showFallbackImage)
          const PopupMenuItem(
            value: 'image',
            child: Row(
              children: [
                Icon(Icons.image_outlined),
                SizedBox(width: 12),
                Expanded(child: Text('Attach Image')),
              ],
            ),
          ),
        if (provider.supportsAudio)
          const PopupMenuItem(
            value: 'audio',
            child: Row(
              children: [
                Icon(Icons.audiotrack_outlined),
                SizedBox(width: 12),
                Expanded(child: Text('Attach Audio')),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildPartPreview(LlamaContentPart part) {
    if (part is LlamaImageContent) {
      if (!kIsWeb && part.path != null) {
        return Image.file(File(part.path!), fit: BoxFit.cover);
      } else if (part.bytes != null) {
        return Image.memory(part.bytes!, fit: BoxFit.cover);
      }
    } else if (part is LlamaAudioContent) {
      return const Center(child: Icon(Icons.audiotrack, size: 32));
    }
    return const Center(child: Icon(Icons.description, size: 32));
  }
}
