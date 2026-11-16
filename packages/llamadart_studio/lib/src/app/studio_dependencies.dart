import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'local_coding_workspace.dart';
import 'shared_prefs_store.dart';

/// Assembles all pure-Dart Studio controllers, ports, and native shutdown
/// coordination for a running `llamadart Studio` instance.
class StudioDependencies {
  /// Creates [StudioDependencies] from explicit controllers and ports.
  StudioDependencies({
    required this.shellController,
    required this.modelHubController,
    required this.chatController,
    required this.codingController,
    required this.speechController,
    required this.imageController,
    required this.labModelCoordinator,
    required this.notebookController,
    required this.playgroundController,
    required this.mcpManager,
    required this.skillRegistry,
    required this.lifecycleCoordinator,
    required this.isWeb,
    required this.isMobile,
    this.appDataDirectory,
  }) {
    lifecycleCoordinator.register(_disposeControllersAndMcp);
  }

  /// Global shell, workspace routing, and settings controller.
  final StudioShellController shellController;

  /// Curated catalog, Hugging Face search, and model cache controller.
  final ModelHubController modelHubController;

  /// Conversation branching, presets, and streaming chat controller.
  final ChatWorkspaceController chatController;

  /// Dedicated Coding workspace controller (repo browser, tools, MCP, skills).
  final CodingWorkspaceController codingController;

  /// Neural TTS and STT controller.
  final SpeechWorkspaceController speechController;

  /// Diffusion image generation controller.
  final ImageWorkspaceController imageController;

  /// Shared coordinator for dedicated Embedding, Reranker, and Decision models.
  final LabModelCoordinator labModelCoordinator;

  /// Multimodal Notebook & Semantic Vault controller.
  final NotebookController notebookController;

  /// Pairwise Embeddings, Reranker, Decision Engine, Tokenizer, and Benchmark controller.
  final PlaygroundWorkspaceController playgroundController;

  /// Live Model Context Protocol (`mcp_dart`) server & tool registry.
  final McpManager mcpManager;

  /// Built-in, filesystem-discovered, and custom `SKILL.md` skills registry.
  final SkillRegistry skillRegistry;

  /// Safe native engine release coordinator invoked before app exit.
  final StudioLifecycleCoordinator lifecycleCoordinator;

  /// Whether running in a WebGPU browser host.
  final bool isWeb;

  /// Whether running on iOS or Android.
  final bool isMobile;

  /// Application storage root for new local Coding workspaces.
  /// Defaults to Studio's path-provider application-support directory.
  final String? appDataDirectory;

  /// Creates an app-owned persistent Coding folder on iOS/Android.
  ///
  /// The caller selects the result through [codingController]. No existing
  /// workspace is replaced or selected by this operation.
  Future<String> createLocalCodingWorkspace() {
    if (isWeb || !isMobile) {
      throw UnsupportedError(
        'Local Coding workspace creation is available only on iOS and Android.',
      );
    }
    return createLocalCodingWorkspaceDirectory(
      appDataDirectory: appDataDirectory,
    );
  }

