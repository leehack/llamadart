part of 'studio_shell_screen.dart';

class _StudioTopBar extends StatelessWidget {
  const _StudioTopBar({
    required this.isCompactMobile,
    required this.isWideDesktop,
    required this.onOpenLeftDrawer,
    required this.onOpenInspectorDrawer,
  });

  final bool isCompactMobile;
  final bool isWideDesktop;
  final VoidCallback onOpenLeftDrawer;
  final VoidCallback onOpenInspectorDrawer;

  @override
  Widget build(BuildContext context) {
    final deps = StudioScope.of(context);
    final palette = StudioPalette.of(context);

    return Container(
      height: 54,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: palette.canvas,
        border: Border(bottom: BorderSide(color: palette.borderSubtle)),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints barConstraints) {
            final showBackendBadge =
                !isCompactMobile && barConstraints.maxWidth >= 700;
            final showFullCommandLabel =
                !isCompactMobile && barConstraints.maxWidth >= 560;
            final showEnginesLabel =
                !isCompactMobile && barConstraints.maxWidth >= 640;

            return Row(
              children: <Widget>[
                if (!isWideDesktop)
                  IconButton(
                    key: const Key('open_sidebar_drawer_button'),
                    tooltip: 'Sessions & Workspaces',
                    visualDensity: VisualDensity.compact,
                    onPressed: onOpenLeftDrawer,
                    icon: const Icon(Icons.menu_rounded, size: 20),
                  ),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: StoreBuilder<StudioRuntimeSnapshot>(
                      store: deps.modelHubController.runtimeStore,
                      builder:
                          (
                            BuildContext context,
                            StudioRuntimeSnapshot runtime,
                          ) {
                            return Builder(
                              builder: (BuildContext pillContext) {
                                return InkWell(
                                  key: const Key('topbar_model_pill'),
                                  borderRadius: BorderRadius.circular(10),
                                  onTap: () => _openQuickModelSwitcher(
                                    pillContext,
                                    deps,
                                    palette,
                                    runtime,
                                  ),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 6,
                                    ),
                                    decoration: BoxDecoration(
                                      color: palette.surfaceElevated,
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(
                                        color: palette.borderSubtle,
                                      ),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: <Widget>[
                                        StatusPulseDot(
                                          color: switch (runtime.phase) {
                                            StudioEnginePhase.ready =>
                                              palette.teal,
                                            StudioEnginePhase.loading ||
                                            StudioEnginePhase.unloading =>
                                              palette.amber,
                                            StudioEnginePhase.error =>
                                              palette.danger,
                                            StudioEnginePhase.unloaded =>
                                              palette.textMuted,
                                          },
                                          pulsing: runtime.isLoading,
                                        ),
                                        const SizedBox(width: 8),
                                        Flexible(
                                          child: Text(
                                            runtime.isLoading
                                                ? (runtime.statusMessage ??
                                                      'Loading model...')
                                                : (runtime.activeModelLabel ??
                                                      'Select local model...'),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 12.5,
                                              fontWeight: FontWeight.w600,
                                              color: palette.textPrimary,
                                            ),
                                          ),
                                        ),
                                        if (showBackendBadge &&
                                            runtime.isReady) ...<Widget>[
                                          const SizedBox(width: 8),
                                          StudioPillBadge(
                                            label: runtime.backendName,
                                            foreground: palette.teal,
                                            monospace: true,
                                          ),
                                        ],
                                        const SizedBox(width: 4),
                                        Icon(
                                          Icons.unfold_more_rounded,
                                          size: 16,
                                          color: palette.textMuted,
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            );
                          },
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                _ActiveEnginesTopBarButton(
                  showLabel: showEnginesLabel,
                  onPressed: () => _showActiveEnginesDialog(context, deps),
                ),
                const SizedBox(width: 4),
                if (showFullCommandLabel)
                  OutlinedButton.icon(
                    key: const Key('open_command_palette_button'),
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                    ),
                    onPressed: () => showStudioCommandPalette(context),
                    icon: const Icon(Icons.search_rounded, size: 15),
                    label: Text(
                      'Commands · ${StudioTheme.shortcutLabel(context, 'K')}',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: palette.textSecondary,
                        fontFamilyFallback: StudioTheme.monoFontFallback,
                      ),
                    ),
                  )
                else
                  IconButton(
                    key: const Key('open_command_palette_button'),
                    tooltip:
                        'Command Palette (${StudioTheme.shortcutLabel(context, 'K')})',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => showStudioCommandPalette(context),
                    icon: const Icon(Icons.search_rounded, size: 19),
                  ),
                const SizedBox(width: 2),
                StoreSelector<StudioShellState, StudioAppearance>(
                  store: deps.shellController.store,
                  selector: (StudioShellState s) => s.settings.appearance,
                  builder: (BuildContext context, StudioAppearance appearance) {
                    return IconButton(
                      tooltip: 'Cycle Appearance (${appearance.name})',
                      visualDensity: VisualDensity.compact,
                      onPressed: () {
                        final next = switch (appearance) {
                          StudioAppearance.system => StudioAppearance.dark,
                          StudioAppearance.dark => StudioAppearance.light,
                          StudioAppearance.light => StudioAppearance.system,
                        };
                        deps.shellController.setAppearance(next);
                      },
                      icon: Icon(switch (appearance) {
                        StudioAppearance.dark => Icons.dark_mode_outlined,
                        StudioAppearance.light => Icons.light_mode_outlined,
                        StudioAppearance.system =>
                          Icons.brightness_auto_outlined,
                      }, size: 19),
                    );
                  },
                ),
                IconButton(
                  key: const Key('toggle_inspector_button'),
                  tooltip: deps.isMobile
                      ? 'Session Inspector'
                      : 'Session Inspector (${StudioTheme.shortcutLabel(context, 'I')})',
                  visualDensity: VisualDensity.compact,
                  onPressed: isWideDesktop
                      ? deps.shellController.toggleInspector
                      : onOpenInspectorDrawer,
                  icon: const Icon(Icons.tune_rounded, size: 19),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _showActiveEnginesDialog(
    BuildContext context,
    StudioDependencies deps,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        return _ActiveEnginesDialog(deps: deps);
      },
    );
  }

  Future<void> _openQuickModelSwitcher(
    BuildContext pillContext,
    StudioDependencies deps,
    StudioPalette palette,
    StudioRuntimeSnapshot runtime,
  ) async {
    final installed = deps.modelHubController.installedChatModels();
    if (installed.isEmpty && !runtime.isReady) {
      deps.shellController.selectWorkspace(StudioWorkspace.models);
      return;
    }

    final box = pillContext.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.maybeOf(pillContext)?.context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) {
      deps.shellController.selectWorkspace(StudioWorkspace.models);
      return;
    }

    final topLeft = box.localToGlobal(Offset.zero, ancestor: overlay);
    final bottomRight = box.localToGlobal(
      box.size.bottomRight(Offset.zero),
      ancestor: overlay,
    );
    final position = RelativeRect.fromRect(
      Rect.fromLTRB(
        topLeft.dx,
        bottomRight.dy + 4,
        bottomRight.dx,
        bottomRight.dy + 4,
      ),
      Offset.zero & overlay.size,
    );

    const browseHubAction = '__browse_model_hub__';
    const unloadAction = '__unload_active_model__';
    final modelsById = <String, StudioModelDescriptor>{
      for (final m in installed.take(12)) m.id: m,
    };

    final selected = await showMenu<String>(
      context: pillContext,
      position: position,
      constraints: BoxConstraints(
        minWidth: 260,
        maxWidth: math.min(380, overlay.size.width - 24),
      ),
      items: <PopupMenuEntry<String>>[
        if (modelsById.isNotEmpty)
          PopupMenuItem<String>(
            enabled: false,
            height: 28,
            child: Text(
              'INSTALLED CHAT MODELS (${installed.length})',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: palette.textMuted,
              ),
            ),
          ),
        for (final model in modelsById.values)
          PopupMenuItem<String>(
            key: Key('quick_model_${model.id}'),
            value: model.id,
            enabled:
                !runtime.isLoading &&
                deps.modelHubController.state.activatingDescriptor == null,
            child: Row(
              children: <Widget>[
                Icon(
                  runtime.activeDescriptor?.id == model.id && runtime.isReady
                      ? Icons.check_circle_rounded
                      : Icons.memory_rounded,
                  size: 16,
                  color:
                      runtime.activeDescriptor?.id == model.id &&
                          runtime.isReady
                      ? palette.teal
                      : palette.textMuted,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        model.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: palette.textPrimary,
                        ),
                      ),
                      if (model.quantizationLabel != null &&
                          model.quantizationLabel!.isNotEmpty)
                        Text(
                          model.quantizationLabel!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color: palette.textMuted,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        if (modelsById.isNotEmpty || runtime.isReady) const PopupMenuDivider(),
        if (runtime.isReady)
          PopupMenuItem<String>(
            key: const Key('quick_model_unload'),
            value: unloadAction,
            child: Row(
              children: <Widget>[
                Icon(Icons.eject_rounded, size: 16, color: palette.amber),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Unload active model',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: palette.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        PopupMenuItem<String>(
          key: const Key('quick_model_browse_hub'),
          value: browseHubAction,
          child: Row(
            children: <Widget>[
              Icon(Icons.hub_outlined, size: 16, color: palette.accent),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Browse Model Hub...',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: palette.textPrimary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );

    if (selected == null) {
      return;
    }
    if (selected == browseHubAction) {
      deps.shellController.selectWorkspace(StudioWorkspace.models);
      return;
    }
    if (deps.modelHubController.runtimeStore.state.isLoading ||
        deps.modelHubController.state.activatingDescriptor != null) {
      return;
    }
    if (selected == unloadAction) {
      await deps.modelHubController.unloadActiveModel();
      return;
    }
    final chosen = modelsById[selected];
    if (chosen != null) {
      unawaited(deps.modelHubController.activateChatModel(chosen));
    }
  }
}

class _SafeBootRecoveryBanner extends StatelessWidget {
  const _SafeBootRecoveryBanner({required this.alert, required this.onDismiss});

  final BootRecoveryAlert alert;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final palette = StudioPalette.of(context);
    return Container(
      key: const Key('safe_boot_recovery_banner'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: palette.amber.withValues(alpha: 0.14),
        border: Border(bottom: BorderSide(color: palette.borderSubtle)),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.shield_outlined, size: 18, color: palette.amber),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Safe Mode Recovery: Previous launch interrupted while loading "${alert.modelName}". Auto-load was paused so you can lower GPU layers or context size first.',
              style: TextStyle(fontSize: 12, color: palette.textPrimary),
            ),
          ),
          TextButton(onPressed: onDismiss, child: const Text('Dismiss')),
        ],
      ),
    );
  }
}

class _ActiveEnginesTopBarButton extends StatelessWidget {
  const _ActiveEnginesTopBarButton({
    required this.showLabel,
    required this.onPressed,
  });

  final bool showLabel;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final deps = StudioScope.of(context);
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
                    final activeCount =
                        (runtime.isReady ? 1 : 0) +
                        (speech.activeTtsModel != null ? 1 : 0) +
                        (speech.activeSttModel != null ? 1 : 0) +
                        (image.activeModel != null ? 1 : 0) +
                        lab.loadedLabModels.length;
                    final hasLoaded = activeCount > 0;

                    if (!showLabel) {
                      return IconButton(
                        key: const Key('topbar_engines_button'),
                        tooltip: activeCount == 0
                            ? 'Active Engines (0 loaded)'
                            : 'Active Engines ($activeCount loaded)',
                        visualDensity: VisualDensity.compact,
                        onPressed: onPressed,
                        icon: Badge(
                          isLabelVisible: hasLoaded,
                          backgroundColor: palette.teal,
                          textColor: palette.canvas,
                          label: Text('$activeCount'),
                          child: Icon(
                            Icons.layers_outlined,
                            size: 19,
                            color: hasLoaded
                                ? palette.teal
                                : palette.textSecondary,
                          ),
                        ),
                      );
                    }

                    return OutlinedButton.icon(
                      key: const Key('topbar_engines_button'),
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        side: BorderSide(
                          color: hasLoaded
                              ? palette.teal.withValues(alpha: 0.45)
                              : palette.borderSubtle,
                        ),
                      ),
                      onPressed: onPressed,
                      icon: Icon(
                        Icons.layers_outlined,
                        size: 15,
                        color: hasLoaded ? palette.teal : palette.textMuted,
                      ),
                      label: Text(
                        hasLoaded ? 'Engines ($activeCount)' : 'Engines',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: hasLoaded
                              ? FontWeight.w700
                              : FontWeight.w500,
                          color: hasLoaded
                              ? palette.teal
                              : palette.textSecondary,
                        ),
                      ),
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
}
