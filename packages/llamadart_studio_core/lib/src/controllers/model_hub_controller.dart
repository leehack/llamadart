import 'dart:async';
import 'dart:math' as math;

import 'package:llamadart/llamadart.dart';
import 'package:meta/meta.dart';

import '../adapters/curated_studio_model_catalog.dart';
import '../domain/studio_model_descriptor.dart';
import '../domain/studio_runtime_snapshot.dart';
import '../ports/inference_port.dart';
import '../ports/model_storage_port.dart';
import '../ports/studio_context_ports.dart';
import '../reactive/state_store.dart';
import '../services/discovery/hugging_face_discovery_service.dart';
import '../services/discovery/memory_fit_estimator.dart';

/// Immutable state for the Model Hub & Cache Manager workspace.
@immutable
class ModelHubState {
  /// Creates a [ModelHubState].
  const ModelHubState({
    this.selectedCategory,
    this.searchQuery = '',
    this.hfResults = const <HuggingFaceRepoHit>[],
    this.expandedRepoId,
    this.expandedRepoFiles = const <StudioModelDescriptor>[],
    this.isSearchingHf = false,
    this.hfErrorMessage,
    this.downloadsByModelId = const <String, StudioModelDownloadProgress>{},
    this.cachedModelIds = const <String>{},
    this.localModels = const <StudioModelDescriptor>[],
    this.localDiscoveredBytes = 0,
    this.cacheEntries = const <ModelCacheEntry>[],
    this.bearerToken = '',
    this.activatingDescriptor,
  });

  /// Active category filter (`null` = all categories).
  final StudioModelCategory? selectedCategory;

  /// Search filter or Hugging Face repository query.
  final String searchQuery;

  /// Live Hugging Face search results.
  final List<HuggingFaceRepoHit> hfResults;

  /// Currently expanded Hugging Face repo ID (`owner/repo`).
  final String? expandedRepoId;

  /// Compatible `.gguf`/`.litertlm` files inside [expandedRepoId].
  final List<StudioModelDescriptor> expandedRepoFiles;

  /// Whether a Hugging Face API request is running.
  final bool isSearchingHf;

  /// Optional Hugging Face search error message.
  final String? hfErrorMessage;

  /// Active or completed download snapshots keyed by `modelId`.
  final Map<String, StudioModelDownloadProgress> downloadsByModelId;

  /// Set of curated/custom `modelId`s verified on local disk.
  final Set<String> cachedModelIds;

  /// Standalone local `.gguf`/`.litertlm` models discovered across local cache
  /// and user-configured folders.
  final List<StudioModelDescriptor> localModels;

  /// Total unique bytes discovered across local model directories.
  final int localDiscoveredBytes;

  /// Raw cache entries for the Storage & Prune drawer.
  final List<ModelCacheEntry> cacheEntries;

  /// Optional Hugging Face access token for gated repositories.
  final String bearerToken;

  /// Model being prepared or loaded, including file and settings preparation.
  final StudioModelDescriptor? activatingDescriptor;

  /// Total disk usage across managed [cacheEntries] and discovered local files.
  int get totalCacheBytes {
    final managed = cacheEntries.fold<int>(
      0,
      (int sum, ModelCacheEntry entry) => sum + (entry.bytes ?? 0),
    );
    return math.max(managed, localDiscoveredBytes);
  }

