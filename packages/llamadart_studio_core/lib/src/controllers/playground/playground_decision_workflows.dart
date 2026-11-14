part of 'playground_workspace_controller.dart';

/// Decision, triage, guardrail, vault audit, and benchmark workflows.
extension PlaygroundDecisionWorkflows on PlaygroundWorkspaceController {
  /// Computes embeddings and pairwise similarity matrix for [texts].
  Future<void> runEmbeddings(List<String> texts) async {
    final embedding = _embedding;
    if (embedding == null) {
      _store.update(
        (PlaygroundWorkspaceState s) =>
            s.copyWith(errorMessage: 'Embedding service is not configured.'),
      );
      return;
    }
    _store.update(
      (PlaygroundWorkspaceState s) => s.copyWith(clearErrorMessage: true),
    );
    try {
      await _labModels.ensureCachedSpecialtyLoaded(
        StudioModelSpecialty.embedding,
      );
      _store.update(
        (PlaygroundWorkspaceState s) => s.copyWith(isEvaluating: true),
      );
      final res = await embedding.computeEmbeddings(texts);
      _store.update(
        (PlaygroundWorkspaceState s) =>
            s.copyWith(isEvaluating: false, embeddingResult: res),
      );
    } catch (error) {
      _store.update(
        (PlaygroundWorkspaceState s) => s.copyWith(
          isEvaluating: false,
          errorMessage: humanizeStudioError(error),
        ),
      );
    }
  }

