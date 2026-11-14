part of 'studio_shell_screen.dart';

class _StudioSidebarContent extends StatelessWidget {
  const _StudioSidebarContent({this.onNavigate});

  final VoidCallback? onNavigate;

  Future<void> _importConversationJson(BuildContext context) async {
    final deps = StudioScope.of(context);
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>['json'],
      withData: true,
    );
    final file = res?.files.firstOrNull;
    if (file == null) {
      return;
    }
    try {
      String? content;
      if (file.bytes != null) {
        content = utf8.decode(file.bytes!);
      } else if (file.path != null) {
        final diskBytes = await StudioPlatformFileHelper.readBytesFromPath(
          file.path!,
        );
        if (diskBytes != null) {
          content = utf8.decode(diskBytes);
        }
      }
      if (content == null || content.trim().isEmpty) {
        return;
      }
      await deps.chatController.importFromJson(content);
      deps.shellController.selectWorkspace(StudioWorkspace.chat);
      onNavigate?.call();
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text('Invalid session JSON: $error')),
        );
      }
    }
  }

  Future<void> _renameDialog(
    BuildContext context,
    StudioConversation conversation,
  ) async {
    final deps = StudioScope.of(context);
    final ctrl = TextEditingController(text: conversation.title);
    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          scrollable: true,
          title: const Text('Rename Session'),
          content: TextField(controller: ctrl, autofocus: true),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                deps.chatController.renameConversation(
                  conversation.id,
                  ctrl.text,
                );
                Navigator.of(dialogContext).pop();
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
    ctrl.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final deps = StudioScope.of(context);
    final palette = StudioPalette.of(context);

    return Container(
      decoration: BoxDecoration(
        color: palette.sidebar,
        border: Border(right: BorderSide(color: palette.borderSubtle)),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 12, 10),
              child: Row(
                children: <Widget>[
                  const LlamadartBrandMark(size: 28),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'llamadart Studio',
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.2,
                        color: palette.textPrimary,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const Key('sidebar_new_chat_button'),
                    tooltip: deps.isMobile
                        ? 'New Chat Session'
                        : 'New Chat Session (${StudioTheme.shortcutLabel(context, 'N')})',
                    visualDensity: VisualDensity.compact,
                    onPressed: () async {
                      await deps.chatController.createConversation();
                      deps.shellController.selectWorkspace(
                        StudioWorkspace.chat,
                      );
                      onNavigate?.call();
                    },
                    icon: const Icon(Icons.edit_square, size: 17),
                  ),
                ],
              ),
            ),
            StoreSelector<StudioShellState, StudioWorkspace>(
              store: deps.shellController.store,
              selector: (StudioShellState s) => s.activeWorkspace,
              builder: (BuildContext context, StudioWorkspace activeWs) {
                Widget buildWorkspaceNavItem(StudioWorkspace ws) {
                  final selected = ws == activeWs;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: InkWell(
                      key: Key('nav_workspace_${ws.routeSegment}'),
                      borderRadius: BorderRadius.circular(10),
                      onTap: () {
                        deps.shellController.selectWorkspace(ws);
                        onNavigate?.call();
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 7,
                        ),
                        decoration: BoxDecoration(
                          color: selected
                              ? palette.accentMuted
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: <Widget>[
                            Icon(
                              _StudioShellScreenState._iconFor(ws),
                              size: 17,
                              color: selected
                                  ? palette.accent
                                  : palette.textSecondary,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                ws.label,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: selected
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                  color: selected
                                      ? palette.textPrimary
                                      : palette.textSecondary,
                                ),
                              ),
                            ),
                            if (!deps.isMobile)
                              Text(
                                StudioTheme.shortcutLabel(
                                  context,
                                  '${ws.shortcutDigit}',
                                ),
                                style: TextStyle(
                                  fontSize: 10.5,
                                  color: palette.textMuted,
                                  fontFamilyFallback:
                                      StudioTheme.monoFontFallback,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  );
                }

                Widget buildSectionHeader(String title) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
                    child: Text(
                      title,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.7,
                        color: palette.textMuted,
                      ),
                    ),
                  );
                }

                final modelsSelected = activeWs == StudioWorkspace.models;

                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      StoreBuilder<StudioRuntimeSnapshot>(
                        store: deps.modelHubController.runtimeStore,
                        builder:
                            (
                              BuildContext context,
                              StudioRuntimeSnapshot runtime,
                            ) {
                              final statusColor = switch (runtime.phase) {
                                StudioEnginePhase.ready => palette.teal,
                                StudioEnginePhase.loading ||
                                StudioEnginePhase.unloading => palette.amber,
                                StudioEnginePhase.error => palette.danger,
                                StudioEnginePhase.unloaded => palette.textMuted,
                              };
                              final activeLabel = runtime.isLoading
                                  ? (runtime.statusMessage ??
                                        'Loading model...')
                                  : (runtime.activeModelLabel ??
                                        'No active model · Browse');

                              return InkWell(
                                key: const Key('nav_workspace_models'),
                                borderRadius: BorderRadius.circular(11),
                                onTap: () {
                                  deps.shellController.selectWorkspace(
                                    StudioWorkspace.models,
                                  );
                                  onNavigate?.call();
                                },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 8,
                                  ),
                                  decoration: BoxDecoration(
                                    color: modelsSelected
                                        ? palette.accentMuted
                                        : palette.surfaceElevated,
                                    borderRadius: BorderRadius.circular(11),
                                    border: Border.all(
                                      color: modelsSelected
                                          ? palette.accent.withValues(
                                              alpha: 0.55,
                                            )
                                          : palette.borderSubtle,
                                    ),
                                  ),
                                  child: Row(
                                    children: <Widget>[
                                      StatusPulseDot(
                                        color: statusColor,
                                        pulsing: runtime.isLoading,
                                      ),
                                      const SizedBox(width: 9),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          mainAxisSize: MainAxisSize.min,
                                          children: <Widget>[
                                            Text(
                                              StudioWorkspace.models.label,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: 12.5,
                                                fontWeight: FontWeight.w700,
                                                color: palette.textPrimary,
                                              ),
                                            ),
                                            Text(
                                              activeLabel,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: 10.5,
                                                color: runtime.isReady
                                                    ? palette.teal
                                                    : palette.textMuted,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      if (!deps.isMobile)
                                        Text(
                                          StudioTheme.shortcutLabel(
                                            context,
                                            '${StudioWorkspace.models.shortcutDigit}',
                                          ),
                                          style: TextStyle(
                                            fontSize: 10.5,
                                            color: palette.textMuted,
                                            fontFamilyFallback:
                                                StudioTheme.monoFontFallback,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              );
                            },
                      ),
                      buildSectionHeader('WORKSPACES'),
                      buildWorkspaceNavItem(StudioWorkspace.chat),
                      buildWorkspaceNavItem(StudioWorkspace.coding),
                      buildWorkspaceNavItem(StudioWorkspace.notes),
                      buildSectionHeader('STUDIOS & DIAGNOSTICS'),
                      buildWorkspaceNavItem(StudioWorkspace.speech),
                      buildWorkspaceNavItem(StudioWorkspace.image),
                      buildWorkspaceNavItem(StudioWorkspace.playground),
                    ],
                  ),
                );
              },
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      'SESSIONS',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.7,
                        color: palette.textMuted,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Import JSON session',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _importConversationJson(context),
                    icon: Icon(
                      Icons.file_upload_outlined,
                      size: 15,
                      color: palette.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: TextField(
                onChanged: deps.chatController.setSearchQuery,
                style: const TextStyle(fontSize: 12),
                decoration: const InputDecoration(
                  hintText: 'Filter sessions...',
                  prefixIcon: Icon(Icons.search_rounded, size: 16),
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: StoreBuilder<ChatWorkspaceState>(
                store: deps.chatController.store,
                builder: (BuildContext context, ChatWorkspaceState chatState) {
                  final list = chatState.filteredConversations;
                  return ListView.builder(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    itemCount: list.length,
                    itemBuilder: (BuildContext context, int idx) {
                      final conv = list[idx];
                      final active =
                          conv.id == chatState.activeConversation?.id;
                      return InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () {
                          deps.chatController.selectConversation(conv.id);
                          deps.shellController.selectWorkspace(
                            StudioWorkspace.chat,
                          );
                          onNavigate?.call();
                        },
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 3),
                          padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
                          decoration: BoxDecoration(
                            color: active
                                ? palette.surfaceElevated
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(10),
                            border: active
                                ? Border.all(color: palette.borderSubtle)
                                : null,
                          ),
                          child: Row(
                            children: <Widget>[
                              if (conv.pinned)
                                Padding(
                                  padding: const EdgeInsets.only(right: 6),
                                  child: Icon(
                                    Icons.push_pin_rounded,
                                    size: 13,
                                    color: palette.amber,
                                  ),
                                ),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    Text(
                                      conv.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 12.5,
                                        fontWeight: active
                                            ? FontWeight.w700
                                            : FontWeight.w500,
                                        color: palette.textPrimary,
                                      ),
                                    ),
                                    Text(
                                      conv.previewSnippet,
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
                              PopupMenuButton<String>(
                                iconSize: 16,
                                padding: EdgeInsets.zero,
                                onSelected: (String action) {
                                  switch (action) {
                                    case 'pin':
                                      deps.chatController.togglePinConversation(
                                        conv.id,
                                      );
                                    case 'rename':
                                      _renameDialog(context, conv);
                                    case 'delete':
                                      deps.chatController.deleteConversation(
                                        conv.id,
                                      );
                                  }
                                },
                                itemBuilder: (_) => <PopupMenuEntry<String>>[
                                  PopupMenuItem<String>(
                                    value: 'pin',
                                    child: Text(
                                      conv.pinned ? 'Unpin' : 'Pin to top',
                                    ),
                                  ),
                                  const PopupMenuItem<String>(
                                    value: 'rename',
                                    child: Text('Rename'),
                                  ),
                                  const PopupMenuItem<String>(
                                    value: 'delete',
                                    child: Text('Delete'),
                                  ),
                                ],
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
          ],
        ),
      ),
    );
  }
}
