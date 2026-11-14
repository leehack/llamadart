import 'dart:async';
import 'dart:developer' as developer;

import 'package:llamadart/llamadart.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:meta/meta.dart';

import '../../domain/mcp_server_config.dart';
import '../../ports/key_value_store.dart';
import '../../ports/studio_context_ports.dart';
import '../../reactive/state_store.dart';
import '../skills/project_context_discovery.dart';
import 'mcp_config_store.dart';
import 'mcp_tool_schema_adapter.dart';
import 'mcp_transport_factory.dart';

part 'mcp_manager_state.dart';

/// Manages Model Context Protocol (`mcp_dart`) client connections, tool
/// invocation, resource reading, and prompt lookup.
class McpManager implements StudioWorkspaceMcpCoordinator {
  /// Creates an [McpManager].
  McpManager({
    required KeyValueStore keyValueStore,
    McpConfigStore? configStore,
    Transport Function(McpServerConfig config)? transportBuilder,
    this.connectionTimeout = const Duration(seconds: 45),
    this.discoveryTimeout = const Duration(seconds: 30),
  }) : _configStore = configStore ?? McpConfigStore(keyValueStore),
       _transportBuilder = transportBuilder ?? createMcpTransport {
    if (discoveryTimeout <= Duration.zero ||
        discoveryTimeout >= connectionTimeout) {
      throw ArgumentError(
        'discoveryTimeout must be positive and shorter than connectionTimeout.',
      );
    }
  }

  /// Maximum duration of transport startup and the complete MCP handshake.
  final Duration connectionTimeout;

  /// Initial stdio discovery budget, including subprocess cold startup.
  ///
  /// Must be positive and shorter than [connectionTimeout], leaving time for
  /// the SDK's legacy initialization fallback.
  final Duration discoveryTimeout;

  /// Stable server ID for Studio's auto-registered Dart & Flutter SDK MCP.
  static const String builtInDartFlutterServerId = 'builtin:dart_flutter';

  /// Live DTD/app-driver tools on `dart mcp-server` that are disabled by default
  /// to keep local LLM prompt-eval fast (still 1-click toggleable in UI).
  static const List<String> defaultDisabledBuiltInDartTools = <String>[
    'dtd',
    'get_runtime_errors',
    'hot_restart',
    'hot_reload',
    'widget_inspector',
    'flutter_driver_command',
    'vm_service',
  ];

  /// Normalizes a workspace path for stable trust-list comparison.
  static String normalizeWorkspaceRoot(String root) =>
      McpConfigStore.normalizeWorkspaceRoot(root);

  final McpConfigStore _configStore;
  final Transport Function(McpServerConfig config) _transportBuilder;
  final StateStore<McpManagerState> _store = StateStore<McpManagerState>(
    const McpManagerState(),
  );
  final Map<String, McpClient> _clients = <String, McpClient>{};
  final Map<String, Transport> _transports = <String, Transport>{};
  final Map<String, McpClient> _inFlightClients = <String, McpClient>{};
  final Map<String, Transport> _inFlightTransports = <String, Transport>{};
  final Map<String, Future<McpServerRuntimeState>> _inFlightConnects =
      <String, Future<McpServerRuntimeState>>{};
  final Map<String, int> _connectGenerations = <String, int>{};
  bool _disposed = false;

  /// Reactive MCP state store.
  @override
  ReadOnlyStore<McpManagerState> get store => _store;

  /// Current MCP state snapshot.
  @override
  McpManagerState get state => _store.state;

  /// Whether [workspaceRoot] is trusted to spawn project-scoped MCP servers.
  bool isWorkspaceTrusted(String? workspaceRoot) =>
      _store.state.isWorkspaceTrusted(workspaceRoot);

  /// Restores saved MCP server configurations and workspace trust records from
  /// [McpConfigStore].
  Future<void> initialize() async {
    final loaded = await _configStore.load();
    final restoredServers = loaded.servers
        .map((McpServerConfig c) => McpServerRuntimeState(config: c))
        .toList(growable: false);
    _store.set(
      McpManagerState(
        servers: List<McpServerRuntimeState>.unmodifiable(restoredServers),
        trustedWorkspaceRoots: Set<String>.unmodifiable(loaded.trustedRoots),
      ),
    );
  }

