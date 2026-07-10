import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:llamadart/llamadart.dart';

import '../models/chat_message.dart';
import '../utils/text_sanitizer.dart';
import 'tool_execution_card.dart';

class MessageBubble extends StatelessWidget {
  static final RegExp _orderedListRegex = RegExp(
    r'^\s*\d+\.\s',
    multiLine: true,
  );

  final ChatMessage message;
  final bool isNextSame;
  final bool isStreaming;
  final VoidCallback? onRegenerate;

  const MessageBubble({
    super.key,
    required this.message,
    required this.isNextSame,
    this.isStreaming = false,
    this.onRegenerate,
  });

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(child: _buildBubble(context));
  }

  Widget _buildBubble(BuildContext context) {
    if (message.role == LlamaChatRole.tool) {
      return const SizedBox.shrink();
    }

    if (message.isInfo) {
      return _buildInfoMessage(context);
    }

    final isUser = message.isUser;
    final messageText = sanitizeForTextLayout(message.text);
    final isTypingPlaceholder =
        !isUser &&
        messageText.trim() == '...' &&
        (message.parts == null || message.parts!.isEmpty);
    final align = isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final colorScheme = Theme.of(context).colorScheme;

    final bubbleColor = isUser
        ? Color.alphaBlend(
            colorScheme.primary.withValues(alpha: 0.18),
            colorScheme.surfaceContainerHighest,
          )
        : Colors.transparent;
    final textColor = colorScheme.onSurface;

    const borderRadius = 18.0;
    final border = BorderRadius.only(
      topLeft: const Radius.circular(borderRadius),
      topRight: const Radius.circular(borderRadius),
      bottomLeft: Radius.circular(isUser ? borderRadius : 4),
      bottomRight: Radius.circular(isUser ? 4 : borderRadius),
    );

    final thinkingTextRaw = message.thinkingText;
    final thinkingText = thinkingTextRaw == null
        ? null
        : sanitizeForTextLayout(thinkingTextRaw);

    return Padding(
      padding: EdgeInsets.only(bottom: isNextSame ? 8 : 18),
      child: Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: _maxBubbleWidth(context)),
          child: Column(
            crossAxisAlignment: align,
            children: [
              if (!isTypingPlaceholder)
                _buildRoleAndTimeLabel(context, isUser: isUser),
              if (message.parts != null)
                ...message.parts!
                    .where(
                      (p) =>
                          p is! LlamaTextContent &&
                          p is! LlamaToolCallContent &&
                          p is! LlamaToolResultContent &&
                          p is! LlamaThinkingContent,
                    )
                    .map((p) => _buildMediaPart(context, p)),
              if (thinkingText != null && thinkingText.trim().isNotEmpty)
                _buildThinkingView(context, thinkingText),
              if (message.isToolCall)
                _buildToolCallView(context)
              else if (isTypingPlaceholder)
                _buildTypingBubble(context)
              else if (messageText.isNotEmpty)
                isStreaming && !isUser
                    ? _buildStreamingTextBubble(
                        context,
                        messageText,
                        textColor: textColor,
                      )
                    : _buildResponseBubble(
                        context,
                        messageText,
                        bubbleColor: bubbleColor,
                        textColor: textColor,
                        border: border,
                        isUser: isUser,
                      ),
              if (!isUser &&
                  !isTypingPlaceholder &&
                  !isStreaming &&
                  !message.isToolCall &&
                  messageText.isNotEmpty)
                _AssistantActions(
                  text: messageText,
                  onRegenerate: onRegenerate,
                ),
            ],
          ),
        ),
      ),
    );
  }

  double _maxBubbleWidth(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    if (width >= 1400) return 860;
    if (width >= 1000) return width * 0.64;
    if (width >= 720) return width * 0.72;
    return width * 0.86;
  }

  Widget _buildRoleAndTimeLabel(BuildContext context, {required bool isUser}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: _MessageMeta(
        roleLabel: isUser ? 'You' : 'llamadart',
        timestamp: _formatTimestamp(context),
      ),
    );
  }

  Widget _buildInfoMessage(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final text = sanitizeForTextLayout(message.text);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHigh.withValues(alpha: 0.65),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: colorScheme.outlineVariant.withValues(alpha: 0.7),
            ),
          ),
          child: Text(
            text,
            style: TextStyle(
              fontSize: 12,
              color: colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildResponseBubble(
    BuildContext context,
    String text, {
    required Color bubbleColor,
    required Color textColor,
    required BorderRadius border,
    required bool isUser,
  }) {
    if (!_hasMarkdownSyntax(text)) {
      return _buildPlainTextBubble(
        context,
        text,
        bubbleColor: bubbleColor,
        textColor: textColor,
        border: border,
        isUser: isUser,
      );
    }

    return _buildMarkdownBubble(
      context,
      text,
      bubbleColor: bubbleColor,
      textColor: textColor,
      border: border,
      isUser: isUser,
    );
  }

  bool _hasMarkdownSyntax(String text) {
    if (text.contains('```') ||
        text.contains('`') ||
        text.contains('**') ||
        text.contains('~~') ||
        text.contains('](') ||
        text.contains('|')) {
      return true;
    }

    final trimmed = text.trimLeft();
    if (trimmed.startsWith('#') ||
        trimmed.startsWith('> ') ||
        trimmed.startsWith('- ') ||
        trimmed.startsWith('* ')) {
      return true;
    }

    if (text.contains('\n- ') || text.contains('\n* ')) {
      return true;
    }

    return _orderedListRegex.hasMatch(text);
  }

  Widget _buildPlainTextBubble(
    BuildContext context,
    String text, {
    required Color bubbleColor,
    required Color textColor,
    required BorderRadius border,
    required bool isUser,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final safeText = sanitizeForTextLayout(text);

    return Container(
      padding: isUser
          ? const EdgeInsets.symmetric(horizontal: 16, vertical: 12)
          : EdgeInsets.zero,
      decoration: isUser
          ? BoxDecoration(
              color: bubbleColor,
              borderRadius: border,
              border: Border.all(
                color: colorScheme.outlineVariant.withValues(alpha: 0.24),
              ),
            )
          : null,
      child: SelectableText(
        safeText,
        style: TextStyle(
          color: textColor.withValues(alpha: isUser ? 0.98 : 0.95),
          fontSize: 16,
          height: 1.45,
        ),
      ),
    );
  }

  Widget _buildMarkdownBubble(
    BuildContext context,
    String text, {
    required Color bubbleColor,
    required Color textColor,
    required BorderRadius border,
    required bool isUser,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final safeText = sanitizeForTextLayout(text);

    return Container(
      padding: isUser
          ? const EdgeInsets.symmetric(horizontal: 16, vertical: 12)
          : EdgeInsets.zero,
      decoration: isUser
          ? BoxDecoration(
              color: bubbleColor,
              borderRadius: border,
              border: Border.all(
                color: colorScheme.outlineVariant.withValues(alpha: 0.24),
              ),
            )
          : null,
      child: MarkdownBody(
        data: safeText,
        selectable: true,
        styleSheet: MarkdownStyleSheet(
          p: TextStyle(
            color: textColor.withValues(alpha: isUser ? 0.98 : 0.95),
            fontSize: 16,
            height: 1.45,
          ),
          h1: TextStyle(
            color: textColor,
            fontSize: 22,
            fontWeight: FontWeight.w700,
            height: 1.25,
          ),
          h2: TextStyle(
            color: textColor,
            fontSize: 19,
            fontWeight: FontWeight.w700,
            height: 1.3,
          ),
          code: TextStyle(
            color: isUser
                ? textColor.withValues(alpha: 0.9)
                : colorScheme.onSurfaceVariant,
            backgroundColor: isUser
                ? Colors.black.withValues(alpha: 0.1)
                : colorScheme.surfaceContainerHighest,
            fontFamily: 'monospace',
          ),
          blockquote: TextStyle(
            color: textColor.withValues(alpha: 0.85),
            fontSize: 14,
            height: 1.45,
          ),
          blockquoteDecoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.34),
            borderRadius: BorderRadius.circular(8),
            border: Border(
              left: BorderSide(
                color: colorScheme.primary.withValues(alpha: 0.65),
                width: 3,
              ),
            ),
          ),
          codeblockDecoration: BoxDecoration(
            color: isUser
                ? Colors.black.withValues(alpha: 0.1)
                : colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      ),
    );
  }

  Widget _buildStreamingTextBubble(
    BuildContext context,
    String text, {
    required Color textColor,
  }) {
    final safeText = sanitizeForTextLayout(text);

    return Padding(
      padding: EdgeInsets.zero,
      child: Text(
        safeText,
        style: TextStyle(
          color: textColor.withValues(alpha: 0.95),
          fontSize: 16,
          height: 1.45,
        ),
      ),
    );
  }

  Widget _buildTypingBubble(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 10),
      child: _TypingDots(),
    );
  }

  String _formatTimestamp(BuildContext context) {
    final localizations = MaterialLocalizations.of(context);
    final mediaQuery = MediaQuery.maybeOf(context);
    final time = TimeOfDay.fromDateTime(message.timestamp);

    return localizations.formatTimeOfDay(
      time,
      alwaysUse24HourFormat: mediaQuery?.alwaysUse24HourFormat ?? false,
    );
  }

  Widget _buildMediaPart(BuildContext context, LlamaContentPart part) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      constraints: const BoxConstraints(maxWidth: 320, maxHeight: 320),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: Theme.of(
            context,
          ).colorScheme.outlineVariant.withValues(alpha: 0.7),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: _buildPartContent(part),
    );
  }

  Widget _buildPartContent(LlamaContentPart part) {
    if (part is LlamaImageContent) {
      if (!kIsWeb && part.path != null) {
        return Image.file(File(part.path!), fit: BoxFit.cover);
      } else if (part.bytes != null) {
        return Image.memory(part.bytes!, fit: BoxFit.cover);
      }
    } else if (part is LlamaAudioContent) {
      return Container(
        padding: const EdgeInsets.all(12),
        color: Colors.black12,
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.audiotrack),
            SizedBox(width: 8),
            Text('Audio message'),
          ],
        ),
      );
    }
    return const Icon(Icons.description);
  }

  Widget _buildToolCallView(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final toolCalls = message.parts?.whereType<LlamaToolCallContent>().toList();
    final toolResults = message.parts
        ?.whereType<LlamaToolResultContent>()
        .toList();

    if (toolCalls == null || toolCalls.isEmpty) {
      return _buildMarkdownBubble(
        context,
        sanitizeForTextLayout(message.text),
        bubbleColor: colorScheme.surfaceContainerHighest,
        textColor: colorScheme.onSurface,
        border: BorderRadius.circular(12),
        isUser: false,
      );
    }

    return ToolExecutionCard(
      toolCalls: toolCalls,
      toolResults: toolResults ?? const [],
    );
  }

  Widget _buildThinkingView(BuildContext context, String thinkingText) {
    final safeThinkingText = sanitizeForTextLayout(thinkingText);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      width: double.infinity,
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 10),
        childrenPadding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: Theme.of(
              context,
            ).colorScheme.outlineVariant.withValues(alpha: 0.55),
          ),
        ),
        collapsedShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: Theme.of(
              context,
            ).colorScheme.outlineVariant.withValues(alpha: 0.35),
          ),
        ),
        title: Row(
          children: [
            Icon(
              Icons.psychology,
              size: 16,
              color: Theme.of(context).colorScheme.secondary,
            ),
            const SizedBox(width: 8),
            Text(
              'Thought process',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.secondary,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: Theme.of(
                  context,
                ).colorScheme.outlineVariant.withValues(alpha: 0.35),
              ),
            ),
            child: Text(
              safeThinkingText,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AssistantActions extends StatefulWidget {
  final String text;
  final VoidCallback? onRegenerate;

  const _AssistantActions({required this.text, this.onRegenerate});

  @override
  State<_AssistantActions> createState() => _AssistantActionsState();
}

class _AssistantActionsState extends State<_AssistantActions> {
  bool _hovered = false;

  Future<void> _copyResponse() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    if (!mounted) return;

    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('Response copied'),
          duration: Duration(milliseconds: 1400),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedOpacity(
        opacity: _hovered ? 1 : 0.55,
        duration: const Duration(milliseconds: 140),
        child: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                onPressed: _copyResponse,
                tooltip: 'Copy response',
                visualDensity: VisualDensity.compact,
                iconSize: 17,
                color: colorScheme.onSurfaceVariant,
                icon: const Icon(
                  Icons.content_copy_rounded,
                  semanticLabel: kIsWeb ? null : 'Copy response',
                ),
              ),
              if (widget.onRegenerate != null)
                IconButton(
                  onPressed: widget.onRegenerate,
                  tooltip: 'Regenerate response',
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  color: colorScheme.onSurfaceVariant,
                  icon: const Icon(
                    Icons.refresh_rounded,
                    semanticLabel: kIsWeb ? null : 'Regenerate response',
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MessageMeta extends StatefulWidget {
  final String roleLabel;
  final String timestamp;

  const _MessageMeta({required this.roleLabel, required this.timestamp});

  @override
  State<_MessageMeta> createState() => _MessageMetaState();
}

class _MessageMetaState extends State<_MessageMeta> {
  bool _showTimestamp = false;

  void _setTimestampVisible(bool visible) {
    if (_showTimestamp == visible) return;
    setState(() {
      _showTimestamp = visible;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return MouseRegion(
      onEnter: (_) => _setTimestampVisible(true),
      onExit: (_) => _setTimestampVisible(false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPress: () => _setTimestampVisible(!_showTimestamp),
        child: Tooltip(
          message: widget.timestamp,
          child: AnimatedSize(
            duration: const Duration(milliseconds: 140),
            curve: Curves.easeOutCubic,
            child: Text(
              _showTimestamp
                  ? '${widget.roleLabel}  ·  ${widget.timestamp}'
                  : widget.roleLabel,
              style: TextStyle(
                fontSize: 12,
                color: colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.1,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TypingDots extends StatefulWidget {
  const _TypingDots();

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSecondaryContainer;

    return SizedBox(
      width: 38,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final progress = _controller.value;
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: List.generate(3, (index) {
              final phase = (progress + (index * 0.2)) % 1.0;
              final alpha =
                  ((0.3 + (0.7 * (1.0 - (phase - 0.5).abs() * 2.0))).clamp(
                            0.25,
                            1.0,
                          )
                          as num)
                      .toDouble();

              return Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: alpha),
                  shape: BoxShape.circle,
                ),
              );
            }),
          );
        },
      ),
    );
  }
}
