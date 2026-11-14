import 'package:llamadart/llamadart.dart';
import 'package:meta/meta.dart';

import '../adapters/curated_studio_model_catalog.dart';
import '../domain/studio_model_descriptor.dart';
import '../ports/model_storage_port.dart';
import '../ports/playground_port.dart';
import '../ports/studio_context_ports.dart';
import '../reactive/state_store.dart';
import '../services/studio_error_formatter.dart';

/// Reactive state tracking dedicated Playground & Notebook auxiliary models
/// (Embedding, Reranker, Decision Head) loaded independently of the primary Chat LLM.
@immutable
class LabModelState {
  /// Creates a [LabModelState].
  const LabModelState({
    this.loadedLabModels =
        const <StudioModelSpecialty, StudioModelDescriptor>{},
    this.loadingModel,
    this.embeddingCapabilities = const EmbeddingCapabilityInfo(),
    this.errorMessage,
  });

  /// Loaded dedicated lab models keyed by specialty.
  final Map<StudioModelSpecialty, StudioModelDescriptor> loadedLabModels;

  /// Dedicated lab model currently downloading or loading into memory.
  final StudioModelDescriptor? loadingModel;

  /// Active embedding engine modality capabilities (text / image / audio).
  final EmbeddingCapabilityInfo embeddingCapabilities;

  /// Optional error message surfaced during dedicated lab model loading.
  final String? errorMessage;

  /// Whether a dedicated model is currently downloading or loading.
  bool get isLoadingModel => loadingModel != null;

  /// Returns an updated copy of [LabModelState].
  LabModelState copyWith({
    Map<StudioModelSpecialty, StudioModelDescriptor>? loadedLabModels,
    StudioModelDescriptor? loadingModel,
    bool clearLoadingModel = false,
    EmbeddingCapabilityInfo? embeddingCapabilities,
    String? errorMessage,
    bool clearErrorMessage = false,
  }) {
    return LabModelState(
      loadedLabModels: loadedLabModels ?? this.loadedLabModels,
      loadingModel: clearLoadingModel
          ? null
          : (loadingModel ?? this.loadingModel),
      embeddingCapabilities:
          embeddingCapabilities ?? this.embeddingCapabilities,
      errorMessage: clearErrorMessage
          ? null
          : (errorMessage ?? this.errorMessage),
    );
  }
}

/// Shared coordinator managing lifecycle, downloading, caching, and capability
/// probing for dedicated auxiliary models (Embedding, Reranker, Decision Head).
///
/// Shared by both [PlaygroundWorkspaceController] and [NotebookController] so
/// each workspace stays focused on its own domain (Single Responsibility).
class LabModelCoordinator {
  /// Creates a [LabModelCoordinator].
  LabModelCoordinator({
    required StudioModelStoragePort storagePort,
    required StudioDedicatedModelLoader modelLoader,
    StudioEmbeddingPort? embeddingPort,
    StudioModelCatalog modelCatalog = const CuratedStudioModelCatalog(),
    required this.isWeb,
    required this.isMobile,
  }) : _storage = storagePort,
       _modelLoader = modelLoader,
       _embeddingPort =
           embeddingPort ??
           (modelLoader is StudioEmbeddingPort ? modelLoader : null),
       _catalog = modelCatalog;

  final StudioModelStoragePort _storage;
  final StudioDedicatedModelLoader _modelLoader;
  final StudioEmbeddingPort? _embeddingPort;
  final StudioModelCatalog _catalog;

  /// Whether running on WebGPU.
  final bool isWeb;

  /// Whether running on iOS/Android.
  final bool isMobile;

  final StateStore<LabModelState> _store = StateStore<LabModelState>(
    const LabModelState(),
  );

  /// Reactive store of loaded/loading dedicated lab models.
  ReadOnlyStore<LabModelState> get store => _store;

  /// Current lab model state snapshot.
  LabModelState get state => _store.state;

  /// Local + curated Playground/Notebook auxiliary models for this host.
  List<StudioModelDescriptor> get availableLabModels => <StudioModelDescriptor>[
    ..._storage.discoveredLocalModels.where(
      (StudioModelDescriptor m) =>
          m.category == StudioModelCategory.playground &&
          m.isSupportedOn(isWeb: isWeb, isMobile: isMobile),
    ),
    ..._catalog.forCategory(
      StudioModelCategory.playground,
      isWeb: isWeb,
      isMobile: isMobile,
    ),
  ];