  /// Bootstraps production dependencies backed by `SharedPreferences`,
  /// `path_provider` application support storage, and `llamadart` native/Web
  /// engines.
  static Future<StudioDependencies> bootstrapProduction({
    String? appDataDirectoryOverride,
    List<String>? localModelRootsOverride,
    KeyValueStore? keyValueStoreOverride,
  }) async {
    final kvStore =
        keyValueStoreOverride ??
        SharedPreferencesKeyValueStore(await SharedPreferences.getInstance());

    const isWebHost = kIsWeb;
    final isMobileHost =
        !isWebHost &&
        (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.android);

    String? appDataPath = appDataDirectoryOverride;
    ModelDownloadManager? downloadManager;
    LocalModelScanner? localScanner;
    if (!isWebHost) {
      if (appDataPath == null) {
        final supportDir = await getApplicationSupportDirectory();
        appDataPath = '${supportDir.path}/llamadart_studio';
      }
      if (isMobileHost) {
        final privateCache = '$appDataPath/model_cache';
        DefaultModelDownloadManager.globalCacheDirectory = privateCache;
        downloadManager = DefaultModelDownloadManager.appPrivate(
          cacheDirectory: privateCache,
        );
        localScanner = LocalModelScanner(
          defaultRoots: localModelRootsOverride ?? <String>[privateCache],
        );
      } else {
        // Share the standard desktop cache (~/Library/Caches/llamadart/models,
        // ~/.cache/llamadart/models, %LOCALAPPDATA%\llamadart\Cache\models)
        // and scan ~/Library/Application Support/llamadart/models as well.
        DefaultModelDownloadManager.globalCacheDirectory = null;
        downloadManager = DefaultModelDownloadManager.auto();
        localScanner = LocalModelScanner(
          defaultRoots:
              localModelRootsOverride ??
              LocalModelScanner.defaultDesktopRoots(),
        );
      }
    }

    final storagePort = DefaultStudioModelStorageAdapter(
      downloadManager: downloadManager,
      localScanner: localScanner,
    );
    final inferencePort = DirectLlamaInferencePort(
      downloadManager: downloadManager,
    );
    final speechPort = DirectLlamaSpeechPort();
    final imagePort = DirectLlamaImagePort(
      requiresLinuxVulkan:
          !isWebHost && defaultTargetPlatform == TargetPlatform.linux,
    );
    final playgroundPort = DirectLlamaPlaygroundPort(
      sharedChatPort: inferencePort,
    );
    final conversationStore = createDefaultConversationStore(
      fallbackKeyValueStore: kvStore,
      directoryPath: appDataPath,
    );
    final noteStore = createDefaultNoteStore(
      fallbackKeyValueStore: kvStore,
      directoryPath: appDataPath,
    );

    return fromPorts(
      keyValueStore: kvStore,
      conversationStore: conversationStore,
      noteStore: noteStore,
      storagePort: storagePort,
      inferencePort: inferencePort,
      speechPort: speechPort,
      imagePort: imagePort,
      playgroundPort: playgroundPort,
      isWeb: isWebHost,
      isMobile: isMobileHost,
      appDataDirectory: appDataPath,
      autoLoadStarterOnFirstLaunch: keyValueStoreOverride == null,
      autoDetectCodingWorkspace: !isWebHost && !isMobileHost,
      autoConnectDefaultMcp: !isWebHost && !isMobileHost,
    );
  }