  /// Returns an updated copy of [ModelHubState].
  ModelHubState copyWith({
    StudioModelCategory? selectedCategory,
    bool clearSelectedCategory = false,
    String? searchQuery,
    List<HuggingFaceRepoHit>? hfResults,
    String? expandedRepoId,
    bool clearExpandedRepoId = false,
    List<StudioModelDescriptor>? expandedRepoFiles,
    bool? isSearchingHf,
    String? hfErrorMessage,
    bool clearHfErrorMessage = false,
    Map<String, StudioModelDownloadProgress>? downloadsByModelId,
    Set<String>? cachedModelIds,
    List<StudioModelDescriptor>? localModels,
    int? localDiscoveredBytes,
    List<ModelCacheEntry>? cacheEntries,
    String? bearerToken,
    StudioModelDescriptor? activatingDescriptor,
    bool clearActivatingDescriptor = false,
  }) {
    return ModelHubState(
      selectedCategory: clearSelectedCategory
          ? null
          : (selectedCategory ?? this.selectedCategory),
      searchQuery: searchQuery ?? this.searchQuery,
      hfResults: hfResults ?? this.hfResults,
      expandedRepoId: clearExpandedRepoId
          ? null
          : (expandedRepoId ?? this.expandedRepoId),
      expandedRepoFiles: expandedRepoFiles ?? this.expandedRepoFiles,
      isSearchingHf: isSearchingHf ?? this.isSearchingHf,
      hfErrorMessage: clearHfErrorMessage
          ? null
          : (hfErrorMessage ?? this.hfErrorMessage),
      downloadsByModelId: downloadsByModelId ?? this.downloadsByModelId,
      cachedModelIds: cachedModelIds ?? this.cachedModelIds,
      localModels: localModels ?? this.localModels,
      localDiscoveredBytes: localDiscoveredBytes ?? this.localDiscoveredBytes,
      cacheEntries: cacheEntries ?? this.cacheEntries,
      bearerToken: bearerToken ?? this.bearerToken,
      activatingDescriptor: clearActivatingDescriptor
          ? null
          : (activatingDescriptor ?? this.activatingDescriptor),
    );
  }
}

/// Coordinates curated model discovery, local cache scanning, Hugging Face Hub
/// browsing, package-cache downloads/pruning, VRAM fit estimation, and
/// crash-guarded chat model loading.
class ModelHubController {
  /// Creates a [ModelHubController].
  ModelHubController({
    required StudioStorageAndInferenceDeps deps,
    required this.isWeb,
    required this.isMobile,
    this.autoLoadStarterOnFirstLaunch = false,
    HuggingFaceDiscoveryService? hfService,
    StudioModelCatalog modelCatalog = const CuratedStudioModelCatalog(),
  }) : _storage = deps.storagePort,
       _inference = deps.inferencePort,
       _shell = deps.shellController,
       _hf = hfService ?? HuggingFaceDiscoveryService(),
       _catalog = modelCatalog {
    _progressSub = _storage.progressStream.listen(_onDownloadProgress);
  }

  final StudioModelStoragePort _storage;
  final StudioInferencePort _inference;
  final StudioModelHubSettingsPort _shell;
  final HuggingFaceDiscoveryService _hf;
  final StudioModelCatalog _catalog;

  /// Whether running in a browser/WebGPU host.
  final bool isWeb;

  /// Whether running on iOS or Android.
  final bool isMobile;

  /// Whether first launch (when `activeModelId == null`) should automatically
  /// load the best cached chat model when `autoLoadLastModel` is enabled.
  final bool autoLoadStarterOnFirstLaunch;

  final StateStore<ModelHubState> _store = StateStore<ModelHubState>(
    const ModelHubState(),
  );
  StreamSubscription<StudioModelDownloadProgress>? _progressSub;
  Future<void>? _inFlightActivation;

  /// Reactive Model Hub state store.
  ReadOnlyStore<ModelHubState> get store => _store;

  /// Current Model Hub state snapshot.
  ModelHubState get state => _store.state;

  /// Reactive runtime/hardware snapshot store from [StudioInferencePort].
  ReadOnlyStore<StudioRuntimeSnapshot> get runtimeStore =>
      _inference.runtimeStore;

  /// Probes hardware diagnostics, scans local caches, and optionally restores
  /// the previously active (or best cached starter) chat model when safe.
  Future<void> initialize() async {
    await _inference.refreshHardwareDiagnostics();
    await refreshCacheInventory();

    final settings = _shell.currentSettings;
    if (!settings.autoLoadLastModel) {
      return;
    }
    if (settings.activeModelId != null) {
      final descriptor =
          _catalog.byId(settings.activeModelId) ??
          _findLocalById(settings.activeModelId!);
      if (descriptor != null &&
          descriptor.category == StudioModelCategory.chat) {
        final cached = await _storage.isCached(descriptor, isWeb: isWeb);
        if (cached) {
          unawaited(activateChatModel(descriptor, applyModelPreset: false));
          return;
        }
      }
    }
    if (autoLoadStarterOnFirstLaunch) {
      final starter = bestAutoLoadChatModel();
      if (starter != null) {
        unawaited(activateChatModel(starter, applyModelPreset: true));
      }
    }
  }

