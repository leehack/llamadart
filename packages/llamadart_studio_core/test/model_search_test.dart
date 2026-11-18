import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

import 'studio_test_fakes.dart';

void main() {
  test(
    'model search combines case insensitive terms across metadata',
    () async {
      final storage = FakeStudioStoragePort();
      final inference = FakeInferencePort();
      final shell = StudioShellController(
        keyValueStore: InMemoryKeyValueStore(),
      );
      final hub = ModelHubController(
        deps: StudioStorageAndInferenceDeps(
          storagePort: storage,
          inferencePort: inference,
          shellController: shell,
        ),
        isWeb: false,
        isMobile: false,
      );
      addTearDown(() async {
        await hub.dispose();
        await shell.dispose();
        await inference.dispose();
        await storage.dispose();
      });
      final all = hub.filteredCuratedModels();
      final model = all.firstWhere((m) => m.name.contains('Qwen3.8 27B'));
      hub.setSearchQuery('  QWEN   27b  ');
      expect(hub.filteredCuratedModels(), contains(model));
      hub.setSearchQuery('27b missing-token');
      expect(hub.filteredCuratedModels(), isEmpty);
      hub.setSearchQuery('   ');
      expect(hub.filteredCuratedModels(), all);
      hub.selectCategory(StudioModelCategory.image);
      hub.setSearchQuery('qwen 27b');
      expect(hub.filteredCuratedModels(), isEmpty);
    },
  );
}
