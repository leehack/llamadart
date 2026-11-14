part of 'mcp_and_skills_sheet.dart';

class _McpServersTab extends StatefulWidget {
  const _McpServersTab();

  @override
  State<_McpServersTab> createState() => _McpServersTabState();
}

class _McpServersTabState extends State<_McpServersTab> {
  final TextEditingController _nameCtrl = TextEditingController();
  final TextEditingController _commandCtrl = TextEditingController();
  final TextEditingController _argsCtrl = TextEditingController();
  final TextEditingController _cwdCtrl = TextEditingController();
  final TextEditingController _urlCtrl = TextEditingController();

  bool _showAddForm = false;
  McpTransportType _transport = McpTransportType.stdio;
  String? _actionError;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _commandCtrl.dispose();
    _argsCtrl.dispose();
    _cwdCtrl.dispose();
    _urlCtrl.dispose();
    super.dispose();
  }

  static List<String> _splitArgs(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return const <String>[];
    }
    final args = <String>[];
    final buf = StringBuffer();
    String? quote;
    for (var i = 0; i < trimmed.length; i++) {
      final ch = trimmed[i];
      if (quote != null) {
        if (ch == quote) {
          quote = null;
        } else {
          buf.write(ch);
        }
        continue;
      }
      if (ch == '"' || ch == "'") {
        quote = ch;
      } else if (ch == ' ' || ch == '\t' || ch == '\n') {
        if (buf.isNotEmpty) {
          args.add(buf.toString());
          buf.clear();
        }
      } else {
        buf.write(ch);
      }
    }
    if (buf.isNotEmpty) {
      args.add(buf.toString());
    }
    return args;
  }

  Future<void> _saveServer({required bool connectNow}) async {
    final deps = StudioScope.of(context);
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(
        () => _actionError = 'Enter a display name for this MCP server.',
      );
      return;
    }
    if (_transport == McpTransportType.stdio &&
        _commandCtrl.text.trim().isEmpty) {
      setState(
        () => _actionError = 'Enter an executable command (e.g. dart or npx).',
      );
      return;
    }
    if (_transport != McpTransportType.stdio && _urlCtrl.text.trim().isEmpty) {
      setState(() => _actionError = 'Enter an HTTP/SSE endpoint URL.');
      return;
    }

    final config = McpServerConfig(
      id: 'mcp_${DateTime.now().microsecondsSinceEpoch}',
      name: name,
      transportType: _transport,
      command: _transport == McpTransportType.stdio
          ? _commandCtrl.text.trim()
          : null,
      args: _transport == McpTransportType.stdio
          ? _splitArgs(_argsCtrl.text)
          : const <String>[],
      workingDirectory:
          _transport == McpTransportType.stdio &&
              _cwdCtrl.text.trim().isNotEmpty
          ? _cwdCtrl.text.trim()
          : null,
      url: _transport != McpTransportType.stdio ? _urlCtrl.text.trim() : null,
      enabled: true,
    );

    setState(() {
      _actionError = null;
      _showAddForm = false;
    });
    _nameCtrl.clear();
    _commandCtrl.clear();
    _argsCtrl.clear();
    _cwdCtrl.clear();
    _urlCtrl.clear();

    await deps.mcpManager.saveServer(config);
    if (connectNow) {
      try {
        await deps.mcpManager.connectServer(config.id);
      } catch (error) {
        if (mounted) {
          setState(() => _actionError = humanizeStudioError(error));
        }
      }
    }
  }

  Future<void> _connectServer(String serverId) async {
    final deps = StudioScope.of(context);
    setState(() => _actionError = null);
    try {
      await deps.mcpManager.connectServer(serverId);
    } catch (error) {
      if (mounted) {
        setState(() => _actionError = humanizeStudioError(error));
      }
    }
  }

  Future<void> _sendResourceToChat(
    McpServerRuntimeState server,
    McpResourceDescriptor resource,
  ) async {
    final deps = StudioScope.of(context);
    try {
      final text = await deps.mcpManager.readResource(
        serverId: server.config.id,
        uri: resource.uri,
      );
      final snippet =
          'Context from MCP server "${server.config.name}" (${resource.uri}):\n\n$text';
      deps.chatController.setComposerDraft(snippet);
      deps.shellController.selectWorkspace(StudioWorkspace.chat);
      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (error) {
      if (mounted) {
        setState(() => _actionError = humanizeStudioError(error));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final deps = StudioScope.of(context);
    final palette = StudioPalette.of(context);

    return StoreBuilder<McpManagerState>(
      store: deps.mcpManager.store,
      builder: (BuildContext context, McpManagerState mcpState) {
        final workspaceRoot = deps.codingController.state.workspaceRoot;
        final untrustedServers = mcpState.untrustedProjectServersFor(
          workspaceRoot,
        );
        return ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            if (untrustedServers.isNotEmpty)
              Container(
                key: const Key('mcp_sheet_untrusted_banner'),
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: palette.amber.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: palette.amber.withValues(alpha: 0.4),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Icon(
                          Icons.shield_outlined,
                          size: 16,
                          color: palette.amber,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Untrusted Repository MCP Config (${untrustedServers.length})',
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                              color: palette.textPrimary,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'For safety, project-defined stdio/HTTP MCP servers are not spawned automatically until you trust this workspace folder.',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: palette.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton.tonalIcon(
                        key: const Key('mcp_sheet_trust_workspace_button'),
                        style: FilledButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                        onPressed: () =>
                            deps.codingController.trustActiveWorkspaceMcp(),
                        icon: const Icon(
                          Icons.verified_user_outlined,
                          size: 15,
                        ),
                        label: const Text('Trust Workspace & Connect'),
                      ),
                    ),
                  ],
                ),
              ),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: palette.surfaceElevated,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: palette.borderSubtle),
              ),
              child: Wrap(
                spacing: 10,
                runSpacing: 10,
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: <Widget>[
                      StudioPillBadge(
                        label: '${mcpState.connectedCount} connected',
                        foreground: mcpState.connectedCount > 0
                            ? palette.teal
                            : palette.textSecondary,
                        monospace: true,
                      ),
                      StudioPillBadge(
                        label: '${mcpState.activeTools.length} tools bridged',
                        foreground: palette.accent,
                        monospace: true,
                      ),
                    ],
                  ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: <Widget>[
                      if (!deps.isWeb)
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                          ),
                          onPressed: () async {
                            setState(() => _actionError = null);
                            try {
                              await deps.mcpManager
                                  .ensureBuiltInDartFlutterServer(
                                    workspaceRoot: deps
                                        .codingController
                                        .state
                                        .workspaceRoot,
                                    autoConnect: true,
                                  );
                              await deps.mcpManager.syncWorkspaceServers(
                                deps.codingController.state.workspaceRoot,
                                autoConnect: true,
                              );
                            } catch (error) {
                              if (mounted) {
                                setState(
                                  () =>
                                      _actionError = humanizeStudioError(error),
                                );
                              }
                            }
                          },
                          icon: const Icon(Icons.refresh_rounded, size: 15),
                          label: const Text('Sync Project MCP'),
                        ),
                      FilledButton.icon(
                        key: const Key('mcp_toggle_add_form_button'),
                        style: FilledButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                        onPressed: () =>
                            setState(() => _showAddForm = !_showAddForm),
                        icon: Icon(
                          _showAddForm
                              ? Icons.close_rounded
                              : Icons.add_rounded,
                          size: 16,
                        ),
                        label: Text(_showAddForm ? 'Cancel' : 'Add MCP Server'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (_actionError != null) ...<Widget>[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: palette.danger.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: palette.danger.withValues(alpha: 0.4),
                  ),
                ),
                child: Text(
                  _actionError!,
                  style: TextStyle(fontSize: 12, color: palette.danger),
                ),
              ),
            ],
            if (_showAddForm) ...<Widget>[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: palette.surfaceElevated,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: palette.borderStrong),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'New MCP Server Connection',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: palette.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      key: const Key('mcp_name_input'),
                      controller: _nameCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Server Display Name',
                        hintText: 'e.g. Workspace Docs or Filesystem',
                      ),
                    ),
                    const SizedBox(height: 10),
                    SegmentedButton<McpTransportType>(
                      style: SegmentedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                      segments: <ButtonSegment<McpTransportType>>[
                        if (!deps.isWeb)
                          const ButtonSegment<McpTransportType>(
                            value: McpTransportType.stdio,
                            label: Text('Stdio'),
                          ),
                        const ButtonSegment<McpTransportType>(
                          value: McpTransportType.streamableHttp,
                          label: Text('Streamable HTTP'),
                        ),
                        const ButtonSegment<McpTransportType>(
                          value: McpTransportType.sse,
                          label: Text('Legacy SSE'),
                        ),
                      ],
                      selected: <McpTransportType>{
                        deps.isWeb && _transport == McpTransportType.stdio
                            ? McpTransportType.streamableHttp
                            : _transport,
                      },
                      onSelectionChanged: (Set<McpTransportType> next) {
                        setState(() => _transport = next.first);
                      },
                    ),
                    const SizedBox(height: 10),
                    if (_transport == McpTransportType.stdio &&
                        !deps.isWeb) ...<Widget>[
                      TextField(
                        key: const Key('mcp_command_input'),
                        controller: _commandCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Command',
                          hintText: 'dart, npx, uvx, or python3',
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        key: const Key('mcp_args_input'),
                        controller: _argsCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Arguments (space-separated)',
                          hintText:
                              '-y @modelcontextprotocol/server-filesystem .',
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        key: const Key('mcp_cwd_input'),
                        controller: _cwdCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Working Directory (optional)',
                        ),
                      ),
                    ] else
                      TextField(
                        key: const Key('mcp_url_input'),
                        controller: _urlCtrl,
                        decoration: const InputDecoration(
                          labelText: 'MCP Endpoint URL',
                          hintText: 'http://127.0.0.1:3000/mcp',
                        ),
                      ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        alignment: WrapAlignment.end,
                        children: <Widget>[
                          OutlinedButton(
                            key: const Key('mcp_save_only_button'),
                            onPressed: () => _saveServer(connectNow: false),
                            child: const Text('Save Only'),
                          ),
                          FilledButton.icon(
                            key: const Key('mcp_save_connect_button'),
                            onPressed: () => _saveServer(connectNow: true),
                            icon: const Icon(Icons.link_rounded, size: 16),
                            label: const Text('Save & Connect'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 12),
            if (mcpState.servers.isEmpty)
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: palette.surfaceElevated,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: palette.borderSubtle),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'No MCP servers configured yet',
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: palette.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Studio automatically loads built-in Dart & Flutter MCP plus project configs from .agents/mcp.json, .mcp.json, and .vscode/mcp.json when available.',
                      style: TextStyle(
                        fontSize: 12,
                        color: palette.textSecondary,
                      ),
                    ),
                  ],
                ),
              )
            else
              for (final server in mcpState.servers)
                _McpServerCard(
                  server: server,
                  onToggleEnabled: (bool v) =>
                      deps.mcpManager.setServerEnabled(server.config.id, v),
                  onConnectToggle: () => server.isConnected
                      ? deps.mcpManager.disconnectServer(server.config.id)
                      : _connectServer(server.config.id),
                  onRemove: server.config.isProjectScoped
                      ? null
                      : () => deps.mcpManager.removeServer(server.config.id),
                  onSendResource: (McpResourceDescriptor r) =>
                      _sendResourceToChat(server, r),
                ),
          ],
        );
      },
    );
  }
}

