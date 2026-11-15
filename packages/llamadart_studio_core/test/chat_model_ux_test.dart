import 'dart:async';

import 'package:llamadart/backend.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

import 'studio_test_fakes.dart';

void main() {
  test('drafts follow conversations and busy handoffs never send', () async {
    final kv = InMemoryKeyValueStore();
    final shell = StudioShellController(keyValueStore: kv);
    final inference = _PausedInference();
    final chat = ChatWorkspaceController(
      conversationStore: KeyValueConversationStore(kv),
      inferencePort: inference,
      shellController: shell,
    );
    addTearDown(() async {
      await chat.dispose();
      await inference.dispose();
      await shell.dispose();
    });
    await chat.initialize();
    final first = chat.state.activeConversationId!;
    chat.setComposerDraft('first unsent');
    final second = await chat.createConversation();
    expect(chat.state.composerDraft, isNull);
    chat.setComposerDraft('second unsent');
    chat.selectConversation(first);
    expect(chat.state.composerDraft, 'first unsent');
    final pending = chat.sendMessage('first unsent');
    await inference.entered.future;
    expect(chat.state.composerDraft, isNull);
    chat.setComposerDraft('next prompt');
    chat.stageDraft('speech transcript');
    expect(chat.state.composerDraft, 'next prompt\n\nspeech transcript');
    expect(inference.calls, 1);
    inference.finished.complete();
    await pending;
    expect(chat.state.composerDraft, 'next prompt\n\nspeech transcript');
    chat.selectConversation(second.id);
    expect(chat.state.composerDraft, 'second unsent');
    chat.selectConversation(first);
    chat.setComposerDraft('');
    chat.selectConversation(second.id);
    chat.selectConversation(first);
    expect(chat.state.composerDraft, isNull);
  });

  for (final switchConversation in <bool>[false, true]) {
    test(
      'saving a sent message preserves a newer draft (switch=$switchConversation)',
      () async {
        final kv = InMemoryKeyValueStore();
        final conversations = _GatedConversationStore(kv);
        final shell = StudioShellController(keyValueStore: kv);
        final inference = _PausedInference();
        final chat = ChatWorkspaceController(
          conversationStore: conversations,
          inferencePort: inference,
          shellController: shell,
        );
        addTearDown(() async {
          await chat.dispose();
          await inference.dispose();
          await shell.dispose();
        });
        await chat.initialize();
        final first = chat.state.activeConversationId!;
        final second = await chat.createConversation();
        chat.selectConversation(first);
        chat.setComposerDraft('sent prompt');
        conversations.delayNextSave = true;
        final send = chat.sendMessage('sent prompt');
        await conversations.entered.future;
        if (switchConversation) chat.selectConversation(second.id);
        chat.setComposerDraft('new draft while saving');
        conversations.finish.complete();
        await inference.entered.future;
        expect(chat.state.composerDraft, 'new draft while saving');
        inference.finished.complete();
        await send;
        expect(chat.state.composerDraft, 'new draft while saving');
        if (switchConversation) {
          chat.selectConversation(first);
          expect(chat.state.composerDraft, isNull);
          chat.selectConversation(second.id);
          expect(chat.state.composerDraft, 'new draft while saving');
        }
      },
    );
  }

  for (final lateFailure in <bool>[false, true]) {
    test('late HF search A cannot replace B (error=$lateFailure)', () async {
      final hf = _GatedHf();
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
        hfService: hf,
      );
      addTearDown(() async {
        await hub.dispose();
        await storage.dispose();
        await inference.dispose();
        await shell.dispose();
      });
      final a = hub.searchHuggingFace('A');
      final b = hub.searchHuggingFace('B');
      const bHit = HuggingFaceRepoHit(
        repoId: 'owner/B',
        downloads: 1,
        likes: 1,
      );
      hf.searches['B']!.complete(<HuggingFaceRepoHit>[bHit]);
      await b;
      if (lateFailure) {
        hf.searches['A']!.completeError(StateError('A unavailable'));
      } else {
        hf.searches['A']!.complete(<HuggingFaceRepoHit>[
          const HuggingFaceRepoHit(repoId: 'owner/A', downloads: 1, likes: 1),
        ]);
      }
      await a;
      expect(hub.state.searchQuery, 'B');
      expect(hub.state.hfResults, <HuggingFaceRepoHit>[bHit]);
      expect(hub.state.hfErrorMessage, isNull);
      expect(hub.state.isSearchingHf, isFalse);
      final disposedSearch = hub.searchHuggingFace('disposed');
      await hub.dispose();
      hf.searches['disposed']!.completeError(StateError('disposed request'));
      await disposedSearch;
      expect(hub.state.hfErrorMessage, isNull);
    });
  }

  for (final lateFailure in <bool>[false, true]) {
    test('late HF A response cannot replace B (error=$lateFailure)', () async {
      final hf = _GatedHf();
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
        hfService: hf,
      );
      addTearDown(() async {
        await hub.dispose();
        await storage.dispose();
        await inference.dispose();
        await shell.dispose();
      });
      final a = hub.expandHuggingFaceRepo('owner/A');
      final b = hub.expandHuggingFaceRepo('owner/B');
      final bFile = CuratedModelCatalog.models.last;
      hf.requests['owner/B']!.complete(<StudioModelDescriptor>[bFile]);
      await b;
      if (lateFailure) {
        hf.requests['owner/A']!.completeError(StateError('A unavailable'));
      } else {
        hf.requests['owner/A']!.complete(<StudioModelDescriptor>[
          CuratedModelCatalog.models.first,
        ]);
      }
      await a;
      expect(hub.state.expandedRepoId, 'owner/B');
      expect(hub.state.expandedRepoFiles, <StudioModelDescriptor>[bFile]);
      expect(hub.state.hfErrorMessage, isNull);
      final collapsed = hub.expandHuggingFaceRepo('owner/A');
      await hub.expandHuggingFaceRepo('owner/A');
      hf.requests['owner/A']!.complete(<StudioModelDescriptor>[bFile]);
      await collapsed;
      expect(hub.state.expandedRepoId, isNull);
      expect(hub.state.expandedRepoFiles, isEmpty);
      expect(hub.state.isSearchingHf, isFalse);
    });
  }

  test(
    'runtime transfer becomes indeterminate during initialization',
    () async {
      final backend = _UrlProgressBackend();
      final port = DirectLlamaInferencePort(backend: backend);
      addTearDown(port.dispose);
      const descriptor = StudioModelDescriptor(
        id: 'remote',
        name: 'Remote',
        description: 'Test',
        category: StudioModelCategory.chat,
        filename: 'model.gguf',
        sourceUri: 'https://example.com/model.gguf',
      );
      final load = port.loadModel(
        assets: ResolvedModelAssets(
          descriptor: descriptor,
          primarySource: descriptor.primarySource(isWeb: true),
        ),
        settings: const StudioSettings(),
        isWeb: true,
      );
      await backend.entered.future;
      expect(port.runtimeStore.state.isLoading, isTrue);
      expect(port.runtimeStore.state.loadProgressFraction, isNull);
      backend.progress!(.42);
      expect(port.runtimeStore.state.loadProgressFraction, .42);
      expect(port.runtimeStore.state.statusMessage, contains('Downloading'));
      backend.progress!(1);
      expect(port.runtimeStore.state.loadProgressFraction, isNull);
      expect(port.runtimeStore.state.statusMessage, contains('Initializing'));
      expect(port.runtimeStore.state.isReady, isFalse);
      backend.finishTransfer.complete();
      await backend.initializing.future;
      expect(port.runtimeStore.state.isReady, isFalse);
      backend.finishInitialization.complete();
      await load;
      expect(port.runtimeStore.state.isReady, isTrue);
    },
  );

  test('load errors redact credentials and retry the same model', () async {
    final inference = _RetryInference();
    final storage = FakeStudioStoragePort();
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
      await storage.dispose();
      await inference.dispose();
      await shell.dispose();
    });
    hub.setBearerToken('hf_example_secret');
    final descriptor = CuratedModelCatalog.models.first;
    await expectLater(hub.activateChatModel(descriptor), throwsStateError);
    expect(hub.state.activationErrorMessage, contains('access denied'));
    expect(
      hub.state.activationErrorMessage,
      isNot(contains('hf_example_secret')),
    );
    expect(hub.state.activationErrorMessage, isNot(contains('signed-secret')));
    expect(hub.state.activationErrorMessage, isNot(contains('password')));
    inference.fail = false;
    await hub.retryLastChatModelLoad();
    expect(inference.runtimeStore.state.activeDescriptor?.id, descriptor.id);
    expect(hub.state.activationErrorMessage, isNull);
    expect(inference.calls, 2);
    inference.fail = true;
    await expectLater(
      hub.loadCustomModel(pathOrUrl: '/tmp/custom.gguf'),
      throwsStateError,
    );
    expect(hub.state.activationErrorMessage, contains('access denied'));
    inference.fail = false;
    await hub.retryLastChatModelLoad();
    expect(inference.customPath, '/tmp/custom.gguf');
    expect(hub.state.activationErrorMessage, isNull);
    inference.fail = true;
    await expectLater(hub.reloadActiveModel(), throwsStateError);
    expect(hub.state.activationErrorMessage, contains('access denied'));
  });

  test(
    'Web URL resolution does not report ready or cached before runtime fetch',
    () async {
      final storage = DefaultStudioModelStorageAdapter();
      final events = <StudioModelDownloadProgress>[];
      final subscription = storage.progressStream.listen(events.add);
      addTearDown(() async {
        await subscription.cancel();
        await storage.dispose();
      });
      final descriptor = CuratedModelCatalog.models.firstWhere(
        (m) => m.primarySource(isWeb: true).isRemote,
      );
      final assets = await storage.ensureDownloaded(descriptor, isWeb: true);
      await Future<void>.delayed(Duration.zero);
      expect(assets.primarySource.isRemote, isTrue);
      expect(events, isEmpty);
      expect(await storage.isCached(descriptor, isWeb: true), isFalse);
    },
  );
}

