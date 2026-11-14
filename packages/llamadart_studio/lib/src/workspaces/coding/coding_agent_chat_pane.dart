part of 'coding_workspace_view.dart';

extension _CodingAgentChatPane on _CodingWorkspaceViewState {
  Widget _buildAgentPane(
    BuildContext context,
    StudioDependencies deps,
    StudioPalette palette,
    CodingWorkspaceState codingState,
    McpManagerState mcpState,
    SkillRegistryState skillState,
  ) {
    return Column(
      children: <Widget>[
        Expanded(
          child: codingState.messages.isEmpty
              ? ListView(
                  padding: const EdgeInsets.all(24),
                  children: <Widget>[
                    Text(
                      'What would you like to build?',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: palette.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Explore your code, ask a question, or describe a change. Review file edits before keeping them.',
                      style: TextStyle(
                        fontSize: 13,
                        color: palette.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: <Widget>[
                        for (final prompt in const <String>[
                          'Inspect the workspace structure and summarize the architecture.',
                          'Search for TODO or error handling edge cases and suggest minimal fixes.',
                          'Read the currently selected file and explain key invariants.',
                        ])
                          ActionChip(
                            label: Text(
                              prompt,
                              style: const TextStyle(fontSize: 12),
                            ),
                            onPressed: () {
                              _promptCtrl.text = prompt;
                            },
                          ),
                      ],
                    ),
                  ],
                )
              : NotificationListener<ScrollNotification>(
                  onNotification: _handleCodingScrollNotification,
                  child: ListView(
                    controller: _chatScrollCtrl,
                    padding: const EdgeInsets.all(18),
                    children: <Widget>[
                      for (final msg in codingState.messages)
                        _CodingMessageCard(
                          message: msg,
                          recentChanges: codingState.recentChanges,
                          onRevertChange: deps.codingController.revertChange,
                          onOpenFile: deps.codingController.openFile,
                        ),
                      StoreBuilder<ActiveTurnStreamState>(
                        store: deps.codingController.activeStreamStore,
                        builder:
                            (
                              BuildContext context,
                              ActiveTurnStreamState stream,
                            ) {
                              if (!stream.isGenerating) {
                                return const SizedBox.shrink();
                              }
                              return _CodingStreamingCard(stream: stream);
                            },
                      ),
                    ],
                  ),
                ),
        ),
        if (codingState.pendingShellApproval != null)
          _PendingBashApprovalBanner(
            approval: codingState.pendingShellApproval!,
            onApprove: () =>
                deps.codingController.resolveShellCommandApproval(true),
            onReject: () =>
                deps.codingController.resolveShellCommandApproval(false),
          ),
        Container(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: palette.surfaceElevated,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: palette.borderStrong),
            ),
            child: StoreSelector<ActiveTurnStreamState, bool>(
              store: deps.codingController.activeStreamStore,
              selector: (ActiveTurnStreamState s) => s.isGenerating,
              builder: (BuildContext context, bool isGenerating) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    TextField(
                      key: const Key('coding_prompt_input'),
                      controller: _promptCtrl,
                      focusNode: _promptFocusNode,
                      minLines: 1,
                      maxLines: 6,
                      decoration: const InputDecoration(
                        hintText: 'Describe a change or ask about your code…',
                        filled: false,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: <Widget>[
                                if (codingState.selectedFileSlice != null &&
                                    codingState.includeSelectedFileContext)
                                  Padding(
                                    padding: const EdgeInsets.only(right: 6),
                                    child: StudioPillBadge(
                                      label:
                                          'Context: ${codingState.selectedFileSlice!.relativePath}',
                                      foreground: palette.accent,
                                      monospace: true,
                                    ),
                                  ),
                                if (mcpState.activeTools.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(right: 6),
                                    child: StudioPillBadge(
                                      label:
                                          '${mcpState.activeTools.length} MCP tools',
                                      foreground: palette.teal,
                                      monospace: true,
                                    ),
                                  ),
                                if (skillState.activeSkills.isNotEmpty)
                                  StudioPillBadge(
                                    label:
                                        '${skillState.activeSkills.length} skills',
                                    foreground: palette.amber,
                                    monospace: true,
                                  ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (isGenerating)
                          FilledButton.tonalIcon(
                            key: const Key('coding_stop_button'),
                            onPressed: deps.codingController.cancelGeneration,
                            icon: Icon(
                              Icons.stop_circle_outlined,
                              size: 17,
                              color: palette.danger,
                            ),
                            label: Text(
                              'Stop',
                              style: TextStyle(color: palette.danger),
                            ),
                          )
                        else
                          FilledButton.icon(
                            key: const Key('coding_send_button'),
                            onPressed: _submitPrompt,
                            icon: const Icon(
                              Icons.arrow_upward_rounded,
                              size: 16,
                            ),
                            label: const Text('Run Agent'),
                          ),
                      ],
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _PendingBashApprovalBanner extends StatelessWidget {
  const _PendingBashApprovalBanner({
    required this.approval,
    required this.onApprove,
    required this.onReject,
  });

  final PendingShellCommandApproval approval;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final palette = StudioPalette.of(context);
    return Container(
      key: const Key('coding_command_approval_banner'),
      margin: const EdgeInsets.fromLTRB(16, 6, 16, 2),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.amber.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.amber.withValues(alpha: 0.55)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.terminal_rounded, size: 16, color: palette.amber),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Approve shell command?',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: palette.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: palette.canvas,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: palette.borderSubtle),
            ),
            child: SelectableText(
              approval.command,
              style: TextStyle(
                fontSize: 11.5,
                color: palette.textPrimary,
                fontFamilyFallback: StudioTheme.monoFontFallback,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              Text(
                'cwd: ${approval.workspaceRoot}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10.5,
                  color: palette.textMuted,
                  fontFamilyFallback: StudioTheme.monoFontFallback,
                ),
              ),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: <Widget>[
                  OutlinedButton(
                    key: const Key('coding_reject_bash_button'),
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: onReject,
                    child: const Text('Reject'),
                  ),
                  FilledButton.icon(
                    key: const Key('coding_approve_bash_button'),
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: onApprove,
                    icon: const Icon(Icons.play_arrow_rounded, size: 16),
                    label: const Text('Approve & Run'),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CodingMessageCard extends StatelessWidget {
  const _CodingMessageCard({
    required this.message,
    required this.recentChanges,
    required this.onRevertChange,
    required this.onOpenFile,
  });

  final StudioMessage message;
  final List<CodingFileChange> recentChanges;
  final Future<bool> Function(String changeId) onRevertChange;
  final Future<void> Function(String relativePath) onOpenFile;

  CodingFileChange? _matchingChangeForCall(StudioToolInvocation call) {
    if (call.name != 'write' && call.name != 'edit') {
      return null;
    }
    try {
      final decoded = jsonDecode(call.argumentsJson);
      if (decoded is Map<String, Object?>) {
        final rawPath = decoded['path'];
        if (rawPath is String && rawPath.trim().isNotEmpty) {
          final normalized = rawPath.trim().replaceAll('\\', '/');
          for (final change in recentChanges) {
            if (change.relativePath == normalized) {
              return change;
            }
          }
        }
      }
    } catch (_) {
      // Ignore malformed JSON arguments in historic transcripts.
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final palette = StudioPalette.of(context);
    final isUser = message.role == StudioRole.user;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: palette.surfaceElevated,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: message.isError
              ? palette.danger.withValues(alpha: 0.6)
              : (isUser ? palette.borderSubtle : palette.borderStrong),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                isUser ? Icons.person_outline_rounded : Icons.code_rounded,
                size: 16,
                color: isUser ? palette.accent : palette.teal,
              ),
              const SizedBox(width: 8),
              Text(
                isUser ? 'You' : 'Coding Agent',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: palette.textPrimary,
                ),
              ),
              const Spacer(),
              if (message.metrics != null)
                StudioPillBadge(
                  label:
                      '${message.metrics!.tokensPerSecond.toStringAsFixed(1)} tok/s',
                  foreground: palette.teal,
                  monospace: true,
                ),
            ],
          ),
          if (message.hasThinking) ...<Widget>[
            const SizedBox(height: 8),
            Material(
              type: MaterialType.transparency,
              child: ExpansionTile(
                dense: true,
                tilePadding: EdgeInsets.zero,
                title: Text(
                  'Reasoning trace',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: palette.textSecondary,
                  ),
                ),
                children: <Widget>[
                  SelectableText(
                    message.thinkingText!,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: palette.textSecondary,
                      fontFamilyFallback: StudioTheme.monoFontFallback,
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (message.hasToolCalls) ...<Widget>[
            const SizedBox(height: 8),
            for (final call in message.toolCalls)
              Builder(
                builder: (BuildContext context) {
                  final matchedChange = _matchingChangeForCall(call);
                  final diffText = matchedChange == null
                      ? ''
                      : (matchedChange.unifiedDiff.isNotEmpty
                            ? matchedChange.unifiedDiff
                            : (matchedChange.beforePreview.isNotEmpty ||
                                      matchedChange.afterPreview.isNotEmpty
                                  ? '${matchedChange.beforePreview.isNotEmpty ? '- ${matchedChange.beforePreview.replaceAll('\n', '\n- ')}\n' : ''}+ ${matchedChange.afterPreview.replaceAll('\n', '\n+ ')}'
                                  : ''));
                  return Container(
                    margin: const EdgeInsets.only(bottom: 6),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: palette.canvas,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: palette.borderSubtle),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            Icon(
                              Icons.terminal_rounded,
                              size: 14,
                              color: call.isError
                                  ? palette.danger
                                  : palette.teal,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: InkWell(
                                onTap: matchedChange != null
                                    ? () =>
                                          onOpenFile(matchedChange.relativePath)
                                    : null,
                                child: Text(
                                  '${call.name}(${call.argumentsJson})',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    color: palette.textPrimary,
                                    fontFamilyFallback:
                                        StudioTheme.monoFontFallback,
                                  ),
                                ),
                              ),
                            ),
                            if (matchedChange != null &&
                                matchedChange.reverted) ...<Widget>[
                              const SizedBox(width: 6),
                              StudioPillBadge(
                                label: 'REVERTED',
                                foreground: palette.textMuted,
                                monospace: true,
                              ),
                            ] else if (matchedChange != null &&
                                matchedChange.canRevert) ...<Widget>[
                              const SizedBox(width: 6),
                              TextButton.icon(
                                style: TextButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  minimumSize: Size.zero,
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                ),
                                onPressed: () =>
                                    onRevertChange(matchedChange.id),
                                icon: Icon(
                                  Icons.undo_rounded,
                                  size: 13,
                                  color: palette.amber,
                                ),
                                label: Text(
                                  'Revert',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: palette.amber,
                                  ),
                                ),
                              ),
                            ],
                            if (call.durationMs != null) ...<Widget>[
                              const SizedBox(width: 6),
                              StudioPillBadge(
                                label: '${call.durationMs} ms',
                                monospace: true,
                              ),
                            ],
                          ],
                        ),
                        if (diffText.isNotEmpty) ...<Widget>[
                          const SizedBox(height: 6),
                          Container(
                            width: double.infinity,
                            constraints: const BoxConstraints(maxHeight: 120),
                            decoration: BoxDecoration(
                              color: palette.surfaceElevated,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: palette.borderSubtle),
                            ),
                            child: SingleChildScrollView(
                              child: SyntaxCodeView(
                                code: diffText,
                                language: 'diff',
                                showLineNumbers: false,
                                fontSize: 10.5,
                                padding: const EdgeInsets.all(6),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  );
                },
              ),
          ],
          if (message.text.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            MarkdownBody(
              data: message.text,
              selectable: true,
              syntaxHighlighter: StudioMarkdownSyntaxHighlighter(
                palette: palette,
                brightness: Theme.of(context).brightness,
              ),
              styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context))
                  .copyWith(
                    p: TextStyle(
                      fontSize: 13.5,
                      height: 1.5,
                      color: palette.textPrimary,
                    ),
                    code: TextStyle(
                      fontSize: 12,
                      color: palette.teal,
                      backgroundColor: palette.canvas,
                      fontFamilyFallback: StudioTheme.monoFontFallback,
                    ),
                    codeblockPadding: const EdgeInsets.all(12),
                    codeblockDecoration: BoxDecoration(
                      color: palette.canvas,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: palette.borderSubtle),
                    ),
                  ),
            ),
          ],
        ],
      ),
    );
  }
}

class _CodingStreamingCard extends StatelessWidget {
  const _CodingStreamingCard({required this.stream});

  final ActiveTurnStreamState stream;

  @override
  Widget build(BuildContext context) {
    final palette = StudioPalette.of(context);
    return RepaintBoundary(
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: palette.surfaceElevated,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: palette.accent.withValues(alpha: 0.6)),
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
                    stream.statusLabel ?? 'Coding Agent · Streaming',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: palette.textPrimary,
                    ),
                  ),
                ),
                StudioPillBadge(
                  label:
                      '${stream.liveTokensPerSecond.toStringAsFixed(1)} tok/s · ${stream.tokensGenerated} tok',
                  foreground: palette.teal,
                  monospace: true,
                ),
              ],
            ),
            if (stream.toolInvocations.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              for (final call in stream.toolInvocations)
                Text(
                  '• ${call.name}(${call.argumentsJson})',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: palette.teal,
                    fontFamilyFallback: StudioTheme.monoFontFallback,
                  ),
                ),
            ],
            if (stream.thinkingText.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                stream.thinkingText,
                maxLines: 6,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  color: palette.textSecondary,
                  fontFamilyFallback: StudioTheme.monoFontFallback,
                ),
              ),
            ],
            if (stream.text.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              MarkdownBody(
                data: stream.text,
                selectable: false,
                syntaxHighlighter: StudioMarkdownSyntaxHighlighter(
                  palette: palette,
                  brightness: Theme.of(context).brightness,
                ),
                styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context))
                    .copyWith(
                      p: TextStyle(
                        fontSize: 13.5,
                        height: 1.5,
                        color: palette.textPrimary,
                      ),
                      code: TextStyle(
                        fontSize: 12,
                        color: palette.teal,
                        backgroundColor: palette.canvas,
                        fontFamilyFallback: StudioTheme.monoFontFallback,
                      ),
                      codeblockPadding: const EdgeInsets.all(12),
                      codeblockDecoration: BoxDecoration(
                        color: palette.canvas,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: palette.borderSubtle),
                      ),
                    ),
              ),
            ],
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: StreamingCursor(),
            ),
          ],
        ),
      ),
    );
  }
}
