part of 'coding_workspace_view.dart';

extension _CodingAgentChatPane on _CodingWorkspaceViewState {
  Widget _buildApproval(StudioDependencies deps, CodingWorkspaceState state) =>
      _PendingBashApprovalBanner(
        approval: state.pendingShellApproval!,
        onApprove: () =>
            deps.codingController.resolveShellCommandApproval(true),
        onReject: () =>
            deps.codingController.resolveShellCommandApproval(false),
        onStop: deps.codingController.cancelGeneration,
      );

  Widget _buildAgentPane(
    BuildContext context,
    StudioDependencies deps,
    StudioPalette palette,
    CodingWorkspaceState codingState,
    McpManagerState mcpState,
    SkillRegistryState skillState, {
    bool includeControls = true,
  }) {
    if (includeControls && codingState.pendingShellApproval != null) {
      return _buildApproval(deps, codingState);
    }
    return Column(
      children: [
        Expanded(
          child: codingState.messages.isEmpty
              ? ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
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
                    for (final prompt in const [
                      'Explain this project',
                      'Find an edge case',
                      'Explain the open file',
                    ])
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: OutlinedButton(
                            onPressed: () => _promptCtrl.text = prompt,
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size(48, 48),
                            ),
                            child: Text(prompt),
                          ),
                        ),
                      ),
                  ],
                )
              : NotificationListener<ScrollNotification>(
                  onNotification: _handleCodingScrollNotification,
                  child: ListView(
                    key: const Key('coding_conversation'),
                    controller: _chatScrollCtrl,
                    padding: const EdgeInsets.all(18),
                    children: [
                      for (final msg in codingState.messages)
                        _CodingMessageCard(
                          message: msg,
                          recentChanges: codingState.recentChanges,
                          onRevertChange: deps.codingController.revertChange,
                          onOpenFile: _openFileAndReveal,
                        ),
                      ToolAvailabilityNoticeCard(
                        notices: codingState.toolAvailabilityNotices,
                        onChooseModel: () => deps.shellController
                            .selectWorkspace(StudioWorkspace.models),
                      ),
                      StoreBuilder<ActiveTurnStreamState>(
                        store: deps.codingController.activeStreamStore,
                        builder: (context, stream) => stream.isGenerating
                            ? _CodingStreamingCard(stream: stream)
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ),
                ),
        ),
        if (includeControls)
          _buildComposer(context, deps, palette, codingState),
      ],
    );
  }

  Widget _buildComposer(
    BuildContext context,
    StudioDependencies deps,
    StudioPalette palette,
    CodingWorkspaceState state,
  ) {
    final compact = _compactLayout;
    // Scaffold has already consumed keyboard insets; use the pane's constraints.
    final shortPane = _shortCodingPane;
    return Container(
      key: const Key('coding_composer'),
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: palette.surfaceElevated,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: palette.borderStrong),
      ),
      child: StoreSelector<ActiveTurnStreamState, (bool, String?)>(
        store: deps.codingController.activeStreamStore,
        selector: (s) => (s.isGenerating, s.statusLabel),
        builder: (context, activity) {
          final running = activity.$1;
          final input = TextField(
            key: const Key('coding_prompt_input'),
            controller: _promptCtrl,
            focusNode: _promptFocusNode,
            minLines: 1,
            maxLines: compact ? (shortPane ? 1 : 2) : 6,
            onTapOutside: compact ? (_) => _promptFocusNode.unfocus() : null,
            decoration: const InputDecoration(
              hintText: 'Ask about your code…',
              filled: false,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
            ),
          );
          final action = running
              ? FilledButton.tonalIcon(
                  key: const Key('coding_stop_button'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(48, 48),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                  onPressed: deps.codingController.cancelGeneration,
                  icon: Icon(
                    Icons.stop_circle_outlined,
                    size: 17,
                    color: palette.danger,
                  ),
                  label: const Text('Stop'),
                )
              : FilledButton.icon(
                  key: const Key('coding_send_button'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(48, 48),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                  onPressed: _submitPrompt,
                  icon: const Icon(Icons.arrow_upward_rounded, size: 16),
                  label: Text(compact ? 'Send' : 'Run Agent'),
                );
          final hasContext =
              state.selectedFileSlice != null &&
              state.includeSelectedFileContext;
          final badges = SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                if (hasContext)
                  StudioPillBadge(
                    label: 'Context: ${state.selectedFileSlice!.relativePath}',
                    foreground: palette.accent,
                    monospace: true,
                  ),
                if (running)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Text(
                      activity.$2 ?? 'Running',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
              ],
            ),
          );
          final inlineAction = compact && shortPane;
          // Send/Stop must not count as an outside tap and dismiss the editor.
          return TextFieldTapRegion(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Reparenting the focused field during keyboard resize closes it.
                Row(
                  children: [
                    Expanded(child: input),
                    if (inlineAction) ...[const SizedBox(width: 8), action],
                  ],
                ),
                if (inlineAction && (hasContext || running)) badges,
                if (!inlineAction)
                  Row(
                    children: [
                      Expanded(child: badges),
                      const SizedBox(width: 8),
                      action,
                    ],
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _PendingBashApprovalBanner extends StatelessWidget {
  const _PendingBashApprovalBanner({
    required this.approval,
    required this.onApprove,
    required this.onReject,
    required this.onStop,
  });
  final PendingShellCommandApproval approval;
  final VoidCallback onApprove;
  final VoidCallback onReject;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final palette = StudioPalette.of(context);
    return Container(
      key: const Key('coding_command_approval_banner'),
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.amber.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.amber.withValues(alpha: 0.55)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: SingleChildScrollView(
              key: const Key('coding_approval_scroll'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Approve shell command?',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 140),
                    child: SingleChildScrollView(
                      key: const Key('coding_approval_command_scroll'),
                      child: StudioSelectableText(
                        approval.command,
                        style: TextStyle(
                          fontSize: 12,
                          color: palette.textPrimary,
                          fontFamilyFallback: StudioTheme.monoFontFallback,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  StudioSelectableText(
                    'cwd: ${approval.workspaceRoot}',
                    style: TextStyle(fontSize: 12, color: palette.textMuted),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  key: const Key('coding_reject_bash_button'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(48, 48),
                  ),
                  onPressed: onReject,
                  child: const Text('Reject'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  key: const Key('coding_approve_bash_button'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(48, 48),
                  ),
                  onPressed: onApprove,
                  child: const Text('Approve'),
                ),
              ),
            ],
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              key: const Key('coding_approval_stop_button'),
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: onStop,
              icon: const Icon(Icons.stop_circle_outlined),
              label: const Text('Stop agent'),
            ),
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
              Expanded(
                child: Text(
                  isUser ? 'You' : 'Coding Agent',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: palette.textPrimary,
                  ),
                ),
              ),
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
                  StudioSelectableText(
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
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    minHeight: 48,
                                  ),
                                  child: Align(
                                    alignment: Alignment.centerLeft,
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
                              ),
                            ),
                          ],
                        ),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: <Widget>[
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
                                  visualDensity: VisualDensity.standard,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  minimumSize: const Size(48, 48),
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
                        if (!call.isRunning)
                          Material(
                            type: MaterialType.transparency,
                            child: ExpansionTile(
                              key: ValueKey('coding_tool_details_${call.id}'),
                              dense: true,
                              tilePadding: EdgeInsets.zero,
                              title: Text(
                                call.isError
                                    ? 'Failed · Details'
                                    : 'Completed · Details',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: call.isError
                                      ? palette.danger
                                      : palette.textSecondary,
                                ),
                              ),
                              children: <Widget>[
                                ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxHeight: 240,
                                  ),
                                  child: SingleChildScrollView(
                                    child: Align(
                                      alignment: Alignment.centerLeft,
                                      child: StudioSelectableText(
                                        'Arguments: ${call.argumentsJson}\n\nResult: ${call.resultJson ?? '(no result)'}',
                                        style: TextStyle(
                                          fontSize: 11.5,
                                          color: palette.textPrimary,
                                          fontFamilyFallback:
                                              StudioTheme.monoFontFallback,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
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
            SelectionArea(
              child: MarkdownBody(
                data: message.text,
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
            Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    StatusPulseDot(color: palette.accent, pulsing: true),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        stream.statusLabel ?? 'Coding Agent · Streaming',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: palette.textPrimary,
                        ),
                      ),
                    ),
                  ],
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
