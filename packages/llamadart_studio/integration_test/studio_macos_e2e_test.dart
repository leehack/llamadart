import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio/llamadart_studio.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

Future<String?> _findDartExecutable() async {
  final home = Platform.environment['HOME'] ?? '';
  final candidates = <String>[
    if (Platform.environment['FLUTTER_ROOT'] != null)
      '${Platform.environment['FLUTTER_ROOT']}/bin/dart',
    '$home/development/flutter/bin/dart',
    '$home/fvm/default/bin/dart',
    '/opt/homebrew/bin/dart',
    '/usr/local/bin/dart',
  ];
  for (final candidate in candidates) {
    if (File(candidate).existsSync()) {
      return candidate;
    }
  }
  try {
    final res = await Process.run('which', <String>['dart']);
    if (res.exitCode == 0) {
      final resolved = res.stdout.toString().trim();
      if (resolved.isNotEmpty && File(resolved).existsSync()) {
        return resolved;
      }
    }
  } catch (_) {}
  return null;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Persistence, Export/Import round-trip & BootGuard Safe-Mode recovery',
    (WidgetTester tester) async {
      final tempDir = await Directory.systemTemp.createTemp(
        'llamadart_studio_persist_e2e_',
      );
      addTearDown(() async {
        if (tempDir.existsSync()) {
          await tempDir.delete(recursive: true);
        }
      });

      final kv = InMemoryKeyValueStore();
      await kv.writeString(
        'studio.settings.v1',
        jsonEncode(const StudioSettings(autoLoadLastModel: true).toJson()),
      );

      // Simulate crash sentinel left behind from an interrupted model load.
      await BootGuardService(kv).beginModelLoad(
        modelName: 'Oversized 999B Model',
        modelIdOrPath: '/tmp/oversized.gguf',
      );
      final shell = StudioShellController(keyValueStore: kv);
      await shell.initialize();

      expect(shell.state.bootRecoveryAlert, isNotNull);
      expect(shell.state.bootRecoveryAlert!.modelName, 'Oversized 999B Model');
      expect(
        shell.state.settings.autoLoadLastModel,
        isFalse,
        reason: 'BootGuard must engage Safe Mode on interrupted load.',
      );
      shell.dismissBootRecoveryAlert();
      expect(shell.state.bootRecoveryAlert, isNull);

      // Persist conversation + off-heap attachment via platform conversation store,
      // then reload from disk in a fresh controller instance.
      final storeA = createDefaultConversationStore(
        fallbackKeyValueStore: kv,
        directoryPath: tempDir.path,
      );
      final inferenceA = _NoOpInferencePort();
      final chatA = ChatWorkspaceController(
        conversationStore: storeA,
        inferencePort: inferenceA,
        shellController: shell,
      );
      await chatA.initialize();
      await chatA.createConversation();
      chatA.addPendingAttachment(
        StudioAttachment(
          id: 'persist_img',
          kind: StudioAttachmentKind.image,
          name: 'disk_sample.png',
          mimeType: 'image/png',
          bytes: Uint8List.fromList(<int>[137, 80, 78, 71, 13, 10, 26, 10]),
          sizeBytes: 8,
        ),
      );
      await chatA.sendMessage('Persist this turn on disk.');

      final savedConv = chatA.state.activeConversation!;
      final savedAttachment = savedConv.activeBranch.first.attachments.first;
      expect(savedAttachment.localPath, isNotNull);
      expect(File(savedAttachment.localPath!).existsSync(), isTrue);

      final exportedMd = chatA.exportActiveAsMarkdown();
      expect(exportedMd, contains('Persist this turn on disk.'));
      final exportedJson = await chatA.exportActiveAsJson();
      expect(exportedJson, contains('Persist this turn on disk.'));

      // Fresh store + controller reading same directory on disk.
      final storeB = createDefaultConversationStore(
        fallbackKeyValueStore: kv,
        directoryPath: tempDir.path,
      );
      final chatB = ChatWorkspaceController(
        conversationStore: storeB,
        inferencePort: inferenceA,
        shellController: shell,
      );
      await chatB.initialize();
      expect(
        chatB.state.conversations.any(
          (StudioConversation c) => c.id == savedConv.id,
        ),
        isTrue,
      );
      final imported = await chatB.importFromJson(exportedJson);
      expect(imported.id, isNot(savedConv.id));
      expect(imported.activeBranch.first.text, 'Persist this turn on disk.');

      await chatA.dispose();
      await chatB.dispose();
      await inferenceA.dispose();
      await shell.dispose();
    },
  );

  testWidgets(
    'Full native macOS Metal E2E across Discovery, Chat (Branch/JSON/KV/Cancel), Note Vault RAG, Decision Engine, Speech Clone/ASR, Diffusion Seed/Negative, Coding+MCP+Skills, and LiteRT-LM',
    (WidgetTester tester) async {
      final tempAppData = await Directory.systemTemp.createTemp(
        'llamadart_studio_e2e_',
      );
      addTearDown(() async {
        if (tempAppData.existsSync()) {
          await tempAppData.delete(recursive: true);
        }
      });

      final deps = await StudioDependencies.bootstrapProduction(
        appDataDirectoryOverride: tempAppData.path,
        keyValueStoreOverride: InMemoryKeyValueStore(),
      );

      var disposed = false;
      addTearDown(() async {
        if (!disposed) {
          debugPrint('[E2E] tearDown: disposing deps');
          await deps.dispose();
          debugPrint('[E2E] tearDown: disposed deps');
        }
      });

      await tester.pumpWidget(LlamadartStudioApp(dependencies: deps));
      await tester.pump(const Duration(milliseconds: 400));

      // -----------------------------------------------------------------------
      // 1. Local Model Discovery, Model Hub & Big Coding Model Catalog Check
      // -----------------------------------------------------------------------
      debugPrint('[E2E] Phase 1: Model Hub discovery');
      final hubState = deps.modelHubController.state;
      expect(
        hubState.localModels.length,
        greaterThanOrEqualTo(5),
        reason: 'Expected LocalModelScanner to discover existing GGUF/LiteRT-LM models in ~/Library/Caches/llamadart/models.',
      );
      expect(
        hubState.totalCacheBytes,
        greaterThan(500 * 1024 * 1024),
        reason: 'Expected non-trivial local model cache footprint on disk.',
      );
      expect(
        hubState.cachedModelIds,
        containsAll(<String>[
          'qwen3.5-0.8b-q4-k-m',
          'qwen3-asr-0.6b-q8-0',
          'sdxs-512-q8_0',
        ]),
      );
      expect(
        CodingWorkspaceController.recommendedCodingModels.map(
          (StudioModelDescriptor m) => m.id,
        ),
        contains('qwen3.6-27b-ud-q4-k-xl'),
      );

      deps.shellController.selectWorkspace(StudioWorkspace.models);
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.textContaining('INSTALLED ON THIS MACHINE'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // Verify custom folder registration & removal round-trip.
      final extraFolder = await Directory('${tempAppData.path}/extra_models')
          .create(recursive: true);
      await deps.modelHubController.addCustomModelDirectory(extraFolder.path);
      expect(
        deps.shellController.state.settings.customModelDirectories,
        contains(extraFolder.path),
      );
      await deps.modelHubController.removeCustomModelDirectory(
        extraFolder.path,
      );
      expect(
        deps.shellController.state.settings.customModelDirectories,
        isNot(contains(extraFolder.path)),
      );

      // -----------------------------------------------------------------------
      // 2. Real Metal Chat Streaming, Branching, GBNF JSON Schema, KV Q8_0,
      //    Speculative ngramCache, Cancel/Regenerate, Tokenizer & Benchmark
      // -----------------------------------------------------------------------
      debugPrint('[E2E] Phase 2: Metal chat streaming');
      final chatModel =
          CuratedModelCatalog.byId('functiongemma-270m-q4-k-m') != null &&
              hubState.cachedModelIds.contains('functiongemma-270m-q4-k-m')
          ? CuratedModelCatalog.byId('functiongemma-270m-q4-k-m')!
          : CuratedModelCatalog.byId('qwen3.5-0.8b-q4-k-m')!;

      debugPrint('[E2E] Phase 2: activating ${chatModel.id}');
      await deps.modelHubController.activateChatModel(chatModel);
      debugPrint('[E2E] Phase 2: activated ${chatModel.id}');
      await deps.shellController.updateSettings(
        (StudioSettings s) => s.copyWith(
          thinkingEnabled: false,
          toolsEnabled: false,
          maxTokens: 48,
          temperature: 0.0,
        ),
      );
      expect(deps.modelHubController.runtimeStore.state.isReady, isTrue);
      expect(
        deps.modelHubController.runtimeStore.state.backendName,
        isNotEmpty,
      );

      deps.shellController.selectWorkspace(StudioWorkspace.chat);
      await tester.pump(const Duration(milliseconds: 300));

      debugPrint('[E2E] Phase 2: sendMessage 1');
      await deps.chatController.sendMessage('Say hello in one short sentence.');
      debugPrint('[E2E] Phase 2: sendMessage 1 done');
      await tester.pump(const Duration(milliseconds: 300));
      expect(deps.chatController.state.lastTurnError, isNull);

      final firstBranch =
          deps.chatController.state.activeConversation!.activeBranch;
      expect(firstBranch.length, 2);
      expect(firstBranch.last.text.trim(), isNotEmpty);
      expect(firstBranch.last.metrics?.generatedTokens ?? 0, greaterThan(0));

      // Non-destructive branch edit with real native generation.
      debugPrint('[E2E] Phase 2: editUserMessageAndBranch');
      await deps.chatController.editUserMessageAndBranch(
        originalMessageId: firstBranch.first.id,
        editedText: 'Count 1, 2, 3.',
      );
      await tester.pump(const Duration(milliseconds: 300));

      final secondBranch =
          deps.chatController.state.activeConversation!.activeBranch;
      expect(secondBranch.length, 2);
      expect(secondBranch.last.text.trim(), isNotEmpty);
      expect(find.text('2 / 2'), findsOneWidget);

      // Cancel & Regenerate verification on real native stream.
      debugPrint('[E2E] Phase 2: cancel + regenerate');
      await deps.shellController.updateSettings(
        (StudioSettings s) => s.copyWith(maxTokens: 256, temperature: 0.2),
      );
      final longTurnFuture = deps.chatController.sendMessage(
        'List 40 distinct prime numbers one per line with explanations.',
      );
      for (var i = 0; i < 400; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        if (deps.chatController.activeStreamStore.state.tokensGenerated >= 2) {
          deps.chatController.stopGeneration();
          break;
        }
        if (!deps.chatController.activeStreamStore.state.isGenerating &&
            i > 10) {
          break;
        }
      }
      await longTurnFuture;
      expect(deps.chatController.activeStreamStore.state.isGenerating, isFalse);
      final cancelledAst =
          deps.chatController.state.activeConversation!.activeBranch.last;
      expect(cancelledAst.role, StudioRole.assistant);

      await deps.shellController.updateSettings(
        (StudioSettings s) => s.copyWith(maxTokens: 32, temperature: 0.0),
      );
      await deps.chatController.regenerateAssistantMessage(cancelledAst.id);
      await tester.pump(const Duration(milliseconds: 250));
      expect(deps.chatController.state.lastTurnError, isNull);
      expect(
        deps.chatController.state.activeConversation!.activeBranch.last.id,
        isNot(cancelledAst.id),
      );

      // Real Token Inspector & Throughput Benchmark on active chat engine.
      debugPrint('[E2E] Phase 2: token inspection & benchmark');
      deps.shellController.selectWorkspace(StudioWorkspace.playground);
      deps.playgroundController.selectTab(PlaygroundToolTab.tokens);
      await tester.pump(const Duration(milliseconds: 250));

      await deps.playgroundController.runTokenInspection(
        'llamadart Studio Metal E2E!',
      );
      expect(deps.playgroundController.state.errorMessage, isNull);
      expect(deps.playgroundController.state.inspectedTokens, isNotEmpty);

      deps.playgroundController.selectTab(PlaygroundToolTab.benchmark);
      await tester.pump(const Duration(milliseconds: 250));
      await deps.playgroundController.runBenchmark(targetDecodeTokens: 16);
      expect(deps.playgroundController.state.errorMessage, isNull);
      expect(deps.playgroundController.state.benchmarkHistory, isNotEmpty);
      final bench = deps.playgroundController.state.benchmarkHistory.first;
      expect(bench.generatedTokens, greaterThan(0));
      expect(bench.decodeTokensPerSecond, greaterThan(0));

      // 2b. Qwen3.5 0.8B: Reasoning + GBNF JSON Schema + KV Cache Q8_0 +
      //     FlashAttention + Speculative ngramCache.
      if (hubState.cachedModelIds.contains('qwen3.5-0.8b-q4-k-m')) {
        debugPrint('[E2E] Phase 2b: Qwen3.5 reasoning + KV Q8_0 + ngramCache');
        final qwenModel = CuratedModelCatalog.byId('qwen3.5-0.8b-q4-k-m')!;
        await deps.shellController.updateSettings(
          (StudioSettings s) => s.copyWith(
            cacheTypeK: KvCacheType.q8_0,
            cacheTypeV: KvCacheType.q8_0,
            flashAttention: FlashAttention.enabled,
            speculativeMode: StudioSpeculativeMode.ngramCache,
            thinkingEnabled: true,
            thinkingBudgetTokens: 0, // Auto (~55% budget)
            toolsEnabled: false,
            maxTokens: 160,
            temperature: 0.2,
          ),
        );
        await deps.modelHubController.activateChatModel(
          qwenModel,
          applyModelPreset: false,
        );
        deps.shellController.selectWorkspace(StudioWorkspace.chat);
        await deps.chatController.createConversation();
        await tester.pump(const Duration(milliseconds: 250));

        await deps.chatController.sendMessage(
          'Explain how KV-cache quantization saves memory in 2 short bullet points.',
        );
        await tester.pump(const Duration(milliseconds: 300));
        expect(deps.chatController.state.lastTurnError, isNull);

        final reasoningTurn =
            deps.chatController.state.activeConversation!.activeBranch.last;
        expect(
          reasoningTurn.thinkingText?.trim(),
          isNotEmpty,
          reason:
              'Qwen3.5 0.8B with thinkingEnabled must capture <think> trace.',
        );
        expect(
          reasoningTurn.text.trim(),
          isNotEmpty,
          reason: 'Reasoning turn must ALWAYS produce a visible final answer after thinking.',
        );

        // GBNF JSON Schema constrained extraction turn.
        debugPrint('[E2E] Phase 2c: GBNF JSON Schema structured output');
        final jsonPreset = StudioPreset.builtInPresets.firstWhere(
          (StudioPreset p) => p.id == 'json_extractor',
        );
        await deps.chatController.createConversation(preset: jsonPreset);
        await deps.shellController.updateSettings(
          (StudioSettings s) => s.copyWith(
            speculativeMode: StudioSpeculativeMode.off,
            thinkingEnabled: false,
            toolsEnabled: false,
            maxTokens: 160,
            temperature: 0.0,
          ),
        );
        await deps.chatController.sendMessage(
          'Release 0.17 shipped Metal FlashAttention and cut TTFT by 38%. Next week we will publish migration docs.',
        );
        await tester.pump(const Duration(milliseconds: 250));
        expect(deps.chatController.state.lastTurnError, isNull);
        expect(deps.chatController.state.lastStructuredJsonValid, isTrue);
        final jsonReply =
            deps.chatController.state.activeConversation!.activeBranch.last;
        final decodedJson = jsonDecode(jsonReply.text) as Map<String, Object?>;
        expect(decodedJson['summary'], isA<String>());
        expect(
          decodedJson['sentiment'],
          anyOf('positive', 'neutral', 'negative'),
        );
        expect(decodedJson['actionItems'], isA<List<Object?>>());

        // Restore default F16 KV settings for subsequent phases.
        await deps.shellController.updateSettings(
          (StudioSettings s) => s.copyWith(
            cacheTypeK: KvCacheType.f16,
            cacheTypeV: KvCacheType.f16,
            flashAttention: FlashAttention.auto,
            speculativeMode: StudioSpeculativeMode.off,
          ),
        );
      }

      // Release chat model before loading specialist multi-engine pipelines.
      debugPrint('[E2E] Phase 2: unloading chat model');
      await deps.modelHubController.unloadActiveModel();

      // -----------------------------------------------------------------------
      // 3. Real Playground Semantic Note Vault (Embeddings + Stage-2 Reranker
      //    + RAG Prompt) & Multi-Key System-1 Decision Engine Workflows
      // -----------------------------------------------------------------------
      debugPrint('[E2E] Phase 3: Playground');
      deps.playgroundController.selectTab(PlaygroundToolTab.embeddings);

      final liteRtEmbedModel = deps.playgroundController.availableLabModels
          .where(
            (StudioModelDescriptor m) =>
                m.specialty == StudioModelSpecialty.embedding &&
                m.filename.toLowerCase().endsWith('.litertlm'),
          )
          .firstOrNull;
      if (liteRtEmbedModel != null) {
        debugPrint('[E2E] Phase 3a: loading ${liteRtEmbedModel.id}');
        await deps.playgroundController.loadLabModel(liteRtEmbedModel);
        expect(
          deps.playgroundController.state.errorMessage,
          isNull,
          reason: 'LiteRT-LM embedding models (EmbeddingGemma 2) must load cleanly on CPU.',
        );
        debugPrint('[E2E] Phase 3a: running embeddings');
        await deps.playgroundController.runEmbeddings(const <String>[
          'Metal GPU shaders accelerate quantized matrix multiplication on Mac.',
          'Apple Silicon GPUs speed up local quantized neural network inference.',
          'Fresh basil and mozzarella make a classic Margherita pizza.',
        ]);
        expect(deps.playgroundController.state.errorMessage, isNull);
        final liteRtRes = deps.playgroundController.state.embeddingResult!;
        expect(liteRtRes.dimensions, 768);
        expect(
          liteRtRes.similarityMatrix[0][1],
          greaterThan(liteRtRes.similarityMatrix[0][2]),
        );
      }

      final embedModel = deps.playgroundController.availableLabModels
          .firstWhere(
            (StudioModelDescriptor m) =>
                m.specialty == StudioModelSpecialty.embedding &&
                m.filename.toLowerCase().contains('embeddinggemma-300m'),
            orElse: () =>
                deps.playgroundController.availableLabModels.firstWhere(
                  (StudioModelDescriptor m) =>
                      m.specialty == StudioModelSpecialty.embedding &&
                      deps.modelHubController.state.cachedModelIds.contains(
                        m.id,
                      ),
                ),
          );

      debugPrint('[E2E] Phase 3b: loading ${embedModel.id}');
      await deps.playgroundController.loadLabModel(embedModel);
      expect(deps.playgroundController.state.errorMessage, isNull);

      debugPrint('[E2E] Phase 3b: running embeddings + Note Vault RAG');
      await deps.playgroundController.runEmbeddings(const <String>[
        'Metal GPU shaders accelerate quantized matrix multiplication on Mac.',
        'Apple Silicon GPUs speed up local quantized neural network inference.',
        'Fresh basil and mozzarella make a classic Margherita pizza.',
      ]);
      expect(deps.playgroundController.state.errorMessage, isNull);
      final embResult = deps.playgroundController.state.embeddingResult;
      expect(embResult, isNotNull);
      expect(embResult!.dimensions, greaterThanOrEqualTo(128));
      expect(
        embResult.similarityMatrix[0][1],
        greaterThan(embResult.similarityMatrix[0][2]),
        reason: 'Related GPU inference passages must have higher cosine similarity than pizza.',
      );

      // Dedicated Multimodal Notebook: navigate UI -> create note -> vector index ->
      // Stage-2 BGE Rerank -> Related Notes + grounded RAG prompt handoff + Ask Notebook.
      deps.shellController.selectWorkspace(StudioWorkspace.notes);
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('Multimodal Notebook'), findsOneWidget);

      final createdNote = await deps.notebookController.createNote(
        title: 'Apple Silicon Q8_0 KV Memory Savings',
        content: 'Enabling Q8_0 KV cache quantization with FlashAttention reduces memory footprint roughly in half for 32K context windows.',
        tags: const <String>['metal', 'memory'],
      );
      await deps.notebookController.indexNotes(forceReindex: true);
      expect(deps.notebookController.state.errorMessage, isNull);
      expect(
        deps.notebookController.state.indexedNoteCount,
        deps.notebookController.state.notes.length,
      );
      expect(deps.notebookController.state.relatedNotes, isNotEmpty);

      final hasBgeReranker = deps.modelHubController.state.cachedModelIds
          .contains('bge-reranker-v2-m3-q8-0');
      deps.notebookController.setRerankVaultHits(hasBgeReranker);
      final vaultHits = await deps.notebookController.searchNotes(
        'How to reduce 32K context window memory on Apple Silicon?',
        rerank: hasBgeReranker,
      );
      expect(deps.notebookController.state.errorMessage, isNull);
      expect(vaultHits, isNotEmpty);
      expect(vaultHits.first.note.id, createdNote.id);
      if (hasBgeReranker) {
        expect(vaultHits.first.rerankScore, isNotNull);
      }

      final ragPrompt = deps.notebookController.buildRagChatPrompt(
        'How can I save context memory on Mac?',
        hits: vaultHits,
      );
      expect(ragPrompt, contains('Apple Silicon Q8_0 KV Memory Savings'));
      deps.chatController.setComposerDraft(ragPrompt);
      expect(deps.chatController.state.composerDraft, contains('Note Vault'));
      deps.chatController.setComposerDraft(null);

      final decisionModel = deps.playgroundController.availableLabModels
          .where(
            (StudioModelDescriptor m) =>
                m.specialty == StudioModelSpecialty.decision &&
                deps.modelHubController.state.cachedModelIds.contains(m.id),
          )
          .firstOrNull;
      expect(
        decisionModel,
        isNotNull,
        reason: 'Expected local Laya + laya-head.safetensors to be discovered.',
      );

      deps.shellController.selectWorkspace(StudioWorkspace.playground);
      deps.playgroundController.selectTab(PlaygroundToolTab.decision);
      debugPrint('[E2E] Phase 3c: runDecisionHead + multi-key batch workflows');
      await deps.playgroundController.runDecisionHead(
        stateText:
            'The user has 16 GB free RAM and wants to load a 1 GB model.',
        yesNoQuestion: 'Does the 1 GB model fit in 16 GB of free memory?',
      );
      expect(deps.playgroundController.state.errorMessage, isNull);
      final sys1 = deps.playgroundController.state.decisionEvaluation;
      expect(sys1, isNotNull);
      expect(sys1!.probabilityTrue, inInclusiveRange(0.0, 1.0));
      expect(sys1.confidence, greaterThanOrEqualTo(0.0));

      final triageBatch = await deps.playgroundController
          .runTriageRouterWorkflow(
            'Refactor lib/src/services/coding_workspace_fs_io.dart and run dart test',
          );
      expect(deps.playgroundController.state.errorMessage, isNull);
      expect(triageBatch, isNotNull);
      expect(triageBatch!.answers.length, 5);

      final preflightBatch = await deps.playgroundController
          .runGuardrailPreflightWorkflow(
            'Delete all build folders recursively.',
          );
      expect(deps.playgroundController.state.errorMessage, isNull);
      expect(preflightBatch, isNotNull);
      expect(preflightBatch!.answers.length, 5);

      final auditResults = await deps.playgroundController.auditVaultNotes(
        applyTagsToNotes: true,
      );
      expect(deps.playgroundController.state.errorMessage, isNull);
      expect(auditResults.length, deps.notebookController.state.notes.length);

      // Standalone cross-encoder reranker tab check.
      if (hasBgeReranker) {
        debugPrint('[E2E] Phase 3d: runReranker');
        deps.playgroundController.selectTab(PlaygroundToolTab.reranker);
        await deps.playgroundController.runReranker(
          query: 'How do I reduce memory usage for long context windows?',
          documents: const <String>[
            'AudioRecorder captures 16 kHz mono PCM samples for speech transcription.',
            'Use Q8_0 or Q4_0 KV cache quantization with FlashAttention enabled.',
          ],
        );
        expect(deps.playgroundController.state.errorMessage, isNull);
        final ranked = deps.playgroundController.state.rerankResults;
        expect(ranked.length, 2);
        expect(
          ranked.first.document,
          contains('KV cache quantization'),
          reason: 'Cross-encoder reranker must rank KV-cache passage above unrelated audio passage.',
        );
      }

      // Phase 3e: Notebook Ask Q&A + System-1 Speed Burst vs Active Chat LLM.
      if (hubState.cachedModelIds.contains('qwen3.5-0.8b-q4-k-m')) {
        debugPrint(
          '[E2E] Phase 3e: Notebook Ask Q&A + Decision Speed Burst vs LLM',
        );
        await deps.shellController.updateSettings(
          (StudioSettings s) => s.copyWith(
            thinkingEnabled: false,
            toolsEnabled: false,
            maxTokens: 96,
            temperature: 0.0,
          ),
        );
        await deps.modelHubController.activateChatModel(
          CuratedModelCatalog.byId('qwen3.5-0.8b-q4-k-m')!,
          applyModelPreset: false,
        );

        deps.shellController.selectWorkspace(StudioWorkspace.notes);
        await tester.pump(const Duration(milliseconds: 200));
        await deps.notebookController.askNotebook(
          'How do I reduce 32K context window memory on Apple Silicon?',
        );
        expect(deps.notebookController.state.errorMessage, isNull);
        expect(
          deps.notebookController.state.notebookAnswerText.trim(),
          isNotEmpty,
        );
        expect(deps.notebookController.state.notebookAnswerSources, isNotEmpty);

        deps.shellController.selectWorkspace(StudioWorkspace.playground);
        deps.playgroundController.selectTab(PlaygroundToolTab.decision);
        await tester.pump(const Duration(milliseconds: 200));
        final speedBench = await deps.playgroundController
            .runDecisionSpeedBenchmark(
              state: 'Refactor lib/main.dart and run dart test',
              questions: const <SystemOneQuestionSpec>[
                SystemOneChoiceQuestionSpec(
                  id: 'domain',
                  prompt: 'Which workspace handles this request?',
                  labels: <String>[
                    'coding_repo',
                    'knowledge_notes',
                    'general_chat',
                  ],
                ),
                SystemOneNoulQuestionSpec(
                  id: 'needs_tools',
                  prompt: 'Does this request require workspace tools?',
                ),
              ],
              iterations: 8,
              compareWithActiveChatLlm: true,
            );
        expect(deps.playgroundController.state.errorMessage, isNull);
        expect(speedBench, isNotNull);
        expect(speedBench!.decisionsPerSecond, greaterThan(0));
        expect(speedBench.llmCompareElapsedMs, isNotNull);
        expect(speedBench.llmCompareElapsedMs!, greaterThan(0));
        expect(speedBench.speedupVsLlm, isNotNull);
        await deps.modelHubController.unloadActiveModel();
      }

      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.takeException(), isNull);
      debugPrint('[E2E] Phase 3: unloading playground models');
      await deps.playgroundController.unloadModels();

      // -----------------------------------------------------------------------
      // 4. Real Speech Studio Neural TTS -> Voice Cloning -> AVPlayer -> ASR
      //    (both audioBytes AND audioFilePath)
      // -----------------------------------------------------------------------
      debugPrint('[E2E] Phase 4: Speech TTS->Clone->ASR');
      deps.shellController.selectWorkspace(StudioWorkspace.speech);
      await tester.pump(const Duration(milliseconds: 200));

      final ttsModel = deps.speechController.availableTtsModels.firstWhere(
        (StudioModelDescriptor m) =>
            m.filename.toLowerCase().contains('0.6b') &&
            deps.modelHubController.state.cachedModelIds.contains(m.id),
        orElse: () => deps.speechController.availableTtsModels.firstWhere(
          (StudioModelDescriptor m) =>
              deps.modelHubController.state.cachedModelIds.contains(m.id),
        ),
      );
      await deps.speechController.loadTtsModel(ttsModel);
      expect(deps.speechController.state.errorMessage, isNull);

      await deps.speechController.synthesizeText(
        text: 'Hello world.',
        language: 'english',
        temperature: 0.6,
      );
      expect(deps.speechController.state.errorMessage, isNull);
      expect(deps.speechController.state.synthesizedHistory, isNotEmpty);

      final synthClip =
          deps.speechController.state.synthesizedHistory.first.clip;
      expect(synthClip.wavBytes.length, greaterThan(4000));
      expect(String.fromCharCodes(synthClip.wavBytes.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(synthClip.wavBytes.sublist(8, 12)), 'WAVE');

      // Voice Cloning via speakerReferenceBytes (re-using real 24kHz WAV clip).
      debugPrint('[E2E] Phase 4a: Voice cloning via speakerReferenceBytes');
      await deps.speechController.synthesizeText(
        text: 'Testing voice clone.',
        language: 'english',
        speakerReferenceBytes: synthClip.wavBytes,
        temperature: 0.6,
      );
      expect(deps.speechController.state.errorMessage, isNull);
      expect(deps.speechController.state.synthesizedHistory.length, 2);
      final clonedClip =
          deps.speechController.state.synthesizedHistory.first.clip;
      expect(clonedClip.wavBytes.length, greaterThan(4000));
      expect(String.fromCharCodes(clonedClip.wavBytes.sublist(0, 4)), 'RIFF');

      // Exercise native AVPlayer WAV playback via the Play/Stop button.
      debugPrint('[E2E] Phase 4b: Speech WAV playback');
      await tester.pump(const Duration(milliseconds: 200));
      final playButton = find.byIcon(Icons.play_circle_fill_rounded).first;
      await tester.ensureVisible(playButton);
      await tester.pumpAndSettle();
      await tester.tap(playButton);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.textContaining('Audio playback failed'), findsNothing);
      expect(tester.takeException(), isNull);
      final stopButton = find.byIcon(Icons.stop_circle_rounded);
      if (stopButton.evaluate().isNotEmpty) {
        await tester.tap(stopButton.first);
        await tester.pump(const Duration(milliseconds: 200));
      }

      debugPrint('[E2E] Phase 4c: Speech ASR (audioBytes & audioFilePath)');
      final sttModel = deps.speechController.availableSttModels.firstWhere(
        (StudioModelDescriptor m) => m.id == 'qwen3-asr-0.6b-q8-0',
      );
      await deps.speechController.loadSttModel(sttModel);
      expect(deps.speechController.state.errorMessage, isNull);

      await deps.speechController.transcribeAudio(
        audioBytes: synthClip.wavBytes,
      );
      expect(deps.speechController.state.errorMessage, isNull);
      final transcriptBytes =
          deps.speechController.state.latestTranscript?.text.toLowerCase() ??
          '';
      expect(transcriptBytes, contains('hello'));

      final wavFile = File('${tempAppData.path}/e2e_asr_sample.wav');
      await wavFile.writeAsBytes(synthClip.wavBytes, flush: true);
      await deps.speechController.transcribeAudio(audioFilePath: wavFile.path);
      expect(deps.speechController.state.errorMessage, isNull);
      final transcriptFile =
          deps.speechController.state.latestTranscript?.text.toLowerCase() ??
          '';
      expect(transcriptFile, contains('hello'));

      // Multimodal Notebook audio note + local ASR transcription check.
      final voiceNote = await deps.notebookController.createNote(
        title: 'Synthesized Greeting Memo',
        content: 'Recorded audio sample from Speech Studio.',
        sourceKind: StudioNoteSourceKind.audio,
        sourceFileName: 'e2e_asr_sample.wav',
        audioWavBytes: synthClip.wavBytes,
        audioDurationMs: 1200,
      );
      final noteTranscript = await deps.notebookController.transcribeAudioNote(
        voiceNote.id,
      );
      expect(deps.notebookController.state.errorMessage, isNull);
      expect(noteTranscript?.toLowerCase(), contains('hello'));

      expect(tester.takeException(), isNull);
      await deps.speechController.unloadModels();

      // -----------------------------------------------------------------------
      // 5. Real Image Studio Diffusion (negativePrompt + Deterministic Seed)
      // -----------------------------------------------------------------------
      debugPrint('[E2E] Phase 5: Image Diffusion');
      deps.shellController.selectWorkspace(StudioWorkspace.image);
      await tester.pump(const Duration(milliseconds: 200));

      final sdxs = deps.imageController.availableModels.firstWhere(
        (StudioModelDescriptor m) => m.id == 'sdxs-512-q8_0',
      );
      await deps.imageController.loadModel(sdxs);
      expect(deps.imageController.state.errorMessage, isNull);

      await deps.imageController.generate(
        prompt: 'Minimal ceramic coffee cup on oak desk, studio lighting',
        negativePrompt: 'blurry, distorted, low quality, text',
        width: 512,
        height: 512,
        steps: 1,
        guidanceScale: 1.0,
        seed: 42,
      );
      expect(deps.imageController.state.errorMessage, isNull);
      expect(deps.imageController.state.gallery, isNotEmpty);

      final generatedImage = deps.imageController.state.gallery.first;
      expect(generatedImage.width, 512);
      expect(generatedImage.height, 512);
      expect(generatedImage.seed, 42);
      expect(
        generatedImage.pngBytes.sublist(0, 8),
        equals(<int>[137, 80, 78, 71, 13, 10, 26, 10]),
      );

      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byTooltip('Save PNG'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await deps.imageController.unloadModel();

      // -----------------------------------------------------------------------
      // 6. Diffusion-to-Vision Chat Handoff & Tool Calling (Qwen3.5 0.8B VL)
      // -----------------------------------------------------------------------
      debugPrint('[E2E] Phase 6: Vision handoff + tool calling');
      final qwenVl = CuratedModelCatalog.byId('qwen3.5-0.8b-q4-k-m')!;
      await deps.modelHubController.activateChatModel(qwenVl);
      await deps.shellController.updateSettings(
        (StudioSettings s) => s.copyWith(
          thinkingEnabled: false,
          toolsEnabled: false,
          maxTokens: 96,
          temperature: 0.0,
        ),
      );

      await deps.chatController.createConversation();
      deps.chatController.addPendingAttachment(
        StudioAttachment(
          id: 'e2e_sdxs_handoff',
          kind: StudioAttachmentKind.image,
          name: 'sdxs_cup.png',
          mimeType: 'image/png',
          bytes: generatedImage.pngBytes,
          sizeBytes: generatedImage.pngBytes.length,
        ),
      );
      deps.shellController.selectWorkspace(StudioWorkspace.chat);

      await deps.chatController.sendMessage(
        'Describe this image in five words or fewer.',
      );
      expect(deps.chatController.state.lastTurnError, isNull);
      final visionReply =
          deps.chatController.state.activeConversation!.activeBranch.last;
      expect(visionReply.text.trim(), isNotEmpty);

      // Tool-enabled turn (verifies tool registry wiring + native grammar/parse).
      await deps.shellController.updateSettings(
        (StudioSettings s) => s.copyWith(
          thinkingEnabled: false,
          toolsEnabled: true,
          maxTokens: 128,
          temperature: 0.0,
        ),
      );
      await deps.chatController.createConversation();
      await deps.chatController.sendMessage(
        'Use the evaluateMath tool to compute (17 * 19) + 5 and state the result.',
      );
      expect(deps.chatController.state.lastTurnError, isNull);
      final toolTurnBranch =
          deps.chatController.state.activeConversation!.activeBranch;
      expect(toolTurnBranch.last.text.trim(), isNotEmpty);

      // -----------------------------------------------------------------------
      // 7. Coding Workspace + AGENTS.md + .agents/skills + .agents/mcp.json +
      //    Built-in Dart & Flutter MCP + pi.dev Toolset + Live Turn
      // -----------------------------------------------------------------------
      debugPrint(
        '[E2E] Phase 7: Coding workspace + AGENTS.md + Skills + .agents/mcp.json',
      );
      final dartExe = await _findDartExecutable();
      expect(
        dartExe,
        isNotNull,
        reason:
            'Expected Dart CLI binary on macOS host to spawn stdio MCP server.',
      );
      final mcpServerScript = File('${tempAppData.path}/e2e_mcp_server.dart');
      await mcpServerScript.writeAsString(r'''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.trim().isEmpty) continue;
    final msg = jsonDecode(line) as Map<String, dynamic>;
    final id = msg['id'];
    final method = msg['method'] as String?;
    if (id == null) continue;
    late Map<String, Object?> result;
    switch (method) {
      case 'initialize':
        result = <String, Object?>{
          'protocolVersion': '2025-03-26',
          'capabilities': <String, Object?>{
            'tools': <String, Object?>{},
            'resources': <String, Object?>{},
          },
          'serverInfo': <String, Object?>{
            'name': 'e2e-stdio-mcp',
            'version': '1.0.0',
          },
        };
      case 'tools/list':
        result = <String, Object?>{
          'tools': <Object?>[
            <String, Object?>{
              'name': 'project_badge',
              'description': 'Returns a verification badge string.',
              'inputSchema': <String, Object?>{
                'type': 'object',
                'properties': <String, Object?>{
                  'label': <String, Object?>{'type': 'string'},
                },
                'required': <String>['label'],
              },
            },
          ],
        };
      case 'tools/call':
        final params = (msg['params'] as Map<String, dynamic>?) ?? const <String, dynamic>{};
        final args = (params['arguments'] as Map<String, dynamic>?) ?? const <String, dynamic>{};
        final label = (args['label'] as String?) ?? 'OK';
        result = <String, Object?>{
          'isError': false,
          'content': <Object?>[
            <String, Object?>{'type': 'text', 'text': 'BADGE:${label.toUpperCase()}'},
          ],
        };
      case 'resources/list':
        result = <String, Object?>{
          'resources': <Object?>[
            <String, Object?>{
              'uri': 'studio://e2e/manifest',
              'name': 'e2e-manifest',
              'mimeType': 'text/plain',
            },
          ],
        };
      case 'resources/read':
        result = <String, Object?>{
          'contents': <Object?>[
            <String, Object?>{
              'uri': 'studio://e2e/manifest',
              'mimeType': 'text/plain',
              'text': 'E2E MCP resource OK',
            },
          ],
        };
      default:
        stdout.writeln(jsonEncode(<String, Object?>{
          'jsonrpc': '2.0',
          'id': id,
          'error': <String, Object?>{
            'code': -32601,
            'message': 'Method not found: $method',
          },
        }));
        continue;
    }
    stdout.writeln(jsonEncode(<String, Object?>{
      'jsonrpc': '2.0',
      'id': id,
      'result': result,
    }));
  }
}
''');

      final codingRepo = Directory('${tempAppData.path}/e2e_coding_project');
      await File('${codingRepo.path}/lib/math_utils.dart')
          .create(recursive: true);
      await File('${codingRepo.path}/lib/math_utils.dart')
          .writeAsString('int multiplyInts(int a, int b) => a * b;\n');
      await File('${codingRepo.path}/AGENTS.md').writeAsString(
        '# E2E Project Rules\nUse explicit pi.dev read/edit tools.\n',
      );
      await File('${codingRepo.path}/.agents/skills/concise-coder/SKILL.md')
          .create(recursive: true);
      await File('${codingRepo.path}/.agents/skills/concise-coder/SKILL.md')
          .writeAsString(
            '---\nname: concise-coder\ndescription: Summarize inspected Dart files concisely.\n---\n\nInspect real files using workspace tools before answering.\n',
          );
      await File('${codingRepo.path}/.agents/mcp.json').writeAsString(
        jsonEncode(<String, Object?>{
          'mcpServers': <String, Object?>{
            'e2e-project-mcp': <String, Object?>{
              'command': dartExe,
              'args': <String>[mcpServerScript.path],
            },
          },
        }),
      );

      await deps.codingController.setWorkspaceRoot(codingRepo.path);
      await deps.codingController.openFile('lib/math_utils.dart');
      expect(
        deps.codingController.state.selectedFileSlice?.content,
        contains('multiplyInts'),
      );
      expect(deps.codingController.state.agentsContext.hasInstructions, isTrue);
      expect(
        deps.codingController.state.agentsContext.instructions,
        contains('Use explicit pi.dev read/edit tools.'),
      );
      expect(
        deps.codingController.state.activeCoreTools,
        equals(const <String>['read', 'write', 'edit', 'grep', 'ls']),
      );
      deps.codingController.setAllowShellCommandTool(true);
      expect(deps.codingController.state.activeCoreTools, contains('bash'));
      deps.codingController.setAllowShellCommandTool(false);

      final discoveredSkill = deps.skillRegistry.state.skills.firstWhere(
        (StudioSkill s) => s.name == 'concise-coder',
      );
      expect(discoveredSkill.isDiscovered, isTrue);
      await deps.skillRegistry.setSkillEnabled(discoveredSkill.id, true);
      expect(
        deps.skillRegistry.buildActiveSkillsSystemContext(),
        contains('concise-coder'),
      );

      // Verify built-in Dart & Flutter MCP + .agents/mcp.json auto-discovery.
      expect(
        deps.mcpManager.state.servers.any(
          (McpServerRuntimeState s) =>
              s.config.id == McpManager.builtInDartFlutterServerId,
        ),
        isTrue,
      );
      final projectMcpServer = deps.mcpManager.state.servers.firstWhere(
        (McpServerRuntimeState s) => s.config.name == 'e2e-project-mcp',
      );
      expect(projectMcpServer.config.isProjectScoped, isTrue);
      final mcpRuntime = await deps.mcpManager.connectServer(
        projectMcpServer.config.id,
      );
      expect(mcpRuntime.isConnected, isTrue);
      expect(
        mcpRuntime.tools.map((McpToolDescriptor t) => t.name),
        contains('project_badge'),
      );
      final mcpCallRes = await deps.mcpManager.callTool(
        serverId: projectMcpServer.config.id,
        toolName: 'project_badge',
        arguments: const <String, Object?>{'label': 'verified'},
      );
      expect(mcpCallRes['text'], 'BADGE:VERIFIED');
      final mcpResourceText = await deps.mcpManager.readResource(
        serverId: projectMcpServer.config.id,
        uri: 'studio://e2e/manifest',
      );
      expect(mcpResourceText, contains('E2E MCP resource OK'));

      // Render Coding workspace UI & run real local model coding turn.
      deps.shellController.selectWorkspace(StudioWorkspace.coding);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('Qwen3.6 27B'), findsAtLeastNWidgets(1));
      expect(
        find.byKey(const Key('coding_active_tools_strip')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      await deps.shellController.updateSettings(
        (StudioSettings s) => s.copyWith(
          thinkingEnabled: false,
          toolsEnabled: true,
          maxTokens: 96,
          temperature: 0.0,
        ),
      );
      await deps.codingController.sendCodingPrompt(
        'Briefly describe what multiplyInts in lib/math_utils.dart does.',
      );
      await tester.pump(const Duration(milliseconds: 250));
      expect(deps.codingController.state.lastError, isNull);
      expect(deps.codingController.state.messages.length, 2);
      expect(deps.codingController.state.messages.last.text.trim(), isNotEmpty);

      await deps.mcpManager.disconnectServer(projectMcpServer.config.id);
      await deps.modelHubController.unloadActiveModel();

      // -----------------------------------------------------------------------
      // 8. Real LiteRT-LM Native Runtime Verification (.litertlm)
      // -----------------------------------------------------------------------
      debugPrint('[E2E] Phase 8: LiteRT-LM');
      final liteRtModel = deps.modelHubController.state.localModels
          .where(
            (StudioModelDescriptor m) =>
                m.filename.toLowerCase() == 'qwen3-0.6b.litertlm',
          )
          .firstOrNull;
      expect(
        liteRtModel,
        isNotNull,
        reason: 'Expected Qwen3-0.6B.litertlm to be discovered in local cache.',
      );

      await deps.modelHubController.activateChatModel(liteRtModel!);
      await deps.shellController.updateSettings(
        (StudioSettings s) => s.copyWith(
          thinkingEnabled: false,
          toolsEnabled: false,
          maxTokens: 32,
          temperature: 0.0,
        ),
      );
      expect(deps.modelHubController.runtimeStore.state.isReady, isTrue);

      await deps.chatController.createConversation();
      await deps.chatController.sendMessage('Reply with one greeting word.');
      expect(deps.chatController.state.lastTurnError, isNull);
      final liteRtReply =
          deps.chatController.state.activeConversation!.activeBranch.last;
      expect(liteRtReply.text.trim(), isNotEmpty);
      expect(tester.takeException(), isNull);

      // Clean native multi-engine teardown before exiting test.
      debugPrint('[E2E] Disposing deps');
      await deps.dispose();
      disposed = true;
      debugPrint('[E2E] Complete');
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}

class _NoOpInferencePort implements StudioInferencePort {
  final StateStore<StudioRuntimeSnapshot> _runtime =
      StateStore<StudioRuntimeSnapshot>(
        const StudioRuntimeSnapshot(phase: StudioEnginePhase.ready),
      );

  @override
  ReadOnlyStore<StudioRuntimeSnapshot> get runtimeStore => _runtime;

  @override
  Future<void> refreshHardwareDiagnostics() async {}

  @override
  Future<void> loadModel({
    required ResolvedModelAssets assets,
    required StudioSettings settings,
    required bool isWeb,
  }) async {}

  @override
  Future<void> loadCustomSource({
    required StudioModelDescriptor descriptor,
    required StudioSettings settings,
    required bool isWeb,
  }) async {}

  @override
  Future<void> unloadModel() async {}

  @override
  Stream<StudioTurnEvent> streamTurn(StudioTurnRequest request) async* {
    yield const StudioTextDeltaEvent('Persisted echo.');
    yield const StudioTurnCompletedEvent(
      StudioTurnResult(
        text: 'Persisted echo.',
        metrics: StudioTurnMetrics(
          generatedTokens: 3,
          elapsedMs: 12,
          decodeElapsedMs: 10,
        ),
      ),
    );
  }

  @override
  void cancelGeneration() {}

  @override
  Future<void> dispose() => _runtime.dispose();
}
