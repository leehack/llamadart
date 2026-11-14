import 'dart:convert';

import 'package:flutter/foundation.dart';
// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio/llamadart_studio.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

import 'studio_widget_test_helpers.dart';

void main() {
  testWidgets(
    'Desktop 3-zone layout streams chat, renders tools/thinking, and branches non-destructively',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final deps = await buildTestDeps();
      addTearDown(deps.dispose);

      await tester.pumpWidget(LlamadartStudioApp(dependencies: deps));
      await tester.pumpAndSettle();

      // Desktop shows persistent Session Inspector and empty-state presets.
      expect(find.text('Session Inspector'), findsOneWidget);
      expect(find.text('Local Multimodal Intelligence'), findsOneWidget);

      // Send initial prompt.
      await tester.enterText(
        find.byKey(const Key('chat_composer_input')),
        'Weather in Seoul?',
      );
      await tester.tap(find.byKey(const Key('chat_send_button')));
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byType(ChatWorkspaceView),
          matching: find.text('Reply to: Weather in Seoul?'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('getWeather'), findsOneWidget);
      expect(find.textContaining('Thought process'), findsOneWidget);

      // Edit the user message to create a non-destructive branch (2 / 2).
      final userMessage =
          deps.chatController.state.activeConversation!.activeBranch.first;
      await tester.tap(find.byKey(Key('edit_msg_${userMessage.id}')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(Key('edit_input_${userMessage.id}')),
        'Weather in Busan?',
      );
      await tester.tap(find.byKey(Key('submit_edit_${userMessage.id}')));
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byType(ChatWorkspaceView),
          matching: find.text('Reply to: Weather in Busan?'),
        ),
        findsOneWidget,
      );
      expect(find.text('2 / 2'), findsOneWidget);
    },
  );

  testWidgets(
    'Mobile layout adapts cleanly without overflow and shows Safe-Boot recovery alert',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final sentinelPayload = jsonEncode(<String, Object?>{
        'modelName': 'Oversized 32B GGUF',
        'modelIdOrPath': 'custom:/oversized.gguf',
        'startedAt': DateTime.utc(2026).toIso8601String(),
      });
      final deps = await buildTestDeps(
        kvSeed: <String, Object>{
          'studio.in_flight_model_load.v1': sentinelPayload,
        },
      );
      addTearDown(deps.dispose);

      await tester.pumpWidget(LlamadartStudioApp(dependencies: deps));
      await tester.pumpAndSettle();

      expect(find.byType(NavigationBar), findsOneWidget);
      expect(
        find.byKey(const Key('safe_boot_recovery_banner')),
        findsOneWidget,
      );
      expect(find.textContaining('Oversized 32B GGUF'), findsOneWidget);

      await tester.tap(find.text('Dismiss'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('safe_boot_recovery_banner')), findsNothing);
    },
  );

  testWidgets(
    'Command Palette navigates to Playground and computes similarity matrix',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 840));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final deps = await buildTestDeps();
      addTearDown(deps.dispose);

      await tester.pumpWidget(LlamadartStudioApp(dependencies: deps));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('open_command_palette_button')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('command_palette_search_field')),
        'Playground',
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Go to Playground'));
      await tester.pumpAndSettle();

      expect(find.text('Developer Playground'), findsOneWidget);

      await tester.tap(find.byKey(const Key('run_embeddings_button')));
      await tester.pumpAndSettle();

      expect(find.text('384 dims'), findsOneWidget);
      expect(find.text('0.72'), findsWidgets);
    },
  );

  testWidgets(
    'Chat auto-scrolls smoothly during long thinking and streaming, pauses on user scroll-up with Jump to latest, and opens Quick Model Switcher',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 680));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final controlledInference = ControllableStreamingInferencePort();
      final kv = InMemoryKeyValueStore();
      final deps = await StudioDependencies.fromPorts(
        keyValueStore: kv,
        conversationStore: KeyValueConversationStore(kv),
        storagePort: FakeStoragePort(),
        inferencePort: controlledInference,
        speechPort: FakeSpeechPort(),
        imagePort: FakeImagePort(),
        playgroundPort: FakePlaygroundPort(),
      );
      addTearDown(deps.dispose);

      await tester.pumpWidget(LlamadartStudioApp(dependencies: deps));
      await tester.pumpAndSettle();

      // 1. Verify Top-Bar Quick Model Switcher popup lists installed models.
      await tester.tap(find.byKey(const Key('topbar_model_pill')));
      await tester.pumpAndSettle();
      expect(find.textContaining('INSTALLED CHAT MODELS'), findsOneWidget);
      expect(find.byKey(const Key('quick_model_unload')), findsOneWidget);
      expect(find.byKey(const Key('quick_model_browse_hub')), findsOneWidget);
      // Dismiss popup menu.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      // 2. Seed enough turns to make the ListView scrollable, then stream a
      // long thinking trace + multi-paragraph response chunk-by-chunk.
      controlledInference.manualMode = false;
      for (var i = 1; i <= 4; i++) {
        await deps.chatController.sendMessage(
          'Seed turn $i with several lines of context.\nLine A\nLine B\nLine C',
        );
      }
      await tester.pumpAndSettle();

      controlledInference.manualMode = true;
      final sendFuture = deps.chatController.sendMessage(
        'Explain KV-cache quantization in detail.',
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));

      // Emit 30 lines of <think> reasoning deltas and verify auto-scroll pins
      // to maxScrollExtent!
      for (var i = 1; i <= 30; i++) {
        controlledInference.emit(
          StudioThinkingDeltaEvent(
            'Step $i: analyzing K/V tensor memory footprint across 32 attention layers...\n',
          ),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pump();

      ScrollableState chatScrollable() => tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byKey(const Key('chat_message_scroll_view')),
              matching: find.byType(Scrollable),
            )
            .first,
      );

      final posDuringThinking = chatScrollable().position;
      expect(posDuringThinking.maxScrollExtent, greaterThan(0));
      expect(
        (posDuringThinking.maxScrollExtent - posDuringThinking.pixels).abs(),
        lessThan(4.0),
        reason: 'Chat ListView must stay pinned to bottom during thinking.',
      );

      // Emit 25 lines of visible Markdown response and verify it stays pinned!
      for (var i = 1; i <= 25; i++) {
        controlledInference.emit(
          StudioTextDeltaEvent(
            '- **Bullet $i**: Quantizing KV cache from FP16 to Q8_0 halves memory bandwidth.\n',
          ),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pump();

      final posDuringAnswer = chatScrollable().position;
      expect(
        (posDuringAnswer.maxScrollExtent - posDuringAnswer.pixels).abs(),
        lessThan(4.0),
        reason:
            'Chat ListView must stay pinned to bottom during streaming text.',
      );

      // Simulate user scrolling up mid-stream -> sticky scroll pauses and
      // "Jump to latest" pill appears!
      await tester.drag(
        find.byKey(const Key('chat_message_scroll_view')),
        const Offset(0, 320),
      );
      await tester.pump();
      expect(
        find.byKey(const Key('chat_jump_to_bottom_button')),
        findsOneWidget,
      );

      // Clicking "Jump to latest" scrolls right back to bottom and hides pill.
      await tester.tap(find.byKey(const Key('chat_jump_to_bottom_button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('chat_jump_to_bottom_button')), findsNothing);
      final posAfterJump = chatScrollable().position;
      expect(
        (posAfterJump.maxScrollExtent - posAfterJump.pixels).abs(),
        lessThan(4.0),
      );

      controlledInference.complete(
        finalText: 'Completed multi-bullet explanation.',
        thinkingText: 'Completed reasoning trace.',
      );
      await sendFuture;
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Global shortcuts (⌘K, ⌘1-7, ⌘I, ⌘N) work even while composer TextField has focus',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final deps = await buildTestDeps();
      addTearDown(deps.dispose);

      await tester.pumpWidget(LlamadartStudioApp(dependencies: deps));
      await tester.pumpAndSettle();

      // Focus the chat composer TextField explicitly.
      await tester.tap(find.byKey(const Key('chat_composer_input')));
      await tester.pumpAndSettle();
      expect(deps.shellController.state.activeWorkspace, StudioWorkspace.chat);
      final initialConvId = deps.chatController.state.activeConversation?.id;

      // Simulate Meta + 2 (switch to Coding workspace while TextField focused).
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.digit2);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.digit2);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();
      expect(
        deps.shellController.state.activeWorkspace,
        StudioWorkspace.coding,
      );
      // Coding workspace promotes Qwen3.8 27B Coding as the primary coding model.
      expect(find.byKey(const Key('coding_setup_panel')), findsNothing);
      await tester.tap(find.byKey(const Key('coding_setup_toggle')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Qwen3.8 27B'), findsWidgets);

      // Simulate Meta + K (open Command Palette), then Meta + K again to close.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('command_palette_search_field')),
        findsOneWidget,
      );

      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('command_palette_search_field')),
        findsNothing,
      );

      // Simulate Meta + I (toggle Session Inspector).
      final beforeInspector = deps.shellController.state.settings.inspectorOpen;
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyI);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyI);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();
      expect(
        deps.shellController.state.settings.inspectorOpen,
        !beforeInspector,
      );

      // Simulate Meta + N (new chat conversation + switch to Chat).
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();
      expect(deps.shellController.state.activeWorkspace, StudioWorkspace.chat);
      expect(
        deps.chatController.state.activeConversation?.id,
        isNot(initialConvId),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Production UX: Composer Think/Tools quick toggles, modality warning, unapplied engine reload badge, and Sampling reset',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final deps = await buildTestDeps();
      addTearDown(deps.dispose);

      // Activate a text-only chat model so loadedEngineSignature & activeDescriptor are set.
      final textOnlyModel = CuratedModelCatalog.models.firstWhere(
        (StudioModelDescriptor m) =>
            m.category == StudioModelCategory.chat && !m.supportsVision,
      );
      await deps.modelHubController.activateChatModel(textOnlyModel);

      await tester.pumpWidget(LlamadartStudioApp(dependencies: deps));
      await tester.pumpAndSettle();

      // 1. Composer 1-click Think & Tools quick-toggle chips.
      final initialThink = deps.shellController.state.settings.thinkingEnabled;
      await tester.tap(find.byKey(const Key('composer_toggle_think_chip')));
      await tester.pumpAndSettle();
      expect(
        deps.shellController.state.settings.thinkingEnabled,
        !initialThink,
      );

      final initialTools = deps.shellController.state.settings.toolsEnabled;
      await tester.tap(find.byKey(const Key('composer_toggle_tools_chip')));
      await tester.pumpAndSettle();
      expect(deps.shellController.state.settings.toolsEnabled, !initialTools);

      // 2. Staging an image on a text-only loaded model surfaces a modality warning.
      deps.chatController.addPendingAttachment(
        StudioAttachment(
          id: 'att_img_1',
          name: 'chart.png',
          kind: StudioAttachmentKind.image,
          mimeType: 'image/png',
          bytes: Uint8List.fromList(<int>[137, 80, 78, 71]),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('composer_modality_warning')),
        findsOneWidget,
      );

      // 3. Changing a load-time parameter (batchSize) highlights Reload required badge.
      expect(
        find.byKey(const Key('unapplied_engine_changes_badge')),
        findsNothing,
      );
      await tester.tap(find.byKey(const Key('inspector_mode_expert')));
      await tester.pumpAndSettle();
      final hardwareScrollable = find.descendant(
        of: find.byKey(const Key('inspector_hardware_list')),
        matching: find.byType(Scrollable),
      );
      final batchChip = find.byKey(const Key('inspector_batch_size_2048'));
      await tester.scrollUntilVisible(
        batchChip,
        200,
        scrollable: hardwareScrollable,
      );
      await tester.pumpAndSettle();
      await tester.tap(batchChip);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('unapplied_engine_changes_badge')),
        findsOneWidget,
      );

      // 4. Sampling tab Reset Defaults restores default temperature/topK cleanly.
      await deps.shellController.updateSettings(
        (StudioSettings s) => s.copyWith(temperature: 1.5),
      );
      await tester.tap(find.text('Sampling').last);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('inspector_reset_sampling_button')),
      );
      await tester.pumpAndSettle();
      expect(
        deps.shellController.state.settings.temperature,
        const StudioSettings().temperature,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'UX #1-#4: Starter setup card, grouped sidebar, Active Engines manager, and Inspector Simple/Expert presets',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      // 1. Unloaded runtime + empty cache surfaces first-run starter setup hero.
      final emptyStorage = EmptyCacheStoragePort();
      final emptyInference = FakeInferencePort();
      await emptyInference.unloadModel();
      final emptyDeps = await buildTestDeps(
        storagePort: emptyStorage,
        inferencePort: emptyInference,
      );
      addTearDown(emptyDeps.dispose);

      await tester.pumpWidget(LlamadartStudioApp(dependencies: emptyDeps));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('chat_starter_setup_card')), findsOneWidget);
      expect(
        find.byKey(const Key('chat_download_starter_button')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('chat_scan_folder_button')), findsOneWidget);
      expect(
        find.byKey(const Key('hero_open_model_hub_button')),
        findsOneWidget,
      );

      // 2. Grouped sidebar hierarchy + Active Engines topbar manager.
      expect(find.text('WORKSPACES'), findsOneWidget);
      expect(find.text('STUDIOS & DIAGNOSTICS'), findsOneWidget);
      expect(find.byKey(const Key('nav_workspace_models')), findsOneWidget);

      final chatModel = CuratedModelCatalog.forCategory(
        StudioModelCategory.chat,
        isWeb: false,
        isMobile: false,
      ).first;
      await emptyDeps.modelHubController.activateChatModel(chatModel);
      await emptyDeps.speechController.loadTtsModel(
        emptyDeps.speechController.availableTtsModels.first,
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('topbar_engines_button')), findsOneWidget);
      await tester.tap(find.byKey(const Key('topbar_engines_button')));
      await tester.pumpAndSettle();
      expect(find.text('Active Engines (2)'), findsOneWidget);
      expect(find.byKey(const Key('free_all_engines_button')), findsOneWidget);

      await tester.tap(find.byKey(const Key('free_all_engines_button')));
      await tester.pumpAndSettle();
      expect(emptyDeps.modelHubController.runtimeStore.state.isReady, isFalse);
      expect(emptyDeps.speechController.state.activeTtsModel, isNull);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      // 3. Session Inspector Simple/Expert progressive disclosure + hardware presets.
      expect(find.byKey(const Key('inspector_mode_simple')), findsOneWidget);
      expect(find.byKey(const Key('inspector_preset_fast')), findsOneWidget);
      expect(find.byKey(const Key('inspector_preset_quality')), findsOneWidget);
      expect(find.byKey(const Key('inspector_batch_size_2048')), findsNothing);

      await tester.tap(find.byKey(const Key('inspector_preset_quality')));
      await tester.pumpAndSettle();
      expect(emptyDeps.shellController.state.settings.contextSize, 16384);
      expect(
        emptyDeps.shellController.state.settings.flashAttention,
        FlashAttention.enabled,
      );

      await tester.tap(find.byKey(const Key('inspector_mode_expert')));
      await tester.pumpAndSettle();
      expect(
        emptyDeps.shellController.state.settings.inspectorExpertMode,
        isTrue,
      );
      expect(
        find.byKey(const Key('inspector_batch_size_2048')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
