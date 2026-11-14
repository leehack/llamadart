import 'dart:async';

// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_studio/llamadart_studio.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

import 'studio_widget_test_helpers.dart';

class _DelayedInferencePort extends FakeInferencePort {
  final StateStore<StudioRuntimeSnapshot> _loadingRuntime =
      StateStore<StudioRuntimeSnapshot>(const StudioRuntimeSnapshot());
  final Completer<void> finishLoad = Completer<void>();
  int loadCalls = 0;

  @override
  ReadOnlyStore<StudioRuntimeSnapshot> get runtimeStore => _loadingRuntime;

  @override
  Future<void> loadModel({
    required ResolvedModelAssets assets,
    required StudioSettings settings,
    required bool isWeb,
  }) async {
    loadCalls++;
    _loadingRuntime.set(
      StudioRuntimeSnapshot(
        phase: StudioEnginePhase.loading,
        activeDescriptor: assets.descriptor,
        activeModelLabel: assets.descriptor.name,
      ),
    );
    await finishLoad.future;
    _loadingRuntime.set(
      StudioRuntimeSnapshot(
        phase: StudioEnginePhase.ready,
        activeDescriptor: assets.descriptor,
        activeModelLabel: assets.descriptor.name,
      ),
    );
  }

  @override
  Future<void> dispose() async {
    if (!finishLoad.isCompleted) finishLoad.complete();
    await _loadingRuntime.dispose();
    await super.dispose();
  }
}

class _DelayedStoragePort extends FakeStoragePort {
  final Completer<void> continuePreparation = Completer<void>();

  @override
  Future<ResolvedModelAssets> ensureDownloaded(
    StudioModelDescriptor descriptor, {
    required bool isWeb,
    String? bearerToken,
  }) async {
    await continuePreparation.future;
    return super.ensureDownloaded(descriptor, isWeb: isWeb);
  }
}

void main() {
  testWidgets(
    'pending model load stays visible and navigation remains usable',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1560, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final inference = _DelayedInferencePort();
      final storage = _DelayedStoragePort();
      final deps = await buildTestDeps(
        inferencePort: inference,
        storagePort: storage,
      );
      addTearDown(deps.dispose);
      await tester.pumpWidget(LlamadartStudioApp(dependencies: deps));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('nav_workspace_models')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('model_hub_search_field')),
        'Qwen3.5 2B',
      );
      await tester.pumpAndSettle();
      const id = 'local:qwen3-5-2b-q4-k-m-gguf';
      final loadButton = find.byKey(const Key('activate_model_$id'));
      await tester.ensureVisible(loadButton);
      await tester.tap(loadButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(inference.loadCalls, 0);
      expect(find.text('Loading...'), findsOneWidget);
      expect(find.text('Preparing model files...'), findsOneWidget);
      expect(tester.widget<FilledButton>(loadButton).onPressed, isNull);
      final banner = find.byKey(const Key('model_load_banner_$id'));
      await tester.scrollUntilVisible(
        banner,
        -300,
        scrollable: find
            .descendant(
              of: find.byType(ModelHubWorkspaceView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.text('Preparing Qwen3.5 2B (Q4_K_M)...'), findsOneWidget);
      storage.continuePreparation.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(inference.loadCalls, 1);
      expect(
        find.text('Loading Qwen3.5 2B (Q4_K_M) into memory...'),
        findsOneWidget,
      );
      expect(banner, findsOneWidget);
      final progress = find.descendant(
        of: banner,
        matching: find.byType(LinearProgressIndicator),
      );
      expect(tester.widget<LinearProgressIndicator>(progress).value, isNull);
      await tester.drag(
        find
            .descendant(
              of: find.byType(ModelHubWorkspaceView),
              matching: find.byType(Scrollable),
            )
            .first,
        const Offset(0, 1000),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const Key('open_custom_model_button')),
            )
            .onPressed,
        isNull,
      );

      await tester.tap(find.byKey(const Key('topbar_model_pill')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        tester
            .widget<PopupMenuItem<String>>(
              find.byKey(const Key('quick_model_$id')),
            )
            .enabled,
        isFalse,
      );
      await tester.tapAt(const Offset(1500, 900));
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.byKey(const Key('nav_workspace_speech')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Speech Studio'), findsOneWidget);
      inference.finishLoad.complete();
      await tester.pumpAndSettle();
      expect(
        deps.shellController.state.activeWorkspace,
        StudioWorkspace.speech,
      );
      expect(inference.loadCalls, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
