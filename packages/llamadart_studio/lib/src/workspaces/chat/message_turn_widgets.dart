part of 'message_turn_card.dart';

class _ThinkingDisclosureCard extends StatefulWidget {
  const _ThinkingDisclosureCard({
    required this.thinkingText,
    this.durationMs,
    this.initiallyExpanded = false,
    this.isStreaming = false,
  });

  final String thinkingText;
  final int? durationMs;
  final bool initiallyExpanded;
  final bool isStreaming;

  @override
  State<_ThinkingDisclosureCard> createState() =>
      _ThinkingDisclosureCardState();
}

class _ThinkingDisclosureCardState extends State<_ThinkingDisclosureCard> {
  final ScrollController _innerScrollController = ScrollController();
  late bool _expanded;
  bool _pinInnerBottom = true;
  bool _isProgrammaticInnerScroll = false;
  bool _innerFrameScheduled = false;

  @override
  void initState() {
    super.initState();
    _expanded = widget.initiallyExpanded;
    if (widget.isStreaming && _expanded) {
      _scheduleInnerScrollToBottom();
    }
  }

  @override
  void didUpdateWidget(covariant _ThinkingDisclosureCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.initiallyExpanded && widget.initiallyExpanded) {
      _expanded = true;
    }
    if (widget.isStreaming &&
        _expanded &&
        _pinInnerBottom &&
        widget.thinkingText != oldWidget.thinkingText) {
      _scheduleInnerScrollToBottom();
    }
    if (oldWidget.isStreaming && !widget.isStreaming) {
      // Collapse neatly once visible response starts streaming so the final
      // answer stays front-and-center while keeping thoughts 1 click away.
      _expanded = widget.initiallyExpanded && !oldWidget.initiallyExpanded;
    }
  }

  void _scheduleInnerScrollToBottom() {
    if (_innerFrameScheduled || !mounted) {
      return;
    }
    _innerFrameScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _innerFrameScheduled = false;
      if (!mounted || !_pinInnerBottom || !_innerScrollController.hasClients) {
        return;
      }
      final target = _innerScrollController.position.maxScrollExtent;
      if ((target - _innerScrollController.offset).abs() > 0.5) {
        _isProgrammaticInnerScroll = true;
        try {
          _innerScrollController.jumpTo(target);
        } finally {
          _isProgrammaticInnerScroll = false;
        }
      }
    });
  }

  @override
  void dispose() {
    _innerScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = StudioPalette.of(context);
    final durationLabel = widget.durationMs != null
        ? ' · ${(widget.durationMs! / 1000).toStringAsFixed(1)}s'
        : '';

    final thinkingBody = _expanded
        ? ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: widget.isStreaming ? 210 : 280,
            ),
            child: NotificationListener<ScrollUpdateNotification>(
              onNotification: (ScrollUpdateNotification n) {
                if (!_isProgrammaticInnerScroll) {
                  final dist = n.metrics.maxScrollExtent - n.metrics.pixels;
                  _pinInnerBottom = dist <= 36.0;
                }
                return false;
              },
              child: Scrollbar(
                controller: _innerScrollController,
                thumbVisibility: widget.isStreaming,
                child: SingleChildScrollView(
                  controller: _innerScrollController,
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                  child: SizedBox(
                    width: double.infinity,
                    child: widget.isStreaming
                        ? Text(
                            widget.thinkingText,
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.45,
                              color: palette.textSecondary,
                              fontFamilyFallback: StudioTheme.monoFontFallback,
                            ),
                          )
                        : SelectableText(
                            widget.thinkingText,
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.45,
                              color: palette.textSecondary,
                              fontFamilyFallback: StudioTheme.monoFontFallback,
                            ),
                          ),
                  ),
                ),
              ),
            ),
          )
        : const SizedBox.shrink();

    return Container(
      decoration: BoxDecoration(
        color: palette.canvas.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: palette.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              child: Row(
                children: <Widget>[
                  Icon(
                    Icons.psychology_outlined,
                    size: 15,
                    color: palette.amber,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      widget.isStreaming
                          ? 'Thinking...'
                          : 'Thought process$durationLabel',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: palette.textSecondary,
                      ),
                    ),
                  ),
                  Icon(
                    _expanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 16,
                    color: palette.textMuted,
                  ),
                ],
              ),
            ),
          ),
          if (widget.isStreaming)
            thinkingBody
          else
            AnimatedSize(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              child: thinkingBody,
            ),
        ],
      ),
    );
  }
}

class _ToolInvocationCard extends StatefulWidget {
  const _ToolInvocationCard({required this.invocation});

  final StudioToolInvocation invocation;

  @override
  State<_ToolInvocationCard> createState() => _ToolInvocationCardState();
}

