part of 'notebook_controller.dart';

/// Semantic indexing, two-stage retrieval + reranking, and RAG Q&A workflows
/// for [NotebookController].
extension NotebookRagWorkflows on NotebookController {
  Future<void> _askNotebookImpl(String rawQuestion, {int topK = 4}) async {
    if (_store.state.isAnsweringNotebook) {
      return;
    }
    final question = rawQuestion.trim();
    if (question.isEmpty) {
      return;
    }
    final inference = _inference;
    if (inference == null) {
      _store.update(
        (NotebookState s) => s.copyWith(
          errorMessage: 'Inference port is unavailable for Notebook Q&A.',
        ),
      );
      return;
    }

    _store.update(
      (NotebookState s) => s.copyWith(
        notebookQuestion: question,
        notebookAnswerText: '',
        isAnsweringNotebook: true,
        notebookAnswerSources: const <NoteSearchHit>[],
        clearErrorMessage: true,
      ),
    );

    final watch = Stopwatch()..start();
    try {
      final hits = await searchNotes(question, topK: topK);
      final sources = hits.isNotEmpty
          ? hits
          : <NoteSearchHit>[
              if (_store.state.selectedNote != null)
                NoteSearchHit(
                  note: _store.state.selectedNote!,
                  cosineScore: 1.0,
                ),
            ];
      _store.update(
        (NotebookState s) => s.copyWith(notebookAnswerSources: sources),
      );

      if (!inference.runtimeStore.state.isReady &&
          _ensureChatModelReady != null) {
        await _ensureChatModelReady();
      }

      final sourceBuf = StringBuffer();
      for (var i = 0; i < sources.length; i++) {
        final hit = sources[i];
        final body = hit.note.searchableText.trim();
        sourceBuf
          ..writeln('[Source ${i + 1}: ${hit.note.title}]')
          ..writeln(
            'Kind: ${hit.note.sourceKind.label} | Sim: ${hit.cosineScore.toStringAsFixed(2)}',
          )
          ..writeln(
            body.isEmpty ? '(Media note with no text transcript yet)' : body,
          )
          ..writeln();
      }

      final prompt =
          'Use the local notebook sources below to answer the user question accurately. '
          'Cite sources inline like [Source 1] or [Source 2]. If a fact is missing from the sources, say so clearly.\n\n'
          '${sourceBuf.toString()}\n'
          'Question: $question';

      final answerBuf = StringBuffer();
      final settings = _shell?.currentSettings ?? const StudioSettings();
      final stream = inference.streamTurn(
        StudioTurnRequest(
          history: <StudioMessage>[
            StudioMessage(
              id: 'nb_q_${DateTime.now().microsecondsSinceEpoch}',
              role: StudioRole.user,
              text: prompt,
              createdAt: DateTime.now(),
            ),
          ],
          settings: settings,
          systemPrompt:
              'You are a local private Notebook research assistant inside llamadart Studio. '
              'Synthesize concise, accurate, source-grounded answers with citations like [Source 1].',
          toolsEnabledOverride: false,
        ),
      );

      final streamDone = Completer<void>();
      var streamFinished = false;
      late final StreamSubscription<StudioTurnEvent> streamSub;
      streamSub = stream.listen(
        (StudioTurnEvent event) {
          switch (event) {
            case StudioTextDeltaEvent(:final delta):
              answerBuf.write(delta);
              _store.update(
                (NotebookState s) =>
                    s.copyWith(notebookAnswerText: answerBuf.toString()),
              );
            case StudioTurnCompletedEvent(:final result):
              final finalText = result.text.trim();
              if (finalText.isNotEmpty) {
                answerBuf
                  ..clear()
                  ..write(finalText);
              }
            case StudioThinkingDeltaEvent():
            case StudioToolInvocationEvent():
              break;
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          streamFinished = true;
          if (!streamDone.isCompleted) {
            streamDone.completeError(error, stackTrace);
          }
        },
        onDone: () {
          streamFinished = true;
          if (!streamDone.isCompleted) {
            streamDone.complete();
          }
        },
        cancelOnError: true,
      );
      try {
        await streamDone.future;
      } finally {
        if (!streamFinished) {
          await streamSub.cancel();
        }
      }

      watch.stop();
      _store.update(
        (NotebookState s) => s.copyWith(
          isAnsweringNotebook: false,
          notebookAnswerText: answerBuf.toString(),
          notebookAnswerElapsedMs: watch.elapsedMilliseconds,
        ),
      );
    } catch (error) {
      watch.stop();
      _store.update(
        (NotebookState s) => s.copyWith(
          isAnsweringNotebook: false,
          errorMessage: humanizeStudioError(error),
        ),
      );
    }
  }

  Future<void> _indexNotesImpl({bool forceReindex = false}) async {
    _store.update((NotebookState s) => s.copyWith(clearErrorMessage: true));
    try {
      await _labModels.ensureCachedSpecialtyLoaded(
        StudioModelSpecialty.embedding,
      );
      _store.update((NotebookState s) => s.copyWith(isEvaluating: true));
      final updated = await _indexMissingNotesInternal(
        _store.state.notes,
        forceReindex: forceReindex,
      );
      final selectedId = _store.state.selectedNoteId;
      _store.update(
        (NotebookState s) => s.copyWith(
          isEvaluating: false,
          notes: updated,
          relatedNotes: selectedId == null
              ? const <NoteSearchHit>[]
              : NotebookController._computeRelatedNotes(updated, selectedId),
        ),
      );
      await _persistNotes(updated);
    } catch (error) {
      _store.update(
        (NotebookState s) => s.copyWith(
          isEvaluating: false,
          errorMessage: humanizeStudioError(error),
        ),
      );
    }
  }

  Future<List<NoteSearchHit>> _searchNotesImpl(
    String query, {
    int topK = 5,
    bool? rerank,
  }) async {
    final trimmed = query.trim();
    _store.update(
      (NotebookState s) =>
          s.copyWith(noteSearchQuery: query, clearErrorMessage: true),
    );
    if (trimmed.isEmpty || _store.state.notes.isEmpty) {
      _store.update(
        (NotebookState s) =>
            s.copyWith(noteSearchHits: const <NoteSearchHit>[]),
      );
      return const <NoteSearchHit>[];
    }

    try {
      final totalWatch = Stopwatch()..start();
      await _labModels.ensureCachedSpecialtyLoaded(
        StudioModelSpecialty.embedding,
      );
      _store.update((NotebookState s) => s.copyWith(isEvaluating: true));

      final indexedNotes = await _indexMissingNotesInternal(_store.state.notes);
      await _persistNotes(indexedNotes);

      final queryVecResult = await _embedding.embedQuery(trimmed);
      final queryVec = queryVecResult.vector;

      final cosineHits =
          <NoteSearchHit>[
            for (final note in indexedNotes)
              if (note.isIndexed)
                NoteSearchHit(
                  note: note,
                  cosineScore: StudioNote.cosineSimilarity(
                    queryVec,
                    note.embedding!,
                  ),
                ),
          ]..sort(
            (NoteSearchHit a, NoteSearchHit b) =>
                b.cosineScore.compareTo(a.cosineScore),
          );

      var finalHits = cosineHits.take(topK.clamp(1, 20)).toList();
      final useRerank = rerank ?? _store.state.rerankVaultHits;
      if (useRerank && cosineHits.isNotEmpty) {
        final reranker = _reranker;
        if (reranker == null) {
          throw StateError('Cross-encoder reranking service is unavailable.');
        }
        final candidates = cosineHits.take((topK * 2).clamp(2, 12)).toList();
        await _labModels.ensureCachedSpecialtyLoaded(
          StudioModelSpecialty.reranker,
        );
        final reranked = await reranker.rerank(
          query: trimmed,
          documents: candidates
              .map((NoteSearchHit h) => h.note.searchableText)
              .toList(growable: false),
        );
        finalHits = reranked
            .map(
              (RankedDocumentItem item) => NoteSearchHit(
                note: candidates[item.originalIndex].note,
                cosineScore: candidates[item.originalIndex].cosineScore,
                rerankScore: item.score,
              ),
            )
            .take(topK)
            .toList(growable: false);
      }

      totalWatch.stop();
      final selectedId = _store.state.selectedNoteId;
      _store.update(
        (NotebookState s) => s.copyWith(
          isEvaluating: false,
          notes: indexedNotes,
          noteSearchHits: List<NoteSearchHit>.unmodifiable(finalHits),
          lastSearchElapsedMs: totalWatch.elapsedMilliseconds,
          relatedNotes: selectedId == null
              ? const <NoteSearchHit>[]
              : NotebookController._computeRelatedNotes(
                  indexedNotes,
                  selectedId,
                ),
        ),
      );
      return finalHits;
    } catch (error) {
      _store.update(
        (NotebookState s) => s.copyWith(
          isEvaluating: false,
          errorMessage: humanizeStudioError(error),
        ),
      );
      return const <NoteSearchHit>[];
    }
  }

  String _buildRagChatPromptImpl(String question, {List<NoteSearchHit>? hits}) {
    final effectiveHits = (hits != null && hits.isNotEmpty)
        ? hits
        : (_store.state.noteSearchHits.isNotEmpty
              ? _store.state.noteSearchHits.take(3).toList()
              : <NoteSearchHit>[
                  if (_store.state.selectedNote != null)
                    NoteSearchHit(
                      note: _store.state.selectedNote!,
                      cosineScore: 1.0,
                    ),
                ]);

    final cleanQuestion = question.trim().isEmpty
        ? 'Summarize the key takeaways and recommended next steps from these notes.'
        : question.trim();
    if (effectiveHits.isEmpty) {
      return cleanQuestion;
    }

    final buf = StringBuffer(
      'Answer using the following private notes from my llamadart Studio Note Vault:\n\n',
    );
    for (var i = 0; i < effectiveHits.length; i++) {
      final hit = effectiveHits[i];
      final tags = hit.note.tags.isEmpty
          ? ''
          : ' [tags: ${hit.note.tags.join(', ')}]';
      buf
        ..writeln(
          '### Note ${i + 1}: ${hit.note.title}$tags '
          '(sim ${hit.cosineScore.toStringAsFixed(2)}'
          '${hit.rerankScore != null ? ', rerank ${hit.rerankScore!.toStringAsFixed(2)}' : ''})',
        )
        ..writeln(hit.note.content.trim())
        ..writeln();
    }
    buf.write('Question: $cleanQuestion');
    return buf.toString();
  }

  Future<List<StudioNote>> _indexMissingNotesInternal(
    List<StudioNote> currentNotes, {
    bool forceReindex = false,
  }) async {
    final activeModelId =
        _labModels.state.loadedLabModels[StudioModelSpecialty.embedding]?.id ??
        'active-embedder';

    final updated = currentNotes.toList();
    final pendingTextIndices = <int>[];
    final pendingTexts = <String>[];
    final pendingTitles = <String?>[];

    for (var i = 0; i < currentNotes.length; i++) {
      final note = currentNotes[i];
      final text = note.searchableText.trim();
      final hasMedia = note.hasImage || note.hasAudio;
      if (text.isEmpty && !hasMedia) {
        continue;
      }
      final staleModel =
          note.embeddingModelId != null &&
          note.embeddingModelId != activeModelId;
      if (!forceReindex && note.isIndexed && !staleModel) {
        continue;
      }

      if (hasMedia) {
        final imageBytes = note.hasImage
            ? await _noteStore.readImageBytes(note)
            : null;
        final audioBytes = note.hasAudio
            ? await _noteStore.readAudioBytes(note)
            : null;
        final res = await _embedding.embedNoteContent(
          NoteEmbeddingInput(
            text: text.isEmpty ? note.title : text,
            title: note.title,
            imageBytes: imageBytes,
            imageMimeType: note.imageMimeType,
            audioWavBytes: audioBytes,
          ),
        );
        updated[i] = updated[i].copyWith(
          embedding: List<double>.unmodifiable(res.vector),
          embeddingModelId: activeModelId,
          isMultimodalIndexed: res.usedMultimodal,
        );
      } else {
        pendingTextIndices.add(i);
        pendingTexts.add(text);
        pendingTitles.add(note.title);
      }
    }

    if (pendingTextIndices.isNotEmpty) {
      final embedded = await _embedding.embedDocuments(
        pendingTexts,
        titles: pendingTitles,
      );
      for (
        var j = 0;
        j < pendingTextIndices.length && j < embedded.vectors.length;
        j++
      ) {
        final idx = pendingTextIndices[j];
        updated[idx] = updated[idx].copyWith(
          embedding: List<double>.unmodifiable(embedded.vectors[j]),
          embeddingModelId: activeModelId,
          isMultimodalIndexed: false,
        );
      }
    }

    return List<StudioNote>.unmodifiable(updated);
  }
}
