import 'dart:math' as math;

// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

import '../../app/studio_dependencies.dart';
import '../../app/studio_theme.dart';
import '../../widgets/model_load_progress_banner.dart';
import '../../widgets/store_widgets.dart';
import '../../widgets/studio_motion.dart';

part 'playground_decision_speed_burst.dart';
part 'playground_decision_tab.dart';
part 'playground_tabs_basic.dart';

enum _CustomQuestionKind { choice, score, noul }

class _CustomCriterionDraft {
  _CustomCriterionDraft({
    required this.id,
    required this.kind,
    required this.prompt,
    this.labelsCsv = 'bug, feature, docs',
  });

  final String id;
  final _CustomQuestionKind kind;
  final String prompt;
  final String labelsCsv;
}

/// Developer Playground showcasing Pairwise Embeddings Cosine Heatmap,
/// Two-Stage Cross-Encoder Reranker, Multi-Key System-1 Decision Engine
/// Workflows & Speed Benchmarks, Token Inspector, and Prefill/Decode Benchmarks.
class PlaygroundWorkspaceView extends StatefulWidget {
  /// Creates a [PlaygroundWorkspaceView].
  const PlaygroundWorkspaceView({super.key});

  @override
  State<PlaygroundWorkspaceView> createState() =>
      _PlaygroundWorkspaceViewState();
}

class _PlaygroundWorkspaceViewState extends State<PlaygroundWorkspaceView> {
  // Pairwise Similarity Matrix controller
  final TextEditingController _embedPassagesCtrl = TextEditingController(
    text:
        'Metal FlashAttention accelerates prefill on Apple Silicon.\n'
        'Quantizing KV cache to Q8_0 cuts context memory nearly in half.\n'
        'Fresh sourdough bread bakes best in a preheated Dutch oven.',
  );

  // Reranker controllers
  final TextEditingController _rerankQueryCtrl = TextEditingController(
    text: 'How do I reduce memory usage for long context windows?',
  );
  final TextEditingController _rerankDocsCtrl = TextEditingController(
    text:
        'Use Q8_0 or Q4_0 KV cache quantization with FlashAttention enabled.\n'
        'AudioRecorder captures 16 kHz mono PCM samples for speech transcription.\n'
        'Lowering n_ctx from 32K to 8K shrinks KV buffer allocation fourfold.',
  );

  // System-1 Decision Engine controllers
  final TextEditingController _triageInputCtrl = TextEditingController(
    text: 'Refactor coding_workspace_fs_io.dart so symlinked temp folders under macOS /var resolve safely and add unit tests.',
  );
  final TextEditingController _preflightInputCtrl = TextEditingController(
    text: 'Explain why KV cache Q8_0 quantization reduces peak VRAM usage on Metal.',
  );
  final TextEditingController _decisionStateCtrl = TextEditingController(
    text: 'Device free VRAM: 6.4 GB. Model size: 2.1 GB Q4_K_M. Requested context: 4096.',
  );
  final TextEditingController _decisionQuestionCtrl = TextEditingController(
    text: 'Can the entire model and KV cache fit in GPU memory?',
  );
  final TextEditingController _customStateCtrl = TextEditingController(
    text: 'Customer reported intermittent OOM crash when opening a 32K context chat after editing a large image.',
  );
  final TextEditingController _customPromptInputCtrl = TextEditingController();
  final TextEditingController _customLabelsInputCtrl = TextEditingController(
    text: 'memory, concurrency, ui_layout, docs',
  );
  _CustomQuestionKind _newCriterionKind = _CustomQuestionKind.choice;
  final List<_CustomCriterionDraft> _customCriteria = <_CustomCriterionDraft>[
    _CustomCriterionDraft(
      id: 'subsystem',
      kind: _CustomQuestionKind.choice,
      prompt: 'Which subsystem is implicated?',
      labelsCsv: 'memory, image_diffusion, chat_ui, storage',
    ),
    _CustomCriterionDraft(
      id: 'severity',
      kind: _CustomQuestionKind.score,
      prompt: 'How severe is the user impact?',
    ),
    _CustomCriterionDraft(
      id: 'reproducible',
      kind: _CustomQuestionKind.noul,
      prompt: 'Does this report contain enough reproduction detail?',
    ),
  ];
  bool _applyAuditTags = true;
  int _decisionBurstIterations = 15;
  bool _compareDecisionWithLlm = false;
  bool _decisionInputsCollapsed = false;
  DecisionWorkflowMode? _lastDecisionMode;
  Object? _lastDecisionEvalRef;
  Object? _lastDecisionBatchRef;
  int _lastNoteAuditCount = 0;

