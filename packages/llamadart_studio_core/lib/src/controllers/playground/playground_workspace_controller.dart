import 'dart:async';

import 'package:meta/meta.dart';

import '../../adapters/curated_studio_model_catalog.dart';
import '../../domain/studio_model_descriptor.dart';
import '../../domain/studio_note.dart';
import '../../ports/model_storage_port.dart';
import '../../ports/playground_port.dart';
import '../../ports/studio_context_ports.dart';
import '../../reactive/state_store.dart';
import '../../services/studio_error_formatter.dart';
import '../lab_model_coordinator.dart';

part 'playground_workspace_state.dart';
part 'playground_decision_workflows.dart';

/// Coordinates Studio's developer Playground (Embeddings similarity, Reranker,
/// Laya System-1 Decision Engine, Tokenizer, and Throughput Benchmarks).
///
/// Depends strictly on segregated capability ports ([StudioEmbeddingPort],
/// [StudioRerankerPort], [StudioDecisionPort], [StudioTokenInspectorPort],
/// [StudioBenchmarkPort]) or a combined [StudioPlaygroundPort], plus shared
/// [LabModelCoordinator].
class PlaygroundWorkspaceController {
  /// Creates a [PlaygroundWorkspaceController].
  PlaygroundWorkspaceController({
    required StudioModelStoragePort storagePort,
    StudioPlaygroundPort? playgroundPort,
    StudioDedicatedModelLoader? modelLoader,
    StudioEmbeddingPort? embeddingPort,
    StudioRerankerPort? rerankerPort,
    StudioDecisionPort? decisionPort,
    StudioTokenInspectorPort? tokenInspectorPort,
    StudioBenchmarkPort? benchmarkPort,
    LabModelCoordinator? labModels,
    StudioModelCatalog modelCatalog = const CuratedStudioModelCatalog(),
    List<StudioNote> Function()? notesProvider,
    Future<void> Function(List<StudioNote> updatedNotes)? onNotesUpdated,
    Future<bool> Function()? ensureChatModelReady,
    required this.isWeb,
    required this.isMobile,
  }) : _embedding = embeddingPort ?? playgroundPort,
       _reranker = rerankerPort ?? playgroundPort,
       _decision = decisionPort ?? playgroundPort,
       _tokens = tokenInspectorPort ?? playgroundPort,
       _benchmark = benchmarkPort ?? playgroundPort,
       _labModels =
           labModels ??
           LabModelCoordinator(
             storagePort: storagePort,
             modelLoader:
                 modelLoader ??
                 playgroundPort ??
                 const _NoOpPlaygroundModelLoader(),
             embeddingPort: embeddingPort ?? playgroundPort,
             modelCatalog: modelCatalog,
             isWeb: isWeb,
             isMobile: isMobile,
           ),
       _ownsLabModels = labModels == null,
       _notesProvider = notesProvider,
       _onNotesUpdated = onNotesUpdated,
       _ensureChatModelReady = ensureChatModelReady;

  final StudioEmbeddingPort? _embedding;
  final StudioRerankerPort? _reranker;
  final StudioDecisionPort? _decision;
  final StudioTokenInspectorPort? _tokens;
  final StudioBenchmarkPort? _benchmark;
  final LabModelCoordinator _labModels;
  final bool _ownsLabModels;
  final List<StudioNote> Function()? _notesProvider;
  final Future<void> Function(List<StudioNote> updatedNotes)? _onNotesUpdated;
  final Future<bool> Function()? _ensureChatModelReady;

  /// Whether running on WebGPU.
  final bool isWeb;

  /// Whether running on iOS/Android.
  final bool isMobile;

  final StateStore<PlaygroundWorkspaceState> _store =
      StateStore<PlaygroundWorkspaceState>(const PlaygroundWorkspaceState());

  /// Reactive Playground store.
  ReadOnlyStore<PlaygroundWorkspaceState> get store => _store;

  /// Current Playground state snapshot.
  PlaygroundWorkspaceState get state => _store.state;

  /// Shared [LabModelCoordinator] managing Embedding, Reranker, and Decision models.
  LabModelCoordinator get labModels => _labModels;

  /// Local + curated Playground models (Embedding, Reranker, Decision) for
  /// this host.
  List<StudioModelDescriptor> get availableLabModels =>
      _labModels.availableLabModels;

  /// Dedicated Playground models relevant to [tab].
  List<StudioModelDescriptor> availableModelsForTab(PlaygroundToolTab tab) {
    final specialty = tab.requiredSpecialty;
    if (specialty == null) {
      return const <StudioModelDescriptor>[];
    }
    return _labModels.availableModelsForSpecialty(specialty);
  }

  /// Switches the active Playground sub-tab.
  void selectTab(PlaygroundToolTab tab) {
    _store.update(
      (PlaygroundWorkspaceState s) =>
          s.copyWith(activeTab: tab, clearErrorMessage: true),
    );
  }

  /// Switches the active workflow inside the Decision Head tab.
  void selectDecisionMode(DecisionWorkflowMode mode) {
    _store.update(
      (PlaygroundWorkspaceState s) =>
          s.copyWith(decisionMode: mode, clearErrorMessage: true),
    );
  }

  /// Cancels an active Playground model download when one is in progress.
  void cancelModelLoad() => _labModels.cancelModelLoad();

  /// Downloads and loads a dedicated Playground model.
  Future<void> loadLabModel(StudioModelDescriptor descriptor) async {
    _store.update(
      (PlaygroundWorkspaceState s) => s.copyWith(clearErrorMessage: true),
    );
    try {
      await _labModels.loadLabModel(descriptor);
    } catch (error) {
      _store.update(
        (PlaygroundWorkspaceState s) =>
            s.copyWith(errorMessage: humanizeStudioError(error)),
      );
    }
  }

  /// Unloads all dedicated Playground engines from memory.
  Future<void> unloadModels() => _labModels.unloadModels();

  /// Disposes internal reactive stores (and owned [LabModelCoordinator] if
  /// not shared externally).
  Future<void> dispose() async {
    if (_ownsLabModels) {
      await _labModels.dispose();
    }
    await _store.dispose();
  }
}

class _NoOpPlaygroundModelLoader implements StudioDedicatedModelLoader {
  const _NoOpPlaygroundModelLoader();

  @override
  Future<void> loadDedicatedModel({
    required ResolvedModelAssets assets,
    required bool isWeb,
  }) async {}

  @override
  Future<void> dispose() async {}
}
