import '../../domain/mcp_server_config.dart';
import 'project_context_discovery.dart';

/// Web stub returning an empty [ProjectAgentsContext].
Future<ProjectAgentsContext> discoverProjectAgentsContextImpl(
  String? workspaceRoot,
) async => ProjectAgentsContext.empty;

/// Web stub returning no project MCP configs.
Future<List<McpServerConfig>> discoverProjectMcpConfigsImpl(
  String? workspaceRoot,
) async => const <McpServerConfig>[];

/// Web stub returning `null`.
Future<String?> resolveHostExecutableImpl(String command) async => null;

/// Web stub returning null when [overrides] is empty.
Map<String, String>? buildMcpProcessEnvironmentImpl(
  Map<String, String> overrides,
) => overrides.isEmpty ? null : overrides;
