import 'package:flutter/foundation.dart';
// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_studio/llamadart_studio.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

import 'studio_widget_test_helpers.dart';

void main() {
  testWidgets(
    'Zero RenderFlex overflows across all workspaces, inspector tabs, and modals from 320px to 1120px',
    (WidgetTester tester) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final deps = await buildTestDeps();
      addTearDown(deps.dispose);

      // Populate rich active state across every workspace controller first.
      deps.chatController.addPendingAttachment(
        const StudioAttachment(
          id: 'long_att_1',
          kind: StudioAttachmentKind.image,
          name: 'Screenshot_2026_11_13_very_long_multimodal_attachment_filename_preview.png',
          sizeBytes: 2048,
        ),
      );
      await deps.chatController.sendMessage('First turn with long telemetry');
      final firstUser =
          deps.chatController.state.activeConversation!.activeBranch.first;
      await deps.chatController.editUserMessageAndBranch(
        originalMessageId: firstUser.id,
        editedText: 'Second branched turn for paginator test',
      );
      deps.chatController.addPendingAttachment(
        const StudioAttachment(
          id: 'long_att_2',
          kind: StudioAttachmentKind.audio,
          name: 'recorded_voice_reference_clip_with_extremely_long_filename_24khz.wav',
          sizeBytes: 4096,
        ),
      );

      final ttsModel = deps.speechController.availableTtsModels.first;
      final sttModel = deps.speechController.availableSttModels.first;
      await deps.speechController.loadTtsModel(ttsModel);
      await deps.speechController.synthesizeText(
        text: 'Testing synthesized clip list tile layout under tight widths.',
      );
      await deps.speechController.loadSttModel(sttModel);
      await deps.speechController.transcribeAudio(audioBytes: Uint8List(32));

      final imgModel = deps.imageController.availableModels.first;
      await deps.imageController.loadModel(imgModel);
      await deps.imageController.generate(
        prompt: 'Minimal desk lamp studio render with dramatic shadows',
      );

      await deps.notebookController.indexNotes();
      await deps.notebookController.searchNotes('KV cache memory');
      await deps.playgroundController.runEmbeddings(const <String>[
        'Passage alpha',
        'Passage beta',
        'Passage gamma',
      ]);
      await deps.playgroundController.runReranker(
        query: 'KV cache quantization',
        documents: const <String>[
          'Use Q8_0 KV cache quantization with FlashAttention enabled.',
          'Unrelated baking recipe document.',
        ],
      );
      await deps.playgroundController.runTriageRouterWorkflow(
        'Refactor coding workspace controller and run tests',
      );
      await deps.playgroundController.runDecisionHead(
        stateText: 'VRAM free 12 GB',
        yesNoQuestion: 'Fits in VRAM?',
      );
      await deps.playgroundController.runTokenInspection(
        'llamadart Studio responsive layout verification!',
      );
      await deps.playgroundController.runBenchmark(targetDecodeTokens: 64);

      const viewports = <Size>[
        Size(320, 568), // Tightest portrait phone (iPhone SE)
        Size(360, 640), // Compact phone
        Size(420, 600), // macOS minSize window
        Size(844, 390), // Phone landscape (short height + tablet rail)
        Size(720, 480), // Short tablet rail
        Size(1020, 760), // Tight 2-column Speech & ModelHub grid
        Size(1120, 720), // Tightest 3-pane desktop (272 + 514 + 334)
      ];

      await tester.pumpWidget(LlamadartStudioApp(dependencies: deps));
      await tester.pumpAndSettle();

      for (final size in viewports) {
        await tester.binding.setSurfaceSize(size);
        await tester.pumpAndSettle();

        // Cycle every workspace.
        for (final ws in StudioWorkspace.values) {
          deps.shellController.selectWorkspace(ws);
          await tester.pumpAndSettle();

          if (ws == StudioWorkspace.playground) {
            for (final tab in PlaygroundToolTab.values) {
              deps.playgroundController.selectTab(tab);
              await tester.pumpAndSettle();

              if (tab == PlaygroundToolTab.embeddings) {
                await tester.scrollUntilVisible(
                  find.byKey(const Key('playground_open_notebook_button')),
                  200,
                  scrollable: find
                      .descendant(
                        of: find.byType(PlaygroundWorkspaceView),
                        matching: find.byType(Scrollable),
                      )
                      .first,
                );
                await tester.pumpAndSettle();
              } else if (tab == PlaygroundToolTab.decision) {
                for (final mode in DecisionWorkflowMode.values) {
                  deps.playgroundController.selectDecisionMode(mode);
                  await tester.pumpAndSettle();
                }
              }
            }
          }
        }

        // Open MCP & Skills modal from Coding workspace at this viewport size.
        deps.shellController.selectWorkspace(StudioWorkspace.coding);
        await tester.pumpAndSettle();
        if (find
            .byKey(const Key('coding_open_mcp_button'))
            .evaluate()
            .isEmpty) {
          await tester.tap(find.byKey(const Key('coding_setup_toggle')));
          await tester.pumpAndSettle();
        }
        await tester.ensureVisible(
          find.byKey(const Key('coding_open_mcp_button')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('coding_open_mcp_button')));
        await tester.pumpAndSettle();
        final skillsTab = find.textContaining('Agent Skills (').last;
        await tester.ensureVisible(skillsTab);
        await tester.pumpAndSettle();
        await tester.tap(skillsTab);
        await tester.pumpAndSettle();
        final agentsTab = find.textContaining('AGENTS.md').last;
        await tester.ensureVisible(agentsTab);
        await tester.pumpAndSettle();
        await tester.tap(agentsTab);
        await tester.pumpAndSettle();
        Navigator.of(tester.element(find.byType(Dialog).first)).pop();
        await tester.pumpAndSettle();

        // Verify Session Inspector (persistent on >=1120, endDrawer below 1120).
        if (size.width < 1120) {
          await tester.tap(find.byKey(const Key('toggle_inspector_button')));
          await tester.pumpAndSettle();
        }
        for (final tabLabel in const <String>[
          'Hardware',
          'Prompt',
          'Sampling',
          'Tools',
        ]) {
          await tester.tap(find.text(tabLabel).last);
          await tester.pumpAndSettle();
        }
        if (size.width < 1120) {
          Navigator.of(tester.element(find.byType(Scaffold).first)).pop();
          await tester.pumpAndSettle();
        }

        // Verify Command Palette modal at this viewport size.
        await tester.tap(find.byKey(const Key('open_command_palette_button')));
        await tester.pumpAndSettle();
        Navigator.of(tester.element(find.byType(Dialog).first)).pop();
        await tester.pumpAndSettle();

        // Verify Model Hub Custom Path dialog & Cache Sheet at narrowest/widest.
        deps.shellController.selectWorkspace(StudioWorkspace.models);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('open_custom_model_button')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('open_cache_sheet_button')));
        await tester.pumpAndSettle();
        Navigator.of(tester.element(find.byType(Scaffold).first)).pop();
        await tester.pumpAndSettle();
      }
    },
  );

  testWidgets(
    'Web mode adapts Coding, Model Hub, Notebook, and Chat cleanly with zero errors',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final kv = InMemoryKeyValueStore();
      final deps = await StudioDependencies.fromPorts(
        keyValueStore: kv,
        conversationStore: KeyValueConversationStore(kv),
        storagePort: FakeStoragePort(),
        inferencePort: FakeInferencePort(),
        speechPort: FakeSpeechPort(),
        imagePort: FakeImagePort(),
        playgroundPort: FakePlaygroundPort(),
        isWeb: true,
        autoDetectCodingWorkspace: false,
        autoConnectDefaultMcp: false,
      );
      addTearDown(deps.dispose);

      await tester.pumpWidget(LlamadartStudioApp(dependencies: deps));
      await tester.pumpAndSettle();

      // Web Chat streaming turn works cleanly.
      await tester.enterText(
        find.byKey(const Key('chat_composer_input')),
        'Hello WebGPU!',
      );
      await tester.tap(find.byKey(const Key('chat_send_button')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(ChatWorkspaceView),
          matching: find.text('Reply to: Hello WebGPU!'),
        ),
        findsOneWidget,
      );

      // Web Model Hub adapts storage cards for browser cache without local folder scanner.
      await tester.tap(find.byKey(const Key('nav_workspace_models')));
      await tester.pumpAndSettle();
      expect(find.text('Model Hub & Cache Manager'), findsOneWidget);
      expect(find.text('Add Folder'), findsNothing);

      // Web Coding hides manual filesystem path input while keeping active tools & skills UI.
      await tester.tap(find.byKey(const Key('nav_workspace_coding')));
      await tester.pumpAndSettle();
      expect(find.text('Coding Agent'), findsOneWidget);
      await tester.tap(find.byKey(const Key('coding_setup_toggle')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('coding_manual_path_button')), findsNothing);
      expect(
        find.byKey(const Key('coding_active_tools_strip')),
        findsOneWidget,
      );

      // Web Notebook renders cleanly.
      await tester.tap(find.byKey(const Key('nav_workspace_notes')));
      await tester.pumpAndSettle();
      expect(deps.shellController.state.activeWorkspace, StudioWorkspace.notes);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Mobile mode (isMobile: true) wraps composer pills cleanly, navigates via bottom NavigationBar & Drawer, and adapts Model Hub',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final kv = InMemoryKeyValueStore();
      final deps = await StudioDependencies.fromPorts(
        keyValueStore: kv,
        conversationStore: KeyValueConversationStore(kv),
        storagePort: FakeStoragePort(),
        inferencePort: FakeInferencePort(),
        speechPort: FakeSpeechPort(),
        imagePort: FakeImagePort(),
        playgroundPort: FakePlaygroundPort(),
        isMobile: true,
        autoDetectCodingWorkspace: false,
        autoConnectDefaultMcp: false,
      );
      addTearDown(deps.dispose);

      await tester.pumpWidget(LlamadartStudioApp(dependencies: deps));
      await tester.pumpAndSettle();

      // Compact mobile shows bottom NavigationBar and unclipped Think + Tools + Send.
      expect(find.byType(NavigationBar), findsOneWidget);
      final toolsPillBox = tester.getRect(find.text('Tools').last);
      final sendButtonBox = tester.getRect(
        find.byKey(const Key('chat_send_button')),
      );
      expect(toolsPillBox.right, lessThanOrEqualTo(390));
      expect(sendButtonBox.right, lessThanOrEqualTo(390));
      // Wrapped pills sit cleanly above the Send row without colliding horizontally.
      expect(toolsPillBox.bottom, lessThanOrEqualTo(sendButtonBox.top));

      // Open and close left Sessions & Workspaces Drawer cleanly.
      await tester.tap(find.byKey(const Key('open_sidebar_drawer_button')));
      await tester.pumpAndSettle();
      expect(find.text('SESSIONS'), findsOneWidget);
      await tester.tap(find.byKey(const Key('nav_workspace_models')));
      await tester.pumpAndSettle();
      expect(find.text('Model Hub & Cache Manager'), findsOneWidget);
      expect(find.text('Add Folder'), findsNothing);

      // Navigate via bottom NavigationBar at narrow 320px width cleanly.
      await tester.binding.setSurfaceSize(const Size(320, 568));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text('Notes'),
        ),
      );
      await tester.pumpAndSettle();
      expect(deps.shellController.state.activeWorkspace, StudioWorkspace.notes);
      expect(tester.takeException(), isNull);
    },
  );
}
