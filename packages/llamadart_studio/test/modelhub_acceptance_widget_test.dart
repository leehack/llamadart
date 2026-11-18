import 'dart:ui' as ui;

// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio/llamadart_studio.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

import 'studio_widget_test_helpers.dart';

class _UnavailableStorage extends FakeStoragePort {
  @override
  Future<ResolvedModelAssets> ensureDownloaded(
    StudioModelDescriptor descriptor, {
    required bool isWeb,
    String? bearerToken,
  }) async =>
      throw LlamaUnsupportedException('Runtime unavailable on this host.');
}

void main() {
  testWidgets('successful model load leaves the chat composer unobstructed', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final deps = await buildTestDeps();
    addTearDown(deps.dispose);
    await tester.pumpWidget(LlamadartStudioApp(dependencies: deps));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav_workspace_models')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('model_hub_search_field')),
      'qwen3.5 0.8b',
    );
    await tester.pumpAndSettle();
    final load = find.byKey(const Key('activate_model_qwen3.5-0.8b-q4-k-m'));
    await tester.ensureVisible(load);
    await tester.pumpAndSettle();
    await tester.tap(load);
    await tester.pumpAndSettle();
    expect(deps.shellController.state.activeWorkspace, StudioWorkspace.chat);
    expect(find.byKey(const Key('chat_send_button')), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final modelId in <String>[
    'sdxs-512-q8_0',
    'qwen3-tts-1.7b-base-q4-k-m',
    'qwen3-asr-0.6b-q8-0',
  ]) {
    testWidgets('Model Hub reports failed load honestly for $modelId', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1280, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final deps = await buildTestDeps(storagePort: _UnavailableStorage());
      addTearDown(deps.dispose);
      final descriptor = CuratedModelCatalog.models.firstWhere(
        (m) => m.id == modelId,
      );
      await tester.pumpWidget(
        StudioScope(
          deps: deps,
          child: MaterialApp(
            theme: StudioTheme.dark(),
            home: const Scaffold(body: ModelHubWorkspaceView()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('model_hub_search_field')),
        descriptor.name,
      );
      await tester.pumpAndSettle();
      final load = find.widgetWithText(FilledButton, 'Load').first;
      await tester.ensureVisible(load);
      await tester.pumpAndSettle();
      await tester.tap(load);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Failed to load ${descriptor.name}:'),
        findsOneWidget,
      );
      expect(find.text('Loaded ${descriptor.name}'), findsNothing);
      expect(
        find.textContaining('Runtime unavailable on this host.'),
        findsOneWidget,
      );
    });
  }

  testWidgets('Model search follows accessibility text updates', (
    tester,
  ) async {
    final deps = await buildTestDeps();
    addTearDown(deps.dispose);
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      StudioScope(
        deps: deps,
        child: MaterialApp(
          theme: StudioTheme.dark(),
          home: const Scaffold(body: ModelHubWorkspaceView()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final field = find.byKey(const Key('model_hub_search_field'));
    final editable = find.descendant(
      of: field,
      matching: find.byType(EditableText),
    );
    await tester.showKeyboard(field);
    await tester.pump();
    final node = tester.getSemantics(editable);
    tester.binding.performSemanticsAction(
      ui.SemanticsActionEvent(
        viewId: tester.view.viewId,
        nodeId: node.id,
        type: SemanticsAction.setText,
        arguments: 'qwen 27b',
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<EditableText>(editable).controller.text, 'qwen 27b');
    expect(deps.modelHubController.state.searchQuery, 'qwen 27b');
    expect(find.text('Qwen3.8 27B Coding'), findsOneWidget);
    semantics.dispose();
  });
}