  // Tokenizer & Benchmark
  final TextEditingController _tokenizeTextCtrl = TextEditingController(
    text: 'llamadart Studio runs GGUF & LiteRT-LM locally at 60fps!',
  );
  int _benchmarkTokens = 64;

  PageStorageBucket? _draftBucket;
  bool _draftRestored = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _draftBucket = PageStorage.maybeOf(context);
    if (_draftRestored) return;
    _draftRestored = true;
    final draft = _draftBucket?.readState(
      context,
      identifier: 'playground_draft',
    ) as Map<String, Object?>?;
    if (draft == null) return;
    _embedPassagesCtrl.value = draft['_embedPassagesCtrl']! as TextEditingValue;
    _rerankQueryCtrl.value = draft['_rerankQueryCtrl']! as TextEditingValue;
    _rerankDocsCtrl.value = draft['_rerankDocsCtrl']! as TextEditingValue;
    _triageInputCtrl.value = draft['_triageInputCtrl']! as TextEditingValue;
    _preflightInputCtrl.value =
        draft['_preflightInputCtrl']! as TextEditingValue;
    _decisionStateCtrl.value = draft['_decisionStateCtrl']! as TextEditingValue;
    _decisionQuestionCtrl.value =
        draft['_decisionQuestionCtrl']! as TextEditingValue;
    _customStateCtrl.value = draft['_customStateCtrl']! as TextEditingValue;
    _customPromptInputCtrl.value =
        draft['_customPromptInputCtrl']! as TextEditingValue;
    _customLabelsInputCtrl.value =
        draft['_customLabelsInputCtrl']! as TextEditingValue;
    _tokenizeTextCtrl.value = draft['_tokenizeTextCtrl']! as TextEditingValue;
    _newCriterionKind = draft['_newCriterionKind'] as _CustomQuestionKind;
    _applyAuditTags = draft['_applyAuditTags'] as bool;
    _decisionBurstIterations = draft['_decisionBurstIterations'] as int;
    _compareDecisionWithLlm = draft['_compareDecisionWithLlm'] as bool;
    _benchmarkTokens = draft['_benchmarkTokens'] as int;
    _customCriteria
      ..clear()
      ..addAll(draft['criteria']! as List<_CustomCriterionDraft>);
  }

  @override
  void deactivate() {
    _draftBucket?.writeState(context, <String, Object?>{
      '_embedPassagesCtrl': _embedPassagesCtrl.value,
      '_rerankQueryCtrl': _rerankQueryCtrl.value,
      '_rerankDocsCtrl': _rerankDocsCtrl.value,
      '_triageInputCtrl': _triageInputCtrl.value,
      '_preflightInputCtrl': _preflightInputCtrl.value,
      '_decisionStateCtrl': _decisionStateCtrl.value,
      '_decisionQuestionCtrl': _decisionQuestionCtrl.value,
      '_customStateCtrl': _customStateCtrl.value,
      '_customPromptInputCtrl': _customPromptInputCtrl.value,
      '_customLabelsInputCtrl': _customLabelsInputCtrl.value,
      '_tokenizeTextCtrl': _tokenizeTextCtrl.value,
      '_newCriterionKind': _newCriterionKind,
      '_applyAuditTags': _applyAuditTags,
      '_decisionBurstIterations': _decisionBurstIterations,
      '_compareDecisionWithLlm': _compareDecisionWithLlm,
      '_benchmarkTokens': _benchmarkTokens,
      'criteria': List<_CustomCriterionDraft>.of(_customCriteria),
    }, identifier: 'playground_draft');
    super.deactivate();
  }

  @override
  void dispose() {
    _embedPassagesCtrl.dispose();
    _rerankQueryCtrl.dispose();
    _rerankDocsCtrl.dispose();
    _triageInputCtrl.dispose();
    _preflightInputCtrl.dispose();
    _decisionStateCtrl.dispose();
    _decisionQuestionCtrl.dispose();
    _customStateCtrl.dispose();
    _customPromptInputCtrl.dispose();
    _customLabelsInputCtrl.dispose();
    _tokenizeTextCtrl.dispose();
    super.dispose();
  }

  static List<String> _nonEmptyLines(String raw) {
    return raw
        .split('\n')
        .map((String s) => s.trim())
        .where((String s) => s.isNotEmpty)
        .toList(growable: false);
  }

  static List<String> _parseCsvTags(String raw) {
    return raw
        .split(',')
        .map((String t) => t.trim())
        .where((String t) => t.isNotEmpty)
        .toSet()
        .toList(growable: false);
  }

  void _syncDecisionInputCollapse(
    PlaygroundWorkspaceState state, {
    required bool isWideDesktop,
  }) {
    final modeChanged =
        _lastDecisionMode != null && _lastDecisionMode != state.decisionMode;
    _lastDecisionMode = state.decisionMode;

    final evalChanged = !identical(
      state.decisionEvaluation,
      _lastDecisionEvalRef,
    );
    final batchChanged = !identical(
      state.decisionBatchEvaluation,
      _lastDecisionBatchRef,
    );
    final auditChanged =
        state.noteAuditResults.length != _lastNoteAuditCount &&
        state.noteAuditResults.isNotEmpty;

    _lastDecisionEvalRef = state.decisionEvaluation;
    _lastDecisionBatchRef = state.decisionBatchEvaluation;
    _lastNoteAuditCount = state.noteAuditResults.length;

    if (modeChanged && _decisionInputsCollapsed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _decisionInputsCollapsed) {
          setState(() => _decisionInputsCollapsed = false);
        }
      });
      return;
    }

    final hasNewResultForMode = switch (state.decisionMode) {
      DecisionWorkflowMode.triageRouter ||
      DecisionWorkflowMode.guardrailPreflight ||
      DecisionWorkflowMode.customChecklist =>
        batchChanged && state.decisionBatchEvaluation != null,
      DecisionWorkflowMode.vaultAudit => auditChanged,
      DecisionWorkflowMode.quickNoul =>
        evalChanged && state.decisionEvaluation != null,
    };

    if (!isWideDesktop && hasNewResultForMode && !_decisionInputsCollapsed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_decisionInputsCollapsed) {
          setState(() => _decisionInputsCollapsed = true);
        }
      });
    }
  }

  bool _hasDecisionResultForMode(PlaygroundWorkspaceState state) {
    return switch (state.decisionMode) {
      DecisionWorkflowMode.triageRouter ||
      DecisionWorkflowMode.guardrailPreflight ||
      DecisionWorkflowMode.customChecklist =>
        state.decisionBatchEvaluation != null,
      DecisionWorkflowMode.vaultAudit => state.noteAuditResults.isNotEmpty,
      DecisionWorkflowMode.quickNoul => state.decisionEvaluation != null,
    };
  }

  String _decisionInputPreview(
    PlaygroundWorkspaceState state,
    NotebookState notebookState,
  ) {
    final raw = switch (state.decisionMode) {
      DecisionWorkflowMode.triageRouter => _triageInputCtrl.text.trim(),
      DecisionWorkflowMode.guardrailPreflight =>
        _preflightInputCtrl.text.trim(),
      DecisionWorkflowMode.vaultAudit =>
        '${notebookState.notes.length} Vault notes · auto-tag ${_applyAuditTags ? 'ON' : 'OFF'}',
      DecisionWorkflowMode.customChecklist =>
        '${_customCriteria.length} criteria · ${_customStateCtrl.text.trim()}',
      DecisionWorkflowMode.quickNoul => _decisionQuestionCtrl.text.trim(),
    };
    return raw.isEmpty ? 'No input text configured' : raw;
  }

  Widget _splitPane({
    required bool isWideDesktop,
    required Widget inputPane,
    required Widget resultPane,
  }) {
    if (!isWideDesktop) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[inputPane, const SizedBox(height: 16), resultPane],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(flex: 5, child: inputPane),
        const SizedBox(width: 16),
        Expanded(flex: 6, child: resultPane),
      ],
    );
  }

  Widget _buildEmptyResultPlaceholder(
    StudioPalette palette, {
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: palette.canvas,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(icon, size: 17, color: palette.textSecondary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: palette.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: TextStyle(
              fontSize: 12,
              height: 1.4,
              color: palette.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final deps = StudioScope.of(context);
    final palette = StudioPalette.of(context);

    return StoreBuilder<ModelHubState>(
      store: deps.modelHubController.store,
      builder: (BuildContext context, ModelHubState hubState) {
        return StoreBuilder<StudioRuntimeSnapshot>(
          store: deps.modelHubController.runtimeStore,
          builder: (BuildContext context, StudioRuntimeSnapshot runtime) {
            return StoreBuilder<LabModelState>(
              store: deps.labModelCoordinator.store,
              builder: (BuildContext context, LabModelState labModelsState) {
                return StoreBuilder<NotebookState>(
                  store: deps.notebookController.store,
                  builder: (BuildContext context, NotebookState notebookState) {
                    return StoreBuilder<PlaygroundWorkspaceState>(
                      store: deps.playgroundController.store,
                      builder: (BuildContext context, PlaygroundWorkspaceState labState) {
                        final tabModels = deps.playgroundController
                            .availableModelsForTab(labState.activeTab);
                        final usesSharedChatEngine =
                            labState.activeTab.requiredSpecialty == null;
                        final isBusy =
                            labState.isEvaluating ||
                            labModelsState.isLoadingModel;
                        final errorMessage =
                            labState.errorMessage ??
                            labModelsState.errorMessage;

                        return LayoutBuilder(
                          builder: (BuildContext context, BoxConstraints constraints) {
                            final isWideDesktop = constraints.maxWidth >= 740;
                            return ListView(
                              padding: const EdgeInsets.all(22),
                              children: <Widget>[
                                Text(
                                  'Developer Playground',
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w800,
                                    color: palette.textPrimary,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Pairwise embeddings similarity, cross-encoder reranking, System-1 decision speed & routing, tokenization, and throughput benchmarks.',
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    color: palette.textSecondary,
                                  ),
                                ),
                                const SizedBox(height: 14),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: PlaygroundToolTab.values.map((
                                    PlaygroundToolTab tab,
                                  ) {
                                    return ChoiceChip(
                                      key: Key('playground_tab_${tab.name}'),
                                      label: Text(tab.label),
                                      selected: labState.activeTab == tab,
                                      onSelected: (_) => deps
                                          .playgroundController
                                          .selectTab(tab),
                                    );
                                  }).toList(),
                                ),
                                if (tabModels.isNotEmpty) ...<Widget>[
                                  const SizedBox(height: 12),
                                  LayoutBuilder(
                                    builder: (BuildContext context, BoxConstraints chipBox) {
                                      final maxChipLabelWidth = math.min(
                                        260.0,
                                        math.max(80.0, chipBox.maxWidth - 72.0),
                                      );
                                      return Wrap(
                                        spacing: 8,
                                        runSpacing: 8,
                                        children: tabModels.map((
                                          StudioModelDescriptor m,
                                        ) {
                                          final loaded =
                                              labModelsState
                                                  .loadedLabModels[m.specialty]
                                                  ?.id ==
                                              m.id;
                                          final loadingThis =
                                              labModelsState.loadingModel?.id ==
                                              m.id;
                                          final installed = hubState
                                              .cachedModelIds
                                              .contains(m.id);
                                          return ActionChip(
                                            key: Key('load_lab_model_${m.id}'),
                                            avatar: loadingThis
                                                ? SizedBox(
                                                    width: 14,
                                                    height: 14,
                                                    child:
                                                        CircularProgressIndicator(
                                                          strokeWidth: 2,
                                                          color: palette.accent,
                                                        ),
                                                  )
                                                : Icon(
                                                    loaded
                                                        ? Icons
                                                              .check_circle_rounded
                                                        : (installed
                                                              ? Icons
                                                                    .bolt_rounded
                                                              : Icons
                                                                    .download_for_offline_outlined),
                                                    size: 16,
                                                    color: loaded
                                                        ? palette.teal
                                                        : (installed
                                                              ? palette.accent
                                                              : palette
                                                                    .textSecondary),
                                                  ),
                                            label: ConstrainedBox(
                                              constraints: BoxConstraints(
                                                maxWidth: maxChipLabelWidth,
                                              ),
                                              child: Text(
                                                '${m.name} (${m.sizeLabel(isWeb: deps.isWeb)})',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  fontSize: 11.5,
                                                ),
                                              ),
                                            ),
                                            onPressed: isBusy
                                                ? null
                                                : () => deps
                                                      .playgroundController
                                                      .loadLabModel(m),
                                          );
                                        }).toList(),
                                      );
                                    },
                                  ),
                                ] else if (usesSharedChatEngine) ...<Widget>[
                                  const SizedBox(height: 12),
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: StudioPillBadge(
                                      label: runtime.isReady
                                          ? 'Active engine: ${runtime.activeModelLabel ?? "Loaded"} · ${runtime.backendName}'
                                          : 'Select a Chat model in the top bar first',
                                      foreground: runtime.isReady
                                          ? palette.teal
                                          : palette.amber,
                                      monospace: true,
                                    ),
                                  ),
                                ],
                                if (labModelsState.loadingModel !=
                                    null) ...<Widget>[
                                  const SizedBox(height: 12),
                                  ModelLoadProgressBanner(
                                    descriptor: labModelsState.loadingModel!,
                                    onCancel: deps
                                        .playgroundController
                                        .cancelModelLoad,
                                  ),
                                ],
                                if (errorMessage != null) ...<Widget>[
                                  const SizedBox(height: 12),
                                  Container(
                                    padding: const EdgeInsets.all(10),
                                    decoration: BoxDecoration(
                                      color: palette.danger.withValues(
                                        alpha: 0.14,
                                      ),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Text(
                                      errorMessage,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: palette.danger,
                                      ),
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 16),
                                AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 180),
                                  child: switch (labState.activeTab) {
                                    PlaygroundToolTab.embeddings =>
                                      _buildEmbeddingsCard(
                                        context,
                                        deps,
                                        labState,
                                        notebookState,
                                        isBusy: isBusy,
                                        isWideDesktop: isWideDesktop,
                                      ),
                                    PlaygroundToolTab.reranker =>
                                      _buildRerankerCard(
                                        context,
                                        deps,
                                        labState,
                                        isBusy: isBusy,
                                        isWideDesktop: isWideDesktop,
                                      ),
                                    PlaygroundToolTab.decision =>
                                      _buildDecisionCard(
                                        context,
                                        deps,
                                        labState,
                                        notebookState,
                                        isBusy: isBusy,
                                        isWideDesktop: isWideDesktop,
                                      ),
                                    PlaygroundToolTab.tokens =>
                                      _buildTokenizerCard(
                                        context,
                                        deps,
                                        labState,
                                        isBusy: isBusy,
                                        isWideDesktop: isWideDesktop,
                                      ),
                                    PlaygroundToolTab.benchmark =>
                                      _buildBenchmarkCard(
                                        context,
                                        deps,
                                        labState,
                                        isBusy: isBusy,
                                        isWideDesktop: isWideDesktop,
                                      ),
                                  },
                                ),
                              ],
                            );
                          },
                        );
                      },
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  void _updateState(VoidCallback fn) {
    if (mounted) {
      setState(fn);
    }
  }
}
