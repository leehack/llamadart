import 'package:file_picker/file_picker.dart';
// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

import '../../app/studio_dependencies.dart';
import '../../app/studio_theme.dart';
import '../../widgets/model_load_progress_banner.dart';
import '../../widgets/store_widgets.dart';
import '../../widgets/studio_motion.dart';

part 'model_hub_cards.dart';
part 'model_hub_discovery.dart';
part 'model_hub_storage.dart';

/// Curated Model Hub, live Hugging Face discovery, VRAM fit planner, and
/// package-cache storage manager.
class ModelHubWorkspaceView extends StatefulWidget {
  /// Creates a [ModelHubWorkspaceView].
  const ModelHubWorkspaceView({super.key});

  @override
  State<ModelHubWorkspaceView> createState() => _ModelHubWorkspaceViewState();
}

class _ModelHubWorkspaceViewState extends State<ModelHubWorkspaceView> {
  final TextEditingController _searchController = TextEditingController();
  _ModelHubSection _section = _ModelHubSection.browse;
  _ModelCapability _capability = _ModelCapability.any;
  _ModelSort _sort = _ModelSort.recommended;

  void _updateDiscovery(VoidCallback update) => setState(update);

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _activateDescriptor(
    BuildContext context,
    StudioModelDescriptor descriptor,
  ) async {
    final deps = StudioScope.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      switch (descriptor.category) {
        case StudioModelCategory.chat:
          await deps.modelHubController.activateChatModel(descriptor);
          if (deps.shellController.state.activeWorkspace ==
              StudioWorkspace.models) {
            deps.shellController.selectWorkspace(StudioWorkspace.chat);
          }
        case StudioModelCategory.speech:
          deps.shellController.selectWorkspace(StudioWorkspace.speech);
          if (descriptor.supportsTextToSpeech) {
            await deps.speechController.loadTtsModel(descriptor);
            final state = deps.speechController.state;
            if (state.errorMessage != null ||
                state.activeTtsModel?.id != descriptor.id) {
              throw LlamaModelException(
                state.errorMessage ?? 'Text-to-Speech model did not load.',
              );
            }
          } else {
            await deps.speechController.loadSttModel(descriptor);
            final state = deps.speechController.state;
            if (state.errorMessage != null ||
                state.activeSttModel?.id != descriptor.id) {
              throw LlamaModelException(
                state.errorMessage ?? 'Speech-to-Text model did not load.',
              );
            }
          }
        case StudioModelCategory.image:
          deps.shellController.selectWorkspace(StudioWorkspace.image);
          await deps.imageController.loadModel(descriptor);
          final state = deps.imageController.state;
          if (state.errorMessage != null ||
              state.activeModel?.id != descriptor.id) {
            throw LlamaModelException(
              state.errorMessage ?? 'Image model did not load.',
            );
          }
        case StudioModelCategory.playground:
          deps.shellController.selectWorkspace(StudioWorkspace.playground);
          await deps.labModelCoordinator.loadLabModel(descriptor);
      }
    } catch (error) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Failed to load ${descriptor.name}: $error')),
      );
    }
  }

  Future<void> _showCustomModelDialog(BuildContext context) async {
    final deps = StudioScope.of(context);
    final pathCtrl = TextEditingController();
    final mmprojCtrl = TextEditingController();

    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          scrollable: true,
          title: const Text('Load Custom Model Path or URL'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 500),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: TextField(
                        controller: pathCtrl,
                        decoration: const InputDecoration(
                          labelText: 'GGUF / LiteRT-LM Path or HTTPS URL',
                          hintText: '/path/to/model.gguf or https://...',
                        ),
                      ),
                    ),
                    if (!deps.isWeb) ...<Widget>[
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: 'Browse local file',
                        onPressed: () async {
                          final picked = await FilePicker.platform.pickFiles();
                          final path = picked?.files.firstOrNull?.path;
                          if (path != null) {
                            pathCtrl.text = path;
                          }
                        },
                        icon: const Icon(Icons.folder_open_rounded),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: mmprojCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Optional mmproj Path or URL (Vision / Audio)',
                  ),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                final primary = pathCtrl.text.trim();
                final mmproj = mmprojCtrl.text.trim();
                Navigator.of(dialogContext).pop();
                if (primary.isEmpty) {
                  return;
                }
                await deps.modelHubController.loadCustomModel(
                  pathOrUrl: primary,
                  mmprojPathOrUrl: mmproj.isEmpty ? null : mmproj,
                );
                deps.shellController.selectWorkspace(StudioWorkspace.chat);
              },
              child: const Text('Load Model'),
            ),
          ],
        );
      },
    );
    pathCtrl.dispose();
    mmprojCtrl.dispose();
  }

  Future<void> _pickAndAddModelFolder(BuildContext context) async {
    final deps = StudioScope.of(context);
    final selected = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Select Local Model Folder (.gguf / .litertlm)',
    );
    if (selected == null || selected.trim().isEmpty) {
      return;
    }
    await deps.modelHubController.addCustomModelDirectory(selected);
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('Scanned model folder: $selected')),
      );
    }
  }

  Widget _buildModelGrid({
    required BuildContext context,
    required StudioDependencies deps,
    required ModelHubState hubState,
    required StudioRuntimeSnapshot runtime,
    required List<StudioModelDescriptor> models,
  }) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final cols = constraints.maxWidth >= 920 ? 2 : 1;
        final cardWidth = cols == 2
            ? (constraints.maxWidth - 14) / 2
            : constraints.maxWidth;
        return Wrap(
          spacing: 14,
          runSpacing: 14,
          children: models.map((StudioModelDescriptor model) {
            final fit = deps.modelHubController.evaluateFit(model);
            final progress = hubState.downloadsByModelId[model.id];
            final isCached = _isOnDevice(model, hubState);
            final isActiveChat =
                runtime.activeDescriptor?.id == model.id && runtime.isReady;

            return SizedBox(
              width: cardWidth,
              child: _ModelDescriptorCard(
                descriptor: model,
                fit: fit,
                progress: progress,
                isCached: isCached,
                isActive: isActiveChat,
                isLoading:
                    (hubState.activatingDescriptor ?? runtime.activeDescriptor)
                            ?.id ==
                        model.id &&
                    (hubState.activatingDescriptor != null ||
                        runtime.isLoading),
                loadingStatus: runtime.isLoading
                    ? runtime.statusMessage ?? 'Initializing model in memory...'
                    : 'Preparing model files...',
                canActivate:
                    (hubState.activatingDescriptor == null &&
                        !runtime.isLoading) ||
                    model.category != StudioModelCategory.chat,
                isWeb: deps.isWeb,
                onActivate: () => _activateDescriptor(context, model),
                onCancelDownload: () =>
                    deps.modelHubController.cancelDownload(model.id),
                onManageStorage: () => _showCacheManagerSheet(context),
              ),
            );
          }).toList(),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final deps = StudioScope.of(context);
    return StoreBuilder<ModelHubState>(
      store: deps.modelHubController.store,
      builder: (BuildContext context, ModelHubState hubState) {
        return StoreBuilder<StudioRuntimeSnapshot>(
          store: deps.modelHubController.runtimeStore,
          builder: (BuildContext context, StudioRuntimeSnapshot runtime) {
            return _buildDiscovery(context, deps, hubState, runtime);
          },
        );
      },
    );
  }
}