  /// Marks [workspaceRoot] as trusted for project-scoped MCP configs and
  /// optionally connects enabled project servers in that workspace.
  @override
  Future<void> trustWorkspace(
    String workspaceRoot, {
    bool connectServers = true,
  }) async {
    final normalized = normalizeWorkspaceRoot(workspaceRoot);
    if (normalized.isEmpty) {
      return;
    }
    final nextTrusted = <String>{
      ..._store.state.trustedWorkspaceRoots,
      normalized,
    };
    _store.update(
      (McpManagerState s) => s.copyWith(
        trustedWorkspaceRoots: Set<String>.unmodifiable(nextTrusted),
      ),
    );
    await _persistTrustedWorkspaces();

    if (!connectServers) {
      return;
    }
    final idsToConnect = <String>[
      for (final s in _store.state.servers)
        if (s.config.isProjectScoped &&
            s.config.enabled &&
            s.config.autoConnect &&
            s.status != McpConnectionStatus.connected &&
            s.status != McpConnectionStatus.connecting &&
            (s.config.workingDirectory == null ||
                normalizeWorkspaceRoot(s.config.workingDirectory!) ==
                    normalized))
          s.config.id,
    ];
    if (idsToConnect.isNotEmpty) {
      await Future.wait(idsToConnect.map(_connectSafe));
    }
  }

  /// Revokes trust for [workspaceRoot] and disconnects any active project-scoped
  /// MCP servers belonging to that workspace.
  Future<void> untrustWorkspace(String workspaceRoot) async {
    final normalized = normalizeWorkspaceRoot(workspaceRoot);
    if (normalized.isEmpty) {
      return;
    }
    final nextTrusted = Set<String>.of(_store.state.trustedWorkspaceRoots)
      ..remove(normalized);
    _store.update(
      (McpManagerState s) => s.copyWith(
        trustedWorkspaceRoots: Set<String>.unmodifiable(nextTrusted),
      ),
    );
    await _persistTrustedWorkspaces();

    final idsToDisconnect = <String>[
      for (final s in _store.state.servers)
        if (s.config.isProjectScoped &&
            (s.isConnected || s.status == McpConnectionStatus.connecting) &&
            (s.config.workingDirectory == null ||
                normalizeWorkspaceRoot(s.config.workingDirectory!) ==
                    normalized))
          s.config.id,
    ];
    for (final id in idsToDisconnect) {
      await disconnectServer(id);
    }
  }

  /// Registers Studio's built-in `Dart & Flutter MCP` (`dart mcp-server`)
  /// when a local `dart` executable is available on the host, optionally
  /// connecting automatically in the background.
  Future<void> ensureBuiltInDartFlutterServer({
    String? workspaceRoot,
    bool autoConnect = true,
  }) async {
    final dartExec = await resolveHostExecutable('dart');
    if (dartExec == null) {
      return;
    }
    final existing = _findServer(builtInDartFlutterServerId);
    final keepExistingFilter = existing?.config.hasCustomToolFilter ?? false;
    final nextConfig = McpServerConfig(
      id: builtInDartFlutterServerId,
      name: 'Dart & Flutter MCP',
      transportType: McpTransportType.stdio,
      command: dartExec,
      args: const <String>['mcp-server'],
      workingDirectory: workspaceRoot,
      enabled: existing?.config.enabled ?? true,
      origin: McpServerOrigin.builtIn,
      sourcePath: 'Dart SDK (dart mcp-server)',
      autoConnect: true,
      disabledTools: keepExistingFilter
          ? existing!.config.disabledTools
          : defaultDisabledBuiltInDartTools,
      hasCustomToolFilter: keepExistingFilter,
    );
    await saveServer(nextConfig);
    if (autoConnect &&
        nextConfig.enabled &&
        existing?.status != McpConnectionStatus.connected &&
        existing?.status != McpConnectionStatus.connecting) {
      unawaited(_connectSafe(builtInDartFlutterServerId));
    }
  }

