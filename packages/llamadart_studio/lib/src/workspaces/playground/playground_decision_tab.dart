part of 'playground_workspace_view.dart';

extension _PlaygroundDecisionTab on _PlaygroundWorkspaceViewState {
  Widget _buildDecisionCard(
    BuildContext context,
    StudioDependencies deps,
    PlaygroundWorkspaceState state,
    NotebookState notebookState, {
    required bool isBusy,
    required bool isWideDesktop,
  }) {
    final palette = StudioPalette.of(context);
    final eval = state.decisionEvaluation;
    final batch = state.decisionBatchEvaluation;

    _syncDecisionInputCollapse(state, isWideDesktop: isWideDesktop);
    final hasResult = _hasDecisionResultForMode(state);

    final Widget expandedInputForm = switch (state.decisionMode) {
      DecisionWorkflowMode.triageRouter => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          TextField(
            key: const Key('decision_triage_input'),
            controller: _triageInputCtrl,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Incoming Developer Request / Task',
            ),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              key: const Key('decision_run_triage_button'),
              onPressed: isBusy
                  ? null
                  : () => deps.playgroundController.runTriageRouterWorkflow(
                      _triageInputCtrl.text,
                    ),
              icon: const Icon(Icons.alt_route_rounded, size: 16),
              label: Text(
                state.isEvaluating
                    ? 'Evaluating...'
                    : 'Route Request (Single Pass)',
              ),
            ),
          ),
        ],
      ),
      DecisionWorkflowMode.guardrailPreflight => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          TextField(
            key: const Key('decision_preflight_input'),
            controller: _preflightInputCtrl,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Prompt or Tool Command to Inspect Before Execution',
            ),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              key: const Key('decision_run_preflight_button'),
              onPressed: isBusy
                  ? null
                  : () =>
                        deps.playgroundController.runGuardrailPreflightWorkflow(
                          _preflightInputCtrl.text,
                        ),
              icon: const Icon(Icons.verified_user_outlined, size: 16),
              label: Text(
                state.isEvaluating
                    ? 'Checking...'
                    : 'Run Safety & Ambiguity Preflight',
              ),
            ),
          ),
        ],
      ),
      DecisionWorkflowMode.vaultAudit => Wrap(
        spacing: 10,
        runSpacing: 10,
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          FilterChip(
            label: const Text('Auto-apply tags to Vault notes'),
            selected: _applyAuditTags,
            onSelected: (bool v) => _updateState(() => _applyAuditTags = v),
          ),
          FilledButton.icon(
            key: const Key('decision_run_audit_button'),
            onPressed: isBusy
                ? null
                : () => deps.playgroundController.auditVaultNotes(
                    applyTagsToNotes: _applyAuditTags,
                  ),
            icon: const Icon(Icons.fact_check_outlined, size: 16),
            label: Text(
              state.isEvaluating
                  ? 'Auditing Notes...'
                  : 'Audit ${notebookState.notes.length} Vault Notes',
            ),
          ),
        ],
      ),
      DecisionWorkflowMode.customChecklist => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          TextField(
            controller: _customStateCtrl,
            maxLines: 3,
            decoration: const InputDecoration(labelText: 'Context / Document'),
          ),
          const SizedBox(height: 10),
          for (var i = 0; i < _customCriteria.length; i++)
            Container(
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: palette.canvas,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: palette.borderSubtle),
              ),
              child: Row(
                children: <Widget>[
                  StudioPillBadge(
                    label: _customCriteria[i].kind.name.toUpperCase(),
                    foreground: palette.accent,
                    monospace: true,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _customCriteria[i].prompt,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    onPressed: () =>
                        _updateState(() => _customCriteria.removeAt(i)),
                    icon: const Icon(Icons.close_rounded, size: 15),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              SegmentedButton<_CustomQuestionKind>(
                showSelectedIcon: false,
                style: SegmentedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                segments: const <ButtonSegment<_CustomQuestionKind>>[
                  ButtonSegment<_CustomQuestionKind>(
                    value: _CustomQuestionKind.choice,
                    label: Text('Choice', style: TextStyle(fontSize: 11)),
                  ),
                  ButtonSegment<_CustomQuestionKind>(
                    value: _CustomQuestionKind.score,
                    label: Text('Score 1-5', style: TextStyle(fontSize: 11)),
                  ),
                  ButtonSegment<_CustomQuestionKind>(
                    value: _CustomQuestionKind.noul,
                    label: Text('Yes/No', style: TextStyle(fontSize: 11)),
                  ),
                ],
                selected: <_CustomQuestionKind>{_newCriterionKind},
                onSelectionChanged: (Set<_CustomQuestionKind> next) {
                  _updateState(() => _newCriterionKind = next.first);
                },
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: TextField(
                  controller: _customPromptInputCtrl,
                  decoration: const InputDecoration(
                    labelText: 'New Criterion Question',
                  ),
                ),
              ),
              if (_newCriterionKind == _CustomQuestionKind.choice)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 200),
                  child: TextField(
                    controller: _customLabelsInputCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Labels (CSV)',
                    ),
                  ),
                ),
              OutlinedButton.icon(
                onPressed: () {
                  final prompt = _customPromptInputCtrl.text.trim();
                  if (prompt.isEmpty) {
                    return;
                  }
                  _updateState(() {
                    _customCriteria.add(
                      _CustomCriterionDraft(
                        id: 'custom_${_customCriteria.length + 1}',
                        kind: _newCriterionKind,
                        prompt: prompt,
                        labelsCsv: _customLabelsInputCtrl.text,
                      ),
                    );
                    _customPromptInputCtrl.clear();
                  });
                },
                icon: const Icon(Icons.add_rounded, size: 16),
                label: const Text('Add'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              key: const Key('decision_run_custom_button'),
              onPressed: isBusy || _customCriteria.isEmpty
                  ? null
                  : () {
                      deps.playgroundController.runDecisionBatch(
                        state: _customStateCtrl.text,
                        questions: _buildCustomQuestionSpecs(),
                      );
                    },
              icon: const Icon(Icons.playlist_play_rounded, size: 17),
              label: const Text('Evaluate Custom Rubric'),
            ),
          ),
        ],
      ),
      DecisionWorkflowMode.quickNoul => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          TextField(
            controller: _decisionStateCtrl,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Observed State / Context',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _decisionQuestionCtrl,
            decoration: const InputDecoration(
              labelText: 'Binary Yes/No Question (System-1 noul)',
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              key: const Key('run_decision_button'),
              onPressed: isBusy
                  ? null
                  : () => deps.playgroundController.runDecisionHead(
                      stateText: _decisionStateCtrl.text,
                      yesNoQuestion: _decisionQuestionCtrl.text,
                    ),
              icon: const Icon(Icons.bolt_rounded, size: 16),
              label: Text(
                state.isEvaluating ? 'Evaluating...' : 'Evaluate System-1',
              ),
            ),
          ),
        ],
      ),
    };

    final Widget inputPane = _decisionInputsCollapsed
        ? Container(
            key: const Key('decision_collapsed_inputs_bar'),
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: palette.canvas,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: palette.borderSubtle),
            ),
            child: Wrap(
              spacing: 8,
              runSpacing: 6,
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: <Widget>[
                      StudioPillBadge(
                        label: state.decisionMode.label,
                        foreground: palette.accent,
                        monospace: true,
                      ),
                      Text(
                        _decisionInputPreview(state, notebookState),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: palette.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                TextButton.icon(
                  key: const Key('decision_edit_inputs_button'),
                  onPressed: () =>
                      _updateState(() => _decisionInputsCollapsed = false),
                  icon: const Icon(Icons.edit_outlined, size: 15),
                  label: const Text('Edit Inputs'),
                ),
              ],
            ),
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (hasResult)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    key: const Key('decision_collapse_inputs_button'),
                    onPressed: () =>
                        _updateState(() => _decisionInputsCollapsed = true),
                    icon: const Icon(Icons.unfold_less_rounded, size: 15),
                    label: const Text('Hide Inputs'),
                  ),
                ),
              expandedInputForm,
            ],
          );

    final Widget? modeResultWidget = switch (state.decisionMode) {
      DecisionWorkflowMode.triageRouter =>
        batch == null
            ? null
            : _DecisionBatchResultsPanel(
                batch: batch,
                actionButton: _buildRoutingActionButton(deps, batch),
              ),
      DecisionWorkflowMode.guardrailPreflight =>
        batch == null
            ? null
            : _DecisionBatchResultsPanel(
                batch: batch,
                actionButton:
                    (batch.byId('action') as SystemOneChoiceAnswer?)?.choice ==
                        'proceed'
                    ? FilledButton.tonalIcon(
                        onPressed: () {
                          deps.chatController.setComposerDraft(
                            _preflightInputCtrl.text.trim(),
                          );
                          deps.shellController.selectWorkspace(
                            StudioWorkspace.chat,
                          );
                        },
                        icon: const Icon(Icons.send_outlined, size: 15),
                        label: const Text('Send Safe Prompt to Chat'),
                      )
                    : null,
              ),
      DecisionWorkflowMode.vaultAudit =>
        state.noteAuditResults.isEmpty
            ? null
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  for (final audit in state.noteAuditResults)
                    Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: palette.canvas,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: palette.borderSubtle),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              Expanded(
                                child: Text(
                                  audit.noteTitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: palette.textPrimary,
                                  ),
                                ),
                              ),
                              TextButton(
                                onPressed: () {
                                  deps.notebookController.selectNote(
                                    audit.noteId,
                                  );
                                  deps.shellController.selectWorkspace(
                                    StudioWorkspace.notes,
                                  );
                                },
                                child: const Text(
                                  'Open Note',
                                  style: TextStyle(fontSize: 11.5),
                                ),
                              ),
                            ],
                          ),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: <Widget>[
                              StudioPillBadge(
                                label: audit.category,
                                foreground: palette.accent,
                                monospace: true,
                              ),
                              StudioPillBadge(
                                label: 'urgency: ${audit.urgency}',
                                foreground: palette.amber,
                                monospace: true,
                              ),
                              StudioPillBadge(
                                label:
                                    'actionability: ${audit.actionabilityScore.toStringAsFixed(1)}/5',
                                foreground: palette.teal,
                                monospace: true,
                              ),
                              StudioPillBadge(
                                label:
                                    'todo: ${(audit.hasActionItem * 100).toStringAsFixed(0)}%',
                                monospace: true,
                              ),
                              StudioPillBadge(
                                label: '${audit.elapsedMs} ms',
                                monospace: true,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                ],
              ),
      DecisionWorkflowMode.customChecklist =>
        batch == null ? null : _DecisionBatchResultsPanel(batch: batch),
      DecisionWorkflowMode.quickNoul =>
        eval == null
            ? null
            : Container(
                padding: const EdgeInsets.all(14),
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
                      children: <Widget>[
                        StudioPillBadge(
                          label: eval.probabilityTrue >= 0.5 ? 'YES' : 'NO',
                          foreground: eval.probabilityTrue >= 0.5
                              ? palette.teal
                              : palette.amber,
                          monospace: true,
                        ),
                        StudioPillBadge(
                          label:
                              'P(true) ${(eval.probabilityTrue * 100).toStringAsFixed(1)}%',
                          monospace: true,
                        ),
                        StudioPillBadge(
                          label: '${eval.elapsedMs} ms · ${eval.deviceName}',
                          monospace: true,
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    AnimatedScoreBar(
                      fraction: eval.probabilityTrue,
                      color: eval.probabilityTrue >= 0.5
                          ? palette.teal
                          : palette.amber,
                    ),
                  ],
                ),
              ),
    };

    final resultsAndBenchPane = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (modeResultWidget != null) ...<Widget>[
          modeResultWidget,
          const SizedBox(height: 14),
        ] else if (isWideDesktop) ...<Widget>[
          _buildEmptyResultPlaceholder(
            palette,
            icon: Icons.bolt_rounded,
            title: '${state.decisionMode.label} Output',
            subtitle: 'Run the active System-1 workflow on the left to inspect single-pass classifications, confidences, and suggested actions.',
          ),
          const SizedBox(height: 14),
        ],
        _buildDecisionSpeedBurstPanel(context, deps, state, isBusy: isBusy),
      ],
    );

    return Container(
      key: const ValueKey<String>('tab_decision'),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: palette.surfaceElevated,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: palette.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: DecisionWorkflowMode.values.map((
              DecisionWorkflowMode mode,
            ) {
              return ChoiceChip(
                key: Key('decision_mode_${mode.id}'),
                label: Text(mode.label, style: const TextStyle(fontSize: 12)),
                selected: state.decisionMode == mode,
                onSelected: (_) {
                  _updateState(() => _decisionInputsCollapsed = false);
                  deps.playgroundController.selectDecisionMode(mode);
                },
              );
            }).toList(),
          ),
          const SizedBox(height: 14),
          if (isWideDesktop && !_decisionInputsCollapsed)
            _splitPane(
              isWideDesktop: true,
              inputPane: inputPane,
              resultPane: resultsAndBenchPane,
            )
          else ...<Widget>[
            inputPane,
            const SizedBox(height: 14),
            resultsAndBenchPane,
          ],
        ],
      ),
    );
  }

  List<SystemOneQuestionSpec> _buildCustomQuestionSpecs() {
    return <SystemOneQuestionSpec>[
      for (final c in _customCriteria)
        switch (c.kind) {
          _CustomQuestionKind.choice => SystemOneChoiceQuestionSpec(
            id: c.id,
            prompt: c.prompt,
            labels:
                _PlaygroundWorkspaceViewState._parseCsvTags(c.labelsCsv).isEmpty
                ? const <String>['option_a', 'option_b']
                : _PlaygroundWorkspaceViewState._parseCsvTags(c.labelsCsv),
          ),
          _CustomQuestionKind.score => SystemOneScoreQuestionSpec(
            id: c.id,
            prompt: c.prompt,
            levels: const <String>['1', '2', '3', '4', '5'],
          ),
          _CustomQuestionKind.noul => SystemOneNoulQuestionSpec(
            id: c.id,
            prompt: c.prompt,
          ),
        },
    ];
  }
}
