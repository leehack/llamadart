import 'dart:async';
import 'dart:convert';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

import 'studio_test_fakes.dart';

const _url =
    'https://user:password@example.invalid/model.gguf?token=secret-canary#fragment-canary';

void main() {
  test('startup removes custom sources persisted by older reloads', () async {
    final kv = InMemoryKeyValueStore();
    await kv.writeString(
      'studio.settings.v1',
      jsonEncode(
        const StudioSettings()
            .copyWith(
              activeModelId: 'custom:$_url',
              modelPath: _url,
              mmprojPath:
                  'https://example.invalid/projector?token=projector-canary',
              contextSize: 8192,
            )
            .toJson(),
      ),
    );
    final shell = StudioShellController(keyValueStore: kv);
    await shell.initialize();
    expect(shell.currentSettings.activeModelId, isNull);
    expect(shell.currentSettings.modelPath, isNull);
    expect(shell.currentSettings.mmprojPath, isNull);
    expect(shell.currentSettings.contextSize, 8192);
    final saved = await kv.readString('studio.settings.v1');
    for (final secret in ['password', 'secret-canary', 'projector-canary']) {
      expect(saved, isNot(contains(secret)));
    }
    await shell.dispose();
  });

  test('boot recovery sanitizes current and legacy URL metadata', () async {
    final kv = InMemoryKeyValueStore();
    final guard = BootGuardService(kv);
    await guard.beginModelLoad(
      modelName: 'Model',
      modelIdOrPath: 'custom:$_url',
    );
    final stored = await kv.readString('studio.in_flight_model_load.v1');
    expect(stored, isNot(contains('secret-canary')));
    expect(stored, isNot(contains('password')));
    await kv.writeString(
      'studio.in_flight_model_load.v1',
      jsonEncode({'modelName': 'Model', 'modelIdOrPath': _url}),
    );
    final alert = await guard.inspectStartupAndClear();
    final recovered = Uri.parse(alert!.modelIdOrPath);
    expect(recovered.host, 'example.invalid');
    expect(recovered.path, '/model.gguf');
    expect(recovered.userInfo, isEmpty);
    expect(recovered.query, isEmpty);
    expect(recovered.fragment, isEmpty);
    expect(await kv.readString('studio.in_flight_model_load.v1'), isNull);
    await kv.writeString(
      'studio.in_flight_model_load.v1',
      'malformed password secret-canary',
    );
    expect((await guard.inspectStartupAndClear())!.modelIdOrPath, isEmpty);
  });

  test(
    'pending custom load persists no private URL in crash recovery',
    () async {
      final kv = InMemoryKeyValueStore();
      final shell = StudioShellController(keyValueStore: kv);
      await shell.initialize();
      final inference = _CustomInference()..pause = Completer<void>();
      final storage = FakeStudioStoragePort();
      final hub = _hub(storage, inference, shell);
      final loading = hub.loadCustomModel(pathOrUrl: _url);
      await inference.entered.future;
      final sentinel = await kv.readString('studio.in_flight_model_load.v1');
      inference.pause!.complete();
      await loading;
      await hub.dispose();
      await inference.dispose();
      await storage.dispose();
      await shell.dispose();
      expect(sentinel, isNotNull);
      for (final secret in ['password', 'secret-canary', 'fragment-canary']) {
        expect(sentinel, isNot(contains(secret)));
      }
    },
  );

  test(
    'Inspector reload keeps custom model and projector session-only',
    () async {
      final kv = InMemoryKeyValueStore();
      final shell = StudioShellController(keyValueStore: kv);
      await shell.initialize();
      await shell.updateSettings(
        (s) => s.copyWith(
          activeModelId: 'curated',
          modelPath: '/models/curated.gguf',
          contextSize: 8192,
        ),
      );
      final before = await kv.readString('studio.settings.v1');
      final inference = _CustomInference();
      final storage = FakeStudioStoragePort();
      final hub = _hub(storage, inference, shell);
      await hub.loadCustomModel(
        pathOrUrl: _url,
        mmprojPathOrUrl:
            'https://example.invalid/projector.gguf?token=projector-canary',
      );
      await hub.reloadActiveModel();
      expect(await kv.readString('studio.settings.v1'), before);
      expect(inference.customSources, [_url, _url]);
      expect(
        inference.projectorSources.last,
        'https://example.invalid/projector.gguf?token=projector-canary',
      );
      expect(inference.lastSettings!.contextSize, 8192);
      await hub.dispose();
      await inference.dispose();
      await storage.dispose();
      await shell.dispose();
    },
  );
}

ModelHubController _hub(
  FakeStudioStoragePort storage,
  StudioInferencePort inference,
  StudioShellController shell,
) => ModelHubController(
  deps: StudioStorageAndInferenceDeps(
    storagePort: storage,
    inferencePort: inference,
    shellController: shell,
  ),
  isWeb: true,
  isMobile: false,
);

class _CustomInference extends UnloadedThenReadyInferencePort {
  final entered = Completer<void>();
  Completer<void>? pause;
  final customSources = <String>[];
  final projectorSources = <String?>[];
  StudioSettings? lastSettings;
  @override
  Future<void> loadCustomSource({
    required StudioModelDescriptor descriptor,
    required StudioSettings settings,
    required bool isWeb,
  }) async {
    customSources.add(descriptor.sourceUri);
    projectorSources.add(descriptor.companions.firstOrNull?.sourceUri);
    lastSettings = settings;
    if (!entered.isCompleted) entered.complete();
    await pause?.future;
    await super.loadModel(
      assets: ResolvedModelAssets(
        descriptor: descriptor,
        primarySource: ModelSource.parse(descriptor.sourceUri),
      ),
      settings: settings,
      isWeb: isWeb,
    );
  }
}
