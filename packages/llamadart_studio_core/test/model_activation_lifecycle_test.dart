import 'dart:async';

import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

import 'studio_test_fakes.dart';

void main() {
  late _LoadInference inference;
  late _LoadStorage storage;
  late StudioShellController shell;
  late ModelHubController hub;

  setUp(() {
    inference = _LoadInference();
    storage = _LoadStorage();
    shell = StudioShellController(keyValueStore: InMemoryKeyValueStore());
    hub = ModelHubController(
      deps: StudioStorageAndInferenceDeps(
        storagePort: storage,
        inferencePort: inference,
        shellController: shell,
      ),
      isWeb: false,
      isMobile: false,
    );
  });

  tearDown(() async {
    await hub.dispose();
    await inference.dispose();
    await shell.dispose();
    await storage.dispose();
  });

  test('three queued activations never overlap native loads', () async {
    final models = CuratedModelCatalog.models
        .where((m) => m.category == StudioModelCategory.chat)
        .take(3)
        .toList();
    final first = hub.activateChatModel(models[0]);
    await inference.entered.future;
    final second = hub.activateChatModel(models[1]);
    final third = hub.activateChatModel(models[2]);
    inference.release.complete();
    await Future.wait([first, second, third]);
    expect(inference.maxConcurrentLoads, 1);
    expect(inference.loadedIds, models.map((m) => m.id));
  });

  test(
    'custom loads share the activation queue and unload follows them',
    () async {
      final model = CuratedModelCatalog.models.first;
      final first = hub.activateChatModel(model);
      await inference.entered.future;
      final custom = hub.loadCustomModel(pathOrUrl: '/models/custom.gguf');
      final unload = hub.unloadActiveModel();
      inference.release.complete();
      await Future.wait([first, custom, unload]);
      expect(inference.maxConcurrentLoads, 1);
      expect(inference.loadedIds, [model.id, 'custom:/models/custom.gguf']);
      expect(inference.unloadedWhileLoading, isFalse);
    },
  );

  test('disposal during download never starts a native load', () async {
    storage.download = Completer<void>();
    final operation = hub.activateChatModel(CuratedModelCatalog.models.first);
    await storage.entered.future;
    await hub.dispose();
    inference.release.complete();
    storage.download!.complete();
    await operation;
    expect(inference.loadedIds, isEmpty);
  });
}

class _LoadStorage extends FakeStudioStoragePort {
  Completer<void>? download;
  final entered = Completer<void>();

  @override
  Future<ResolvedModelAssets> ensureDownloaded(
    StudioModelDescriptor descriptor, {
    required bool isWeb,
    String? bearerToken,
  }) async {
    if (!entered.isCompleted) entered.complete();
    await download?.future;
    return super.ensureDownloaded(descriptor, isWeb: isWeb);
  }
}

class _LoadInference extends FakeInferencePort {
  final entered = Completer<void>();
  final release = Completer<void>();
  final loadedIds = <String>[];
  int concurrentLoads = 0;
  int maxConcurrentLoads = 0;
  bool unloadedWhileLoading = false;

  Future<void> _load(String id) async {
    loadedIds.add(id);
    concurrentLoads++;
    if (concurrentLoads > maxConcurrentLoads) {
      maxConcurrentLoads = concurrentLoads;
    }
    if (!entered.isCompleted) entered.complete();
    await release.future;
    await Future<void>.delayed(Duration.zero);
    concurrentLoads--;
  }

  @override
  Future<void> loadModel({
    required ResolvedModelAssets assets,
    required StudioSettings settings,
    required bool isWeb,
  }) => _load(assets.descriptor.id);

  @override
  Future<void> loadCustomSource({
    required StudioModelDescriptor descriptor,
    required StudioSettings settings,
    required bool isWeb,
  }) => _load(descriptor.id);

  @override
  Future<void> unloadModel() async {
    unloadedWhileLoading = concurrentLoads > 0;
  }
}
