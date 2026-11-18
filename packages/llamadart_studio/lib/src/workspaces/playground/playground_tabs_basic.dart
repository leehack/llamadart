part of 'playground_workspace_view.dart';

extension _PlaygroundBasicTabs on _PlaygroundWorkspaceViewState {
  Widget _buildEmbeddingsCard(
    BuildContext context,
    StudioDependencies deps,
    PlaygroundWorkspaceState state,
    NotebookState notebookState, {
    required bool isBusy,
    required bool isWideDesktop,
  }) {
    final palette = StudioPalette.of(context);
    final res = state.embeddingResult;

    final inputPane = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'Pairwise Similarity Matrix',
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w700,
            color: palette.textPrimary,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _embedPassagesCtrl,
          maxLines: 5,
          decoration: const InputDecoration(
            labelText: 'Passages to Embed (one per line)',
          ),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
            key: const Key('run_embeddings_button'),
            onPressed: isBusy
                ? null
                : () => deps.playgroundController.runEmbeddings(
                    _PlaygroundWorkspaceViewState._nonEmptyLines(
                      _embedPassagesCtrl.text,
                    ),
                  ),
            icon: const Icon(Icons.grid_on_rounded, size: 16),
            label: Text(
              state.isEvaluating ? 'Computing...' : 'Compute Similarity Matrix',
            ),
          ),
        ),
      ],
    );

    final resultPane = res == null
        ? (isWideDesktop
              ? _buildEmptyResultPlaceholder(
                  palette,
                  icon: Icons.grid_on_rounded,
                  title: 'Cosine Similarity Heatmap',
                  subtitle: 'Enter two or more passages on the left and click Compute Similarity Matrix to inspect pairwise cosine similarity scores.',
                )
              : const SizedBox.shrink())
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: <Widget>[
                  StudioPillBadge(
                    label: '${res.dimensions} dims',
                    foreground: palette.teal,
                    monospace: true,
                  ),
                  StudioPillBadge(
                    label: '${res.elapsedMs} ms',
                    monospace: true,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Table(
                  defaultColumnWidth: const FixedColumnWidth(84),
                  border: TableBorder.all(color: palette.borderSubtle),
                  children: List<TableRow>.generate(
                    res.similarityMatrix.length,
                    (int r) => TableRow(
                      children: List<Widget>.generate(
                        res.similarityMatrix[r].length,
                        (int c) {
                          final sim = res.similarityMatrix[r][c];
                          final alpha = sim.clamp(0.0, 1.0) * 0.45;
                          return Container(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            alignment: Alignment.center,
                            color: palette.accent.withValues(alpha: alpha),
                            child: Text(
                              sim.toStringAsFixed(2),
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: palette.textPrimary,
                                fontFamilyFallback:
                                    StudioTheme.monoFontFallback,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );

    return Container(
      key: const ValueKey<String>('tab_embeddings'),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: palette.surfaceElevated,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: palette.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: palette.canvas,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: palette.borderSubtle),
            ),
            child: Wrap(
              spacing: 12,
              runSpacing: 10,
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 460),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Icon(
                            Icons.auto_stories_outlined,
                            size: 16,
                            color: palette.accent,
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              'Multimodal Notebook (Audio, Image & RAG Q&A)',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: palette.textPrimary,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${notebookState.indexedNoteCount}/${notebookState.notes.length} notes indexed · Live 16 kHz mic capture, Qwen3-ASR & EmbeddingGemma 2',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: palette.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                FilledButton.tonalIcon(
                  key: const Key('playground_open_notebook_button'),
                  onPressed: () => deps.shellController.selectWorkspace(
                    StudioWorkspace.notes,
                  ),
                  icon: const Icon(Icons.open_in_new_rounded, size: 15),
                  label: const Text('Open Multimodal Notebook'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _splitPane(
            isWideDesktop: isWideDesktop,
            inputPane: inputPane,
            resultPane: resultPane,
          ),
        ],
      ),
    );
  }

  Widget _buildRerankerCard(
    BuildContext context,
    StudioDependencies deps,
    PlaygroundWorkspaceState state, {
    required bool isBusy,
    required bool isWideDesktop,
  }) {
    final palette = StudioPalette.of(context);
    final scores = state.rerankResults
        .map((RankedDocumentItem e) => e.score)
        .toList(growable: false);
    final minScore = scores.isEmpty ? 0.0 : scores.reduce(math.min);
    final maxScore = scores.isEmpty ? 1.0 : scores.reduce(math.max);
    final span = maxScore - minScore;

    double barFractionFor(double score) {
      if (scores.length <= 1 || span.abs() < 1e-6) {
        return (1.0 / (1.0 + math.exp(-score))).clamp(0.12, 1.0);
      }
      return (0.15 + 0.85 * ((score - minScore) / span)).clamp(0.12, 1.0);
    }

    final inputPane = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        TextField(
          controller: _rerankQueryCtrl,
          decoration: const InputDecoration(labelText: 'Search Query'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _rerankDocsCtrl,
          maxLines: 5,
          decoration: const InputDecoration(
            labelText: 'Candidate Passages (one per line)',
          ),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
            key: const Key('run_reranker_button'),
            onPressed: isBusy
                ? null
                : () => deps.playgroundController.runReranker(
                    query: _rerankQueryCtrl.text,
                    documents: _PlaygroundWorkspaceViewState._nonEmptyLines(
                      _rerankDocsCtrl.text,
                    ),
                  ),
            icon: const Icon(Icons.sort_rounded, size: 16),
            label: Text(
              state.isEvaluating ? 'Scoring...' : 'Rerank Candidates',
            ),
          ),
        ),
      ],
    );

    final resultPane = state.rerankResults.isEmpty
        ? (isWideDesktop
              ? _buildEmptyResultPlaceholder(
                  palette,
                  icon: Icons.sort_rounded,
                  title: 'Cross-Encoder Relevance Scores',
                  subtitle: 'Score candidate passages against your query to see ranked relevance probabilities and relative bar spreads.',
                )
              : const SizedBox.shrink())
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              for (var rank = 0; rank < state.rerankResults.length; rank++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          StudioPillBadge(
                            label: '#${rank + 1}',
                            foreground: rank == 0
                                ? palette.teal
                                : palette.textSecondary,
                            monospace: true,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              state.rerankResults[rank].document,
                              style: const TextStyle(fontSize: 12.5),
                            ),
                          ),
                          const SizedBox(width: 8),
                          StudioPillBadge(
                            label: state.rerankResults[rank].score
                                .toStringAsFixed(3),
                            foreground: palette.teal,
                            monospace: true,
                          ),
                        ],
                      ),
                      const SizedBox(height: 5),
                      AnimatedScoreBar(
                        fraction: barFractionFor(
                          state.rerankResults[rank].score,
                        ),
                        color: rank == 0 ? palette.teal : palette.accent,
                      ),
                    ],
                  ),
                ),
            ],
          );

    return Container(
      key: const ValueKey<String>('tab_reranker'),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: palette.surfaceElevated,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: palette.borderSubtle),
      ),
      child: _splitPane(
        isWideDesktop: isWideDesktop,
        inputPane: inputPane,
        resultPane: resultPane,
      ),
    );
  }

  Widget _buildTokenizerCard(
    BuildContext context,
    StudioDependencies deps,
    PlaygroundWorkspaceState state, {
    required bool isBusy,
    required bool isWideDesktop,
  }) {
    final palette = StudioPalette.of(context);
    final colors = <Color>[
      palette.accent.withValues(alpha: 0.22),
      palette.teal.withValues(alpha: 0.22),
      palette.amber.withValues(alpha: 0.22),
    ];

    final inputPane = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        TextField(
          controller: _tokenizeTextCtrl,
          maxLines: 3,
          decoration: const InputDecoration(
            labelText: 'Input Text to Tokenize',
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: Wrap(
            spacing: 10,
            runSpacing: 10,
            alignment: state.inspectedTokens.isNotEmpty
                ? WrapAlignment.spaceBetween
                : WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              if (state.inspectedTokens.isNotEmpty)
                StudioPillBadge(
                  label: '${state.inspectedTokens.length} tokens',
                  foreground: palette.teal,
                  monospace: true,
                ),
              FilledButton.icon(
                key: const Key('run_tokenizer_button'),
                onPressed: isBusy
                    ? null
                    : () => deps.playgroundController.runTokenInspection(
                        _tokenizeTextCtrl.text,
                      ),
                icon: const Icon(Icons.tag_rounded, size: 16),
                label: Text(
                  state.isEvaluating ? 'Tokenizing...' : 'Inspect Tokens',
                ),
              ),
            ],
          ),
        ),
      ],
    );

    final resultPane = state.inspectedTokens.isEmpty
        ? (isWideDesktop
              ? _buildEmptyResultPlaceholder(
                  palette,
                  icon: Icons.tag_rounded,
                  title: 'Token Breakdown',
                  subtitle: 'Tokenize any prompt on the left to inspect exact token boundaries, whitespace markers, and integer IDs.',
                )
              : const SizedBox.shrink())
        : Wrap(
            spacing: 6,
            runSpacing: 6,
            children: List<Widget>.generate(state.inspectedTokens.length, (
              int i,
            ) {
              final tok = state.inspectedTokens[i];
              final visiblePiece = tok.piece
                  .replaceAll(' ', '·')
                  .replaceAll('\n', '↵');
              return Tooltip(
                message: 'Token ID: ${tok.id}',
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: colors[i % colors.length],
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: palette.borderSubtle),
                  ),
                  child: Text(
                    '$visiblePiece (${tok.id})',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: palette.textPrimary,
                      fontFamilyFallback: StudioTheme.monoFontFallback,
                    ),
                  ),
                ),
              );
            }),
          );

    return Container(
      key: const ValueKey<String>('tab_tokens'),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: palette.surfaceElevated,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: palette.borderSubtle),
      ),
      child: _splitPane(
        isWideDesktop: isWideDesktop,
        inputPane: inputPane,
        resultPane: resultPane,
      ),
    );
  }

  Widget _buildBenchmarkCard(
    BuildContext context,
    StudioDependencies deps,
    PlaygroundWorkspaceState state, {
    required bool isBusy,
    required bool isWideDesktop,
  }) {
    final palette = StudioPalette.of(context);

    final inputPane = SizedBox(
      width: double.infinity,
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <int>[32, 64, 128].map((int n) {
              return ChoiceChip(
                label: Text('$n decode tok'),
                selected: _benchmarkTokens == n,
                onSelected: (_) => _updateState(() => _benchmarkTokens = n),
              );
            }).toList(),
          ),
          FilledButton.icon(
            key: const Key('run_benchmark_button'),
            onPressed: isBusy
                ? null
                : () => deps.playgroundController.runBenchmark(
                    targetDecodeTokens: _benchmarkTokens,
                  ),
            icon: const Icon(Icons.speed_rounded, size: 16),
            label: Text(
              state.isEvaluating ? 'Benchmarking...' : 'Run Benchmark',
            ),
          ),
        ],
      ),
    );

    final resultPane = state.benchmarkHistory.isEmpty
        ? (isWideDesktop
              ? _buildEmptyResultPlaceholder(
                  palette,
                  icon: Icons.speed_rounded,
                  title: 'Throughput Runs',
                  subtitle: 'Select a target decode token budget and run a synthetic prompt-prefill + token-decode benchmark on the active engine.',
                )
              : const SizedBox.shrink())
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              for (final run in state.benchmarkHistory)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: palette.canvas,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: palette.borderSubtle),
                  ),
                  child: Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: <Widget>[
                      Text(
                        run.modelName,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: palette.textPrimary,
                        ),
                      ),
                      StudioPillBadge(label: run.backendName, monospace: true),
                      StudioPillBadge(
                        label:
                            'Prefill ${run.prefillTokensPerSecond.toStringAsFixed(1)} tok/s',
                        foreground: palette.accent,
                        monospace: true,
                      ),
                      StudioPillBadge(
                        label:
                            'Decode ${run.decodeTokensPerSecond.toStringAsFixed(1)} tok/s',
                        foreground: palette.teal,
                        monospace: true,
                      ),
                      StudioPillBadge(
                        label: 'TTFT ${run.prefillLatencyMs} ms',
                        monospace: true,
                      ),
                    ],
                  ),
                ),
            ],
          );

    return Container(
      key: const ValueKey<String>('tab_benchmark'),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: palette.surfaceElevated,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: palette.borderSubtle),
      ),
      child: _splitPane(
        isWideDesktop: isWideDesktop,
        inputPane: inputPane,
        resultPane: resultPane,
      ),
    );
  }
}

class _LatencyBarRow extends StatelessWidget {
  const _LatencyBarRow({
    required this.label,
    required this.latencyLabel,
    required this.fraction,
    required this.color,
  });

  final String label;
  final String latencyLabel;
  final double fraction;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final palette = StudioPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: palette.textPrimary,
                ),
              ),
            ),
            Text(
              latencyLabel,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: color,
                fontFamilyFallback: StudioTheme.monoFontFallback,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        AnimatedScoreBar(fraction: fraction, color: color),
      ],
    );
  }
}