  /// Runs cross-encoder document reranking against [query].
  Future<void> runReranker({
    required String query,
    required List<String> documents,
  }) async {
    final reranker = _reranker;
    if (reranker == null) {
      _store.update(
        (PlaygroundWorkspaceState s) =>
            s.copyWith(errorMessage: 'Reranker service is not configured.'),
      );
      return;
    }
    _store.update(
      (PlaygroundWorkspaceState s) => s.copyWith(clearErrorMessage: true),
    );
    try {
      await _labModels.ensureCachedSpecialtyLoaded(
        StudioModelSpecialty.reranker,
      );
      _store.update(
        (PlaygroundWorkspaceState s) => s.copyWith(isEvaluating: true),
      );
      final ranked = await reranker.rerank(query: query, documents: documents);
      _store.update(
        (PlaygroundWorkspaceState s) =>
            s.copyWith(isEvaluating: false, rerankResults: ranked),
      );
    } catch (error) {
      _store.update(
        (PlaygroundWorkspaceState s) => s.copyWith(
          isEvaluating: false,
          errorMessage: humanizeStudioError(error),
        ),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // System-1 Decision Engine (Single-Pass Multi-Key Workflows + Noul)
  // ---------------------------------------------------------------------------

  /// Evaluates a single Laya System-1 yes/no (`noul`) question on [stateText].
  Future<void> runDecisionHead({
    required String stateText,
    required String yesNoQuestion,
  }) async {
    final decision = _decision;
    if (decision == null) {
      _store.update(
        (PlaygroundWorkspaceState s) =>
            s.copyWith(errorMessage: 'Decision service is not configured.'),
      );
      return;
    }
    _store.update(
      (PlaygroundWorkspaceState s) => s.copyWith(clearErrorMessage: true),
    );
    try {
      await _labModels.ensureCachedSpecialtyLoaded(
        StudioModelSpecialty.decision,
      );
      _store.update(
        (PlaygroundWorkspaceState s) => s.copyWith(isEvaluating: true),
      );
      final eval = await decision.evaluateSystemOne(
        stateText: stateText,
        yesNoQuestion: yesNoQuestion,
      );
      _store.update(
        (PlaygroundWorkspaceState s) =>
            s.copyWith(isEvaluating: false, decisionEvaluation: eval),
      );
    } catch (error) {
      _store.update(
        (PlaygroundWorkspaceState s) => s.copyWith(
          isEvaluating: false,
          errorMessage: humanizeStudioError(error),
        ),
      );
    }
  }

  /// Evaluates multiple typed `ChoiceKey`, `ScoreKey`, and `NoulKey` questions
  /// in a single System-1 forward pass on [state].
  Future<SystemOneBatchEvaluation?> runDecisionBatch({
    required Object state,
    required List<SystemOneQuestionSpec> questions,
  }) async {
    final decision = _decision;
    if (decision == null) {
      _store.update(
        (PlaygroundWorkspaceState s) =>
            s.copyWith(errorMessage: 'Decision service is not configured.'),
      );
      return null;
    }
    _store.update(
      (PlaygroundWorkspaceState s) => s.copyWith(clearErrorMessage: true),
    );
    try {
      await _labModels.ensureCachedSpecialtyLoaded(
        StudioModelSpecialty.decision,
      );
      _store.update(
        (PlaygroundWorkspaceState s) => s.copyWith(isEvaluating: true),
      );
      final eval = await decision.evaluateSystemOneBatch(
        state: state,
        questions: questions,
      );
      _store.update(
        (PlaygroundWorkspaceState s) =>
            s.copyWith(isEvaluating: false, decisionBatchEvaluation: eval),
      );
      return eval;
    } catch (error) {
      _store.update(
        (PlaygroundWorkspaceState s) => s.copyWith(
          isEvaluating: false,
          errorMessage: humanizeStudioError(error),
        ),
      );
      return null;
    }
  }

  /// Runs a System-1 speed burst benchmark across [iterations] passes and
  /// optionally compares latency head-to-head against the active Chat LLM.
  Future<DecisionBenchmarkSummary?> runDecisionSpeedBenchmark({
    required Object state,
    required List<SystemOneQuestionSpec> questions,
    int iterations = 15,
    bool compareWithActiveChatLlm = false,
  }) async {
    final decision = _decision;
    if (decision == null) {
      _store.update(
        (PlaygroundWorkspaceState s) =>
            s.copyWith(errorMessage: 'Decision service is not configured.'),
      );
      return null;
    }
    _store.update(
      (PlaygroundWorkspaceState s) => s.copyWith(clearErrorMessage: true),
    );
    try {
      await _labModels.ensureCachedSpecialtyLoaded(
        StudioModelSpecialty.decision,
      );
      if (compareWithActiveChatLlm && _ensureChatModelReady != null) {
        await _ensureChatModelReady();
      }
      _store.update(
        (PlaygroundWorkspaceState s) => s.copyWith(isEvaluating: true),
      );
      final summary = await decision.runDecisionSpeedBenchmark(
        state: state,
        questions: questions,
        iterations: iterations,
        compareWithActiveChatLlm: compareWithActiveChatLlm,
      );
      _store.update(
        (PlaygroundWorkspaceState s) =>
            s.copyWith(isEvaluating: false, decisionBenchmark: summary),
      );
      return summary;
    } catch (error) {
      _store.update(
        (PlaygroundWorkspaceState s) => s.copyWith(
          isEvaluating: false,
          errorMessage: humanizeStudioError(error),
        ),
      );
      return null;
    }
  }

  /// Runs the Smart Task Triage & Model Router workflow in a single pass.
  Future<SystemOneBatchEvaluation?> runTriageRouterWorkflow(String taskText) {
    return runDecisionBatch(
      state: taskText,
      questions: const <SystemOneQuestionSpec>[
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
          prompt: 'Does this request require calling file, math, or MCP tools?',
        ),
        SystemOneNoulQuestionSpec(
          id: 'needs_thinking',
          prompt:
              'Does this request benefit from step-by-step chain-of-thought reasoning?',
        ),
      ],
    );
  }

  /// Runs the Prompt & Safety Preflight Gate workflow before running a prompt.
  Future<SystemOneBatchEvaluation?> runGuardrailPreflightWorkflow(
    String promptText,
  ) {
    return runDecisionBatch(
      state: promptText,
      questions: const <SystemOneQuestionSpec>[
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
          prompt:
              'Does the text contain API keys, tokens, passwords, or private credentials?',
        ),
        SystemOneNoulQuestionSpec(
          id: 'destructive_intent',
          prompt:
              'Does this ask to delete data, overwrite files, or run destructive commands?',
        ),
        SystemOneNoulQuestionSpec(
          id: 'underspecified',
          prompt:
              'Is the request missing important constraints or target file paths?',
        ),
      ],
    );
  }

  /// Runs multi-key classification (`category`, `urgency`, `actionability`,
  /// `has_action_item`) over every note supplied by the Multimodal Notebook,
  /// optionally persisting the derived tags onto each [StudioNote].
  Future<List<NoteAuditResult>> auditVaultNotes({
    bool applyTagsToNotes = true,
  }) async {
    final decision = _decision;
    if (decision == null) {
      _store.update(
        (PlaygroundWorkspaceState s) =>
            s.copyWith(errorMessage: 'Decision service is not configured.'),
      );
      return const <NoteAuditResult>[];
    }
    _store.update(
      (PlaygroundWorkspaceState s) => s.copyWith(clearErrorMessage: true),
    );
    final currentNotes = _notesProvider?.call() ?? const <StudioNote>[];
    if (currentNotes.isEmpty) {
      return const <NoteAuditResult>[];
    }

    const questions = <SystemOneQuestionSpec>[
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
        levels: <String>['fyi_1', 'note_2', 'review_3', 'todo_4', 'blocker_5'],
      ),
      SystemOneNoulQuestionSpec(
        id: 'has_action_item',
        prompt:
            'Does this note contain an unresolved task, bug, or follow-up item?',
      ),
    ];

    try {
      await _labModels.ensureCachedSpecialtyLoaded(
        StudioModelSpecialty.decision,
      );
      _store.update(
        (PlaygroundWorkspaceState s) => s.copyWith(isEvaluating: true),
      );

      final audits = <NoteAuditResult>[];
      final updatedNotes = <StudioNote>[];

      for (final note in currentNotes) {
        final eval = await decision.evaluateSystemOneBatch(
          state: note.searchableText,
          questions: questions,
        );
        final catAns = eval.byId('category') as SystemOneChoiceAnswer?;
        final urgAns = eval.byId('urgency') as SystemOneChoiceAnswer?;
        final actAns = eval.byId('actionability') as SystemOneScoreAnswer?;
        final todoAns = eval.byId('has_action_item') as SystemOneNoulAnswer?;

        final category = catAns?.choice ?? 'reference';
        final urgency = urgAns?.choice ?? 'reference';
        final actionabilityScore = (actAns?.score ?? 0.0) + 1.0;
        final hasActionItem = todoAns?.probabilityTrue ?? 0.0;
        final meanConfidence = eval.answers.isEmpty
            ? 0.0
            : eval.answers
                      .map((SystemOneQuestionAnswer a) => a.confidence)
                      .reduce((double a, double b) => a + b) /
                  eval.answers.length;

        audits.add(
          NoteAuditResult(
            noteId: note.id,
            noteTitle: note.title,
            category: category,
            urgency: urgency,
            actionabilityScore: actionabilityScore,
            hasActionItem: hasActionItem,
            confidence: meanConfidence,
            elapsedMs: eval.elapsedMs,
          ),
        );

        if (applyTagsToNotes) {
          final mergedTags = <String>{
            ...note.tags,
            category,
            if (hasActionItem >= 0.55) 'action-item',
          }.toList(growable: false);
          updatedNotes.add(note.copyWith(tags: mergedTags));
        } else {
          updatedNotes.add(note);
        }
      }

      _store.update(
        (PlaygroundWorkspaceState s) => s.copyWith(
          isEvaluating: false,
          noteAuditResults: List<NoteAuditResult>.unmodifiable(audits),
        ),
      );
      if (applyTagsToNotes && _onNotesUpdated != null) {
        await _onNotesUpdated(List<StudioNote>.unmodifiable(updatedNotes));
      }
      return audits;
    } catch (error) {
      _store.update(
        (PlaygroundWorkspaceState s) => s.copyWith(
          isEvaluating: false,
          errorMessage: humanizeStudioError(error),
        ),
      );
      return const <NoteAuditResult>[];
    }
  }

