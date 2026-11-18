import 'package:meta/meta.dart';

/// Supported Model Context Protocol (`mcp_dart`) client transports.
enum McpTransportType {
  /// Local subprocess communicating via newline-delimited JSON-RPC on stdin/stdout.
  stdio('Stdio Process'),

  /// Modern MCP Streamable HTTP / SSE transport.
  streamableHttp('Streamable HTTP'),

  /// Legacy HTTP+SSE compatibility transport.
  sse('Legacy SSE');

  const McpTransportType(this.label);

  /// Human-readable transport label.
  final String label;
}

/// Provenance of an [McpServerConfig].
enum McpServerOrigin {
  /// Manually added by the user in Studio.
  user('Custom'),

  /// Auto-registered built-in server (e.g. Dart & Flutter SDK MCP).
  builtIn('Built-in'),

  /// Discovered from workspace `.agents/mcp.json`, `.mcp.json`, or `.vscode/mcp.json`.
  project('Workspace');

  const McpServerOrigin(this.label);

  /// Human-readable provenance label.
  final String label;
}

/// Persisted configuration for an MCP server managed by Studio via `mcp_dart`.
@immutable
class McpServerConfig {
  /// Creates an [McpServerConfig].
  const McpServerConfig({
    required this.id,
    required this.name,
    required this.transportType,
    this.command,
    this.args = const <String>[],
    this.workingDirectory,
    this.environment = const <String, String>{},
    this.url,
    this.headers = const <String, String>{},
    this.enabled = true,
    this.origin = McpServerOrigin.user,
    this.sourcePath,
    this.autoConnect = false,
    this.disabledTools = const <String>[],
    this.hasCustomToolFilter = false,
  });

  /// Unique server identifier.
  final String id;

  /// Display name shown in Coding/Chat inspector panels.
  final String name;

  /// Transport type (`stdio`, `streamableHttp`, or `sse`).
  final McpTransportType transportType;

  /// Executable command for `stdio` servers (e.g. `npx`, `uvx`, `dart`).
  final String? command;

  /// Command-line arguments for `stdio` servers.
  final List<String> args;

  /// Optional working directory for `stdio` subprocesses.
  final String? workingDirectory;

  /// Additional environment variables passed to `stdio` subprocesses.
  final Map<String, String> environment;

  /// Endpoint URL for `streamableHttp` or `sse` servers.
  final String? url;

  /// Custom HTTP headers for remote transports.
  final Map<String, String> headers;

  /// Whether tools exposed by this connected server are injected into turns.
  final bool enabled;

  /// Where this configuration originated (`user`, `builtIn`, or `project`).
  final McpServerOrigin origin;

  /// Optional workspace-relative config path or SDK note (e.g. `.agents/mcp.json`).
  final String? sourcePath;

  /// Whether Studio should attempt auto-connection when registering this server.
  final bool autoConnect;

  /// Original MCP tool names excluded from prompt injection for this server.
  final List<String> disabledTools;

  /// Whether the user explicitly customized per-tool filtering on this server.
  final bool hasCustomToolFilter;

  /// Whether a tool reported by this server is active for prompt injection.
  bool isToolEnabled(String rawToolName) =>
      !disabledTools.contains(rawToolName);

  /// Whether this is a Studio built-in MCP server.
  bool get isBuiltIn => origin == McpServerOrigin.builtIn;

  /// Whether this server was discovered from workspace project files.
  bool get isProjectScoped => origin == McpServerOrigin.project;

  /// Concise origin badge label for UI cards.
  String get originLabel {
    if (sourcePath != null && sourcePath!.trim().isNotEmpty) {
      return sourcePath!.trim();
    }
    return origin.label;
  }

  /// Concise connection endpoint summary for UI display.
  String get endpointSummary {
    return switch (transportType) {
      McpTransportType.stdio => '${command ?? ''} ${args.join(' ')}'.trim(),
      McpTransportType.streamableHttp ||
      McpTransportType.sse => (url ?? '').trim(),
    };
  }

