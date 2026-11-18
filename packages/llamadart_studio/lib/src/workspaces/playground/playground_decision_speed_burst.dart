part of 'playground_workspace_view.dart';

extension _PlaygroundDecisionBurst on _PlaygroundWorkspaceViewState {
  Future<void> _runDecisionSpeedBurst(
    StudioDependencies deps,
    PlaygroundWorkspaceState state,
  ) async {
    late final Object burstState;
    late final List<SystemOneQuestionSpec> burstQuestions;
    switch (state.decisionMode) {
      case DecisionWorkflowMode.triageRouter:
        burstState = _triageInputCtrl.text;
        burstQuestions = const <SystemOneQuestionSpec>[
          SystemOneChoiceQuestionSpec(
            id: 'domain',
            prompt: 'Which workspace best handles this request?',
            labels: <String>[
              'coding_repo',
              'knowledge_notes',
              'tool_automation',
              'multimodal_media',
              'general_chat',
            ],
          ),
          SystemOneChoiceQuestionSpec(
            id: 'model_tier',
            prompt: 'Which local model capacity tier is appropriate?',
            labels: <String>[
              'fast_0_8b',
              'balanced_4b_12b',
              'flagship_27b_coding',
            ],
          ),
          SystemOneScoreQuestionSpec(
            id: 'complexity',
            prompt: 'How complex is this request?',
            levels: <String>[
              'trivial_1',
              'simple_2',
              'moderate_3',
              'complex_4',
              'architectural_5',
            ],
          ),
          SystemOneNoulQuestionSpec(
            id: 'needs_tools',
            prompt:
                'Does this request require calling file, math, or MCP tools?',
          ),
          SystemOneNoulQuestionSpec(
            id: 'needs_thinking',
            prompt: 'Does this request benefit from step-by-step chain-of-thought reasoning?',
          ),
        ];
      case DecisionWorkflowMode.guardrailPreflight:
        burstState = _preflightInputCtrl.text;
        burstQuestions = const <SystemOneQuestionSpec>[
          SystemOneChoiceQuestionSpec(
            id: 'action',
            prompt: 'What preflight action should Studio take before running?',
            labels: <String>[
              'proceed',
              'ask_clarification',
              'confirm_risky_action',
              'redact_secrets_first',
            ],
          ),
          SystemOneScoreQuestionSpec(
            id: 'risk',
            prompt: 'How sensitive or risky is this prompt/command?',
            levels: <String>[
              'safe_1',
              'low_2',
              'caution_3',
              'sensitive_4',
              'critical_5',
            ],
          ),
          SystemOneNoulQuestionSpec(
            id: 'contains_secrets',
            prompt: 'Does the text contain API keys, tokens, passwords, or private credentials?',
          ),
        ];
      case DecisionWorkflowMode.vaultAudit:
        burstState =
            deps.notebookController.state.notes.firstOrNull?.searchableText ??
            _triageInputCtrl.text;
        burstQuestions = const <SystemOneQuestionSpec>[
          SystemOneChoiceQuestionSpec(
            id: 'category',
            prompt: 'What is the primary topic of this note?',
            labels: <String>[
              'architecture',
              'tuning',
              'debugging',
              'workflow',
              'reference',
            ],
          ),
          SystemOneChoiceQuestionSpec(
            id: 'urgency',
            prompt: 'What priority level does this note have?',
            labels: <String>['archive', 'reference', 'active', 'urgent'],
          ),
          SystemOneScoreQuestionSpec(
            id: 'actionability',
            prompt: 'How actionable is this note right now?',
            levels: <String>[
              'fyi_1',
              'note_2',
              'review_3',
              'todo_4',
              'blocker_5',
            ],
          ),
          SystemOneNoulQuestionSpec(
            id: 'has_action_item',
            prompt: 'Does this note contain an unresolved task, bug, or follow-up item?',
          ),
        ];
      case DecisionWorkflowMode.customChecklist:
        burstState = _customStateCtrl.text;
        burstQuestions = _customCriteria.isNotEmpty
            ? _buildCustomQuestionSpecs()
            : const <SystemOneQuestionSpec>[
                SystemOneNoulQuestionSpec(
                  id: 'check',
                  prompt: 'Is this document actionable?',
                ),
              ];
      case DecisionWorkflowMode.quickNoul:
        burstState = _decisionStateCtrl.text;
        burstQuestions = <SystemOneQuestionSpec>[
          SystemOneNoulQuestionSpec(
            id: 'noul',
            prompt: _decisionQuestionCtrl.text.trim().isEmpty
                ? 'Does this condition hold?'
                : _decisionQuestionCtrl.text.trim(),
          ),
        ];
    }

    await deps.playgroundController.runDecisionSpeedBenchmark(
      state: burstState,
      questions: burstQuestions,
      iterations: _decisionBurstIterations,
      compareWithActiveChatLlm: _compareDecisionWithLlm,
    );
  }