  /// Dedicated lab models matching [specialty], with multimodal embedding
  /// models sorted first when [specialty] is [StudioModelSpecialty.embedding].
  List<StudioModelDescriptor> availableModelsForSpecialty(
    StudioModelSpecialty specialty,
  ) {
    final matching = availableLabModels
        .where((StudioModelDescriptor m) => m.specialty == specialty)
        .toList();
    if (specialty == StudioModelSpecialty.embedding) {
      matching.sort((StudioModelDescriptor a, StudioModelDescriptor b) {
        final aScore =
            (a.embeddingProfile == LlamaEmbeddingProfile.embeddingGemma2
                ? 2
                : 0) +
            (a.supportsVision || a.supportsAudio ? 1 : 0);
        final bScore =
            (b.embeddingProfile == LlamaEmbeddingProfile.embeddingGemma2
                ? 2
                : 0) +
            (b.supportsVision || b.supportsAudio ? 1 : 0);
        return bScore.compareTo(aScore);
      });
    }
    return List<StudioModelDescriptor>.unmodifiable(matching);
  }

  /// Cancels an active lab model download when one is in progress.
  void cancelModelLoad() {
    final loading = _store.state.loadingModel;
    if (loading == null) {
      return;
    }
    _storage.cancelDownload(loading.id);
  }

  /// Downloads and loads a dedicated [descriptor] (Embedding, Reranker, or Decision).
  Future<void> loadLabModel(StudioModelDescriptor descriptor) async {
    _store.update(
      (LabModelState s) =>
          s.copyWith(loadingModel: descriptor, clearErrorMessage: true),
    );
    try {
      await _loadDedicatedInternal(descriptor);
      _store.update((LabModelState s) => s.copyWith(clearLoadingModel: true));
    } catch (error) {
      _store.update(
        (LabModelState s) => s.copyWith(
          clearLoadingModel: true,
          errorMessage: humanizeStudioError(error),
        ),
      );
      rethrow;
    }
  }

  /// Loads the first cached dedicated model for [specialty] if none is active yet.
  Future<void> ensureCachedSpecialtyLoaded(
    StudioModelSpecialty specialty,
  ) async {
    if (_store.state.loadedLabModels.containsKey(specialty)) {
      return;
    }
    final candidates = availableModelsForSpecialty(specialty);
    final cachedCandidates = <StudioModelDescriptor>[];
    for (final candidate in candidates) {
      if (await _storage.isCached(candidate, isWeb: isWeb)) {
        cachedCandidates.add(candidate);
      }
    }
    if (cachedCandidates.isEmpty) {
      return;
    }
    Object? lastError;
    try {
      for (final candidate in cachedCandidates) {
        _store.update(
          (LabModelState s) =>
              s.copyWith(loadingModel: candidate, clearErrorMessage: true),
        );
        try {
          await _loadDedicatedInternal(candidate);
          return;
        } catch (error) {
          lastError = error;
        }
      }
      if (lastError != null) {
        throw lastError;
      }
    } finally {
      _store.update((LabModelState s) => s.copyWith(clearLoadingModel: true));
    }
  }

  Future<void> _loadDedicatedInternal(StudioModelDescriptor descriptor) async {
    final assets = await _storage.ensureDownloaded(descriptor, isWeb: isWeb);
    if (_store.state.loadedLabModels.containsKey(descriptor.specialty)) {
      final clearedMap = Map<StudioModelSpecialty, StudioModelDescriptor>.of(
        _store.state.loadedLabModels,
      )..remove(descriptor.specialty);
      _store.update(
        (LabModelState s) => s.copyWith(loadedLabModels: clearedMap),
      );
    }
    await _modelLoader.loadDedicatedModel(assets: assets, isWeb: isWeb);
    final updatedMap = Map<StudioModelSpecialty, StudioModelDescriptor>.of(
      _store.state.loadedLabModels,
    )..[descriptor.specialty] = descriptor;
    EmbeddingCapabilityInfo? probedCaps;
    if (descriptor.specialty == StudioModelSpecialty.embedding &&
        _embeddingPort != null) {
      probedCaps = await _embeddingPort.probeEmbeddingCapabilities();
    }
    _store.update(
      (LabModelState s) => s.copyWith(
        loadedLabModels:
            Map<StudioModelSpecialty, StudioModelDescriptor>.unmodifiable(
              updatedMap,
            ),
        embeddingCapabilities: probedCaps,
      ),
    );
  }

  /// Unloads all dedicated auxiliary engines from memory.
  Future<void> unloadModels() async {
    await _modelLoader.dispose();
    _store.update(
      (LabModelState s) => s.copyWith(
        loadedLabModels: const <StudioModelSpecialty, StudioModelDescriptor>{},
        embeddingCapabilities: const EmbeddingCapabilityInfo(),
      ),
    );
  }

  /// Disposes the internal reactive state store.
  Future<void> dispose() => _store.dispose();
}