  /// Returns all locally cached/discovered chat models supported on this host,
  /// ordered with recommended curated models first, then other cached curated
  /// models, then standalone discovered local models.
  List<StudioModelDescriptor> installedChatModels() {
    final s = _store.state;
    final seenFilenames = <String>{};
    final result = <StudioModelDescriptor>[];

    final curatedChat =
        _catalog
            .forCategory(
              StudioModelCategory.chat,
              isWeb: isWeb,
              isMobile: isMobile,
            )
            .where((StudioModelDescriptor m) => s.cachedModelIds.contains(m.id))
            .toList()
          ..sort((StudioModelDescriptor a, StudioModelDescriptor b) {
            if (a.isRecommended != b.isRecommended) {
              return a.isRecommended ? -1 : 1;
            }
            return a.sizeBytes.compareTo(b.sizeBytes);
          });

    for (final m in curatedChat) {
      seenFilenames.add(m.filename.toLowerCase());
      result.add(m);
    }

    for (final local in s.localModels) {
      if (local.category != StudioModelCategory.chat) {
        continue;
      }
      if (!local.isSupportedOn(isWeb: isWeb, isMobile: isMobile)) {
        continue;
      }
      if (seenFilenames.contains(local.filename.toLowerCase())) {
        continue;
      }
      seenFilenames.add(local.filename.toLowerCase());
      result.add(local);
    }
    return result;
  }

  /// Picks the best cached chat model that safely fits hardware memory.
  StudioModelDescriptor? bestAutoLoadChatModel() {
    final activeId = _shell.currentSettings.activeModelId;
    final candidates = installedChatModels();
    if (candidates.isEmpty) {
      return null;
    }
    if (activeId != null) {
      for (final c in candidates) {
        if (c.id == activeId) {
          return c;
        }
      }
    }
    final fitting = candidates
        .where(
          (StudioModelDescriptor c) =>
              evaluateFit(c).status != MemoryFitStatus.exceedsMemory,
        )
        .toList(growable: false);
    if (fitting.isNotEmpty) {
      return fitting.first;
    }
    return candidates.first;
  }

  /// Ensures a chat model is loaded before sending a message, automatically
  /// activating [bestAutoLoadChatModel] when one is already cached on disk.
  Future<bool> ensureChatModelReady() async {
    if (_inference.runtimeStore.state.isReady) {
      return true;
    }
    final pending = _inFlightActivation;
    if (pending != null) {
      try {
        await pending;
      } catch (_) {}
      return _inference.runtimeStore.state.isReady;
    }
    if (_store.state.cachedModelIds.isEmpty &&
        _store.state.localModels.isEmpty) {
      await refreshCacheInventory();
    }
    final candidate = bestAutoLoadChatModel();
    if (candidate == null) {
      return false;
    }
    try {
      await activateChatModel(
        candidate,
        applyModelPreset: _shell.currentSettings.activeModelId == null,
      );
    } catch (_) {
      return false;
    }
    return _inference.runtimeStore.state.isReady;
  }

  StudioModelDescriptor? _findLocalById(String id) {
    for (final model in _store.state.localModels) {
      if (model.id == id) {
        return model;
      }
    }
    return null;
  }

  /// Returns discovered standalone local models filtered by category & query.
  List<StudioModelDescriptor> filteredLocalModels() {
    final s = _store.state;
    final base = s.localModels
        .where(
          (StudioModelDescriptor m) =>
              s.selectedCategory == null || m.category == s.selectedCategory,
        )
        .where(
          (StudioModelDescriptor m) =>
              m.isSupportedOn(isWeb: isWeb, isMobile: isMobile),
        )
        .toList(growable: false);
    return base
        .where((m) => _matchesSearch(m, s.searchQuery))
        .toList(growable: false);
  }

  /// Returns curated models filtered by active category, search text, and host.
  List<StudioModelDescriptor> filteredCuratedModels() {
    final s = _store.state;
    final base = _catalog.forCategory(
      s.selectedCategory,
      isWeb: isWeb,
      isMobile: isMobile,
    );
    return base
        .where((m) => _matchesSearch(m, s.searchQuery))
        .toList(growable: false);
  }

  static bool _matchesSearch(StudioModelDescriptor model, String query) {
    final terms = query.trim().toLowerCase().split(RegExp(r'\s+'));
    final text =
        '${model.name} ${model.description} ${model.publisher} ${model.filename} ${model.quantizationLabel ?? ''}'
            .toLowerCase();
    return terms.every(text.contains);
  }

