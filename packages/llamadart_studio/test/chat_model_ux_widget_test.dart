import 'dart:async';

// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_studio/llamadart_studio.dart';
import 'package:llamadart_studio/src/widgets/download_activity_bar.dart';
import 'package:llamadart_studio/src/widgets/model_load_error_banner.dart';
import 'package:llamadart_studio/src/widgets/model_load_progress_banner.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

import 'studio_widget_test_helpers.dart';

void main() {
  testWidgets('drafts and visible search survive workspace remounts', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 840));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final deps = await buildTestDeps();
    addTearDown(deps.dispose);
    await tester.pumpWidget(LlamadartStudioApp(dependencies: deps));
    await tester.pumpAndSettle();
    final first = deps.chatController.state.activeConversationId!;
    await tester.enterText(
      find.byKey(const Key('chat_composer_input')),
      'Unsent first',
    );
    await deps.shellController.selectWorkspace(StudioWorkspace.models);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('model_hub_search_field')),
      'qwen 27b',
    );
    await tester.pumpAndSettle();
    final result = tester
        .widget<Text>(find.byKey(const Key('model_hub_result_count')))
        .data;
    await deps.shellController.selectWorkspace(StudioWorkspace.chat);
    await tester.pumpAndSettle();
    expect(_text(tester, 'chat_composer_input'), 'Unsent first');
    final second = await deps.chatController.createConversation();
    await tester.pumpAndSettle();
    expect(_text(tester, 'chat_composer_input'), isEmpty);
    await tester.enterText(
      find.byKey(const Key('chat_composer_input')),
      'Unsent second',
    );
    deps.chatController.selectConversation(first);
    await tester.pumpAndSettle();
    expect(_text(tester, 'chat_composer_input'), 'Unsent first');
    deps.chatController.selectConversation(second.id);
    await tester.pumpAndSettle();
    expect(_text(tester, 'chat_composer_input'), 'Unsent second');
    await deps.shellController.selectWorkspace(StudioWorkspace.models);
    await tester.pumpAndSettle();
    expect(_text(tester, 'model_hub_search_field'), 'qwen 27b');
    expect(
      tester.widget<Text>(find.byKey(const Key('model_hub_result_count'))).data,
      result,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Stop while loading allows a newer prompt before load completes',
    (tester) async {
      final inference = _HeldLoadInference();
      final deps = await buildTestDeps(inferencePort: inference);
      addTearDown(deps.dispose);
      addTearDown(() {
        if (!inference.release.isCompleted) inference.release.complete();
      });
      await tester.pumpWidget(LlamadartStudioApp(dependencies: deps));
      await tester.pumpAndSettle();
      final input = find.byKey(const Key('chat_composer_input'));
      await tester.enterText(input, 'First prompt');
      await tester.tap(find.byKey(const Key('chat_send_button')));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(inference.entered.isCompleted, isTrue);
      await tester.tap(find.byKey(const Key('chat_stop_button')));
      await tester.pump();
      await tester.enterText(input, 'Newer prompt');
      await tester.tap(find.byKey(const Key('chat_send_button')));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(
        deps.chatController.state.activeConversation!.nodes
            .where((n) => n.role == StudioRole.user)
            .map((n) => n.text),
        ['First prompt', 'Newer prompt'],
      );
      expect(deps.chatController.activeStreamStore.state.isGenerating, isTrue);
      inference.release.complete();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('420px filters collapse with active count and reset', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 780));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final deps = await buildTestDeps();
    addTearDown(deps.dispose);
    await tester.pumpWidget(LlamadartStudioApp(dependencies: deps));
    await tester.pumpAndSettle();
    await deps.shellController.selectWorkspace(StudioWorkspace.models);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('model_hub_search_field')), findsOneWidget);
    expect(find.byKey(const Key('model_hub_capability')), findsNothing);
    expect(
      tester.getRect(find.byKey(const Key('model_hub_result_count'))).bottom,
      lessThan(650),
    );
    await tester.tap(find.byKey(const Key('model_hub_filter_toggle')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('model_hub_capability')),
      100,
      scrollable: find
          .descendant(
            of: find.byType(ModelHubWorkspaceView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.byKey(const Key('model_hub_capability')), findsOneWidget);
    deps.modelHubController.selectCategory(StudioModelCategory.image);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('model_hub_filter_toggle')),
      -100,
      scrollable: find
          .descendant(
            of: find.byType(ModelHubWorkspaceView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(find.byKey(const Key('model_hub_filter_toggle')));
    await tester.pumpAndSettle();
    expect(find.text('Filters & sort (1 active)'), findsOneWidget);
    await tester.tap(find.byKey(const Key('model_hub_reset_compact')));
    await tester.pumpAndSettle();
    expect(deps.modelHubController.state.selectedCategory, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('quick load failure persists in Chat and retries', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 840));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final inference = _FailingInference();
    final deps = await buildTestDeps(inferencePort: inference);
    addTearDown(deps.dispose);
    await tester.pumpWidget(LlamadartStudioApp(dependencies: deps));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('topbar_model_pill')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('quick_model_local:qwen3-5-2b-q4-k-m-gguf')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('chat_model_load_error')), findsOneWidget);
    expect(find.textContaining('Forced load failure'), findsWidgets);
    expect(tester.takeException(), isNull);
    inference.fail = false;
    await tester.tap(find.byKey(const Key('retry_chat_model_load')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('chat_model_load_error')), findsNothing);
    expect(inference.calls, 2);
  });

  testWidgets(
    'late model failure is safe after the originating view unmounts',
    (tester) async {
      final gate = Completer<void>();
      Future<void>? action;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () {
                action = runModelLoadAction(context, () => gate.future);
              },
              child: const Text('Load'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Load'));
      await tester.pumpWidget(const SizedBox.shrink());
      gate.completeError(StateError('late failure'));
      await action;
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Web transfer and initialization progress display without premature Ready',
    (tester) async {
      final inference = _ProgressInference();
      final kv = InMemoryKeyValueStore();
      final deps = await StudioDependencies.fromPorts(
        keyValueStore: kv,
        conversationStore: KeyValueConversationStore(kv),
        storagePort: FakeStoragePort(),
        inferencePort: inference,
        speechPort: FakeSpeechPort(),
        imagePort: FakeImagePort(),
        playgroundPort: FakePlaygroundPort(),
        isWeb: true,
      );
      addTearDown(deps.dispose);
      final descriptor = CuratedModelCatalog.models.firstWhere(
        (m) => m.primarySource(isWeb: true).isRemote,
      );
      await tester.pumpWidget(
        StudioScope(
          deps: deps,
          child: MaterialApp(
            home: Scaffold(
              body: Column(
                children: <Widget>[
                  const DownloadActivityBar(),
                  ModelLoadProgressBanner(descriptor: descriptor),
                ],
              ),
            ),
          ),
        ),
      );
      inference.progress(descriptor, .42, 'Downloading runtime model files...');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('42%'), findsNWidgets(2));
      expect(find.textContaining('Ready'), findsNothing);
      expect(
        tester
            .widgetList<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .map((p) => p.value),
        everyElement(.42),
      );
      inference.progress(descriptor, null, 'Initializing runtime weights...');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.textContaining('Initializing runtime weights...'),
        findsWidgets,
      );
      expect(
        tester
            .widgetList<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .map((p) => p.value),
        everyElement(isNull),
      );
      inference.ready(descriptor);
      await tester.pump();
      expect(find.byKey(const Key('download_activity_bar')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}

String _text(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(Key(key))).controller!.text;

class _FailingInference extends FakeInferencePort {
  bool fail = true;
  int calls = 0;
  @override
  Future<void> loadModel({
    required ResolvedModelAssets assets,
    required StudioSettings settings,
    required bool isWeb,
  }) async {
    calls++;
    if (fail) throw StateError('Forced load failure');
    await super.loadModel(assets: assets, settings: settings, isWeb: isWeb);
  }
}

class _ProgressInference extends FakeInferencePort {
  final runtime = StateStore<StudioRuntimeSnapshot>(
    const StudioRuntimeSnapshot(),
  );
  @override
  ReadOnlyStore<StudioRuntimeSnapshot> get runtimeStore => runtime;
  void progress(StudioModelDescriptor model, double? fraction, String status) =>
      runtime.set(
        StudioRuntimeSnapshot(
          phase: StudioEnginePhase.loading,
          activeDescriptor: model,
          loadProgressFraction: fraction,
          statusMessage: status,
        ),
      );
  void ready(StudioModelDescriptor model) => runtime.set(
    StudioRuntimeSnapshot(
      phase: StudioEnginePhase.ready,
      activeDescriptor: model,
    ),
  );
  @override
  Future<void> dispose() async {
    await runtime.dispose();
    await super.dispose();
  }
}

class _HeldLoadInference extends _ProgressInference {
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> loadModel({
    required ResolvedModelAssets assets,
    required StudioSettings settings,
    required bool isWeb,
  }) async {
    progress(assets.descriptor, null, 'Loading local model...');
    entered.complete();
    await release.future;
    ready(assets.descriptor);
  }
}