class _McpServerCard extends StatelessWidget {
  const _McpServerCard({
    required this.server,
    required this.onToggleEnabled,
    required this.onConnectToggle,
    required this.onSendResource,
    this.onRemove,
  });

  final McpServerRuntimeState server;
  final ValueChanged<bool> onToggleEnabled;
  final VoidCallback onConnectToggle;
  final VoidCallback? onRemove;
  final ValueChanged<McpResourceDescriptor> onSendResource;

  @override
  Widget build(BuildContext context) {
    final palette = StudioPalette.of(context);
    final cfg = server.config;

    return Container(
      key: Key('mcp_server_card_${cfg.id}'),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: palette.surfaceElevated,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: server.isConnected
              ? palette.teal.withValues(alpha: 0.45)
              : palette.borderSubtle,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              StatusPulseDot(
                color: switch (server.status) {
                  McpConnectionStatus.connected => palette.teal,
                  McpConnectionStatus.connecting => palette.amber,
                  McpConnectionStatus.error => palette.danger,
                  McpConnectionStatus.disconnected => palette.textMuted,
                },
                pulsing: server.status == McpConnectionStatus.connecting,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      cfg.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: palette.textPrimary,
                      ),
                    ),
                    Text(
                      cfg.endpointSummary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: palette.textMuted,
                        fontFamilyFallback: StudioTheme.monoFontFallback,
                      ),
                    ),
                  ],
                ),
              ),
              Transform.scale(
                scale: 0.85,
                child: Switch.adaptive(
                  value: cfg.enabled,
                  onChanged: onToggleEnabled,
                ),
              ),
              IconButton(
                tooltip: server.isConnected ? 'Disconnect' : 'Connect',
                visualDensity: VisualDensity.compact,
                onPressed: server.status == McpConnectionStatus.connecting
                    ? null
                    : onConnectToggle,
                icon: Icon(
                  server.isConnected
                      ? Icons.link_off_rounded
                      : Icons.link_rounded,
                  size: 18,
                  color: server.isConnected ? palette.amber : palette.teal,
                ),
              ),
              if (onRemove != null)
                IconButton(
                  tooltip: 'Remove server',
                  visualDensity: VisualDensity.compact,
                  onPressed: onRemove,
                  icon: Icon(
                    Icons.delete_outline_rounded,
                    size: 18,
                    color: palette.textMuted,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[
              StudioPillBadge(
                label: cfg.originLabel,
                foreground: cfg.isBuiltIn
                    ? palette.teal
                    : (cfg.isProjectScoped
                          ? palette.accent
                          : palette.textSecondary),
                monospace: true,
              ),
              StudioPillBadge(label: cfg.transportType.label, monospace: true),
              StudioPillBadge(
                label: server.status.label,
                foreground: switch (server.status) {
                  McpConnectionStatus.connected => palette.teal,
                  McpConnectionStatus.connecting => palette.amber,
                  McpConnectionStatus.error => palette.danger,
                  McpConnectionStatus.disconnected => palette.textSecondary,
                },
                monospace: true,
              ),
              if (server.serverVersion != null &&
                  server.serverVersion!.isNotEmpty)
                StudioPillBadge(label: server.serverVersion!, monospace: true),
            ],
          ),
          if (cfg.sourcePath != null && cfg.sourcePath!.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              'Source: ${cfg.sourcePath!}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10.5,
                color: palette.textMuted,
                fontFamilyFallback: StudioTheme.monoFontFallback,
              ),
            ),
          ],
          if (server.errorMessage != null) ...<Widget>[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: palette.danger.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                server.errorMessage!,
                style: TextStyle(fontSize: 11.5, color: palette.danger),
              ),
            ),
          ],
          if (server.tools.isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            Builder(
              builder: (BuildContext context) {
                final deps = StudioScope.of(context);
                final activeCount = server.tools
                    .where((McpToolDescriptor t) => cfg.isToolEnabled(t.name))
                    .length;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'EXPOSED TOOLS ($activeCount / ${server.tools.length} active)',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.6,
                        color: palette.textMuted,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: <Widget>[
                        for (final tool in server.tools)
                          Tooltip(
                            message: tool.description.isEmpty
                                ? tool.name
                                : tool.description,
                            child: FilterChip(
                              key: Key('mcp_tool_chip_${cfg.id}_${tool.name}'),
                              selected: cfg.isToolEnabled(tool.name),
                              showCheckmark: true,
                              visualDensity: VisualDensity.compact,
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              label: Text(
                                tool.exposedToolName,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontFamilyFallback:
                                      StudioTheme.monoFontFallback,
                                  color: cfg.isToolEnabled(tool.name)
                                      ? palette.teal
                                      : palette.textMuted,
                                ),
                              ),
                              onSelected: (bool next) => deps.mcpManager
                                  .setToolEnabled(cfg.id, tool.name, next),
                            ),
                          ),
                      ],
                    ),
                  ],
                );
              },
            ),
          ],
          if (server.resources.isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            Text(
              'RESOURCES (${server.resources.length})',
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: palette.textMuted,
              ),
            ),
            const SizedBox(height: 6),
            for (final resource in server.resources)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        '${resource.name} (${resource.uri})',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: palette.textSecondary,
                          fontFamilyFallback: StudioTheme.monoFontFallback,
                        ),
                      ),
                    ),
                    TextButton.icon(
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: () => onSendResource(resource),
                      icon: const Icon(Icons.send_outlined, size: 14),
                      label: const Text(
                        'Send to Chat',
                        style: TextStyle(fontSize: 11.5),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}