  /// Synchronizes workspace-scoped MCP servers from `.agents/mcp.json`,
  /// `.mcp.json`, `.vscode/mcp.json`, and `.agents/mcp/*.json`.
  ///
  /// For security, project-scoped stdio/HTTP servers never auto-spawn when
  /// [requireTrustForAutoConnect] is `true` unless [workspaceRoot] has been
  /// explicitly trusted via [trustWorkspace].
  @override
  Future<void> syncWorkspaceServers(
    String? workspaceRoot, {
    bool autoConnect = true,
    bool requireTrustForAutoConnect = true,
  }) async {
    final discovered = await discoverProjectMcpConfigs(workspaceRoot);
    final staleProjectIds = _store.state.servers
        .where(
          (McpServerRuntimeState s) =>
              s.config.isProjectScoped &&
              !discovered.any((McpServerConfig d) => d.id == s.config.id),
        )
        .map((McpServerRuntimeState s) => s.config.id)
        .toList(growable: false);

    for (final staleId in staleProjectIds) {
      await disconnectServer(staleId);
    }

    final existingById = <String, McpServerRuntimeState>{
      for (final s in _store.state.servers) s.config.id: s,
    };

    final nextList = <McpServerRuntimeState>[
      for (final s in _store.state.servers)
        if (!s.config.isProjectScoped)
          s.config.id == builtInDartFlutterServerId &&
                  workspaceRoot != null &&
                  workspaceRoot.trim().isNotEmpty
              ? s.copyWith(
                  config: s.config.copyWith(
                    workingDirectory: workspaceRoot.trim(),
                  ),
                )
              : s,
    ];

    final canAutoConnectProject =
        autoConnect &&
        (!requireTrustForAutoConnect || isWorkspaceTrusted(workspaceRoot));

    final toConnect = <String>[];
    for (final cfg in discovered) {
      final prev = existingById[cfg.id];
      if (prev != null &&
          prev.config.endpointSummary == cfg.endpointSummary &&
          prev.config.workingDirectory == cfg.workingDirectory) {
        nextList.add(
          prev.copyWith(config: cfg.copyWith(enabled: prev.config.enabled)),
        );
        if (canAutoConnectProject &&
            prev.config.enabled &&
            cfg.autoConnect &&
            prev.status == McpConnectionStatus.disconnected) {
          toConnect.add(cfg.id);
        }
      } else {
        if (prev != null && prev.isConnected) {
          await disconnectServer(cfg.id);
        }
        nextList.add(McpServerRuntimeState(config: cfg));
        if (canAutoConnectProject && cfg.enabled && cfg.autoConnect) {
          toConnect.add(cfg.id);
        }
      }
    }

    _store.update(
      (McpManagerState s) => s.copyWith(
        servers: List<McpServerRuntimeState>.unmodifiable(nextList),
      ),
    );
    for (final id in toConnect) {
      unawaited(_connectSafe(id));
    }
  }

  Future<void> _connectSafe(String serverId) async {
    try {
      await connectServer(serverId);
    } catch (_) {
      // Error state is already recorded on McpServerRuntimeState.
    }
  }

  /// Adds or updates an [McpServerConfig] and persists it.
  Future<McpServerConfig> saveServer(McpServerConfig config) async {
    final servers = _store.state.servers.toList();
    final idx = servers.indexWhere(
      (McpServerRuntimeState s) => s.config.id == config.id,
    );
    if (idx >= 0) {
      servers[idx] = servers[idx].copyWith(config: config);
    } else {
      servers.add(McpServerRuntimeState(config: config));
    }
    _store.update(
      (McpManagerState s) => s.copyWith(servers: List.unmodifiable(servers)),
    );
    await _persistConfigs();
    return config;
  }

  /// Removes a configured MCP server, disconnecting its client if running.
  Future<void> removeServer(String serverId) async {
    await disconnectServer(serverId);
    final next = _store.state.servers
        .where((McpServerRuntimeState s) => s.config.id != serverId)
        .toList(growable: false);
    _store.update(
      (McpManagerState s) => s.copyWith(servers: List.unmodifiable(next)),
    );
    await _persistConfigs();
  }

  /// Toggles whether tools from [serverId] are exposed to inference turns.
  Future<void> setServerEnabled(String serverId, bool enabled) async {
    final current = _findServer(serverId);
    if (current == null) {
      return;
    }
    await saveServer(current.config.copyWith(enabled: enabled));
  }