  /// Creates and initializes [StudioDependencies] from injected ports (used by
  /// both production startup and deterministic widget tests).
  static Future<StudioDependencies> fromPorts({
    required KeyValueStore keyValueStore,
    required StudioConversationStore conversationStore,
    StudioNoteStore? noteStore,
    McpManager? mcpManager,
    required StudioModelStoragePort storagePort,
    required StudioInferencePort inferencePort,
    required StudioSpeechPort speechPort,
    required StudioImagePort imagePort,
    required StudioPlaygroundPort playgroundPort,
    bool isWeb = false,
    bool isMobile = false,
    String? appDataDirectory,
    bool autoLoadStarterOnFirstLaunch = false,
    bool autoDetectCodingWorkspace = false,
    bool autoConnectDefaultMcp = false,
  }) async {
    final lifecycle = StudioLifecycleCoordinator();
    final shell = StudioShellController(keyValueStore: keyValueStore);
    await shell.initialize();

    final resolvedMcpManager =
        mcpManager ?? McpManager(keyValueStore: keyValueStore);
    final skillRegistry = SkillRegistry(keyValueStore: keyValueStore);

    final hub = ModelHubController(
      deps: StudioStorageAndInferenceDeps(
        storagePort: storagePort,
        inferencePort: inferencePort,
        shellController: shell,
      ),
      isWeb: isWeb,
      isMobile: isMobile,
      autoLoadStarterOnFirstLaunch: autoLoadStarterOnFirstLaunch,
    );
    late final CodingWorkspaceController coding;
    final chat = ChatWorkspaceController(
      conversationStore: conversationStore,
      inferencePort: inferencePort,
      shellController: shell,
      mcpManager: resolvedMcpManager,
      skillRegistry: skillRegistry,
      ensureModelReady: hub.ensureChatModelReady,
      workspaceInstructionsProvider: () =>
          coding.state.agentsContext.hasInstructions
          ? coding.state.agentsContext.instructions
          : null,
    );
    coding = CodingWorkspaceController(
      inferencePort: inferencePort,
      shellController: shell,
      keyValueStore: keyValueStore,
      mcpManager: resolvedMcpManager,
      skillRegistry: skillRegistry,
      ensureModelReady: hub.ensureChatModelReady,
      autoConnectWorkspaceMcp: autoConnectDefaultMcp,
      localProcessExecutionAvailable: !isWeb && !isMobile,
    );
    final speech = SpeechWorkspaceController(
      storagePort: storagePort,
      speechPort: speechPort,
      isWeb: isWeb,
      isMobile: isMobile,
    );
    final image = ImageWorkspaceController(
      storagePort: storagePort,
      imagePort: imagePort,
      isWeb: isWeb,
      isMobile: isMobile,
    );
    final labModels = LabModelCoordinator(
      storagePort: storagePort,
      modelLoader: playgroundPort,
      embeddingPort: playgroundPort,
      isWeb: isWeb,
      isMobile: isMobile,
    );
    final notebook = NotebookController(
      storagePort: storagePort,
      embeddingPort: playgroundPort,
      rerankerPort: playgroundPort,
      labModels: labModels,
      noteStore: noteStore,
      keyValueStore: keyValueStore,
      inferencePort: inferencePort,
      shellController: shell,
      sttPort: speechPort,
      ensureChatModelReady: hub.ensureChatModelReady,
      isWeb: isWeb,
      isMobile: isMobile,
    );
    final playground = PlaygroundWorkspaceController(
      storagePort: storagePort,
      playgroundPort: playgroundPort,
      labModels: labModels,
      notesProvider: () => notebook.state.notes,
      onNotesUpdated: notebook.applyAuditedNotes,
      ensureChatModelReady: hub.ensureChatModelReady,
      isWeb: isWeb,
      isMobile: isMobile,
    );

    lifecycle
      ..register(storagePort.dispose)
      ..register(playgroundPort.dispose)
      ..register(imagePort.dispose)
      ..register(speechPort.dispose)
      ..register(inferencePort.dispose);

    await Future.wait(<Future<void>>[
      resolvedMcpManager.initialize(),
      skillRegistry.initialize(),
      chat.initialize(),
      hub.initialize(),
      image.initialize(),
      notebook.initialize(),
    ]);
    await coding.initialize(autoDetectDefaultRoot: autoDetectCodingWorkspace);
    if (!isWeb && autoConnectDefaultMcp) {
      unawaited(
        resolvedMcpManager.ensureBuiltInDartFlutterServer(
          workspaceRoot: coding.state.workspaceRoot,
          autoConnect: true,
        ),
      );
    }

    return StudioDependencies(
      shellController: shell,
      modelHubController: hub,
      chatController: chat,
      codingController: coding,
      speechController: speech,
      imageController: image,
      labModelCoordinator: labModels,
      notebookController: notebook,
      playgroundController: playground,
      mcpManager: resolvedMcpManager,
      skillRegistry: skillRegistry,
      lifecycleCoordinator: lifecycle,
      isWeb: isWeb,
      isMobile: isMobile,
      appDataDirectory: appDataDirectory,
    );
  }

  /// Disposes all controllers and native engines cleanly.
  Future<void> dispose() => lifecycleCoordinator.shutdownAll();

  Future<void> _disposeControllersAndMcp() async {
    // Signal cancellation before closing MCP, but do not join an async*
    // subscription until MCP has released the tool handler it may await.
    final controllers = _disposeControllers();
    final mcp = mcpManager.dispose();
    await Future.wait(<Future<void>>[controllers, mcp]);
  }

  Future<void> _disposeControllers() async {
    await Future.wait(<Future<void>>[
      codingController.dispose(),
      chatController.dispose(),
      modelHubController.dispose(),
      speechController.dispose(),
      imageController.dispose(),
      notebookController.dispose(),
      playgroundController.dispose(),
      labModelCoordinator.dispose(),
      skillRegistry.dispose(),
      shellController.dispose(),
    ]);
  }
}

/// Inherited dependency scope exposing [StudioDependencies] down the widget tree.
class StudioScope extends InheritedWidget {
  /// Creates a [StudioScope].
  const StudioScope({super.key, required this.deps, required super.child});

  /// Active dependency bundle.
  final StudioDependencies deps;

  /// Looks up [StudioDependencies] from the nearest ancestor [StudioScope].
  static StudioDependencies of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<StudioScope>();
    assert(scope != null, 'No StudioScope found in widget tree.');
    return scope!.deps;
  }

  @override
  bool updateShouldNotify(covariant StudioScope oldWidget) =>
      !identical(oldWidget.deps, deps);
}