  /// Registers a custom local model directory to scan and refreshes inventory.
  Future<void> addCustomModelDirectory(String directoryPath) async {
    final clean = directoryPath.trim();
    if (clean.isEmpty) {
      return;
    }
    final existing = _shell.currentSettings.customModelDirectories;
    if (!existing.contains(clean)) {
      await _shell.updateSettings(
        (s) => s.copyWith(customModelDirectories: <String>[...existing, clean]),
      );
    }
    await refreshCacheInventory();
  }

  /// Removes a custom local model directory and refreshes inventory.
  Future<void> removeCustomModelDirectory(String directoryPath) async {
    final existing = _shell.currentSettings.customModelDirectories;
    if (!existing.contains(directoryPath)) {
      return;
    }
    await _shell.updateSettings(
      (s) => s.copyWith(
        customModelDirectories: existing
            .where((String dir) => dir != directoryPath)
            .toList(growable: false),
      ),
    );
    await refreshCacheInventory();
  }

  /// Evaluates VRAM/RAM fit for [descriptor] on the current device.
  MemoryFitAssessment evaluateFit(StudioModelDescriptor descriptor) {
    final runtime = _inference.runtimeStore.state;
    final settings = _shell.currentSettings;
    return MemoryFitEstimator.evaluate(
      modelSizeBytes: descriptor.effectiveSizeBytes(isWeb: isWeb),
      requestedContextSize: settings.autoTuneHardware
          ? descriptor.preset.contextSize
          : settings.contextSize,
      cacheTypeK: settings.cacheTypeK,
      cacheTypeV: settings.cacheTypeV,
      vramFreeBytes: runtime.vramFreeBytes,
      vramTotalBytes: runtime.vramTotalBytes,
      minRamGb: descriptor.minRamGb,
      isWeb: isWeb,
    );
  }

  /// Updates the active category filter (`null` shows all categories).
  void selectCategory(StudioModelCategory? category) {
    _store.update(
      (ModelHubState s) => category == null
          ? s.copyWith(clearSelectedCategory: true)
          : s.copyWith(selectedCategory: category),
    );
  }

  /// Updates the search text.
  void setSearchQuery(String query) {
    _store.update((ModelHubState s) => s.copyWith(searchQuery: query));
  }

  /// Sets an optional Hugging Face bearer token in memory for gated downloads.
  void setBearerToken(String token) {
    _store.update((ModelHubState s) => s.copyWith(bearerToken: token.trim()));
  }

  /// Queries Hugging Face Hub for GGUF / LiteRT-LM repositories.
  Future<void> searchHuggingFace([String? customQuery]) async {
    final query = (customQuery ?? _store.state.searchQuery).trim();
    _store.update(
      (ModelHubState s) => s.copyWith(
        searchQuery: query,
        isSearchingHf: true,
        clearHfErrorMessage: true,
      ),
    );
    try {
      final hits = await _hf.searchRepositories(
        query,
        bearerToken: _store.state.bearerToken,
      );
      _store.update(
        (ModelHubState s) => s.copyWith(hfResults: hits, isSearchingHf: false),
      );
    } catch (error) {
      _store.update(
        (ModelHubState s) =>
            s.copyWith(isSearchingHf: false, hfErrorMessage: error.toString()),
      );
    }
  }

  /// Expands a Hugging Face repository and lists its loadable GGUF files.
  Future<void> expandHuggingFaceRepo(String repoId) async {
    if (_store.state.expandedRepoId == repoId) {
      _store.update(
        (ModelHubState s) => s.copyWith(
          clearExpandedRepoId: true,
          expandedRepoFiles: const <StudioModelDescriptor>[],
        ),
      );
      return;
    }
    _store.update(
      (ModelHubState s) => s.copyWith(
        expandedRepoId: repoId,
        expandedRepoFiles: const <StudioModelDescriptor>[],
        isSearchingHf: true,
        clearHfErrorMessage: true,
      ),
    );
    try {
      final files = await _hf.inspectRepositoryFiles(
        repoId,
        bearerToken: _store.state.bearerToken,
      );
      _store.update(
        (ModelHubState s) =>
            s.copyWith(expandedRepoFiles: files, isSearchingHf: false),
      );
    } catch (error) {
      _store.update(
        (ModelHubState s) =>
            s.copyWith(isSearchingHf: false, hfErrorMessage: error.toString()),
      );
    }
  }