  /// Toggles whether a specific MCP tool [toolName] on [serverId] is injected
  /// into inference prompts.
  Future<void> setToolEnabled(
    String serverId,
    String toolName,
    bool enabled,
  ) async {
    final current = _findServer(serverId);
    if (current == null) {
      return;
    }
    final nextDisabled = current.config.disabledTools.toSet();
    if (enabled) {
      nextDisabled.remove(toolName);
    } else {
      nextDisabled.add(toolName);
    }
    await saveServer(
      current.config.copyWith(
        disabledTools: List<String>.unmodifiable(nextDisabled.toList()..sort()),
        hasCustomToolFilter: true,
      ),
    );
  }

  /// Connects to [serverId] via `mcp_dart` and discovers its tools, resources,
  /// and prompts.
  Future<McpServerRuntimeState> connectServer(String serverId) async {
    if (_disposed) {
      throw StateError('McpManager has been disposed.');
    }
    final entry = _findServer(serverId);
    if (entry == null) {
      throw ArgumentError('Unknown MCP server "$serverId".');
    }

    final existingInFlight = _inFlightConnects[serverId];
    if (existingInFlight != null) {
      return existingInFlight;
    }

    final generation = (_connectGenerations[serverId] ?? 0) + 1;
    _connectGenerations[serverId] = generation;
    late final Future<McpServerRuntimeState> future;
    future = _connectServerInternal(serverId, generation).whenComplete(() {
      if (identical(_inFlightConnects[serverId], future)) {
        unawaited(_inFlightConnects.remove(serverId));
      }
    });
    _inFlightConnects[serverId] = future;
    return future;
  }

  Future<McpServerRuntimeState> _connectServerInternal(
    String serverId,
    int generation,
  ) async {
    final entry = _findServer(serverId);
    if (entry == null) {
      throw ArgumentError('Unknown MCP server "$serverId".');
    }

    await _closeExistingClients(serverId);
    if (_disposed) {
      throw StateError('McpManager has been disposed.');
    }
    if (_connectGenerations[serverId] != generation) {
      throw StateError('MCP connection to "$serverId" was cancelled.');
    }

    _mutateServer(
      serverId,
      (McpServerRuntimeState s) => s.copyWith(
        status: McpConnectionStatus.connecting,
        clearErrorMessage: true,
      ),
    );

    McpClient? client;
    Transport? transport;
    try {
      transport = _transportBuilder(entry.config);
      client = McpClient(
        const Implementation(name: 'llamadart_studio', version: '0.1.0'),
        // Cold stdio startup can exceed the SDK's five-second discovery probe.
        // Leave time for legacy initialization within the connection deadline.
        options: McpClientOptions(legacyDiscoveryTimeout: discoveryTimeout),
      );
      _inFlightClients[serverId] = client;
      _inFlightTransports[serverId] = transport;

      await client.connect(transport).timeout(connectionTimeout);
      if (_disposed ||
          _connectGenerations[serverId] != generation ||
          !identical(_inFlightClients[serverId], client)) {
        await _closeQuietly(client: client, transport: transport);
        throw StateError('MCP connection to "$serverId" was cancelled.');
      }

      _inFlightClients.remove(serverId);
      _inFlightTransports.remove(serverId);
      _clients[serverId] = client;
      _transports[serverId] = transport;

      final serverVersion = client.getServerVersion();
      final versionLabel = serverVersion == null
          ? null
          : '${serverVersion.name} ${serverVersion.version}'.trim();

      final toolsResult = await client.listTools().timeout(
        const Duration(seconds: 15),
      );
      final resources = await _safeListResources(client);
      final prompts = await _safeListPrompts(client);

      if (_disposed || _connectGenerations[serverId] != generation) {
        if (identical(_clients[serverId], client)) {
          _clients.remove(serverId);
        }
        if (identical(_transports[serverId], transport)) {
          _transports.remove(serverId);
        }
        await _closeQuietly(client: client, transport: transport);
        throw StateError(
          _disposed
              ? 'McpManager has been disposed.'
              : 'MCP connection to "$serverId" was cancelled.',
        );
      }

      final existingUsedNames = <String>{
        for (final other in _store.state.servers)
          if (other.config.id != serverId)
            for (final t in other.tools) t.exposedToolName,
      };
      final toolDescriptors = <McpToolDescriptor>[];
      for (final tool in toolsResult.tools) {
        final exposedName = McpToolSchemaAdapter.allocateExposedToolName(
          serverName: entry.config.name,
          rawToolName: tool.name,
          usedNames: existingUsedNames,
        );
        existingUsedNames.add(exposedName);
        toolDescriptors.add(
          McpToolDescriptor(
            serverId: serverId,
            serverName: entry.config.name,
            name: tool.name,
            exposedToolName: exposedName,
            description: tool.description ?? '',
            inputSchema: tool.inputSchema.toJson(),
          ),
        );
      }

      final updated = entry.copyWith(
        status: McpConnectionStatus.connected,
        serverVersion: versionLabel,
        tools: List<McpToolDescriptor>.unmodifiable(toolDescriptors),
        resources: List<McpResourceDescriptor>.unmodifiable(resources),
        prompts: List<McpPromptDescriptor>.unmodifiable(prompts),
        clearErrorMessage: true,
      );
      _mutateServer(serverId, (_) => updated);
      return updated;
    } catch (error) {
      if (identical(_inFlightClients[serverId], client)) {
        _inFlightClients.remove(serverId);
      }
      if (identical(_inFlightTransports[serverId], transport)) {
        _inFlightTransports.remove(serverId);
      }
      if (identical(_clients[serverId], client)) {
        _clients.remove(serverId);
      }
      if (identical(_transports[serverId], transport)) {
        _transports.remove(serverId);
      }
      await _closeQuietly(client: client, transport: transport);

      if (!_disposed && _connectGenerations[serverId] == generation) {
        final failed = entry.copyWith(
          status: McpConnectionStatus.error,
          tools: const <McpToolDescriptor>[],
          resources: const <McpResourceDescriptor>[],
          prompts: const <McpPromptDescriptor>[],
          errorMessage: error.toString(),
        );
        _mutateServer(serverId, (_) => failed);
      }
      rethrow;
    }
  }