  // ---------------------------------------------------------------------------
  // Tokenizer & Throughput Benchmark
  // ---------------------------------------------------------------------------

  /// Tokenizes [text] using the active model vocabulary.
  Future<void> runTokenInspection(String text) async {
    final tokens = _tokens;
    if (tokens == null) {
      _store.update(
        (PlaygroundWorkspaceState s) => s.copyWith(
          errorMessage: 'Token inspector service is not configured.',
        ),
      );
      return;
    }
    _store.update(
      (PlaygroundWorkspaceState s) =>
          s.copyWith(isEvaluating: true, clearErrorMessage: true),
    );
    try {
      final pieces = await tokens.inspectTokens(text);
      _store.update(
        (PlaygroundWorkspaceState s) =>
            s.copyWith(isEvaluating: false, inspectedTokens: pieces),
      );
    } catch (error) {
      _store.update(
        (PlaygroundWorkspaceState s) => s.copyWith(
          isEvaluating: false,
          errorMessage: humanizeStudioError(error),
        ),
      );
    }
  }

  /// Executes a deterministic prefill + decode throughput benchmark.
  Future<void> runBenchmark({int targetDecodeTokens = 64}) async {
    final benchmark = _benchmark;
    if (benchmark == null) {
      _store.update(
        (PlaygroundWorkspaceState s) =>
            s.copyWith(errorMessage: 'Benchmark service is not configured.'),
      );
      return;
    }
    _store.update(
      (PlaygroundWorkspaceState s) =>
          s.copyWith(isEvaluating: true, clearErrorMessage: true),
    );
    try {
      final summary = await benchmark.runBenchmark(
        targetDecodeTokens: targetDecodeTokens,
      );
      _store.update(
        (PlaygroundWorkspaceState s) => s.copyWith(
          isEvaluating: false,
          benchmarkHistory: <BenchmarkRunSummary>[
            summary,
            ...s.benchmarkHistory,
          ],
        ),
      );
    } catch (error) {
      _store.update(
        (PlaygroundWorkspaceState s) => s.copyWith(
          isEvaluating: false,
          errorMessage: humanizeStudioError(error),
        ),
      );
    }
  }
}