  /// Returns an updated copy of [McpServerConfig].
  McpServerConfig copyWith({
    String? name,
    McpTransportType? transportType,
    String? command,
    List<String>? args,
    String? workingDirectory,
    Map<String, String>? environment,
    String? url,
    Map<String, String>? headers,
    bool? enabled,
    McpServerOrigin? origin,
    String? sourcePath,
    bool? autoConnect,
    List<String>? disabledTools,
    bool? hasCustomToolFilter,
  }) {
    return McpServerConfig(
      id: id,
      name: name ?? this.name,
      transportType: transportType ?? this.transportType,
      command: command ?? this.command,
      args: args ?? this.args,
      workingDirectory: workingDirectory ?? this.workingDirectory,
      environment: environment ?? this.environment,
      url: url ?? this.url,
      headers: headers ?? this.headers,
      enabled: enabled ?? this.enabled,
      origin: origin ?? this.origin,
      sourcePath: sourcePath ?? this.sourcePath,
      autoConnect: autoConnect ?? this.autoConnect,
      disabledTools: disabledTools ?? this.disabledTools,
      hasCustomToolFilter: hasCustomToolFilter ?? this.hasCustomToolFilter,
    );
  }

  /// Serializes configuration to JSON.
  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'name': name,
      'transportType': transportType.name,
      if (command != null) 'command': command,
      if (args.isNotEmpty) 'args': args,
      if (workingDirectory != null) 'workingDirectory': workingDirectory,
      if (environment.isNotEmpty) 'environment': environment,
      if (url != null) 'url': url,
      if (headers.isNotEmpty) 'headers': headers,
      'enabled': enabled,
      'origin': origin.name,
      if (sourcePath != null) 'sourcePath': sourcePath,
      if (autoConnect) 'autoConnect': true,
      if (disabledTools.isNotEmpty) 'disabledTools': disabledTools,
      if (hasCustomToolFilter) 'hasCustomToolFilter': true,
    };
  }

  /// Restores an [McpServerConfig] from JSON.
  factory McpServerConfig.fromJson(Map<String, Object?> json) {
    final transportName = json['transportType'] as String?;
    final transport = McpTransportType.values.firstWhere(
      (McpTransportType t) => t.name == transportName,
      orElse: () => McpTransportType.stdio,
    );
    final originName = json['origin'] as String?;
    final origin = McpServerOrigin.values.firstWhere(
      (McpServerOrigin o) => o.name == originName,
      orElse: () => McpServerOrigin.user,
    );
    final rawArgs = json['args'];
    final rawEnv = json['environment'];
    final rawHeaders = json['headers'];
    final rawDisabled = json['disabledTools'];
    return McpServerConfig(
      id:
          (json['id'] as String?) ??
          'mcp_${DateTime.now().microsecondsSinceEpoch}',
      name: (json['name'] as String?) ?? 'MCP Server',
      transportType: transport,
      command: json['command'] as String?,
      args: rawArgs is List
          ? rawArgs.whereType<String>().toList(growable: false)
          : const <String>[],
      workingDirectory: json['workingDirectory'] as String?,
      environment: rawEnv is Map
          ? <String, String>{
              for (final e in rawEnv.entries)
                if (e.key is String && e.value != null)
                  e.key as String: e.value.toString(),
            }
          : const <String, String>{},
      url: json['url'] as String?,
      headers: rawHeaders is Map
          ? <String, String>{
              for (final e in rawHeaders.entries)
                if (e.key is String && e.value != null)
                  e.key as String: e.value.toString(),
            }
          : const <String, String>{},
      enabled: (json['enabled'] as bool?) ?? true,
      origin: origin,
      sourcePath: json['sourcePath'] as String?,
      autoConnect: (json['autoConnect'] as bool?) ?? false,
      disabledTools: rawDisabled is List
          ? rawDisabled.whereType<String>().toList(growable: false)
          : const <String>[],
      hasCustomToolFilter: (json['hasCustomToolFilter'] as bool?) ?? false,
    );
  }
}

