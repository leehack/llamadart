part of 'coding_workspace_view.dart';

extension _CodingWorkspaceHeaderExtension on _CodingWorkspaceViewState {
  Widget _buildHeader(
    BuildContext context,
    StudioDependencies deps,
    StudioPalette palette,
    CodingWorkspaceState codingState,
    McpManagerState mcpState,
    SkillRegistryState skillState,
    ModelHubState hubState,
    StudioRuntimeSnapshot runtime, {
    bool compact = false,
    bool setupSheet = false,
  }) {
    final modelStrip = <StudioModelDescriptor>[];
    final seenIds = <String>{};
    final seenFilenames = <String>{};

    void addModelIfNew(StudioModelDescriptor m) {
      if (!m.isSupportedOn(isWeb: deps.isWeb, isMobile: deps.isMobile)) {
        return;
      }
      final fn = m.filename.toLowerCase();
      if (!seenIds.add(m.id) || (fn.isNotEmpty && !seenFilenames.add(fn))) {
        return;
      }
      modelStrip.add(m);
    }

    for (final m in CodingWorkspaceController.recommendedCodingModels) {
      addModelIfNew(m);
    }
    for (final m in deps.modelHubController.installedChatModels()) {
      addModelIfNew(m);
    }

    bool isModelInstalled(StudioModelDescriptor m) {
      if (hubState.cachedModelIds.contains(m.id)) {
        return true;
      }
      final fn = m.filename.toLowerCase();
      return hubState.localModels.any(
        (StudioModelDescriptor l) =>
            l.id == m.id || (fn.isNotEmpty && l.filename.toLowerCase() == fn),
      );
    }

    bool isModelActive(StudioModelDescriptor m) {
      if (!runtime.isReady || runtime.activeDescriptor == null) {
        return false;
      }
      final active = runtime.activeDescriptor!;
      return active.id == m.id ||
          (m.filename.isNotEmpty &&
              active.filename.toLowerCase() == m.filename.toLowerCase());
    }

    final localWorkspaceAction = TextButton.icon(
      key: Key(
        setupSheet || _showSetup
            ? 'coding_create_local_workspace_setup_button'
            : 'coding_create_local_workspace_button',
      ),
      onPressed:
          _creatingLocalWorkspace || _pickingFolder || _openingLocalWorkspace
          ? null
          : () {
              if (setupSheet) Navigator.pop(context);
              _createLocalWorkspace();
            },
      icon: _creatingLocalWorkspace
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.create_new_folder_outlined, size: 18),
      label: Text(
        _creatingLocalWorkspace
            ? 'Creating workspace…'
            : 'Create local workspace',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );

    final actionButtons = <Widget>[
      if (!deps.isWeb && !deps.isMobile)
        IconButton(
          key: const Key('coding_manual_path_button'),
          tooltip: 'Enter workspace path',
          visualDensity: VisualDensity.compact,
          onPressed: _openManualPathDialog,
          icon: const Icon(Icons.edit_location_alt_outlined, size: 17),
        ),
      OutlinedButton.icon(
        key: const Key('coding_open_mcp_button'),
        style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
        onPressed: () => showMcpAndSkillsSheet(context, initialTab: 0),
        icon: const Icon(Icons.cable_rounded, size: 15),
        label: Text(
          'MCP (${mcpState.connectedCount}/${mcpState.servers.length})',
          style: const TextStyle(fontSize: 12),
        ),
      ),
      OutlinedButton.icon(
        key: const Key('coding_open_skills_button'),
        style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
        onPressed: () => showMcpAndSkillsSheet(context, initialTab: 1),
        icon: const Icon(Icons.auto_fix_high_outlined, size: 15),
        label: Text(
          'Skills (${skillState.activeSkills.length})',
          style: const TextStyle(fontSize: 12),
        ),
      ),
      if (!deps.isWeb && !deps.isMobile)
        FilterChip(
          key: const Key('coding_shell_toggle'),
          label: const Text('bash', style: TextStyle(fontSize: 11.5)),
          selected: codingState.allowShellCommandTool,
          onSelected: deps.codingController.setAllowShellCommandTool,
        ),
      if (!deps.isWeb && !deps.isMobile && codingState.allowShellCommandTool)
        FilterChip(
          key: const Key('coding_confirm_bash_toggle'),
          label: const Text(
            'Ask before bash',
            style: TextStyle(fontSize: 11.5),
          ),
          selected: codingState.confirmShellCommands,
          onSelected: deps.codingController.setConfirmShellCommands,
        ),
      IconButton(
        key: const Key('coding_clear_button'),
        tooltip: 'Clear coding session',
        visualDensity: VisualDensity.compact,
        onPressed: deps.codingController.clearSession,
        icon: const Icon(Icons.delete_sweep_outlined, size: 18),
      ),
    ];

    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 16 : 24,
        vertical: compact ? 0 : 12,
      ),
      decoration: BoxDecoration(
        color: palette.canvas,
        border: Border(bottom: BorderSide(color: palette.borderSubtle)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (!setupSheet)
            Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      if (deps.isMobile &&
                          !deps.isWeb &&
                          (codingState.workspaceRoot == null ||
                              _creatingLocalWorkspace))
                        localWorkspaceAction
                      else
                        Text(
                          compact
                              ? (codingState.workspaceRoot
                                        ?.replaceAll('\\', '/')
                                        .split('/')
                                        .last ??
                                    'Open folder')
                              : 'Coding Agent',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: palette.textPrimary,
                          ),
                        ),
                      if (!compact) const SizedBox(height: 4),
                      if (!compact)
                        Text(
                          codingState.workspaceRoot ??
                              'Choose a folder to work with your code',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: palette.textMuted,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (!deps.isWeb)
                  IconButton(
                    key: const Key('coding_pick_folder_button'),
                    tooltip: 'Open workspace folder',
                    onPressed:
                        _pickingFolder ||
                            _creatingLocalWorkspace ||
                            _openingLocalWorkspace
                        ? null
                        : _pickFolder,
                    icon: const Icon(Icons.folder_open_rounded, size: 20),
                  ),
                if (!compact)
                  IconButton(
                    key: const Key('coding_explorer_toggle'),
                    tooltip: _showExplorer ? 'Hide files' : 'Show files',
                    isSelected: _showExplorer,
                    onPressed: () =>
                        _updateState(() => _showExplorer = !_showExplorer),
                    icon: const Icon(Icons.view_sidebar_outlined, size: 20),
                  ),
                IconButton(
                  key: const Key('coding_setup_toggle'),
                  tooltip: _showSetup ? 'Hide coding setup' : 'Coding setup',
                  isSelected: _showSetup,
                  onPressed: () {
                    if (!compact) {
                      _updateState(() => _showSetup = !_showSetup);
                      return;
                    }
                    showModalBottomSheet<void>(
                      context: context,
                      isScrollControlled: true,
                      showDragHandle: true,
                      builder: (sheetContext) => Padding(
                        padding: EdgeInsets.only(
                          bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
                        ),
                        child: SafeArea(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Align(
                                alignment: Alignment.centerRight,
                                child: TextButton(
                                  key: const Key('coding_setup_done'),
                                  onPressed: () => Navigator.pop(sheetContext),
                                  child: const Text('Done'),
                                ),
                              ),
                              StoreBuilder<McpManagerState>(
                                store: deps.mcpManager.store,
                                builder: (context, mcp) =>
                                    StoreBuilder<SkillRegistryState>(
                                      store: deps.skillRegistry.store,
                                      builder: (context, skills) =>
                                          StoreBuilder<ModelHubState>(
                                            store:
                                                deps.modelHubController.store,
                                            builder: (context, hub) =>
                                                StoreBuilder<
                                                  StudioRuntimeSnapshot
                                                >(
                                                  store: deps
                                                      .modelHubController
                                                      .runtimeStore,
                                                  builder: (context, runtime) =>
                                                      StoreBuilder<
                                                        CodingWorkspaceState
                                                      >(
                                                        store: deps
                                                            .codingController
                                                            .store,
                                                        builder:
                                                            (context, state) =>
                                                                _buildHeader(
                                                                  context,
                                                                  deps,
                                                                  palette,
                                                                  state,
                                                                  mcp,
                                                                  skills,
                                                                  hub,
                                                                  runtime,
                                                                  compact: true,
                                                                  setupSheet:
                                                                      true,
                                                                ),
                                                      ),
                                                ),
                                          ),
                                    ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                  icon: const Icon(Icons.tune_rounded, size: 20),
                ),
              ],
            ),
          if (deps.isWeb && !setupSheet)
            const Text('Local workspace files are unavailable on Web.'),
          if (!compact) const SizedBox(height: 10),
          if (!compact && !setupSheet)
            Row(
              children: <Widget>[
                Icon(
                  runtime.isReady
                      ? Icons.check_circle_outline
                      : Icons.circle_outlined,
                  size: 14,
                  color: runtime.isReady ? palette.teal : palette.textMuted,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    runtime.activeModelLabel ??
                        'Select a coding model in setup',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: palette.textSecondary,
                    ),
                  ),
                ),
                TextButton(
                  key: const Key('coding_model_setup_button'),
                  onPressed: () => _updateState(() => _showSetup = !_showSetup),
                  child: Text(
                    runtime.isReady ? 'Change model' : 'Choose model',
                  ),
                ),
              ],
            ),
          if (_showSetup || setupSheet)
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: setupSheet
                    ? ((MediaQuery.sizeOf(context).height -
                                  MediaQuery.viewInsetsOf(context).bottom -
                                  MediaQuery.viewPaddingOf(context).vertical -
                                  120) *
                              0.85)
                          .clamp(0.0, double.infinity)
                    : MediaQuery.sizeOf(context).height * 0.32,
              ),
              child: SingleChildScrollView(
                key: const Key('coding_setup_panel'),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const SizedBox(height: 8),
                    if (deps.isMobile && !deps.isWeb)
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          localWorkspaceAction,
                          TextButton.icon(
                            key: const Key(
                              'coding_open_local_workspaces_button',
                            ),
                            onPressed:
                                _creatingLocalWorkspace ||
                                    _pickingFolder ||
                                    _openingLocalWorkspace
                                ? null
                                : () {
                                    if (setupSheet) Navigator.pop(context);
                                    _openLocalWorkspace();
                                  },
                            icon: const Icon(
                              Icons.folder_open_rounded,
                              size: 18,
                            ),
                            label: const Text('Open local workspace'),
                          ),
                        ],
                      ),
                    if (deps.isMobile)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 12),
                        child: Text(
                          'Local commands and process MCP servers are unavailable on mobile. Network MCP remains available. Create a local workspace in app storage for file tools. Files persist across restarts until app data is removed; use Copy in file details to copy text elsewhere. External provider folders may be inaccessible; local creation does not grant provider access.',
                        ),
                      ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: actionButtons,
                    ),
                    if (modelStrip.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 10),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: <Widget>[
                            Text(
                              'Coding Models:',
                              style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                                color: palette.textMuted,
                              ),
                            ),
                            const SizedBox(width: 8),
                            for (final model in modelStrip)
                              Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: ActionChip(
                                  key: Key('coding_model_chip_${model.id}'),
                                  avatar:
                                      (hubState.activatingDescriptor?.id ==
                                              model.id ||
                                          _pendingModel?.id == model.id)
                                      ? SizedBox(
                                          width: 14,
                                          height: 14,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: palette.accent,
                                          ),
                                        )
                                      : Icon(
                                          isModelActive(model)
                                              ? Icons.check_circle_rounded
                                              : (isModelInstalled(model)
                                                    ? Icons.bolt_rounded
                                                    : Icons
                                                          .download_for_offline_outlined),
                                          size: 15,
                                          color: isModelActive(model)
                                              ? palette.teal
                                              : palette.accent,
                                        ),
                                  label: Text(
                                    '${model.name} (${model.sizeLabel(isWeb: deps.isWeb)})',
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      fontWeight: isModelActive(model)
                                          ? FontWeight.w700
                                          : FontWeight.w500,
                                    ),
                                  ),
                                  onPressed:
                                      (runtime.isLoading ||
                                          hubState.activatingDescriptor !=
                                              null ||
                                          _pendingModel != null)
                                      ? null
                                      : () => _activateCodingModel(deps, model),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    SingleChildScrollView(
                      key: const Key('coding_active_tools_strip'),
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: <Widget>[
                          Text(
                            'Tools:',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: palette.textMuted,
                            ),
                          ),
                          const SizedBox(width: 6),
                          if (codingState.activeCoreTools.isEmpty)
                            Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: StudioPillBadge(
                                label: 'Select folder for read · write · edit · grep · ls',
                                foreground: palette.textMuted,
                                monospace: true,
                              ),
                            )
                          else
                            for (final toolName in codingState.activeCoreTools)
                              Padding(
                                padding: const EdgeInsets.only(right: 5),
                                child: StudioPillBadge(
                                  label: toolName,
                                  foreground: toolName == 'bash'
                                      ? palette.amber
                                      : palette.accent,
                                  monospace: true,
                                ),
                              ),
                          Padding(
                            padding: const EdgeInsets.only(right: 5),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(8),
                              onTap: () =>
                                  showMcpAndSkillsSheet(context, initialTab: 0),
                              child: StudioPillBadge(
                                label:
                                    'MCP: ${mcpState.activeTools.length} (${mcpState.connectedCount}/${mcpState.servers.length})',
                                foreground: mcpState.activeTools.isNotEmpty
                                    ? palette.teal
                                    : palette.textSecondary,
                                monospace: true,
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(right: 5),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(8),
                              onTap: () =>
                                  showMcpAndSkillsSheet(context, initialTab: 1),
                              child: StudioPillBadge(
                                label:
                                    'Skills: ${skillState.activeSkills.length}',
                                foreground: skillState.activeSkills.isNotEmpty
                                    ? palette.amber
                                    : palette.textSecondary,
                                monospace: true,
                              ),
                            ),
                          ),
                          InkWell(
                            borderRadius: BorderRadius.circular(8),
                            onTap: () =>
                                showMcpAndSkillsSheet(context, initialTab: 2),
                            child: StudioPillBadge(
                              label: codingState.agentsContext.hasInstructions
                                  ? 'AGENTS.md (${codingState.agentsContext.sourceFiles.length})'
                                  : 'AGENTS.md (none)',
                              foreground:
                                  codingState.agentsContext.hasInstructions
                                  ? palette.teal
                                  : palette.textMuted,
                              monospace: true,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