class _PausedInference extends FakeInferencePort {
  final entered = Completer<void>();
  final finished = Completer<void>();
  int calls = 0;
  @override
  Stream<StudioTurnEvent> streamTurn(StudioTurnRequest request) async* {
    calls++;
    entered.complete();
    await finished.future;
    yield const StudioTextDeltaEvent('done');
  }
}

class _GatedConversationStore extends KeyValueConversationStore {
  _GatedConversationStore(super.store);

  bool delayNextSave = false;
  final entered = Completer<void>();
  final finish = Completer<void>();

  @override
  Future<void> save(StudioConversation conversation) async {
    if (delayNextSave) {
      delayNextSave = false;
      entered.complete();
      await finish.future;
    }
    await super.save(conversation);
  }
}

class _GatedHf extends HuggingFaceDiscoveryService {
  final searches = <String, Completer<List<HuggingFaceRepoHit>>>{};

  @override
  Future<List<HuggingFaceRepoHit>> searchRepositories(
    String query, {
    int limit = 16,
    String? bearerToken,
  }) {
    return (searches[query] = Completer<List<HuggingFaceRepoHit>>()).future;
  }

  final requests = <String, Completer<List<StudioModelDescriptor>>>{};
  @override
  Future<List<StudioModelDescriptor>> inspectRepositoryFiles(
    String repoId, {
    String? bearerToken,
  }) {
    return (requests[repoId] = Completer<List<StudioModelDescriptor>>()).future;
  }
}

