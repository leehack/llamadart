part of 'notebook_workspace_view.dart';

extension _NotebookRagPanelExtension on _NotebookWorkspaceViewState {
  Widget _buildRagCapturePanel(
    BuildContext context,
    StudioDependencies deps,
    StudioPalette palette,
    NotebookState state,
    StudioRuntimeSnapshot runtime, {
    required bool isBusy,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: palette.surfaceElevated,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: palette.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          TextField(
            key: const Key('vault_search_input'),
            controller: _searchCtrl,
            decoration: const InputDecoration(
              labelText: 'Ask or search your notes',
              hintText: 'What would you like to find out?',
              prefixIcon: Icon(Icons.search_rounded, size: 18),
            ),
            onSubmitted: isBusy || state.isAnsweringNotebook
                ? null
                : (String q) async {
                    await _saveCurrentNote(deps);
                    await deps.notebookController.askNotebook(q);
                  },
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              StudioPillBadge(
                label: runtime.isReady
                    ? 'Q&A Model: ${runtime.activeModelLabel ?? "Loaded"}'
                    : 'A cached chat model loads when you ask',
                foreground: runtime.isReady ? palette.teal : palette.textMuted,
                monospace: true,
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  OutlinedButton.icon(
                    key: const Key('vault_search_button'),
                    onPressed: isBusy
                        ? null
                        : () async {
                            await _saveCurrentNote(deps);
                            await deps.notebookController.searchNotes(
                              _searchCtrl.text,
                            );
                          },
                    icon: const Icon(Icons.manage_search_rounded, size: 16),
                    label: const Text('Search'),
                  ),
                  if (state.isAnsweringNotebook)
                    FilledButton.tonalIcon(
                      key: const Key('notebook_cancel_ask_button'),
                      onPressed: deps.notebookController.cancelNotebookAnswer,
                      icon: Icon(
                        Icons.stop_circle_outlined,
                        size: 16,
                        color: palette.danger,
                      ),
                      label: Text(
                        'Stop',
                        style: TextStyle(color: palette.danger),
                      ),
                    )
                  else
                    FilledButton.icon(
                      key: const Key('notebook_ask_button'),
                      onPressed: isBusy
                          ? null
                          : () async {
                              await _saveCurrentNote(deps);
                              await deps.notebookController.askNotebook(
                                _searchCtrl.text,
                              );
                            },
                      icon: const Icon(Icons.auto_awesome_rounded, size: 16),
                      label: const Text('Ask Notebook'),
                    ),
                ],
              ),
            ],
          ),
          if (state.isAnsweringNotebook ||
              state.notebookAnswerText.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            Container(
              key: const Key('notebook_answer_card'),
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: palette.canvas,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: state.isAnsweringNotebook
                      ? palette.accent.withValues(alpha: 0.65)
                      : palette.teal.withValues(alpha: 0.45),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      StatusPulseDot(
                        color: state.isAnsweringNotebook
                            ? palette.accent
                            : palette.teal,
                        pulsing: state.isAnsweringNotebook,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          state.isAnsweringNotebook
                              ? 'Synthesizing grounded answer...'
                              : 'Grounded Notebook Answer',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: palette.textPrimary,
                          ),
                        ),
                      ),
                      if (state.notebookAnswerElapsedMs != null &&
                          !state.isAnsweringNotebook)
                        StudioPillBadge(
                          label: '${state.notebookAnswerElapsedMs} ms',
                          foreground: palette.teal,
                          monospace: true,
                        ),
                    ],
                  ),
                  if (state.notebookAnswerText.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 8),
                    MarkdownBody(
                      data: state.notebookAnswerText,
                      selectable: true,
                      syntaxHighlighter: StudioMarkdownSyntaxHighlighter(
                        palette: palette,
                        brightness: Theme.of(context).brightness,
                      ),
                      styleSheet:
                          MarkdownStyleSheet.fromTheme(
                            Theme.of(context),
                          ).copyWith(
                            p: TextStyle(
                              fontSize: 13,
                              height: 1.5,
                              color: palette.textPrimary,
                            ),
                            code: TextStyle(
                              fontSize: 12,
                              color: palette.teal,
                              backgroundColor: palette.surfaceElevated,
                              fontFamilyFallback: StudioTheme.monoFontFallback,
                            ),
                          ),
                    ),
                  ],
                  if (state.notebookAnswerSources.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: List<Widget>.generate(
                        state.notebookAnswerSources.length,
                        (int i) {
                          final src = state.notebookAnswerSources[i];
                          return ActionChip(
                            avatar: Icon(
                              _NotebookWorkspaceViewState._iconForKind(
                                src.note.sourceKind,
                              ),
                              size: 14,
                              color: palette.teal,
                            ),
                            label: Text(
                              'Source ${i + 1}: ${src.note.title}',
                              style: const TextStyle(fontSize: 11),
                            ),
                            onPressed: () async {
                              await _saveCurrentNote(deps);
                              deps.notebookController.selectNote(src.note.id);
                            },
                          );
                        },
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
          if (state.noteSearchHits.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: palette.canvas,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: palette.borderSubtle),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: <Widget>[
                      Text(
                        'TOP SEMANTIC MATCHES (${state.noteSearchHits.length})',
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.6,
                          color: palette.textMuted,
                        ),
                      ),
                      FilledButton.tonalIcon(
                        key: const Key('vault_send_to_chat_button'),
                        onPressed: () => _sendVaultToChat(deps),
                        icon: const Icon(Icons.auto_awesome, size: 15),
                        label: const Text('Send Hits to Chat (RAG)'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  for (var i = 0; i < state.noteSearchHits.length; i++)
                    InkWell(
                      onTap: () async {
                        await _saveCurrentNote(deps);
                        deps.notebookController.selectNote(
                          state.noteSearchHits[i].note.id,
                        );
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 5),
                        child: Row(
                          children: <Widget>[
                            StudioPillBadge(
                              label: '#${i + 1}',
                              foreground: i == 0
                                  ? palette.teal
                                  : palette.textSecondary,
                              monospace: true,
                            ),
                            const SizedBox(width: 8),
                            Icon(
                              _NotebookWorkspaceViewState._iconForKind(
                                state.noteSearchHits[i].note.sourceKind,
                              ),
                              size: 14,
                              color: palette.textSecondary,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                state.noteSearchHits[i].note.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600,
                                  color: palette.textPrimary,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            StudioPillBadge(
                              label:
                                  'cos ${state.noteSearchHits[i].cosineScore.toStringAsFixed(2)}',
                              foreground: palette.accent,
                              monospace: true,
                            ),
                            if (state.noteSearchHits[i].rerankScore !=
                                null) ...<Widget>[
                              const SizedBox(width: 6),
                              StudioPillBadge(
                                label:
                                    'rr ${state.noteSearchHits[i].rerankScore!.toStringAsFixed(2)}',
                                foreground: palette.teal,
                                monospace: true,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
