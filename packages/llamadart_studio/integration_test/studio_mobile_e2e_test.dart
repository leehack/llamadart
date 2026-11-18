import 'dart:io';

// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio/llamadart_studio.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Mobile E2E: bootstrapProduction, native FFI probe, responsive 7-workspace navigation, and drawers',
    (WidgetTester tester) async {
      final capturedFlutterErrors = <FlutterErrorDetails>[];
      final previousOnError = FlutterError.onError;
      FlutterError.onError = (FlutterErrorDetails details) {
        capturedFlutterErrors.add(details);
        previousOnError?.call(details);
      };
      addTearDown(() => FlutterError.onError = previousOnError);

      // 1. Native backend FFI initialization check on the running mobile OS.
      final probeEngine = LlamaEngine(LlamaBackend());
      final backendName = await probeEngine.getBackendName();
      expect(backendName.trim(), isNotEmpty);
      await probeEngine.dispose();

      // 2. Full production bootstrap into isolated temp directory.
      final tempDir = await Directory.systemTemp.createTemp(
        'llamadart_studio_mobile_e2e_',
      );
      addTearDown(() async {
        if (tempDir.existsSync()) {
          await tempDir.delete(recursive: true);
        }
      });

      final kv = InMemoryKeyValueStore();
      final deps = await StudioDependencies.bootstrapProduction(
        appDataDirectoryOverride: tempDir.path,
        localModelRootsOverride: <String>['${tempDir.path}/models'],
        keyValueStoreOverride: kv,
      );
      addTearDown(deps.dispose);

      expect(deps.isMobile, isTrue);
      expect(deps.isWeb, isFalse);
      expect(deps.codingController.state.workspaceRoot, isNull);

      await tester.pumpWidget(LlamadartStudioApp(dependencies: deps));
      await tester.pumpAndSettle();

      // 3. Verify adaptive chrome matches the device's actual logical width tier:
      //    <720 compact mobile NavigationBar, 720..1119 tablet NavigationRail,
      //    >=1120 wide docked sidebar + docked inspector.
      final screenSize =
          tester.view.physicalSize / tester.view.devicePixelRatio;
      final isCompactPhone = screenSize.width < 720;
      final isTabletRail = screenSize.width >= 720 && screenSize.width < 1120;
      final isWideTablet = screenSize.width >= 1120;
      if (isCompactPhone) {
        expect(find.byType(NavigationBar), findsOneWidget);
        final toolsBox = tester.getRect(find.text('Tools').last);
        final sendBox = tester.getRect(
          find.byKey(const Key('chat_send_button')),
        );
        expect(toolsBox.right, lessThanOrEqualTo(screenSize.width + 0.5));
        expect(sendBox.right, lessThanOrEqualTo(screenSize.width + 0.5));
        expect(toolsBox.bottom, lessThanOrEqualTo(sendBox.top + 0.5));
      } else if (isTabletRail) {
        expect(find.byType(NavigationRail), findsOneWidget);
        expect(find.byType(NavigationBar), findsNothing);
      } else {
        expect(find.byType(NavigationBar), findsNothing);
        expect(find.byType(NavigationRail), findsNothing);
        expect(
          find.byKey(const Key('open_sidebar_drawer_button')),
          findsNothing,
        );
        expect(find.byKey(const Key('nav_workspace_coding')), findsOneWidget);
      }

      // 4. Open left Drawer (on phone/rail) or use permanent sidebar, then navigate to Coding Workspace.
      if (!isWideTablet) {
        await tester.tap(find.byKey(const Key('open_sidebar_drawer_button')));
        await tester.pumpAndSettle();
      }
      expect(find.text('SESSIONS'), findsOneWidget);

      await tester.tap(find.byKey(const Key('nav_workspace_coding')));
      await tester.pumpAndSettle();
      expect(
        deps.shellController.state.activeWorkspace,
        StudioWorkspace.coding,
      );
      await tester.tap(find.byKey(const Key('coding_setup_toggle')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('coding_active_tools_strip')),
        findsOneWidget,
      );

      // Switch compact Coding sections if segmented UI is active.
      if (find.textContaining('Files (').evaluate().isNotEmpty) {
        await tester.tap(find.textContaining('Files (').first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Agent').first);
        await tester.pumpAndSettle();
      }

      // Open MCP & Skills sheet and switch tabs cleanly.
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
      Navigator.of(tester.element(find.byType(Dialog).first)).pop();
      await tester.pumpAndSettle();

      // 5. Navigate to Multimodal Notebook and create a persisted note.
      if (isCompactPhone) {
        await tester.tap(
          find.descendant(
            of: find.byType(NavigationBar),
            matching: find.text('Notes'),
          ),
        );
      } else if (isTabletRail) {
        await tester.tap(
          find.descendant(
            of: find.byType(NavigationRail),
            matching: find.text('Notes'),
          ),
        );
      } else {
        await tester.tap(find.byKey(const Key('nav_workspace_notes')));
      }
      await tester.pumpAndSettle();
      expect(deps.shellController.state.activeWorkspace, StudioWorkspace.notes);

      final initialNoteCount = deps.notebookController.state.notes.length;
      await tester.ensureVisible(
        find.byKey(const Key('vault_new_note_button')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('vault_new_note_button')));
      await tester.pumpAndSettle();
      expect(
        deps.notebookController.state.notes.length,
        greaterThan(initialNoteCount),
      );

      await tester.ensureVisible(
        find.byKey(const Key('vault_note_title_input')),
      );
      await tester.enterText(
        find.byKey(const Key('vault_note_title_input')),
        'Mobile acceptance — Montréal',
      );
      await tester.ensureVisible(
        find.byKey(const Key('vault_note_content_input')),
      );
      await tester.enterText(
        find.byKey(const Key('vault_note_content_input')),
        'Saved on the actual mobile host.',
      );
      await tester.ensureVisible(
        find.byKey(const Key('vault_save_note_button')),
      );
      await tester.tap(find.byKey(const Key('vault_save_note_button')));
      await tester.pumpAndSettle();
      final reopenedNotes = await createDefaultNoteStore(
        fallbackKeyValueStore: kv,
        directoryPath: tempDir.path,
      ).loadAll();
      expect(
        reopenedNotes.any(
          (StudioNote note) =>
              note.title == 'Mobile acceptance — Montréal' &&
              note.content == 'Saved on the actual mobile host.',
        ),
        isTrue,
      );

      Future<void> navigateTo(StudioWorkspace workspace) async {
        if (!isWideTablet) {
          await tester.tap(find.byKey(const Key('open_sidebar_drawer_button')));
          await tester.pumpAndSettle();
        }
        final destination = find.byKey(
          Key('nav_workspace_${workspace.routeSegment}'),
        );
        await tester.ensureVisible(destination);
        await tester.tap(destination);
        await tester.pumpAndSettle();
        expect(deps.shellController.state.activeWorkspace, workspace);
      }

      // 6. Verify Speech, Image, Playground (Lab), and Model Hub workspaces.
      await navigateTo(StudioWorkspace.speech);
      await tester.pumpAndSettle();
      expect(
        deps.shellController.state.activeWorkspace,
        StudioWorkspace.speech,
      );

      await navigateTo(StudioWorkspace.image);
      await tester.pumpAndSettle();
      expect(deps.shellController.state.activeWorkspace, StudioWorkspace.image);

      await navigateTo(StudioWorkspace.playground);
      await tester.pumpAndSettle();
      for (final tab in PlaygroundToolTab.values) {
        deps.playgroundController.selectTab(tab);
        await tester.pumpAndSettle();
        if (tab == PlaygroundToolTab.decision) {
          for (final mode in DecisionWorkflowMode.values) {
            deps.playgroundController.selectDecisionMode(mode);
            await tester.pumpAndSettle();
          }
        }
      }

      await navigateTo(StudioWorkspace.models);
      await tester.pumpAndSettle();
      expect(find.text('Model Hub & Cache Manager'), findsOneWidget);
      // Add Folder is desktop-only and must stay hidden on mobile.
      expect(find.text('Add Folder'), findsNothing);

      await tester.enterText(
        find.byKey(const Key('model_hub_search_field')),
        'no-such-mobile-acceptance-model',
      );
      await tester.pumpAndSettle();
      expect(
        deps.modelHubController.state.searchQuery,
        'no-such-mobile-acceptance-model',
      );
      final hubScroll = find
          .descendant(
            of: find.byType(ModelHubWorkspaceView),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.text('No models match your filters.'),
        180,
        scrollable: hubScroll,
      );
      expect(find.text('No models match your filters.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('model_hub_reset')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('open_cache_sheet_button')),
        -180,
        scrollable: hubScroll,
      );
      await tester.tap(find.byKey(const Key('open_cache_sheet_button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('storage_file_list')), findsOneWidget);
      expect(
        find.text('No managed downloads yet. Download a model from Browse.'),
        findsOneWidget,
      );
      Navigator.of(tester.element(find.byKey(const Key('storage_file_list'))))
          .pop();
      await tester.pumpAndSettle();

      // 7. Verify Session Inspector (endDrawer on phone/rail, docked panel on wide tablets) & cycle tabs.
      if (!isWideTablet) {
        await tester.tap(find.byKey(const Key('toggle_inspector_button')));
        await tester.pumpAndSettle();
      } else {
        expect(deps.shellController.state.settings.inspectorOpen, isTrue);
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
      if (isWideTablet) {
        await tester.tap(find.byKey(const Key('toggle_inspector_button')));
        await tester.pumpAndSettle();
        expect(deps.shellController.state.settings.inspectorOpen, isFalse);
        await tester.tap(find.byKey(const Key('toggle_inspector_button')));
        await tester.pumpAndSettle();
        expect(deps.shellController.state.settings.inspectorOpen, isTrue);
      } else {
        Navigator.of(tester.element(find.byType(Scaffold).first)).pop();
        await tester.pumpAndSettle();
      }

      // 8. Open Command Palette & dismiss cleanly.
      await tester.tap(find.byKey(const Key('open_command_palette_button')));
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.byType(Dialog).first)).pop();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(
        capturedFlutterErrors,
        isEmpty,
        reason:
            'Unexpected Flutter errors / layout overflows on mobile device: $capturedFlutterErrors',
      );
    },
  );
}
