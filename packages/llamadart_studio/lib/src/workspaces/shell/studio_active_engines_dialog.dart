part of 'studio_shell_screen.dart';

class _ActiveEnginesDialog extends StatelessWidget {
  const _ActiveEnginesDialog({required this.deps});

  final StudioDependencies deps;

  @override
  Widget build(BuildContext context) {
    final palette = StudioPalette.of(context);

    return StoreBuilder<StudioRuntimeSnapshot>(
      store: deps.modelHubController.runtimeStore,
      builder: (BuildContext context, StudioRuntimeSnapshot runtime) {
        return StoreBuilder<SpeechWorkspaceState>(
          store: deps.speechController.store,
          builder: (BuildContext context, SpeechWorkspaceState speech) {
            return StoreBuilder<ImageWorkspaceState>(
              store: deps.imageController.store,
              builder: (BuildContext context, ImageWorkspaceState image) {
                return StoreBuilder<LabModelState>(
                  store: deps.labModelCoordinator.store,
                  builder: (BuildContext context, LabModelState lab) {
                    final hasSpeech =
                        speech.activeTtsModel != null ||
                        speech.activeSttModel != null;
                    final hasLab = lab.loadedLabModels.isNotEmpty;
                    final totalLoaded =
                        (runtime.isReady ? 1 : 0) +
                        (speech.activeTtsModel != null ? 1 : 0) +
                        (speech.activeSttModel != null ? 1 : 0) +
                        (image.activeModel != null ? 1 : 0) +
                        lab.loadedLabModels.length;

                    return AlertDialog(
                      scrollable: true,
                      title: Row(
                        children: <Widget>[
                          Icon(
                            Icons.layers_outlined,
                            size: 20,
                            color: palette.accent,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Active Engines ($totalLoaded)',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      content: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 460),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              'Chat & Coding share the primary LLM engine. Speech, Image, and Playground Lab load independent models so specialized tasks can stay warm or be ejected individually.',
                              style: TextStyle(
                                fontSize: 12,
                                color: palette.textSecondary,
                                height: 1.35,
                              ),
                            ),
                            const SizedBox(height: 12),
                            _EngineSlotRow(
                              title: 'Chat & Coding LLM',
                              subtitle: 'Chat, Coding Agent, Prompting',
                              modelLabel: runtime.isReady
                                  ? '${runtime.activeModelLabel ?? 'Loaded'} · ${runtime.backendName}'
                                  : (runtime.isLoading
                                        ? (runtime.statusMessage ??
                                              'Loading...')
                                        : null),
                              isLoaded: runtime.isReady,
                              isBusy: runtime.isLoading,
                              onEject: runtime.isReady && !runtime.isLoading
                                  ? () => deps.modelHubController
                                        .unloadActiveModel()
                                  : null,
                            ),
                            _EngineSlotRow(
                              title: 'Speech TTS',
                              subtitle: 'Neural text-to-speech synthesis',
                              modelLabel: speech.activeTtsModel?.name,
                              isLoaded: speech.activeTtsModel != null,
                              isBusy: speech.isLoadingTts,
                              onEject: hasSpeech
                                  ? () => deps.speechController.unloadModels()
                                  : null,
                            ),
                            _EngineSlotRow(
                              title: 'Speech STT',
                              subtitle: 'Speech-to-text transcription',
                              modelLabel: speech.activeSttModel?.name,
                              isLoaded: speech.activeSttModel != null,
                              isBusy: speech.isLoadingStt,
                              onEject: hasSpeech
                                  ? () => deps.speechController.unloadModels()
                                  : null,
                            ),
                            _EngineSlotRow(
                              title: 'Image Diffusion',
                              subtitle: 'Stable Diffusion / FLUX checkpoint',
                              modelLabel: image.activeModel?.name,
                              isLoaded: image.activeModel != null,
                              isBusy: image.isLoadingModel,
                              onEject: image.activeModel != null
                                  ? () => deps.imageController.unloadModel()
                                  : null,
                            ),
                            _EngineSlotRow(
                              title: 'Playground & Notebook Lab',
                              subtitle: 'Embeddings, Reranker, Decision Head',
                              modelLabel: hasLab
                                  ? lab.loadedLabModels.entries
                                        .map(
                                          (
                                            MapEntry<
                                              StudioModelSpecialty,
                                              StudioModelDescriptor
                                            >
                                            e,
                                          ) =>
                                              '${_specialtyLabel(e.key)}: ${e.value.name}',
                                        )
                                        .join(' · ')
                                  : null,
                              isLoaded: hasLab,
                              isBusy: lab.loadingModel != null,
                              onEject: hasLab
                                  ? () =>
                                        deps.labModelCoordinator.unloadModels()
                                  : null,
                            ),
                          ],
                        ),
                      ),
                      actions: <Widget>[
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('Close'),
                        ),
                        FilledButton.tonalIcon(
                          key: const Key('free_all_engines_button'),
                          onPressed: totalLoaded == 0
                              ? null
                              : () async {
                                  await Future.wait(<Future<void>>[
                                    if (runtime.isReady)
                                      deps.modelHubController
                                          .unloadActiveModel(),
                                    if (hasSpeech)
                                      deps.speechController.unloadModels(),
                                    if (image.activeModel != null)
                                      deps.imageController.unloadModel(),
                                    if (hasLab)
                                      deps.labModelCoordinator.unloadModels(),
                                  ]);
                                },
                          icon: const Icon(Icons.eject_rounded, size: 16),
                          label: const Text('Free All Memory'),
                        ),
                      ],
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  static String _specialtyLabel(StudioModelSpecialty specialty) {
    return switch (specialty) {
      StudioModelSpecialty.embedding => 'Embed',
      StudioModelSpecialty.reranker => 'Rerank',
      StudioModelSpecialty.decision => 'Decision',
      StudioModelSpecialty.qwen3Asr || StudioModelSpecialty.liteRtAsr => 'STT',
      StudioModelSpecialty.qwen3Tts => 'TTS',
      StudioModelSpecialty.stableDiffusion => 'Image',
      StudioModelSpecialty.generalChat => 'Chat',
    };
  }
}

class _EngineSlotRow extends StatelessWidget {
  const _EngineSlotRow({
    required this.title,
    required this.subtitle,
    required this.modelLabel,
    required this.isLoaded,
    required this.isBusy,
    this.onEject,
  });

  final String title;
  final String subtitle;
  final String? modelLabel;
  final bool isLoaded;
  final bool isBusy;
  final VoidCallback? onEject;

  @override
  Widget build(BuildContext context) {
    final palette = StudioPalette.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: palette.surfaceElevated,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isLoaded
              ? palette.teal.withValues(alpha: 0.4)
              : palette.borderSubtle,
        ),
      ),
      child: Row(
        children: <Widget>[
          StatusPulseDot(
            color: isLoaded
                ? palette.teal
                : (isBusy ? palette.amber : palette.textMuted),
            pulsing: isBusy,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: palette.textPrimary,
                  ),
                ),
                Text(
                  modelLabel ?? '$subtitle · Idle',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: isLoaded ? palette.teal : palette.textMuted,
                  ),
                ),
              ],
            ),
          ),
          if (onEject != null) ...<Widget>[
            const SizedBox(width: 8),
            TextButton(
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              ),
              onPressed: onEject,
              child: const Text('Eject', style: TextStyle(fontSize: 11.5)),
            ),
          ],
        ],
      ),
    );
  }
}