  /// Downloads [descriptor] into the package cache without loading it.
  Future<ResolvedModelAssets> downloadModel(
    StudioModelDescriptor descriptor,
  ) async {
    final resolved = await _storage.ensureDownloaded(
      descriptor,
      isWeb: isWeb,
      bearerToken: _store.state.bearerToken.isEmpty
          ? null
          : _store.state.bearerToken,
    );
    await refreshCacheInventory();
    return resolved;
  }

  /// Cancels an active download for [modelId].
  void cancelDownload(String modelId) {
    _storage.cancelDownload(modelId);
  }

  /// Downloads (if needed) and loads [descriptor] into the Chat runtime,
  /// applying [BootGuardService] crash protection and hardware auto-tuning.
  Future<void> activateChatModel(
    StudioModelDescriptor descriptor, {
    bool applyModelPreset = true,
  }) async {
    final existing = _inFlightActivation;
    if (existing != null) {
      try {
        await existing;
      } catch (_) {}
      if (_inference.runtimeStore.state.activeDescriptor?.id == descriptor.id &&
          _inference.runtimeStore.state.isReady) {
        return;
      }
    }

    _store.update(
      (ModelHubState s) => s.copyWith(activatingDescriptor: descriptor),
    );
    final future = _performActivateChatModel(
      descriptor,
      applyModelPreset: applyModelPreset,
    );
    _inFlightActivation = future;
    try {
      await future;
    } finally {
      if (identical(_inFlightActivation, future)) {
        _inFlightActivation = null;
        _store.update(
          (ModelHubState s) => s.copyWith(clearActivatingDescriptor: true),
        );
      }
    }
  }

  Future<void> _performActivateChatModel(
    StudioModelDescriptor descriptor, {
    required bool applyModelPreset,
  }) async {
    final assets = await downloadModel(descriptor);
    final fit = evaluateFit(descriptor);

    var nextSettings = _shell.currentSettings.copyWith(
      activeModelId: descriptor.id,
      modelPath: assets.primarySource.path ?? descriptor.sourceUri,
      mmprojPath: assets.companionSources['projector']?.path,
      clearMmprojPath: assets.companionSources['projector'] == null,
      modelBytesHint: descriptor.effectiveSizeBytes(isWeb: isWeb),
    );

    if (applyModelPreset) {
      nextSettings = nextSettings.copyWith(
        temperature: descriptor.preset.temperature,
        topK: descriptor.preset.topK,
        topP: descriptor.preset.topP,
        minP: descriptor.preset.minP,
        penalty: descriptor.preset.penalty,
        requestedContextSize: descriptor.preset.contextSize,
        contextSize: nextSettings.autoTuneHardware
            ? fit.recommendedContextSize
            : descriptor.preset.contextSize,
        gpuLayers: nextSettings.autoTuneHardware
            ? fit.recommendedGpuLayers
            : nextSettings.gpuLayers,
        maxTokens: descriptor.preset.maxTokens,
        thinkingEnabled:
            descriptor.supportsThinking && descriptor.preset.thinkingEnabled,
        thinkingBudgetTokens: descriptor.preset.thinkingBudgetTokens,
      );
    } else if (nextSettings.autoTuneHardware) {
      nextSettings = nextSettings.copyWith(
        contextSize: fit.recommendedContextSize,
        gpuLayers: fit.recommendedGpuLayers,
      );
    }

    await _shell.updateSettings((_) => nextSettings);
    await _shell.bootGuard.beginModelLoad(
      modelName: descriptor.name,
      modelIdOrPath: descriptor.id,
    );
    try {
      await _inference.loadModel(
        assets: assets,
        settings: nextSettings,
        isWeb: isWeb,
      );
    } finally {
      await _shell.bootGuard.completeModelLoad();
    }
  }