class _ToolInvocationCardState extends State<_ToolInvocationCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final palette = StudioPalette.of(context);
    final call = widget.invocation;

    return Container(
      decoration: BoxDecoration(
        color: palette.canvas.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: call.isError
              ? palette.danger.withValues(alpha: 0.6)
              : palette.borderSubtle,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                children: <Widget>[
                  Icon(
                    call.isRunning
                        ? Icons.sync_rounded
                        : Icons.terminal_rounded,
                    size: 15,
                    color: call.isError ? palette.danger : palette.teal,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${call.name}(${call.argumentsJson})',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: palette.textPrimary,
                        fontFamilyFallback: StudioTheme.monoFontFallback,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  StudioPillBadge(
                    label: call.isRunning
                        ? 'Running'
                        : (call.durationMs != null
                              ? '${call.durationMs} ms'
                              : 'Done'),
                    foreground: call.isError ? palette.danger : palette.teal,
                    monospace: true,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Arguments: ${call.argumentsJson}',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: palette.textSecondary,
                      fontFamilyFallback: StudioTheme.monoFontFallback,
                    ),
                  ),
                  if (call.resultJson != null) ...<Widget>[
                    const SizedBox(height: 6),
                    Text(
                      'Result: ${call.resultJson}',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: palette.teal,
                        fontFamilyFallback: StudioTheme.monoFontFallback,
                      ),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _AttachmentChip extends StatelessWidget {
  const _AttachmentChip({required this.attachment});

  final StudioAttachment attachment;

  @override
  Widget build(BuildContext context) {
    final palette = StudioPalette.of(context);
    final provider = attachment.kind == StudioAttachmentKind.image
        ? StudioPlatformFileHelper.resolveImageProvider(
            bytes: attachment.bytes,
            localPath: attachment.localPath,
          )
        : null;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: palette.canvas,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: palette.borderSubtle),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (provider != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(5),
              child: Image(
                image: provider,
                width: 34,
                height: 34,
                fit: BoxFit.cover,
              ),
            )
          else
            Icon(
              attachment.kind == StudioAttachmentKind.image
                  ? Icons.image_outlined
                  : Icons.graphic_eq_rounded,
              size: 16,
              color: palette.accent,
            ),
          const SizedBox(width: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 160),
            child: Text(
              attachment.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: palette.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}

class _MarkdownMessageBody extends StatelessWidget {
  const _MarkdownMessageBody({
    required this.text,
    this.isError = false,
    this.isStreaming = false,
  });

  final String text;
  final bool isError;
  final bool isStreaming;

  @override
  Widget build(BuildContext context) {
    final palette = StudioPalette.of(context);
    if (isError) {
      return SelectableText(
        text,
        style: TextStyle(fontSize: 13, color: palette.danger, height: 1.45),
      );
    }

    return MarkdownBody(
      data: text,
      selectable: !isStreaming,
      syntaxHighlighter: StudioMarkdownSyntaxHighlighter(
        palette: palette,
        brightness: Theme.of(context).brightness,
      ),
      styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
        p: TextStyle(fontSize: 14, height: 1.55, color: palette.textPrimary),
        code: TextStyle(
          fontSize: 12.5,
          color: palette.teal,
          backgroundColor: palette.canvas,
          fontFamilyFallback: StudioTheme.monoFontFallback,
        ),
        codeblockDecoration: BoxDecoration(
          color: palette.canvas,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: palette.borderSubtle),
        ),
      ),
    );
  }
}

class _TurnTelemetryBar extends StatelessWidget {
  const _TurnTelemetryBar({required this.metrics, this.structuredJsonValid});

  final StudioTurnMetrics metrics;
  final bool? structuredJsonValid;

  @override
  Widget build(BuildContext context) {
    final palette = StudioPalette.of(context);
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: <Widget>[
        StudioPillBadge(
          label: '${metrics.tokensPerSecond.toStringAsFixed(1)} tok/s',
          foreground: palette.teal,
          monospace: true,
        ),
        if (metrics.firstTokenLatencyMs != null)
          StudioPillBadge(
            label: 'TTFT ${metrics.firstTokenLatencyMs} ms',
            monospace: true,
          ),
        StudioPillBadge(
          label: '${metrics.generatedTokens} tok',
          monospace: true,
        ),
        if (metrics.backendLabel != null && metrics.backendLabel!.isNotEmpty)
          StudioPillBadge(label: metrics.backendLabel!, monospace: true),
        if (structuredJsonValid != null)
          StudioPillBadge(
            label: structuredJsonValid! ? 'JSON Schema ✓' : 'Schema Mismatch',
            foreground: structuredJsonValid! ? palette.teal : palette.danger,
            monospace: true,
          ),
      ],
    );
  }
}
