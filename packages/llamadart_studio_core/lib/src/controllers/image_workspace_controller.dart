import 'package:llamadart/llamadart.dart';
import 'package:meta/meta.dart';

import '../adapters/curated_studio_model_catalog.dart';
import '../domain/studio_model_descriptor.dart';
import '../ports/image_port.dart';
import '../ports/model_storage_port.dart';
import '../ports/studio_context_ports.dart';
import '../reactive/state_store.dart';
import '../services/studio_error_formatter.dart';

/// Immutable state for the Image Studio diffusion workspace.
@immutable
class ImageWorkspaceState {
  /// Creates an [ImageWorkspaceState].
  const ImageWorkspaceState({
    this.runtimeCapabilities,
    this.activeModel,
    this.loadingModel,
    this.isLoadingModel = false,
    this.isGenerating = false,
    this.step = 0,
    this.totalSteps = 0,
    this.phaseLabel,
    this.gallery = const <StudioGeneratedImageItem>[],
    this.errorMessage,
  });

  /// Runtime capabilities reported by `ImageGenerationEngine`.
  final ImageGenerationCapabilities? runtimeCapabilities;

  /// Currently loaded diffusion checkpoint descriptor.
  final StudioModelDescriptor? activeModel;

  /// Checkpoint descriptor currently downloading or loading into memory.
  final StudioModelDescriptor? loadingModel;

  /// Whether a checkpoint is downloading/loading.
  final bool isLoadingModel;

  /// Whether a diffusion sampling/decoding pass is active.
  final bool isGenerating;

  /// Current progress step within [totalSteps].
  final int step;

  /// Total steps in the current diffusion phase.
  final int totalSteps;

  /// Human-readable phase label (`Encoding prompt...`, `Sampling 2/4...`).
  final String? phaseLabel;

  /// Session gallery of generated images (newest first).
  final List<StudioGeneratedImageItem> gallery;

  /// Optional error banner message.
  final String? errorMessage;

  /// Returns an updated copy of [ImageWorkspaceState].
  ImageWorkspaceState copyWith({
    ImageGenerationCapabilities? runtimeCapabilities,
    StudioModelDescriptor? activeModel,
    bool clearActiveModel = false,
    StudioModelDescriptor? loadingModel,
    bool clearLoadingModel = false,
    bool? isLoadingModel,
    bool? isGenerating,
    int? step,
    int? totalSteps,
    String? phaseLabel,
    bool clearPhaseLabel = false,
    List<StudioGeneratedImageItem>? gallery,
    String? errorMessage,
    bool clearErrorMessage = false,
  }) {
    return ImageWorkspaceState(
      runtimeCapabilities: runtimeCapabilities ?? this.runtimeCapabilities,
      activeModel: clearActiveModel ? null : (activeModel ?? this.activeModel),
      loadingModel: clearLoadingModel
          ? null
          : (loadingModel ?? this.loadingModel),
      isLoadingModel: isLoadingModel ?? this.isLoadingModel,
      isGenerating: isGenerating ?? this.isGenerating,
      step: step ?? this.step,
      totalSteps: totalSteps ?? this.totalSteps,
      phaseLabel: clearPhaseLabel ? null : (phaseLabel ?? this.phaseLabel),
      gallery: gallery ?? this.gallery,
      errorMessage: clearErrorMessage
          ? null
          : (errorMessage ?? this.errorMessage),
    );
  }
}

/// Coordinates Stable Diffusion checkpoint loading, step-level progress, and
/// session image gallery state.
class ImageWorkspaceController {
  /// Creates an [ImageWorkspaceController].
  ImageWorkspaceController({
    required StudioModelStoragePort storagePort,
    required StudioImagePort imagePort,
    StudioModelCatalog modelCatalog = const CuratedStudioModelCatalog(),
    required this.isWeb,
    required this.isMobile,
  }) : _storage = storagePort,
       _image = imagePort,
       _catalog = modelCatalog;

  final StudioModelStoragePort _storage;
  final StudioImagePort _image;
  final StudioModelCatalog _catalog;

  /// Whether running on Web.
  final bool isWeb;

  /// Whether running on iOS/Android.
  final bool isMobile;

  final StateStore<ImageWorkspaceState> _store =
      StateStore<ImageWorkspaceState>(const ImageWorkspaceState());

  /// Reactive Image Studio store.
  ReadOnlyStore<ImageWorkspaceState> get store => _store;

  /// Current Image Studio state snapshot.
  ImageWorkspaceState get state => _store.state;

  /// Available local + curated diffusion models for the host.
  List<StudioModelDescriptor> get availableModels => <StudioModelDescriptor>[
    ..._storage.discoveredLocalModels.where(
      (StudioModelDescriptor m) =>
          m.category == StudioModelCategory.image &&
          m.isSupportedOn(isWeb: isWeb, isMobile: isMobile),
    ),
    ..._catalog.forCategory(
      StudioModelCategory.image,
      isWeb: isWeb,
      isMobile: isMobile,
    ),
  ];

