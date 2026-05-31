import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:llamadart/llamadart.dart';
import 'package:provider/provider.dart';

import '../providers/chat_provider.dart';
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
  bool _hasDraftText = false;

  @override
  void initState() {
    super.initState();
    _hasDraftText = widget.controller.text.trim().isNotEmpty;
    widget.controller.addListener(_onTextChanged);
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

  bool _showDesktopShortcutsHint(TargetPlatform platform) {
    return kIsWeb ||
        platform == TargetPlatform.macOS ||
        platform == TargetPlatform.windows ||
        platform == TargetPlatform.linux;
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ChatProvider>(
      builder: (context, provider, _) {
        final isGenerating = provider.isGenerating;
        final isReady = provider.isReady;
        final hasAttachments = provider.stagedParts.isNotEmpty;
        final canSubmit =
            !isGenerating && isReady && (_hasDraftText || hasAttachments);
        final colorScheme = Theme.of(context).colorScheme;
        final showShortcutHint = _showDesktopShortcutsHint(
          Theme.of(context).platform,
        );
        final width = MediaQuery.sizeOf(context).width;
        final isDesktop = width >= 900;
        final safeBottom = MediaQuery.paddingOf(context).bottom;

        return Container(
          padding: EdgeInsets.fromLTRB(
            isDesktop ? 22 : 12,
            10,
            isDesktop ? 22 : 12,
            (isDesktop ? 14 : 10) + safeBottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      colorScheme.surfaceContainerLow.withValues(alpha: 0.92),
                      colorScheme.surfaceContainerHigh.withValues(alpha: 0.9),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(isDesktop ? 26 : 20),
                  border: Border.all(
                    color: colorScheme.outlineVariant.withValues(alpha: 0.45),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.24),
                      blurRadius: 20,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (provider.toolsEnabled) ...[
                      _buildFunctionCallingRow(context, provider),
                      const SizedBox(height: 10),
                    ],
                    if (provider.stagedParts.isNotEmpty)
                      _buildStagedPartsStrip(context, provider),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        if (provider.canAttachMedia)
                          _buildAttachmentMenu(context, provider),
                        Expanded(
                          child: Container(
                            decoration: BoxDecoration(
                              color: colorScheme.surface.withValues(
                                alpha: 0.68,
                              ),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: colorScheme.outlineVariant.withValues(
                                  alpha: 0.42,
                                ),
                              ),
                            ),
                            child: CallbackShortcuts(
                              bindings: {
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
                              },
                              child: TextField(
                                controller: widget.controller,
                                focusNode: widget.focusNode,
                                enabled: isReady,
                                maxLines: 6,
                                minLines: 1,
                                textCapitalization:
                                    TextCapitalization.sentences,
                                textInputAction: showShortcutHint
                                    ? TextInputAction.newline
                                    : TextInputAction.send,
                                onSubmitted: (_) {
                                  if (!showShortcutHint && canSubmit) {
                                    widget.onSend();
                                  }
                                },
                                decoration: InputDecoration(
                                  hintText: showShortcutHint
                                      ? 'Start typing a prompt, use option + enter to append'
                                      : 'Type a message...',
                                  border: InputBorder.none,
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 12,
                                  ),
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
                            color: canSubmit
                                ? colorScheme.primary
                                : colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: IconButton(
                            tooltip: isGenerating
                                ? 'Stop generation'
                                : 'Send message',
                            onPressed: isGenerating
                                ? () => provider.stopGeneration()
                                : (canSubmit ? widget.onSend : null),
                            icon: isGenerating
                                ? Icon(
                                    Icons.stop_rounded,
                                    color: colorScheme.error,
                                  )
                                : Icon(
                                    Icons.arrow_upward_rounded,
                                    color: canSubmit
                                        ? colorScheme.onPrimary
                                        : colorScheme.onSurfaceVariant,
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (showShortcutHint)
                Padding(
                  padding: const EdgeInsets.only(top: 8, right: 4),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      'Tip: Cmd/Ctrl + Enter to send',
                      style: TextStyle(
                        fontSize: 11,
                        color: colorScheme.onSurfaceVariant.withValues(
                          alpha: 0.9,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildStagedPartsStrip(BuildContext context, ChatProvider provider) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      height: 84,
      margin: const EdgeInsets.only(bottom: 12),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: provider.stagedParts.length,
        separatorBuilder: (context, index) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final part = provider.stagedParts[index];
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
                  icon: const Icon(Icons.close_rounded, size: 14),
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
      icon: Icon(Icons.add_circle_outline_rounded, color: colorScheme.primary),
      tooltip: 'Add attachment',
      onSelected: (value) {
        if (value == 'image') {
          provider.pickImage();
        } else if (value == 'audio') {
          provider.pickAudio();
        }
      },
      itemBuilder: (context) => [
        if (provider.supportsVision || showFallbackImage)
          const PopupMenuItem(
            value: 'image',
            child: Row(
              children: [
                Icon(Icons.image_outlined),
                SizedBox(width: 12),
                Text('Attach Image'),
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
                Text('Attach Audio'),
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
