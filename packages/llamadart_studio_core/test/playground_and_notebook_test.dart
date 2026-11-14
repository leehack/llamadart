import 'dart:convert';
import 'dart:typed_data';

import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

import 'studio_test_fakes.dart';

void main() {
  group('Semantic Note Vault & Multi-Key Decision Workflows', () {
    test(
      'persists notes, indexes vectors, searches with two-stage rerank, and runs batch triage/audit',
      () async {
        final kv = InMemoryKeyValueStore();
        final storage = FakeStudioStoragePort();
        final playgroundPort = MockNoteAndDecisionPlaygroundPort();

        final labModels = LabModelCoordinator(
          storagePort: storage,
          modelLoader: playgroundPort,
          embeddingPort: playgroundPort,
          isWeb: false,
          isMobile: false,
        );
        final notebook = NotebookController(
          storagePort: storage,
          embeddingPort: playgroundPort,
          rerankerPort: playgroundPort,
          labModels: labModels,
          keyValueStore: kv,
          isWeb: false,
          isMobile: false,
        );
        await notebook.initialize();
        expect(notebook.state.notes, isNotEmpty);

        final created = await notebook.createNote(
          title: 'Metal KV Quantization',
          content: 'Q8_0 KV cache quantization cuts memory in half on Metal.',
          tags: const <String>['memory', 'metal'],
        );
        await notebook.indexNotes();
        expect(notebook.state.indexedNoteCount, notebook.state.notes.length);

        // Two-stage vector + cross-encoder rerank search.
        notebook.setRerankVaultHits(true);
        final hits = await notebook.searchNotes(
          'How to halve KV memory on Metal?',
        );
        expect(hits, isNotEmpty);
        expect(hits.first.note.id, created.id);
        expect(hits.first.rerankScore, isNotNull);

        final ragPrompt = notebook.buildRagChatPrompt(
          'How to halve KV memory on Metal?',
          hits: hits,
        );
        expect(ragPrompt, contains('Metal KV Quantization'));

        // Re-initialize from KeyValueStore and confirm note + vector survived.
        await notebook.dispose();
        await labModels.dispose();

        final reloadedLabModels = LabModelCoordinator(
          storagePort: storage,
          modelLoader: playgroundPort,
          embeddingPort: playgroundPort,
          isWeb: false,
          isMobile: false,
        );
        final reloadedNotebook = NotebookController(
          storagePort: storage,
          embeddingPort: playgroundPort,
          rerankerPort: playgroundPort,
          labModels: reloadedLabModels,
          keyValueStore: kv,
          isWeb: false,
          isMobile: false,
        );
        final reloadedPlayground = PlaygroundWorkspaceController(
          storagePort: storage,
          playgroundPort: playgroundPort,
          labModels: reloadedLabModels,
          notesProvider: () => reloadedNotebook.state.notes,
          onNotesUpdated: reloadedNotebook.applyAuditedNotes,
          isWeb: false,
          isMobile: false,
        );
        await reloadedNotebook.initialize();
        expect(
          reloadedNotebook.state.notes.any(
            (StudioNote n) => n.id == created.id,
          ),
          isTrue,
        );
        expect(reloadedNotebook.state.indexedNoteCount, greaterThan(0));

        // Run Multi-Key Decision workflows (triage, preflight, batch vault audit + auto-tag).
        final triage = await reloadedPlayground.runTriageRouterWorkflow(
          'Refactor coding_workspace_fs_io.dart and run dart test',
        );
        expect(triage, isNotNull);
        expect(triage!.answers.length, 5);

        final preflight = await reloadedPlayground
            .runGuardrailPreflightWorkflow(
              'Summarize my local KV cache notes cleanly.',
            );
        expect(preflight, isNotNull);
        expect(preflight!.answers.length, 5);

        final auditResults = await reloadedPlayground.auditVaultNotes(
          applyTagsToNotes: true,
        );
        expect(auditResults.length, reloadedNotebook.state.notes.length);
        final auditedCreated = reloadedNotebook.state.notes.firstWhere(
          (StudioNote n) => n.id == created.id,
        );
        expect(
          auditedCreated.tags,
          containsAll(<String>['architecture', 'action-item']),
        );

        await reloadedPlayground.dispose();
        await reloadedNotebook.dispose();
        await reloadedLabModels.dispose();
        await storage.dispose();
      },
    );
  });

  group('Multimodal Notebook (Audio/Image/RAG/ASR) & Decision Speed Burst', () {
    test(
      'StudioNote multimodal JSON round-trip preserves image, audio & transcript',
      () {
        final wavBytes = Uint8List.fromList(<int>[82, 73, 70, 70, 1, 2, 3, 4]);
        final imgBytes = Uint8List.fromList(<int>[137, 80, 78, 71]);
        final note = StudioNote(
          id: 'mm_1',
          title: 'Design Whiteboard & Voice',
          content: 'Architecture discussion notes.',
          createdAt: DateTime.utc(2026, 2, 1),
          updatedAt: DateTime.utc(2026, 2, 1),
          tags: const <String>['design'],
          sourceKind: StudioNoteSourceKind.audio,
          sourceFileName: 'meeting.wav',
          imageBase64: base64Encode(imgBytes),
          imageMimeType: 'image/png',
          audioBase64: base64Encode(wavBytes),
          audioDurationMs: 4200,
          transcript: 'We agreed to use Q8_0 KV cache on Metal.',
          embedding: const <double>[0.5, 0.5, 0.707],
          embeddingModelId: 'embeddinggemma-2-740m',
          isMultimodalIndexed: true,
        );

        final decoded = StudioNote.fromJson(note.toJson());
        expect(decoded.sourceKind, StudioNoteSourceKind.audio);
        expect(decoded.sourceFileName, 'meeting.wav');
        expect(decoded.imageMimeType, 'image/png');
        expect(base64Decode(decoded.audioBase64!), equals(wavBytes));
        expect(decoded.audioDurationMs, 4200);
        expect(decoded.transcript, contains('Q8_0 KV cache'));
        expect(decoded.isMultimodalIndexed, isTrue);
        expect(decoded.searchableText, contains('Transcript:'));
      },
    );

    test(
      'indexes multimodal notes via embedNoteContent, transcribes audio via ASR, streams askNotebook RAG, and runs Decision Speed Burst',
      () async {
        final kv = InMemoryKeyValueStore();
        final storage = FakeStudioStoragePort();
        final playgroundPort = MockNoteAndDecisionPlaygroundPort();
        final inference = FakeInferencePort()
          ..nextEvents = const <StudioTurnEvent>[
            StudioTextDeltaEvent('KV cache Q8_0 halves '),
            StudioTextDeltaEvent('context memory [Source 1].'),
            StudioTurnCompletedEvent(
              StudioTurnResult(
                text: 'KV cache Q8_0 halves context memory [Source 1].',
                metrics: StudioTurnMetrics(
                  generatedTokens: 9,
                  elapsedMs: 18,
                  decodeElapsedMs: 15,
                ),
              ),
            ),
          ];
        final sttPort = MockAsrSpeechPort();
        final shell = StudioShellController(keyValueStore: kv);
        await shell.initialize();

        final labModels = LabModelCoordinator(
          storagePort: storage,
          modelLoader: playgroundPort,
          embeddingPort: playgroundPort,
          isWeb: false,
          isMobile: false,
        );
        final notebook = NotebookController(
          storagePort: storage,
          embeddingPort: playgroundPort,
          rerankerPort: playgroundPort,
          labModels: labModels,
          keyValueStore: kv,
          inferencePort: inference,
          shellController: shell,
          sttPort: sttPort,
          isWeb: false,
          isMobile: false,
        );
        final playground = PlaygroundWorkspaceController(
          storagePort: storage,
          playgroundPort: playgroundPort,
          labModels: labModels,
          isWeb: false,
          isMobile: false,
        );
        await notebook.initialize();

        final voiceNote = await notebook.createNote(
          title: 'Metal Voice Memo',
          content: '',
          sourceKind: StudioNoteSourceKind.audio,
          audioWavBytes: Uint8List.fromList(<int>[82, 73, 70, 70, 9, 8, 7, 6]),
          audioDurationMs: 2500,
        );

        final transcript = await notebook.transcribeAudioNote(voiceNote.id);
        expect(transcript, 'Voice note recommends Q8_0 KV cache on Metal.');

        await notebook.indexNotes(forceReindex: true);
        expect(playgroundPort.multimodalEmbedCalls, greaterThanOrEqualTo(1));
        final reindexedVoice = notebook.state.notes.firstWhere(
          (StudioNote n) => n.id == voiceNote.id,
        );
        expect(reindexedVoice.isIndexed, isTrue);
        expect(reindexedVoice.isMultimodalIndexed, isTrue);
        expect(
          notebook.state.multimodalIndexedNoteCount,
          greaterThanOrEqualTo(1),
        );

        await notebook.askNotebook('How do I cut KV memory on Metal?');
        expect(notebook.state.isAnsweringNotebook, isFalse);
        expect(notebook.state.notebookAnswerText, contains('[Source 1]'));
        expect(notebook.state.notebookAnswerSources, isNotEmpty);

        // DecisionBenchmarkSummary getters & controller speed burst run.
        final benchmark = await playground.runDecisionSpeedBenchmark(
          state: 'Refactor controller and run dart test',
          questions: const <SystemOneQuestionSpec>[
            SystemOneNoulQuestionSpec(id: 'q1', prompt: 'Needs tools?'),
            SystemOneChoiceQuestionSpec(
              id: 'q2',
              prompt: 'Workspace?',
              labels: <String>['coding_repo', 'general_chat'],
            ),
          ],
          iterations: 15,
          compareWithActiveChatLlm: true,
        );
        expect(benchmark, isNotNull);
        expect(benchmark!.passesPerSecond, greaterThan(100));
        expect(benchmark.decisionsPerSecond, greaterThan(200));
        expect(benchmark.speedupVsLlm, greaterThan(50));
        expect(playground.state.decisionBenchmark, isNotNull);

        await playground.dispose();
        await notebook.dispose();
        await labModels.dispose();
        await shell.dispose();
        await sttPort.dispose();
        await inference.dispose();
        await storage.dispose();
      },
    );
  });
}
