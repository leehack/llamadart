import 'dart:convert';

import 'package:flutter/foundation.dart';
// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio/llamadart_studio.dart';
import 'package:llamadart_studio/src/app/platform_file_helper.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

import 'studio_widget_test_helpers.dart';
import 'test_io_helper.dart';

void main() {
  testWidgets(
    'Model Hub, Speech Studio, and Image Studio workspaces render and run actions cleanly',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1360, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final deps = await buildTestDeps();
      addTearDown(deps.dispose);

      await tester.pumpWidget(LlamadartStudioApp(dependencies: deps));
      await tester.pumpAndSettle();

      // Navigate to Model Hub.
      await tester.tap(find.byKey(const Key('nav_workspace_models')));
      await tester.pumpAndSettle();
      expect(find.text('Model Hub & Cache Manager'), findsOneWidget);
      expect(find.text('Qwen3.5 0.8B Instruct'), findsOneWidget);

      // Navigate to Speech Studio.
      await tester.tap(find.byKey(const Key('nav_workspace_speech')));
      await tester.pumpAndSettle();
      expect(find.text('Speech Studio'), findsOneWidget);
      expect(find.text('Synthesize WAV'), findsOneWidget);

      // Navigate to Image Studio and generate a deterministic test image.
      await tester.tap(find.byKey(const Key('nav_workspace_image')));
      await tester.pumpAndSettle();
      expect(find.text('Image Studio'), findsOneWidget);

      await tester.tap(find.byKey(const Key('load_image_pipeline_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('generate_image_button')));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Save PNG'), findsOneWidget);
    },
  );

  testWidgets(
    'Playground filters model chips per tab, shows live download progress + Cancel, and never mislabels downloads as Scoring...',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 860));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final storage = ControllableDownloadStoragePort();
      final kv = InMemoryKeyValueStore();
      final deps = await StudioDependencies.fromPorts(
        keyValueStore: kv,
        conversationStore: KeyValueConversationStore(kv),
        storagePort: storage,
        inferencePort: FakeInferencePort(),
        speechPort: FakeSpeechPort(),
        imagePort: FakeImagePort(),
        playgroundPort: FakePlaygroundPort(),
      );
      addTearDown(deps.dispose);

      await tester.pumpWidget(LlamadartStudioApp(dependencies: deps));
      await tester.pumpAndSettle();

      deps.shellController.selectWorkspace(StudioWorkspace.playground);
      deps.playgroundController.selectTab(PlaygroundToolTab.reranker);
      await tester.pumpAndSettle();

      // On the Reranker tab, only reranker chips appear — embedding & decision
      // chips are filtered out.
      expect(
        find.byKey(const Key('load_lab_model_bge-reranker-v2-m3-q8-0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('load_lab_model_nomic-embed-text-v1.5-q8-0')),
        findsNothing,
      );

      // Tap BGE Reranker v2 M3 to start downloading.
      await tester.tap(
        find.byKey(const Key('load_lab_model_bge-reranker-v2-m3-q8-0')),
      );
      await tester.pump();

      storage.emitProgress(
        const StudioModelDownloadProgress(
          modelId: 'bge-reranker-v2-m3-q8-0',
          stage: ModelDownloadTaskStage.downloading,
          receivedBytes: 254 * 1024 * 1024,
          totalBytes: 606 * 1024 * 1024,
          fraction: 0.42,
          statusLabel: 'Fetching from Hugging Face',
        ),
      );
      await tester.pump();

      // Live progress banner shows model name, percentage, MB, and Cancel —
      // while the action button still says "Rerank Candidates" (NOT "Scoring...").
      expect(
        find.byKey(const Key('model_load_banner_bge-reranker-v2-m3-q8-0')),
        findsOneWidget,
      );
      expect(
        find.textContaining('Downloading BGE Reranker v2 M3'),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(PlaygroundWorkspaceView),
          matching: find.text('42%'),
        ),
        findsOneWidget,
      );
      expect(find.text('Rerank Candidates'), findsOneWidget);
      expect(find.text('Scoring...'), findsNothing);

      // Clicking Cancel invokes storage.cancelDownload.
      await tester.tap(
        find.byKey(const Key('cancel_model_download_bge-reranker-v2-m3-q8-0')),
      );
      await tester.pumpAndSettle();
      expect(storage.cancelledModelIds, contains('bge-reranker-v2-m3-q8-0'));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Session Inspector shows speculative decoding guidance and temp WAV helper preserves .wav extension',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 920));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      const pathProviderChannel = MethodChannel(
        'plugins.flutter.io/path_provider',
      );
      String? tempDirPath;
      if (!kIsWeb) {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          pathProviderChannel,
          (MethodCall call) async {
            if (call.method == 'getTemporaryDirectory') {
              return '$tempDirPath/nested_cache_dir';
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            pathProviderChannel,
            null,
          ),
        );
      }

      await tester.runAsync(() async {
        final wavBytes = Uint8List.fromList(<int>[82, 73, 70, 70, 1, 2, 3, 4]);
        if (kIsWeb) {
          final wavPath = await StudioPlatformFileHelper.writeTempWavFile(
            wavBytes,
            clipId: 'clip:1/test',
          );
          expect(wavPath, isNull);
          return;
        }
        tempDirPath = await createTempDir('studio_wav_test_');
        try {
          final wavPath = await StudioPlatformFileHelper.writeTempWavFile(
            wavBytes,
            clipId: 'clip:1/test',
          );
          expect(wavPath, isNotNull);
          expect(wavPath!, endsWith('.wav'));
          expect(readBytesSync(wavPath), wavBytes);
          await StudioPlatformFileHelper.deleteFileIfExists(wavPath);
          expect(fileExistsSync(wavPath), isFalse);
        } finally {
          await deleteDirIfExists(tempDirPath);
        }
      });

      final deps = await buildTestDeps();
      addTearDown(deps.dispose);

      await tester.pumpWidget(LlamadartStudioApp(dependencies: deps));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('inspector_mode_expert')));
      await tester.pumpAndSettle();

      const guidance =
          'Applies on compatible text-only turns. MTP requires model support and Apply & Reload.';
      await tester.scrollUntilVisible(
        find.text(guidance),
        200,
        scrollable: find.descendant(
          of: find.byKey(const Key('inspector_hardware_list')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text(guidance), findsOneWidget);
    },
  );

  testWidgets(
    'Multimodal Notebook creates notes, indexes embeddings, searches semantically, streams RAG Ask Notebook answers, and sends hits to Chat',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1360, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final deps = await buildTestDeps();
      addTearDown(deps.dispose);

      await tester.pumpWidget(LlamadartStudioApp(dependencies: deps));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('nav_workspace_notes')));
      await tester.pumpAndSettle();
      expect(deps.shellController.state.activeWorkspace, StudioWorkspace.notes);
      expect(
        find.byKey(const Key('notebook_record_audio_button')),
        findsOneWidget,
      );

      // Create a new note and save custom content.
      await tester.tap(find.byKey(const Key('vault_new_note_button')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('vault_note_title_input')),
        'KV Cache Memory Tuning',
      );
      await tester.enterText(
        find.byKey(const Key('vault_note_tags_input')),
        'memory, metal',
      );
      await tester.enterText(
        find.byKey(const Key('vault_note_content_input')),
        'Enable Q8_0 KV cache quantization with FlashAttention to cut context memory usage in half.',
      );
      await tester.ensureVisible(
        find.byKey(const Key('vault_save_note_button')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('vault_save_note_button')));
      await tester.pumpAndSettle();

      // Index all notes and run semantic search with Stage-2 reranking.
      await tester.scrollUntilVisible(
        find.byKey(const Key('notebook_ask_section')),
        200,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('notebook_workspace_scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(find.text('Ask notebook'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Search settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Search settings'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('vault_index_notes_button')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('vault_index_notes_button')));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byKey(const Key('vault_rerank_switch')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('vault_rerank_switch')));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byKey(const Key('vault_search_input')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('vault_search_input')),
        'How do I reduce KV cache memory?',
      );
      await tester.ensureVisible(find.byKey(const Key('vault_search_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('vault_search_button')));
      await tester.pumpAndSettle();

      expect(deps.notebookController.state.noteSearchHits, isNotEmpty);

      // Ask Notebook inline RAG Q&A and check grounded answer card + citations.
      await tester.ensureVisible(find.byKey(const Key('notebook_ask_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('notebook_ask_button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('notebook_answer_card')), findsOneWidget);
      expect(
        deps.notebookController.state.notebookAnswerText,
        contains('Reply to:'),
      );

      // Send hits to Chat (RAG) and verify Chat composer receives the context.
      expect(
        find.byKey(const Key('vault_send_to_chat_button')),
        findsOneWidget,
      );
      await tester.ensureVisible(
        find.byKey(const Key('vault_send_to_chat_button')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('vault_send_to_chat_button')));
      await tester.pumpAndSettle();

      expect(deps.shellController.state.activeWorkspace, StudioWorkspace.chat);
      expect(
        deps.chatController.state.composerDraft,
        contains('KV Cache Memory Tuning'),
      );
    },
  );

  testWidgets(
    'Decision Head runs triageRouter, batch vaultAudit, and System-1 Speed Burst + LLM comparison',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1360, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final deps = await buildTestDeps();
      addTearDown(deps.dispose);

      await tester.pumpWidget(LlamadartStudioApp(dependencies: deps));
      await tester.pumpAndSettle();

      deps.shellController.selectWorkspace(StudioWorkspace.playground);
      deps.playgroundController.selectTab(PlaygroundToolTab.decision);
      await tester.pumpAndSettle();

      // 1. Run Task & Model Router (triageRouter).
      await tester.ensureVisible(
        find.byKey(const Key('decision_triage_input')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('decision_triage_input')),
        'Refactor CodingWorkspaceController and add MCP server resource tests',
      );
      await tester.ensureVisible(
        find.byKey(const Key('decision_run_triage_button')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('decision_run_triage_button')));
      await tester.pumpAndSettle();

      expect(
        deps.playgroundController.state.decisionBatchEvaluation,
        isNotNull,
      );
      expect(
        deps.playgroundController.state.decisionBatchEvaluation!.answers.length,
        5,
      );

      // 2. Run Speed Burst Benchmark & Head-to-Head Chat LLM Comparison.
      await tester.ensureVisible(
        find.byKey(const Key('decision_speed_burst_panel')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('decision_compare_llm_switch')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('decision_run_speed_burst_button')),
      );
      await tester.pumpAndSettle();

      expect(deps.playgroundController.state.decisionBenchmark, isNotNull);
      expect(find.byKey(const Key('decision_speedup_badge')), findsOneWidget);
      expect(find.textContaining('decisions/s'), findsAtLeastNWidgets(1));

      // 3. Switch to Batch Note Audit (vaultAudit) and run audit across Vault notes.
      await tester.ensureVisible(
        find.byKey(const Key('decision_mode_vault_audit')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('decision_mode_vault_audit')));
      await tester.pumpAndSettle();

      await tester.ensureVisible(
        find.byKey(const Key('decision_run_audit_button')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('decision_run_audit_button')));
      await tester.pumpAndSettle();

      expect(deps.playgroundController.state.noteAuditResults, isNotEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Coding Workspace activates clicked coding model, shows pi.dev tools + SyntaxCodeView + AGENTS.md & SKILL.md modal',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1560, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final repoPath = await tester.runAsync(
        () => createTempDir('studio_widget_coding_'),
      );
      addTearDown(() async {
        await tester.runAsync(() => deleteDirIfExists(repoPath));
      });
      if (repoPath != null) {
        await tester.runAsync(() async {
          await writeTextFile(
            '$repoPath/AGENTS.md',
            '# Studio Repo Rules\nUse explicit pi.dev tools.',
          );
          await writeTextFile(
            '$repoPath/lib/main.dart',
            'void main() {\n  print("hello syntax");\n}\n',
          );
        });
      }

      final deps = await buildTestDeps();
      addTearDown(deps.dispose);

      await tester.pumpWidget(LlamadartStudioApp(dependencies: deps));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('nav_workspace_coding')));
      await tester.pumpAndSettle();

      expect(find.text('Coding Agent'), findsOneWidget);
      await tester.tap(find.byKey(const Key('coding_setup_toggle')));
      await tester.pumpAndSettle();
      final qwen27Chip = find.byKey(
        const Key('coding_model_chip_qwen3.6-27b-ud-q4-k-xl'),
      );
      expect(qwen27Chip, findsOneWidget);

      // Clicking a coding model chip activates it cleanly.
      await tester.tap(qwen27Chip);
      await tester.pumpAndSettle();
      expect(
        deps.modelHubController.runtimeStore.state.activeDescriptor?.id,
        'qwen3.6-27b-ud-q4-k-xl',
      );

      expect(
        find.byKey(const Key('coding_active_tools_strip')),
        findsOneWidget,
      );

      // Point Coding workspace at our temp repo (when dart:io is available) &
      // open a Dart file to verify Active Tools Strip + SyntaxCodeView + AGENTS.md.
      if (repoPath != null) {
        await tester.runAsync(() async {
          await deps.codingController.setWorkspaceRoot(repoPath);
          await deps.codingController.openFile('lib/main.dart');
        });
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: find.byKey(const Key('coding_active_tools_strip')),
            matching: find.text('read'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(const Key('coding_active_tools_strip')),
            matching: find.text('edit'),
          ),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const Key('coding_explorer_toggle')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('coding_file_syntax_preview')),
          findsOneWidget,
        );
      } else {
        expect(
          find.descendant(
            of: find.byKey(const Key('coding_active_tools_strip')),
            matching: find.text(
              'Select folder for read · write · edit · grep · ls',
            ),
          ),
          findsOneWidget,
        );
      }

      // Open manual folder path dialog and verify cancel path works cleanly.
      await tester.tap(find.byKey(const Key('coding_manual_path_button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('coding_manual_path_field')), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      // Open MCP & Skills modal, check AGENTS.md tab, switch to Agent Skills,
      // and create a SKILL.md skill.
      await tester.tap(find.byKey(const Key('coding_open_skills_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('AGENTS.md').last);
      await tester.pumpAndSettle();
      if (repoPath != null) {
        expect(
          find.textContaining('Use explicit pi.dev tools.'),
          findsOneWidget,
        );
      }

      await tester.tap(find.textContaining('Agent Skills (').last);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('skills_toggle_create_button')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('skill_markdown_input')),
        '---\nname: dart-review\ndescription: Strict Dart & Flutter code review workflow.\n---\n\nAlways run dart analyze before reporting success.',
      );
      await tester.tap(find.byKey(const Key('skill_save_markdown_button')));
      await tester.pumpAndSettle();

      expect(
        deps.skillRegistry.state.skills.any(
          (StudioSkill s) => s.name == 'dart-review',
        ),
        isTrue,
      );
      Navigator.of(tester.element(find.byType(Dialog).first)).pop();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'SessionInspectorPanel exposes batch sizes, threads, mmap/mlock, advanced params, presencePenalty, and MCP per-tool FilterChips',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final deps = await buildTestDeps();
      addTearDown(deps.dispose);

      // Seed a saved MCP server with tools disabled/enabled so MCP sheet renders chips.
      await deps.mcpManager.saveServer(
        const McpServerConfig(
          id: 'test_mcp_server',
          name: 'Test MCP Server',
          transportType: McpTransportType.stdio,
          command: 'dart',
          args: <String>['mcp-server'],
        ),
      );

      await tester.pumpWidget(LlamadartStudioApp(dependencies: deps));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('inspector_mode_expert')));
      await tester.pumpAndSettle();

      final hardwareScrollable = find.descendant(
        of: find.byKey(const Key('inspector_hardware_list')),
        matching: find.byType(Scrollable),
      );

      // Hardware tab: tap batchSize=2048 and microBatchSize=512 chips.
      final batchChip = find.byKey(const Key('inspector_batch_size_2048'));
      await tester.scrollUntilVisible(
        batchChip,
        200,
        scrollable: hardwareScrollable,
      );
      await tester.pumpAndSettle();
      await tester.tap(batchChip);
      await tester.pumpAndSettle();
      expect(deps.shellController.state.settings.batchSize, 2048);

      final ubatchChip = find.byKey(
        const Key('inspector_micro_batch_size_512'),
      );
      await tester.ensureVisible(ubatchChip);
      await tester.pumpAndSettle();
      await tester.tap(ubatchChip);
      await tester.pumpAndSettle();
      expect(deps.shellController.state.settings.microBatchSize, 512);

      // Expand Advanced Engine Parameters and verify RoPE inputs.
      final advTile = find.byKey(const Key('inspector_advanced_engine_tile'));
      await tester.scrollUntilVisible(
        advTile,
        200,
        scrollable: hardwareScrollable,
      );
      await tester.pumpAndSettle();
      await tester.tap(advTile);
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('inspector_rope_freq_base')),
        '1000000',
      );
      await tester.pumpAndSettle();
      expect(deps.shellController.state.settings.ropeFrequencyBase, 1000000.0);

      // Sampling tab: verify Presence Penalty control exists.
      await tester.tap(find.text('Sampling').last);
      await tester.pumpAndSettle();
      expect(find.text('Presence Penalty'), findsOneWidget);

      // Verify MCP per-tool toggle works via McpManager & MCP sheet opens cleanly.
      await deps.mcpManager.setToolEnabled(
        'test_mcp_server',
        'analyze_files',
        false,
      );
      final updatedServer = deps.mcpManager.state.servers.firstWhere(
        (McpServerRuntimeState s) => s.config.id == 'test_mcp_server',
      );
      expect(updatedServer.config.isToolEnabled('analyze_files'), isFalse);

      await tester.tap(find.text('Tools').last);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('inspector_open_mcp_skills_button')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Test MCP Server'), findsOneWidget);
      Navigator.of(tester.element(find.byType(Dialog).first)).pop();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Production UX: Untrusted workspace MCP security gate, Notebook auto-save status badge, and StudioErrorFallbackCard',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final repoPath = await tester.runAsync(
        () => createTempDir('studio_mcp_trust_ui_'),
      );
      addTearDown(() async {
        await tester.runAsync(() => deleteDirIfExists(repoPath));
      });

      final deps = await buildTestDeps();
      addTearDown(deps.dispose);

      if (!kIsWeb && repoPath != null) {
        await tester.runAsync(() async {
          await writeTextFile(
            '$repoPath/.mcp.json',
            jsonEncode(<String, Object>{
              'mcpServers': <String, Object>{
                'untrusted_repo_mcp': <String, Object>{
                  'url': 'http://127.0.0.1:1/mcp',
                },
              },
            }),
          );
          await deps.codingController.setWorkspaceRoot(repoPath);
        });
      }

      await tester.pumpWidget(LlamadartStudioApp(dependencies: deps));
      await tester.pumpAndSettle();

      if (!kIsWeb && repoPath != null) {
        deps.shellController.selectWorkspace(StudioWorkspace.coding);
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('coding_untrusted_mcp_banner')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const Key('trust_workspace_mcp_button')));
        await tester.pumpAndSettle();
        expect(deps.mcpManager.isWorkspaceTrusted(repoPath), isTrue);
        expect(
          find.byKey(const Key('coding_untrusted_mcp_banner')),
          findsNothing,
        );
      }

      // Notebook auto-saves edited content after 600ms debounce without manual Save tap.
      deps.shellController.selectWorkspace(StudioWorkspace.notes);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('vault_new_note_button')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('notebook_save_status_badge')),
        findsOneWidget,
      );

      await tester.enterText(
        find.byKey(const Key('vault_note_title_input')),
        'Auto-saved Architecture Note',
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Auto-saving…'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();
      expect(
        deps.notebookController.state.notes.any(
          (StudioNote n) => n.title == 'Auto-saved Architecture Note',
        ),
        isTrue,
      );
      expect(find.text('Saved'), findsOneWidget);

      // Verify StudioErrorFallbackCard renders humanized message without gray crash box.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StudioErrorFallbackCard(
              details: FlutterErrorDetails(
                exception: StateError('Synthetic widget failure'),
              ),
            ),
          ),
        ),
      );
      expect(
        find.byKey(const Key('studio_error_fallback_card')),
        findsOneWidget,
      );
      expect(find.text('Component Render Error'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'UX #5 & #6: Coding diff revert + bash approval banner and Playground wide split + narrow Decision auto-collapse',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final repoPath = await tester.runAsync(
        () => createTempDir('studio_ux5_coding_'),
      );
      addTearDown(() async {
        await tester.runAsync(() => deleteDirIfExists(repoPath));
      });
      if (!kIsWeb && repoPath != null) {
        await tester.runAsync(() async {
          await writeTextFile('$repoPath/lib/demo.dart', 'final int x = 1;\n');
        });
      }

      final deps = await buildTestDeps();
      addTearDown(deps.dispose);

      if (!kIsWeb && repoPath != null) {
        await tester.runAsync(() async {
          await deps.codingController.setWorkspaceRoot(repoPath);
          final tools = <String, ToolDefinition>{
            for (final t in deps.codingController.buildCodingTools()) t.name: t,
          };
          await tools['edit']!.invoke(<String, dynamic>{
            'path': 'lib/demo.dart',
            'findText': 'x = 1',
            'replaceText': 'x = 42',
          });
        });
      }

      await tester.pumpWidget(LlamadartStudioApp(dependencies: deps));
      await tester.pumpAndSettle();

      // Coding Workspace UX #5: diff viewer, 1-click Revert, and bash approval gate.
      await tester.tap(find.byKey(const Key('nav_workspace_coding')));
      await tester.pumpAndSettle();

      if (!kIsWeb && repoPath != null) {
        expect(deps.codingController.state.recentChanges, hasLength(1));
        await tester.tap(find.text('Edits (1)'));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('coding_revert_change_0')), findsOneWidget);
        await tester.ensureVisible(
          find.byKey(const Key('coding_revert_change_0')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('coding_revert_change_0')));
        for (
          var i = 0;
          i < 50 && !deps.codingController.state.recentChanges.first.reverted;
          i++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
          await tester.pump();
        }
        await tester.pumpAndSettle();
        expect(
          deps.codingController.state.recentChanges.first.reverted,
          isTrue,
        );

        await tester.tap(find.text('Agent'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('coding_setup_toggle')));
        await tester.pumpAndSettle();
        // Enable `bash` tool -> Ask before bash toggle appears; pending bash shows approval banner.
        deps.codingController.setAllowShellCommandTool(true);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('coding_confirm_bash_toggle')),
          findsOneWidget,
        );

        final bashTool = deps.codingController.buildCodingTools().firstWhere(
          (ToolDefinition t) => t.name == 'bash',
        );
        late Future<Object?> pendingBash;
        await tester.runAsync(() async {
          pendingBash = bashTool.invoke(<String, dynamic>{
            'command': 'echo approved_from_banner',
          });
        });
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('coding_command_approval_banner')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const Key('coding_approve_bash_button')));
        await tester.pumpAndSettle();
        final bashResult =
            await tester.runAsync(() => pendingBash) as Map<String, Object?>;
        expect(bashResult['exitCode'], 0);
      }

      // Playground UX #6: wide desktop shows side-by-side empty output placeholder;
      // narrow viewport auto-collapses Decision inputs with Edit Inputs summary bar.
      await tester.tap(find.byKey(const Key('nav_workspace_playground')));
      await tester.pumpAndSettle();
      expect(find.text('Cosine Similarity Heatmap'), findsOneWidget);

      await tester.binding.setSurfaceSize(const Size(640, 800));
      await tester.pumpAndSettle();
      deps.playgroundController.selectTab(PlaygroundToolTab.decision);
      await tester.pumpAndSettle();

      await tester.ensureVisible(
        find.byKey(const Key('decision_run_triage_button')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('decision_run_triage_button')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('decision_collapsed_inputs_bar')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('decision_edit_inputs_button')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('decision_edit_inputs_button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('decision_triage_input')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