  /// Probes Stable Diffusion runtime availability on the current host.
  Future<void> initialize() async {
    if (isWeb) {
      _store.update(
        (ImageWorkspaceState s) => s.copyWith(
          runtimeCapabilities: const ImageGenerationCapabilities(
            isSupported: false,
            unsupportedReason:
                'Stable Diffusion runs natively on macOS, Windows, Linux, iOS, '
                'and Android.',
          ),
        ),
      );
      return;
    }
    try {
      final caps = await _image.checkRuntime();
      _store.update(
        (ImageWorkspaceState s) => s.copyWith(runtimeCapabilities: caps),
      );
    } catch (error) {
      _store.update(
        (ImageWorkspaceState s) =>
            s.copyWith(errorMessage: humanizeStudioError(error)),
      );
    }
  }

  /// Downloads and loads [descriptor] into the diffusion engine.
  Future<void> loadModel(StudioModelDescriptor descriptor) async {
    _store.update(
      (ImageWorkspaceState s) => s.copyWith(
        isLoadingModel: true,
        loadingModel: descriptor,
        clearErrorMessage: true,
      ),
    );
    try {
      final assets = await _storage.ensureDownloaded(descriptor, isWeb: isWeb);
      final caps = await _image.loadModel(assets: assets);
      _store.update(
        (ImageWorkspaceState s) => s.copyWith(
          activeModel: descriptor,
          runtimeCapabilities: caps,
          isLoadingModel: false,
          clearLoadingModel: true,
        ),
      );
    } catch (error) {
      _store.update(
        (ImageWorkspaceState s) => s.copyWith(
          isLoadingModel: false,
          clearLoadingModel: true,
          errorMessage: humanizeStudioError(error),
        ),
      );
    }
  }

  Future<void> _ensureCachedCheckpointLoaded() async {
    if (_store.state.activeModel != null) {
      return;
    }
    for (final candidate in availableModels) {
      if (await _storage.isCached(candidate, isWeb: isWeb)) {
        await loadModel(candidate);
        return;
      }
    }
  }

  /// Generates a new image and prepends it to the session gallery.
  Future<StudioGeneratedImageItem?> generate({
    required String prompt,
    String negativePrompt = '',
    int width = 512,
    int height = 512,
    int steps = 1,
    double guidanceScale = 1.0,
    int? seed,
  }) async {
    final trimmed = prompt.trim();
    if (trimmed.isEmpty || _store.state.isGenerating) {
      return null;
    }
    await _ensureCachedCheckpointLoaded();
    if (_store.state.errorMessage != null && _store.state.activeModel == null) {
      return null;
    }
    _store.update(
      (ImageWorkspaceState s) => s.copyWith(
        isGenerating: true,
        step: 0,
        totalSteps: steps,
        phaseLabel: 'Encoding prompt...',
        clearErrorMessage: true,
      ),
    );

    try {
      final item = await _image.generateImage(
        prompt: trimmed,
        negativePrompt: negativePrompt.trim(),
        width: width,
        height: height,
        steps: steps,
        guidanceScale: guidanceScale,
        seed: seed,
        onProgress: (ImageGenerationProgressEvent event) {
          final label = switch (event.phase) {
            ImageGenerationPhase.loading => 'Loading tensors...',
            ImageGenerationPhase.encodingPrompt => 'Encoding text prompt...',
            ImageGenerationPhase.sampling =>
              'Sampling step ${event.step} / ${event.steps}',
            ImageGenerationPhase.decoding => 'Decoding VAE latents...',
          };
          _store.update(
            (ImageWorkspaceState s) => s.copyWith(
              step: event.step,
              totalSteps: event.steps,
              phaseLabel: label,
            ),
          );
        },
      );
      _store.update(
        (ImageWorkspaceState s) => s.copyWith(
          isGenerating: false,
          clearPhaseLabel: true,
          gallery: <StudioGeneratedImageItem>[
            item,
            ...s.gallery,
          ].take(maxGalleryItems).toList(growable: false),
        ),
      );
      return item;
    } catch (error) {
      _store.update(
        (ImageWorkspaceState s) => s.copyWith(
          isGenerating: false,
          clearPhaseLabel: true,
          errorMessage: humanizeStudioError(error),
        ),
      );
      return null;
    }
  }

  /// Maximum in-memory PNG gallery items retained per session.
  static const int maxGalleryItems = 24;

  /// Removes a single generated image from the in-memory gallery.
  void removeGalleryItem(String itemId) {
    _store.update(
      (ImageWorkspaceState s) => s.copyWith(
        gallery: s.gallery
            .where((StudioGeneratedImageItem item) => item.id != itemId)
            .toList(growable: false),
      ),
    );
  }

  /// Clears all generated images from the in-memory session gallery.
  void clearGallery() {
    _store.update(
      (ImageWorkspaceState s) =>
          s.copyWith(gallery: const <StudioGeneratedImageItem>[]),
    );
  }

  /// Cancels the active image generation pass.
  void cancelGeneration() {
    _image.cancelGeneration();
  }

  /// Unloads the active diffusion engine from memory.
  Future<void> unloadModel() async {
    await _image.dispose();
    _store.update(
      (ImageWorkspaceState s) => s.copyWith(clearActiveModel: true),
    );
  }

  /// Disposes internal reactive store.
  Future<void> dispose() => _store.dispose();
}
