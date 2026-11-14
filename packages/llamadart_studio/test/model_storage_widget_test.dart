// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio/llamadart_studio.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

import 'studio_widget_test_helpers.dart';

class _Storage extends FakeStoragePort {
  final List<String> removed = <String>[];
  final List<ModelCacheEntry> entries = <ModelCacheEntry>[
    for (final name in <String>['large', 'small'])
      ModelCacheEntry(
        sourceCanonicalKey: 'https://example.com/$name.gguf',
        cacheKey: name,
        fileName: '$name.gguf',
        filePath: '/models/$name.gguf',
        bytes: (name == 'large' ? 2 : 1) * 1024 * 1024 * 1024,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      ),
  ];
  @override
  List<StudioModelDescriptor> get discoveredLocalModels =>
      const <StudioModelDescriptor>[
        StudioModelDescriptor(
          id: 'managed-local',
          name: 'Managed duplicate',
          publisher: 'Local',
          description: '',
          category: StudioModelCategory.chat,
          filename: 'large.gguf',
          sourceUri: '/models/large.gguf',
          sizeBytes: 2 * 1024 * 1024 * 1024,
        ),
        StudioModelDescriptor(
          id: 'external',
          name: 'External model',
          publisher: 'Local',
          description: '',
          category: StudioModelCategory.chat,
          filename: 'external.gguf',
          sourceUri: '/external/external.gguf',
          sizeBytes: 4 * 1024 * 1024 * 1024,
        ),
      ];
  @override
  Future<List<StudioModelDescriptor>> refreshLocalModels({
    List<String> extraDirectories = const <String>[],
  }) async => discoveredLocalModels;
  @override
  Future<List<ModelCacheEntry>> listCachedEntries() async => entries;
  @override
  Future<void> removeCacheEntry(String cacheKey) async {
    removed.add(cacheKey);
    entries.removeWhere((e) => e.cacheKey == cacheKey);
  }
}

class _IdleInference extends FakeInferencePort {
  final StateStore<StudioRuntimeSnapshot> runtime =
      StateStore<StudioRuntimeSnapshot>(const StudioRuntimeSnapshot());
  @override
  ReadOnlyStore<StudioRuntimeSnapshot> get runtimeStore => runtime;
  @override
  Future<void> dispose() async {
    await runtime.dispose();
    await super.dispose();
  }
}

void main() {
  testWidgets(
    'storage separates sizes and requires confirmation before removal',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1100, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final storage = _Storage();
      final deps = await buildTestDeps(
        storagePort: storage,
        inferencePort: _IdleInference(),
      );
      addTearDown(deps.dispose);
      await tester.pumpWidget(LlamadartStudioApp(dependencies: deps));
      await tester.pumpAndSettle();
      deps.shellController.selectWorkspace(StudioWorkspace.models);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('open_cache_sheet_button')));
      await tester.pumpAndSettle();
      expect(find.text('3.00 GiB in downloaded files'), findsOneWidget);
      expect(
        find.text('2 managed files · 1 additional local models'),
        findsOneWidget,
      );
      await tester.enterText(find.byKey(const Key('storage_search')), 'large');
      await tester.pumpAndSettle();
      expect(find.text('small.gguf'), findsNothing);
      await tester.tap(find.text('large.gguf'));
      await tester.pumpAndSettle();
      final remove = find.byKey(const Key('storage_remove_large'));
      await tester.ensureVisible(remove);
      await tester.tap(remove);
      await tester.pumpAndSettle();
      expect(find.text('Remove downloaded file?'), findsOneWidget);
      expect(storage.removed, isEmpty);
      await tester.tap(find.text('Keep file'));
      await tester.pumpAndSettle();
      expect(storage.removed, isEmpty);
      await tester.tap(remove);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove file'));
      await tester.pumpAndSettle();
      expect(storage.removed, <String>['large']);
      await tester.drag(
        find.byKey(const Key('storage_file_list')),
        const Offset(0, 1000),
      );
      await tester.pumpAndSettle();
      expect(find.text('1.00 GiB in downloaded files'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('storage protects loaded files at narrow width', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final storage = _Storage();
    final deps = await buildTestDeps(storagePort: storage);
    addTearDown(deps.dispose);
    await tester.pumpWidget(LlamadartStudioApp(dependencies: deps));
    await tester.pumpAndSettle();
    deps.shellController.selectWorkspace(StudioWorkspace.models);
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const Key('open_cache_sheet_button')),
    );
    await tester.tap(find.byKey(const Key('open_cache_sheet_button')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Unload active models'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('large.gguf'),
      150,
      scrollable: find
          .descendant(
            of: find.byKey(const Key('storage_file_list')),
            matching: find.byType(Scrollable),
          )
          .first,
    );

    await tester.tap(find.text('large.gguf'));
    await tester.pumpAndSettle();
    final remove = find.byKey(const Key('storage_remove_large'));
    await tester.ensureVisible(remove);
    expect(tester.widget<TextButton>(remove).onPressed, isNull);
    expect(storage.removed, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