  Widget _buildDecisionSpeedBurstPanel(
    BuildContext context,
    StudioDependencies deps,
    PlaygroundWorkspaceState state, {
    required bool isBusy,
  }) {
    final palette = StudioPalette.of(context);
    final bench = state.decisionBenchmark;

    return Container(
      key: const Key('decision_speed_burst_panel'),
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
            spacing: 10,
            runSpacing: 10,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(Icons.speed_rounded, size: 17, color: palette.teal),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      'System-1 Speed Burst & LLM Head-to-Head',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: palette.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: <int>[10, 15, 30].map((int count) {
                  return ChoiceChip(
                    key: Key('decision_burst_iters_$count'),
                    label: Text(
                      '$count×',
                      style: const TextStyle(fontSize: 11.5),
                    ),
                    selected: _decisionBurstIterations == count,
                    onSelected: isBusy
                        ? null
                        : (_) => _updateState(
                            () => _decisionBurstIterations = count,
                          ),
                  );
                }).toList(),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Runs $_decisionBurstIterations consecutive single-pass System-1 evaluations on the active workflow prompt and optionally races the active Chat LLM on the exact same rubric.',
            style: TextStyle(fontSize: 11.5, color: palette.textSecondary),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              FilterChip(
                key: const Key('decision_compare_llm_switch'),
                label: const Text(
                  'Compare vs Active Chat LLM',
                  style: TextStyle(fontSize: 11.5),
                ),
                selected: _compareDecisionWithLlm,
                onSelected: isBusy
                    ? null
                    : (bool next) =>
                          _updateState(() => _compareDecisionWithLlm = next),
              ),
              FilledButton.icon(
                key: const Key('decision_run_speed_burst_button'),
                onPressed: isBusy
                    ? null
                    : () => _runDecisionSpeedBurst(deps, state),
                icon: const Icon(Icons.flash_on_rounded, size: 16),
                label: Text(
                  state.isEvaluating ? 'Measuring...' : 'Run Speed Burst',
                ),
              ),
            ],
          ),
          if (bench != null) ...<Widget>[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                StudioPillBadge(
                  label: 'median ${bench.medianMs} ms',
                  foreground: palette.teal,
                  monospace: true,
                ),
                StudioPillBadge(
                  label: 'min ${bench.minMs} ms',
                  foreground: palette.accent,
                  monospace: true,
                ),
                StudioPillBadge(
                  label: 'p95 ${bench.p95Ms} ms',
                  monospace: true,
                ),
                StudioPillBadge(
                  label: '${bench.passesPerSecond.toStringAsFixed(0)} passes/s',
                  foreground: palette.teal,
                  monospace: true,
                ),
                StudioPillBadge(
                  label:
                      '${bench.decisionsPerSecond.toStringAsFixed(0)} decisions/s',
                  foreground: palette.accent,
                  monospace: true,
                ),
                StudioPillBadge(label: bench.deviceName, monospace: true),
              ],
            ),
            if (bench.llmCompareElapsedMs != null) ...<Widget>[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: palette.surfaceElevated,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: palette.borderSubtle),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: <Widget>[
                        Text(
                          'HEAD-TO-HEAD VS ${bench.llmCompareModelName ?? "ACTIVE CHAT LLM"}',
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.6,
                            color: palette.textMuted,
                          ),
                        ),
                        if (bench.speedupVsLlm != null)
                          StudioPillBadge(
                            key: const Key('decision_speedup_badge'),
                            label:
                                '${bench.speedupVsLlm!.toStringAsFixed(1)}x faster than LLM',
                            foreground: palette.teal,
                            monospace: true,
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    _LatencyBarRow(
                      label: 'System-1 Head',
                      latencyLabel: '${bench.medianMs} ms',
                      fraction:
                          (bench.medianMs /
                                  math.max(1, bench.llmCompareElapsedMs!))
                              .clamp(0.03, 1.0),
                      color: palette.teal,
                    ),
                    const SizedBox(height: 6),
                    _LatencyBarRow(
                      label: bench.llmCompareModelName ?? 'Active Chat LLM',
                      latencyLabel: '${bench.llmCompareElapsedMs} ms',
                      fraction: 1.0,
                      color: palette.amber,
                    ),
                    if (bench.llmCompareSummary != null &&
                        bench.llmCompareSummary!.trim().isNotEmpty) ...<Widget>[
                      const SizedBox(height: 8),
                      Text(
                        bench.llmCompareSummary!.trim(),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: palette.textSecondary,
                          fontFamilyFallback: StudioTheme.monoFontFallback,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget? _buildRoutingActionButton(
    StudioDependencies deps,
    SystemOneBatchEvaluation batch,
  ) {
    final domain = (batch.byId('domain') as SystemOneChoiceAnswer?)?.choice;
    if (domain == null) {
      return null;
    }
    return FilledButton.tonalIcon(
      onPressed: () {
        switch (domain) {
          case 'coding_repo':
            deps.shellController.selectWorkspace(StudioWorkspace.coding);
          case 'knowledge_notes':
            deps.shellController.selectWorkspace(StudioWorkspace.notes);
          case 'multimodal_media':
            deps.shellController.selectWorkspace(StudioWorkspace.image);
          default:
            deps.chatController.setComposerDraft(_triageInputCtrl.text.trim());
            deps.shellController.selectWorkspace(StudioWorkspace.chat);
        }
      },
      icon: const Icon(Icons.open_in_new_rounded, size: 15),
      label: Text('Open Suggested Workspace ($domain)'),
    );
  }
}

class _DecisionBatchResultsPanel extends StatelessWidget {
  const _DecisionBatchResultsPanel({required this.batch, this.actionButton});

  final SystemOneBatchEvaluation batch;
  final Widget? actionButton;

  @override
  Widget build(BuildContext context) {
    final palette = StudioPalette.of(context);

    return Container(
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
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              StudioPillBadge(
                label:
                    'Single pass · ${batch.elapsedMs} ms · ${batch.avgMsPerQuestion.toStringAsFixed(1)} ms/q · ${batch.questionsPerSecond.toStringAsFixed(0)} q/s · ${batch.deviceName}',
                foreground: palette.teal,
                monospace: true,
              ),
              ?actionButton,
            ],
          ),
          const SizedBox(height: 12),
          for (final answer in batch.answers)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: switch (answer) {
                SystemOneChoiceAnswer(
                  :final id,
                  :final choice,
                  :final confidence,
                ) =>
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              id,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: palette.textSecondary,
                                fontFamilyFallback:
                                    StudioTheme.monoFontFallback,
                              ),
                            ),
                          ),
                          StudioPillBadge(
                            label: choice,
                            foreground: palette.accent,
                            monospace: true,
                          ),
                          const SizedBox(width: 6),
                          StudioPillBadge(
                            label: '${(confidence * 100).toStringAsFixed(0)}%',
                            monospace: true,
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      AnimatedScoreBar(
                        fraction: confidence.clamp(0.0, 1.0),
                        color: palette.accent,
                      ),
                    ],
                  ),
                SystemOneScoreAnswer(
                  :final id,
                  :final score,
                  :final confidence,
                ) =>
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              id,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: palette.textSecondary,
                                fontFamilyFallback:
                                    StudioTheme.monoFontFallback,
                              ),
                            ),
                          ),
                          StudioPillBadge(
                            label: '${(score + 1.0).toStringAsFixed(2)} / 5.0',
                            foreground: palette.teal,
                            monospace: true,
                          ),
                          const SizedBox(width: 6),
                          StudioPillBadge(
                            label: '${(confidence * 100).toStringAsFixed(0)}%',
                            monospace: true,
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      AnimatedScoreBar(
                        fraction: ((score + 1.0) / 5.0).clamp(0.0, 1.0),
                        color: palette.teal,
                      ),
                    ],
                  ),
                SystemOneNoulAnswer(:final id, :final probabilityTrue) => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            id,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: palette.textSecondary,
                              fontFamilyFallback: StudioTheme.monoFontFallback,
                            ),
                          ),
                        ),
                        StudioPillBadge(
                          label: probabilityTrue >= 0.5 ? 'YES' : 'NO',
                          foreground: probabilityTrue >= 0.5
                              ? palette.teal
                              : palette.amber,
                          monospace: true,
                        ),
                        const SizedBox(width: 6),
                        StudioPillBadge(
                          label:
                              '${(probabilityTrue * 100).toStringAsFixed(1)}%',
                          monospace: true,
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    AnimatedScoreBar(
                      fraction: probabilityTrue.clamp(0.0, 1.0),
                      color: probabilityTrue >= 0.5
                          ? palette.teal
                          : palette.amber,
                    ),
                  ],
                ),
              },
            ),
        ],
      ),
    );
  }
}