  Future<void> _closeExistingClients(String serverId) async {
    final inFlightClient = _inFlightClients.remove(serverId);
    final inFlightTransport = _inFlightTransports.remove(serverId);
    final client = _clients.remove(serverId);
    final transport = _transports.remove(serverId);

    await _closeQuietly(client: inFlightClient, transport: inFlightTransport);
    await _closeQuietly(client: client, transport: transport);
  }

  /// Disconnects a running MCP server client & transport cleanly.
  Future<void> disconnectServer(String serverId) async {
    _connectGenerations[serverId] = (_connectGenerations[serverId] ?? 0) + 1;
    unawaited(_inFlightConnects.remove(serverId));
    await _closeExistingClients(serverId);

    _mutateServer(
      serverId,
      (McpServerRuntimeState s) => s.copyWith(
        status: McpConnectionStatus.disconnected,
        tools: const <McpToolDescriptor>[],
        resources: const <McpResourceDescriptor>[],
        prompts: const <McpPromptDescriptor>[],
        clearErrorMessage: true,
      ),
    );
  }

  Future<void> _closeQuietly({McpClient? client, Transport? transport}) async {
    if (client != null) {
      try {
        await client.close().timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
    if (transport != null) {
      try {
        await transport.close().timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
  }

  /// Calls an MCP tool directly (used by both agent tool execution and tests).
  Future<Map<String, Object?>> callTool({
    required String serverId,
    required String toolName,
    Map<String, dynamic> arguments = const <String, dynamic>{},
  }) async {
    final client = _clients[serverId];
    if (client == null) {
      throw StateError('MCP server "$serverId" is not connected.');
    }
    final result = await client.callTool(
      CallToolRequest(name: toolName, arguments: arguments),
    );
    final textParts = <String>[
      for (final item in result.content)
        if (item is TextContent) item.text,
    ];
    final combinedText = textParts.join('\n').trim();
    return <String, Object?>{
      'isError': result.isError,
      if (combinedText.isNotEmpty) 'text': combinedText,
      if (result.structuredContent != null)
        'structuredContent': result.structuredContent,
      if (combinedText.isEmpty && result.structuredContent == null)
        'content': result.content.map((Content c) => c.toJson()).toList(),
    };
  }

  /// Reads a resource from [serverId] at [uri], returning extracted text.
  Future<String> readResource({
    required String serverId,
    required String uri,
  }) async {
    final client = _clients[serverId];
    if (client == null) {
      throw StateError('MCP server "$serverId" is not connected.');
    }
    final result = await client.readResource(ReadResourceRequest(uri: uri));
    final parts = <String>[];
    for (final content in result.contents) {
      if (content is TextResourceContents) {
        parts.add(content.text);
      } else if (content is BlobResourceContents) {
        parts.add(
          '[Binary resource ${content.mimeType ?? ''} (${content.blob.length} base64 chars)]',
        );
      }
    }
    return parts.join('\n\n');
  }

  /// Builds executable `llamadart` [ToolDefinition]s for all enabled &
  /// connected MCP servers.
  @override
  List<ToolDefinition> buildActiveToolDefinitions() {
    final defs = <ToolDefinition>[];
    for (final tool in _store.state.activeTools) {
      defs.add(
        toLlamaToolDefinition(
          tool,
          handler: (ToolParams params) => callTool(
            serverId: tool.serverId,
            toolName: tool.name,
            arguments: Map<String, dynamic>.from(params.raw),
          ),
        ),
      );
    }
    return defs;
  }

  /// Converts an [McpToolDescriptor] into a `llamadart` [ToolDefinition],
  /// sanitizing its JSON Schema and preferring `ToolParam` definitions when
  /// representable so all chat templates (including `qwen3CoderXml` used by
  /// Qwen3.5 / Qwen3.6) qualify cleanly.
  static ToolDefinition toLlamaToolDefinition(
    McpToolDescriptor tool, {
    required Future<Object?> Function(ToolParams params) handler,
  }) => McpToolSchemaAdapter.toLlamaToolDefinition(tool, handler: handler);

  /// Converts any [ToolDefinition] (including canonical JSON Schema tools)
  /// into a legacy [ToolParam]-backed [ToolDefinition] compatible with all
  /// chat templates including `ChatFormat.qwen3CoderXml` (Qwen3.5 / Qwen3.6).
  static ToolDefinition coerceToLegacyToolDefinition(ToolDefinition tool) =>
      McpToolSchemaAdapter.coerceToLegacyToolDefinition(tool);

  /// Sanitizes an arbitrary JSON Schema from an external MCP tool so both
  /// native GBNF grammar compilers and model chat templates accept it cleanly.
  static Map<String, dynamic> sanitizeMcpInputSchema(
    Map<String, dynamic> rawSchema,
  ) => McpToolSchemaAdapter.sanitizeMcpInputSchema(rawSchema);

  McpServerRuntimeState? _findServer(String serverId) {
    for (final s in _store.state.servers) {
      if (s.config.id == serverId) {
        return s;
      }
    }
    return null;
  }

  void _mutateServer(
    String serverId,
    McpServerRuntimeState Function(McpServerRuntimeState current) fn,
  ) {
    if (_disposed || _store.isDisposed) {
      return;
    }
    final next = _store.state.servers
        .map((McpServerRuntimeState s) => s.config.id == serverId ? fn(s) : s)
        .toList(growable: false);
    _store.update(
      (McpManagerState s) => s.copyWith(servers: List.unmodifiable(next)),
    );
  }

  Future<void> _persistConfigs() => _configStore.saveServers(
    _store.state.servers.map((McpServerRuntimeState s) => s.config),
  );

  Future<void> _persistTrustedWorkspaces() =>
      _configStore.saveTrustedRoots(_store.state.trustedWorkspaceRoots);

  /// Disconnects all active MCP clients and disposes internal state.
  Future<void> dispose() async {
    _disposed = true;
    final ids = <String>{
      ..._clients.keys,
      ..._transports.keys,
      ..._inFlightClients.keys,
      ..._inFlightTransports.keys,
    }.toList(growable: false);
    for (final id in ids) {
      await disconnectServer(id);
    }
    await _store.dispose();
  }
}
