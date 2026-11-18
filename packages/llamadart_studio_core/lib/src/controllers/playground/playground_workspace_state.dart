part of 'playground_workspace_controller.dart';

/// Sub-tab inside Studio's developer Playground workspace.
enum PlaygroundToolTab {
  /// Pairwise Embeddings similarity lab.
  embeddings('Embeddings'),

  /// Cross-encoder query-document reranker.
  reranker('Reranker'),

  /// Laya System-1 Decision Engine (multi-key triage, preflight, speed).
  decision('Decision Head'),

  /// Tokenizer ID & piece visualizer.
  tokens('Tokenizer'),

  /// Prefill & decode throughput benchmark.
  benchmark('Benchmark');

  const PlaygroundToolTab(this.label);

  /// Display tab label.
  final String label;

  /// Dedicated model specialty associated with this tab, or `null` when the
  /// tab operates on the active Chat/shared engine.
  StudioModelSpecialty? get requiredSpecialty => switch (this) {
    PlaygroundToolTab.embeddings => StudioModelSpecialty.embedding,
    PlaygroundToolTab.reranker => StudioModelSpecialty.reranker,
    PlaygroundToolTab.decision => StudioModelSpecialty.decision,
    PlaygroundToolTab.tokens || PlaygroundToolTab.benchmark => null,
  };
}

/// Built-in practical workflow modes inside the System-1 Decision Head tab.
enum DecisionWorkflowMode {
  /// Single-pass task classifier + model tier router (`ChoiceKey` + `ScoreKey` + `NoulKey`).
  triageRouter('triage_router', 'Task & Model Router'),

  /// Safety, secrets & ambiguity gate before running prompts or commands.
  guardrailPreflight('guardrail_preflight', 'Prompt Preflight'),

  /// Batch classify & score every note inside the Multimodal Notebook.
  vaultAudit('vault_audit', 'Batch Note Audit'),

  /// User-defined mixed `ChoiceKey` / `ScoreKey` / `NoulKey` rubric.
  customChecklist('custom_checklist', 'Custom Rubric'),

  /// Single yes/no (`NoulKey`) probe.
  quickNoul('quick_noul', 'Quick Yes/No');

  const DecisionWorkflowMode(this.id, this.label);

  /// Stable workflow identifier.
  final String id;

  /// Display tab/chip label.
  final String label;
}

/// Structured audit summary produced by running System-1 batch classification
/// across a [StudioNote] in the Multimodal Notebook.
@immutable
class NoteAuditResult {
  /// Creates a [NoteAuditResult].
  const NoteAuditResult({
    required this.noteId,
    required this.noteTitle,
    required this.category,
    required this.urgency,
    required this.actionabilityScore,
    required this.hasActionItem,
    required this.confidence,
    required this.elapsedMs,
  });

  /// Audited note ID.
  final String noteId;

  /// Title snapshot when audited.
  final String noteTitle;

  /// Top `ChoiceKey` topic category.
  final String category;

  /// Top `ChoiceKey` urgency bucket.
  final String urgency;

  /// `ScoreKey` actionability level (`1..5` display scale).
  final double actionabilityScore;

  /// `NoulKey` probability that the note has an unresolved action item.
  final double hasActionItem;

  /// Mean/minimum confidence across evaluated keys.
  final double confidence;

  /// Inference latency for this note in milliseconds.
  final int elapsedMs;
}

/// Immutable state for the developer Playground Lab workspace.
@immutable
class PlaygroundWorkspaceState {
  /// Creates a [PlaygroundWorkspaceState].
  const PlaygroundWorkspaceState({
    this.activeTab = PlaygroundToolTab.embeddings,
    this.isEvaluating = false,
    this.embeddingResult,
    this.rerankResults = const <RankedDocumentItem>[],
    this.decisionEvaluation,
    this.decisionBatchEvaluation,
    this.decisionBenchmark,
    this.decisionMode = DecisionWorkflowMode.triageRouter,
    this.noteAuditResults = const <NoteAuditResult>[],
    this.inspectedTokens = const <InspectedToken>[],
    this.benchmarkHistory = const <BenchmarkRunSummary>[],
    this.errorMessage,
  });

  /// Active Playground sub-tab.
  final PlaygroundToolTab activeTab;

  /// Whether an evaluation/scoring/benchmark pass is actively running.
  final bool isEvaluating;

  /// Latest pairwise embedding comparison matrix.
  final EmbeddingComparisonResult? embeddingResult;

  /// Latest reranked candidate documents.
  final List<RankedDocumentItem> rerankResults;

  /// Latest System-1 single yes/no decision output.
  final SystemOneEvaluation? decisionEvaluation;

  /// Latest multi-key System-1 batch evaluation output.
  final SystemOneBatchEvaluation? decisionBatchEvaluation;

  /// Latest System-1 speed burst & LLM comparison benchmark.
  final DecisionBenchmarkSummary? decisionBenchmark;

  /// Active workflow inside the Decision Head tab.
  final DecisionWorkflowMode decisionMode;

  /// Latest batch audit results across Notebook notes.
  final List<NoteAuditResult> noteAuditResults;

  /// Latest tokenized pieces.
  final List<InspectedToken> inspectedTokens;

  /// Completed throughput benchmark runs (newest first).
  final List<BenchmarkRunSummary> benchmarkHistory;

  /// Optional error banner message.
  final String? errorMessage;

  /// Returns an updated copy of [PlaygroundWorkspaceState].
  PlaygroundWorkspaceState copyWith({
    PlaygroundToolTab? activeTab,
    bool? isEvaluating,
    EmbeddingComparisonResult? embeddingResult,
    List<RankedDocumentItem>? rerankResults,
    SystemOneEvaluation? decisionEvaluation,
    SystemOneBatchEvaluation? decisionBatchEvaluation,
    DecisionBenchmarkSummary? decisionBenchmark,
    DecisionWorkflowMode? decisionMode,
    List<NoteAuditResult>? noteAuditResults,
    List<InspectedToken>? inspectedTokens,
    List<BenchmarkRunSummary>? benchmarkHistory,
    String? errorMessage,
    bool clearErrorMessage = false,
  }) {
    return PlaygroundWorkspaceState(
      activeTab: activeTab ?? this.activeTab,
      isEvaluating: isEvaluating ?? this.isEvaluating,
      embeddingResult: embeddingResult ?? this.embeddingResult,
      rerankResults: rerankResults ?? this.rerankResults,
      decisionEvaluation: decisionEvaluation ?? this.decisionEvaluation,
      decisionBatchEvaluation:
          decisionBatchEvaluation ?? this.decisionBatchEvaluation,
      decisionBenchmark: decisionBenchmark ?? this.decisionBenchmark,
      decisionMode: decisionMode ?? this.decisionMode,
      noteAuditResults: noteAuditResults ?? this.noteAuditResults,
      inspectedTokens: inspectedTokens ?? this.inspectedTokens,
      benchmarkHistory: benchmarkHistory ?? this.benchmarkHistory,
      errorMessage: clearErrorMessage
          ? null
          : (errorMessage ?? this.errorMessage),
    );
  }
}