class _RetryInference extends UnloadedThenReadyInferencePort {
  bool fail = true;
  int calls = 0;
  String? customPath;
  void check() {
    calls++;
    if (fail) {
      throw StateError(
        'access denied Bearer hf_example_secret https://user:password@example.com/model?token=signed-secret#private',
      );
    }
  }

  @override
  Future<void> loadModel({
    required ResolvedModelAssets assets,
    required StudioSettings settings,
    required bool isWeb,
  }) async {
    check();
    await super.loadModel(assets: assets, settings: settings, isWeb: isWeb);
  }

  @override
  Future<void> loadCustomSource({
    required StudioModelDescriptor descriptor,
    required StudioSettings settings,
    required bool isWeb,
  }) async {
    check();
    customPath = descriptor.sourceUri;
  }
}

class _UrlProgressBackend extends FakeSpeculativeFallbackBackend
    implements BackendRuntimeIdentity {
  @override
  LlamaRuntime get runtime => LlamaRuntime.llamaCpp;
  final entered = Completer<void>();
  final finishTransfer = Completer<void>();
  final initializing = Completer<void>();
  final finishInitialization = Completer<void>();
  void Function(double)? progress;
  @override
  bool get supportsUrlLoading => true;
  @override
  Future<int> modelLoadFromUrl(
    String url,
    ModelParams params, {
    void Function(double)? onProgress,
  }) async {
    progress = onProgress;
    entered.complete();
    await finishTransfer.future;
    return super.modelLoad(url, params);
  }

  @override
  Future<int> contextCreate(int modelHandle, ModelParams params) async {
    initializing.complete();
    await finishInitialization.future;
    return super.contextCreate(modelHandle, params);
  }
}
