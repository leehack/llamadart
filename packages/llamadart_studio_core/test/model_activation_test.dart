import 'dart:async';

import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

import 'studio_test_fakes.dart';

void main() {
  for (final failure in <String?>[null, 'preparation', 'runtime']) {
    test(
      'activation is visible through preparation and load ($failure)',
      () async {
        final storage = _DelayedStorage();
        final inference = _DelayedInference();
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
        final descriptor = CuratedModelCatalog.models.first;
        final operation = hub.activateChatModel(descriptor);
        final expected = failure == null
            ? expectLater(operation, completes)
            : expectLater(operation, throwsStateError);

        expect(hub.state.activatingDescriptor, same(descriptor));
        expect(inference.loadEntered.isCompleted, isFalse);
        if (failure == 'preparation') {
          storage.preparation.completeError(StateError('Preparation failed'));
        } else {
          storage.preparation.complete();
          await inference.loadEntered.future;
          expect(hub.state.activatingDescriptor, same(descriptor));
          if (failure == 'runtime') {
            inference.loadFinished.completeError(StateError('Load failed'));
          } else {
            inference.loadFinished.complete();
          }
        }
        await expected;
        expect(hub.state.activatingDescriptor, isNull);
      },
    );
  }
  test('custom activation stays visible and clears on load failure', () async {
    final storage = FakeStudioStoragePort();
    final inference = _DelayedInference();
    final shell = StudioShellController(keyValueStore: InMemoryKeyValueStore());
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
    final operation = hub.loadCustomModel(pathOrUrl: '/models/custom.gguf');
    final expected = expectLater(operation, throwsStateError);
    expect(hub.state.activatingDescriptor?.filename, 'custom.gguf');
    await inference.loadEntered.future;
    expect(hub.state.activatingDescriptor?.filename, 'custom.gguf');
    inference.loadFinished.completeError(StateError('Load failed'));
    await expected;
    expect(hub.state.activatingDescriptor, isNull);
  });
}

class _DelayedStorage extends FakeStudioStoragePort {
  final Completer<void> preparation = Completer<void>();

  @override
  Future<ResolvedModelAssets> ensureDownloaded(
    StudioModelDescriptor descriptor, {
    required bool isWeb,
    String? bearerToken,
  }) async {
    await preparation.future;
    return super.ensureDownloaded(
      descriptor,
      isWeb: isWeb,
      bearerToken: bearerToken,
    );
  }
}

class _DelayedInference extends UnloadedThenReadyInferencePort {
  final Completer<void> loadEntered = Completer<void>();
  final Completer<void> loadFinished = Completer<void>();

  @override
  Future<void> loadModel({
    required ResolvedModelAssets assets,
    required StudioSettings settings,
    required bool isWeb,
  }) async {
    loadEntered.complete();
    await loadFinished.future;
    await super.loadModel(assets: assets, settings: settings, isWeb: isWeb);
  }

  @override
  Future<void> loadCustomSource({
    required StudioModelDescriptor descriptor,
    required StudioSettings settings,
    required bool isWeb,
  }) async {
    loadEntered.complete();
    await loadFinished.future;
  }
}
