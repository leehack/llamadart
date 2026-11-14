// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_studio/llamadart_studio.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

import 'studio_widget_test_helpers.dart';

class _SameFilenameStorage extends FakeStoragePort {
  final descriptor = StudioModelDescriptor(
    id: 'local:same-name',
    name: 'My local model',
    description: 'Local file without curated companions',
    category: StudioModelCategory.chat,
    filename: CuratedModelCatalog.models.first.filename,
    sourceUri: '/tmp/same-name.gguf',
  );
  @override
  List<StudioModelDescriptor> get discoveredLocalModels => [descriptor];
  @override
  Future<List<StudioModelDescriptor>> refreshLocalModels({
    List<String> extraDirectories = const [],
  }) async => [descriptor];
  @override
  Future<bool> isCached(
    StudioModelDescriptor descriptor, {
    required bool isWeb,
  }) async => false;
}

void main() {
  testWidgets(
    'On device retains local file with unavailable curated filename',
    (tester) async {
      final storage = _SameFilenameStorage();
      final deps = await buildTestDeps(storagePort: storage);
      addTearDown(deps.dispose);
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
      await tester.tap(find.byKey(const Key('model_hub_section_onDevice')));
      await tester.pumpAndSettle();
      expect(find.text('My local model'), findsOneWidget);
      expect(find.text('Local file'), findsOneWidget);
      expect(find.byTooltip('Delete cached weights'), findsNothing);
    },
  );
  for (final width in <double>[360, 1280]) {
    testWidgets(
      'Model discovery filters, resets and switches sources at $width',
      (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final deps = await buildTestDeps();
        addTearDown(deps.dispose);
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
          'qwen 27b',
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const Key('model_hub_result_count')),
        );
        await tester.pumpAndSettle();
        expect(find.text('Qwen3.8 27B Coding'), findsOneWidget);
        await tester.scrollUntilVisible(
          find.byKey(const Key('model_hub_search_field')),
          -250,
          scrollable: find
              .descendant(
                of: find.byKey(
                  const PageStorageKey<String>('model_hub_scroll'),
                ),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('model_hub_search_field')),
          'unavailable-model',
        );
        await tester.pumpAndSettle();
        expect(find.text('No models match your filters.'), findsOneWidget);
        await tester.ensureVisible(find.byKey(const Key('model_hub_reset')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('model_hub_reset')));
        await tester.pumpAndSettle();
        expect(deps.modelHubController.state.searchQuery, isEmpty);
        await tester.scrollUntilVisible(
          find.byKey(const Key('model_hub_section_onDevice')),
          -250,
          scrollable: find
              .descendant(
                of: find.byKey(
                  const PageStorageKey<String>('model_hub_scroll'),
                ),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.tap(find.byKey(const Key('model_hub_section_onDevice')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('add_model_folder_button')),
          findsOneWidget,
        );
        await tester.tap(
          find.byKey(const Key('model_hub_section_huggingFace')),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('model_hub_search_hf')), findsOneWidget);
        expect(find.byKey(const Key('model_hub_capability')), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