  /// Loads a custom local file path or remote URL directly into the Chat engine.
  Future<void> loadCustomModel({
    required String pathOrUrl,
    String? mmprojPathOrUrl,
  }) async {
    final trimmed = pathOrUrl.trim();
    if (trimmed.isEmpty) {
      return;
    }
    final filename =
        Uri.tryParse(trimmed)?.pathSegments.lastOrNull ??
        trimmed.split('/').last;
    final descriptor = StudioModelDescriptor(
      id: 'custom:$trimmed',
      name: filename.isEmpty ? 'Custom Model' : filename,
      description: 'User-provided local path or URL.',
      category: StudioModelCategory.chat,
      filename: filename.isEmpty ? 'model.gguf' : filename,
      sourceUri: trimmed,
      supportsVision: mmprojPathOrUrl != null && mmprojPathOrUrl.isNotEmpty,
      supportsToolCalling: true,
      supportsThinking: true,
      companions: <StudioModelCompanionAsset>[
        if (mmprojPathOrUrl != null && mmprojPathOrUrl.trim().isNotEmpty)
          StudioModelCompanionAsset(
            role: 'projector',
            filename: 'mmproj.gguf',
            sourceUri: mmprojPathOrUrl.trim(),
          ),
      ],
    );

    _store.update(
      (ModelHubState s) => s.copyWith(activatingDescriptor: descriptor),
    );
    try {
      await _shell.bootGuard.beginModelLoad(
        modelName: descriptor.name,
        modelIdOrPath: trimmed,
      );
      await _inference.loadCustomSource(
        descriptor: descriptor,
        settings: _shell.currentSettings,
        isWeb: isWeb,
      );
    } finally {
      _store.update(
        (ModelHubState s) => s.copyWith(clearActivatingDescriptor: true),
      );
      await _shell.bootGuard.completeModelLoad();
    }
  }

  /// Reloads the currently active chat model after hardware/context changes.
  Future<void> reloadActiveModel() async {
    final active = _inference.runtimeStore.state.activeDescriptor;
    if (active == null) {
      return;
    }
    await activateChatModel(active, applyModelPreset: false);
  }

  /// Unloads the active chat model from memory.
  Future<void> unloadActiveModel() async {
    await _inference.unloadModel();
  }

  /// Refreshes local directory scan, cached model flags, and raw disk inventory.
  Future<void> refreshCacheInventory() async {
    final localModels = await _storage.refreshLocalModels(
      extraDirectories: _shell.currentSettings.customModelDirectories,
    );
    final entries = await _storage.listCachedEntries();
    final cachedIds = <String>{for (final local in localModels) local.id};
    for (final model in _catalog.models) {
      if (await _storage.isCached(model, isWeb: isWeb)) {
        cachedIds.add(model.id);
      }
    }
    _store.update(
      (ModelHubState s) => s.copyWith(
        localModels: localModels,
        localDiscoveredBytes: _storage.discoveredLocalBytes,
        cacheEntries: entries,
        cachedModelIds: cachedIds,
      ),
    );
  }

  /// Deletes cached files for [descriptor].
  Future<void> deleteCachedModel(StudioModelDescriptor descriptor) async {
    await _storage.removeCachedModel(descriptor, isWeb: isWeb);
    await refreshCacheInventory();
  }

  /// Deletes an individual cache entry by [cacheKey].
  Future<void> deleteCacheEntry(String cacheKey) async {
    await _storage.removeCacheEntry(cacheKey);
    await refreshCacheInventory();
  }

  /// Prunes cached models older than [maxAge] or exceeding [maxBytes].
  Future<void> pruneCache({Duration? maxAge, int? maxBytes}) async {
    await _storage.pruneCache(maxAge: maxAge, maxBytes: maxBytes);
    await refreshCacheInventory();
  }

  void _onDownloadProgress(StudioModelDownloadProgress progress) {
    final updated = Map<String, StudioModelDownloadProgress>.of(
      _store.state.downloadsByModelId,
    )..[progress.modelId] = progress;
    final cached = Set<String>.of(_store.state.cachedModelIds);
    if (progress.stage == ModelDownloadTaskStage.ready) {
      cached.add(progress.modelId);
    } else if (progress.stage == ModelDownloadTaskStage.idle) {
      cached.remove(progress.modelId);
    }
    _store.update(
      (ModelHubState s) =>
          s.copyWith(downloadsByModelId: updated, cachedModelIds: cached),
    );
  }

  /// Disposes internal subscriptions and reactive stores.
  Future<void> dispose() async {
    await _progressSub?.cancel();
    await _store.dispose();
  }
}

/// Dependency bundle passed into [ModelHubController].
@immutable
class StudioStorageAndInferenceDeps {
  /// Creates [StudioStorageAndInferenceDeps].
  const StudioStorageAndInferenceDeps({
    required this.storagePort,
    required this.inferencePort,
    required this.shellController,
  });

  /// Model download & cache port.
  final StudioModelStoragePort storagePort;

  /// Primary inference port.
  final StudioInferencePort inferencePort;

  /// Settings persistence and boot-guard port.
  final StudioModelHubSettingsPort shellController;
}
