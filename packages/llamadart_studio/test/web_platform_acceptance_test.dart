@TestOn('browser')
library;

// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_studio/llamadart_studio.dart';
import 'package:llamadart_studio/src/app/local_coding_workspace.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

import 'studio_widget_test_helpers.dart';

void main() {
  testWidgets('Web Coding explicitly excludes local workspace creation', (
    tester,
  ) async {
    final deps = await buildTestDeps(isWeb: true);
    addTearDown(deps.dispose);
    await tester.pumpWidget(
      StudioScope(
        deps: deps,
        child: MaterialApp(
          theme: StudioTheme.dark(),
          home: const Scaffold(body: CodingWorkspaceView()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Local workspace files are unavailable on Web.'),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('coding_create_local_workspace_button')),
      findsNothing,
    );
    expect(find.byKey(const Key('coding_pick_folder_button')), findsNothing);
    expect(deps.createLocalCodingWorkspace, throwsUnsupportedError);
    expect(deps.listLocalCodingWorkspaces, throwsUnsupportedError);
    await expectLater(
      createLocalCodingWorkspaceDirectory(),
      throwsUnsupportedError,
    );
    await expectLater(
      listLocalCodingWorkspaceDirectories(),
      throwsUnsupportedError,
    );
    expect(deps.codingController.state.workspaceRoot, isNull);
    expect(deps.codingController.state.activeCoreTools, isEmpty);
  });

  testWidgets('Web Image Studio explains the real unsupported runtime', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final kv = InMemoryKeyValueStore();
    final deps = await StudioDependencies.fromPorts(
      keyValueStore: kv,
      conversationStore: KeyValueConversationStore(kv),
      storagePort: FakeStoragePort(),
      inferencePort: FakeInferencePort(),
      speechPort: FakeSpeechPort(),
      imagePort: DirectLlamaImagePort(),
      playgroundPort: FakePlaygroundPort(),
      isWeb: true,
    );
    addTearDown(deps.dispose);
    final capabilities = deps.imageController.state.runtimeCapabilities!;
    expect(capabilities.isSupported, isFalse);
    expect(capabilities.unsupportedReason, isNotEmpty);
    await tester.pumpWidget(
      StudioScope(
        deps: deps,
        child: MaterialApp(
          theme: StudioTheme.dark(),
          home: const Scaffold(body: ImageWorkspaceView()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(capabilities.unsupportedReason!), findsOneWidget);
    expect(find.byKey(const Key('load_image_pipeline_button')), findsNothing);
    final generate = tester.widget<FilledButton>(
      find.byKey(const Key('generate_image_button')),
    );
    expect(generate.onPressed, isNull);
    expect(deps.imageController.state.gallery, isEmpty);
  });
}