/// Connection lifecycle state for an MCP server.
enum McpConnectionStatus {
  /// Not currently connected.
  disconnected('Disconnected'),

  /// Handshake & capability discovery in progress.
  connecting('Connecting'),

  /// Connected and ready to invoke tools/resources/prompts.
  connected('Connected'),

  /// Last connection attempt or transport failed.
  error('Error');

  const McpConnectionStatus(this.label);

  /// Human-readable status badge label.
  final String label;
}

/// Discovered MCP tool descriptor.
@immutable
class McpToolDescriptor {
  /// Creates an [McpToolDescriptor].
  const McpToolDescriptor({
    required this.serverId,
    required this.serverName,
    required this.name,
    required this.exposedToolName,
    this.description = '',
    this.inputSchema = const <String, dynamic>{},
  });

  /// Owning server ID.
  final String serverId;

  /// Owning server display name.
  final String serverName;

  /// Original tool name on the MCP server.
  final String name;

  /// Sanitized tool name exposed to `llamadart`.
  final String exposedToolName;

  /// Tool description.
  final String description;

  /// Raw JSON Schema parameters reported by the MCP server.
  final Map<String, dynamic> inputSchema;
}

/// Discovered MCP resource descriptor.
@immutable
class McpResourceDescriptor {
  /// Creates an [McpResourceDescriptor].
  const McpResourceDescriptor({
    required this.serverId,
    required this.uri,
    required this.name,
    this.description,
    this.mimeType,
  });

  /// Owning server ID.
  final String serverId;

  /// Resource URI.
  final String uri;

  /// Resource name.
  final String name;

  /// Optional human-readable description.
  final String? description;

  /// Optional MIME type.
  final String? mimeType;
}

/// Discovered MCP prompt descriptor.
@immutable
class McpPromptDescriptor {
  /// Creates an [McpPromptDescriptor].
  const McpPromptDescriptor({
    required this.serverId,
    required this.name,
    this.description,
  });

  /// Owning server ID.
  final String serverId;

  /// Prompt name.
  final String name;

  /// Optional prompt description.
  final String? description;
}

/// Live runtime state snapshot for a configured MCP server.
@immutable
class McpServerRuntimeState {
  /// Creates an [McpServerRuntimeState].
  const McpServerRuntimeState({
    required this.config,
    this.status = McpConnectionStatus.disconnected,
    this.serverVersion,
    this.tools = const <McpToolDescriptor>[],
    this.resources = const <McpResourceDescriptor>[],
    this.prompts = const <McpPromptDescriptor>[],
    this.errorMessage,
  });

  /// Persisted configuration.
  final McpServerConfig config;

  /// Current connection status.
  final McpConnectionStatus status;

  /// Reported MCP server name/version string after handshake.
  final String? serverVersion;

  /// Tools discovered on this server.
  final List<McpToolDescriptor> tools;

  /// Resources discovered on this server.
  final List<McpResourceDescriptor> resources;

  /// Prompts discovered on this server.
  final List<McpPromptDescriptor> prompts;

  /// Optional error details when [status] is [McpConnectionStatus.error].
  final String? errorMessage;

  /// Whether currently connected.
  bool get isConnected => status == McpConnectionStatus.connected;

  /// Returns an updated copy of [McpServerRuntimeState].
  McpServerRuntimeState copyWith({
    McpServerConfig? config,
    McpConnectionStatus? status,
    String? serverVersion,
    List<McpToolDescriptor>? tools,
    List<McpResourceDescriptor>? resources,
    List<McpPromptDescriptor>? prompts,
    String? errorMessage,
    bool clearErrorMessage = false,
  }) {
    return McpServerRuntimeState(
      config: config ?? this.config,
      status: status ?? this.status,
      serverVersion: serverVersion ?? this.serverVersion,
      tools: tools ?? this.tools,
      resources: resources ?? this.resources,
      prompts: prompts ?? this.prompts,
      errorMessage: clearErrorMessage
          ? null
          : (errorMessage ?? this.errorMessage),
    );
  }
}
