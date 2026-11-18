part of 'mcp_manager.dart';

/// Immutable snapshot of all configured MCP servers and their live `mcp_dart`
/// tools, resources, and prompts.
@immutable
class McpManagerState {
  /// Creates an [McpManagerState].
  const McpManagerState({
    this.servers = const <McpServerRuntimeState>[],
    this.trustedWorkspaceRoots = const <String>{},
  });

  /// Configured servers in display order.
  final List<McpServerRuntimeState> servers;

  /// Normalized workspace root directories explicitly trusted to spawn
  /// project-scoped `.mcp.json` / `.agents/mcp.json` servers.
  final Set<String> trustedWorkspaceRoots;

  /// Connected servers count.
  int get connectedCount =>
      servers.where((McpServerRuntimeState s) => s.isConnected).length;

  /// Total bridged tools from enabled connected servers (excluding disabled tools).
  List<McpToolDescriptor> get activeTools => <McpToolDescriptor>[
    for (final s in servers)
      if (s.config.enabled && s.isConnected)
        for (final t in s.tools)
          if (s.config.isToolEnabled(t.name)) t,
  ];

  /// Whether [workspaceRoot] has been explicitly trusted by the user.
  bool isWorkspaceTrusted(String? workspaceRoot) {
    if (workspaceRoot == null || workspaceRoot.trim().isEmpty) {
      return false;
    }
    return trustedWorkspaceRoots.contains(
      McpConfigStore.normalizeWorkspaceRoot(workspaceRoot),
    );
  }

  /// Discovered project-scoped MCP servers in [workspaceRoot] blocked from
  /// auto-connecting until [workspaceRoot] is trusted.
  List<McpServerRuntimeState> untrustedProjectServersFor(
    String? workspaceRoot,
  ) {
    if (workspaceRoot == null ||
        workspaceRoot.trim().isEmpty ||
        isWorkspaceTrusted(workspaceRoot)) {
      return const <McpServerRuntimeState>[];
    }
    final targetRoot = McpConfigStore.normalizeWorkspaceRoot(workspaceRoot);
    return servers
        .where(
          (McpServerRuntimeState s) =>
              s.config.isProjectScoped &&
              (s.config.workingDirectory == null ||
                  McpConfigStore.normalizeWorkspaceRoot(
                        s.config.workingDirectory!,
                      ) ==
                      targetRoot),
        )
        .toList(growable: false);
  }

  /// Returns an updated copy of [McpManagerState].
  McpManagerState copyWith({
    List<McpServerRuntimeState>? servers,
    Set<String>? trustedWorkspaceRoots,
  }) {
    return McpManagerState(
      servers: servers ?? this.servers,
      trustedWorkspaceRoots:
          trustedWorkspaceRoots ?? this.trustedWorkspaceRoots,
    );
  }
}

extension _McpManagerListingHelpers on McpManager {
  Future<List<McpResourceDescriptor>> _safeListResources(
    McpClient client,
  ) async {
    try {
      final caps = client.getServerCapabilities();
      if (caps?.resources == null) {
        return const <McpResourceDescriptor>[];
      }
      final serverId = _clients.entries
          .firstWhere(
            (MapEntry<String, McpClient> e) => identical(e.value, client),
          )
          .key;
      final res = await client.listResources();
      return res.resources
          .map(
            (Resource r) => McpResourceDescriptor(
              serverId: serverId,
              uri: r.uri,
              name: r.name,
              description: r.description,
              mimeType: r.mimeType,
            ),
          )
          .toList(growable: false);
    } catch (error, stackTrace) {
      developer.log(
        'Failed to list MCP resources',
        name: 'llamadart_studio.mcp',
        error: error,
        stackTrace: stackTrace,
      );
      return const <McpResourceDescriptor>[];
    }
  }

  Future<List<McpPromptDescriptor>> _safeListPrompts(McpClient client) async {
    try {
      final caps = client.getServerCapabilities();
      if (caps?.prompts == null) {
        return const <McpPromptDescriptor>[];
      }
      final serverId = _clients.entries
          .firstWhere(
            (MapEntry<String, McpClient> e) => identical(e.value, client),
          )
          .key;
      final res = await client.listPrompts();
      return res.prompts
          .map(
            (Prompt p) => McpPromptDescriptor(
              serverId: serverId,
              name: p.name,
              description: p.description,
            ),
          )
          .toList(growable: false);
    } catch (error, stackTrace) {
      developer.log(
        'Failed to list MCP prompts',
        name: 'llamadart_studio.mcp',
        error: error,
        stackTrace: stackTrace,
      );
      return const <McpPromptDescriptor>[];
    }
  }
}
