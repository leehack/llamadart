import 'package:meta/meta.dart';

import '../../domain/mcp_server_config.dart';
import 'project_context_discovery_stub.dart'
    if (dart.library.io) 'project_context_discovery_io.dart'
    as impl;

/// Discovered `AGENTS.md` / `.agents/AGENTS.md` / `CLAUDE.md` project
/// instructions loaded from a workspace root.
@immutable
class ProjectAgentsContext {
  /// Creates a [ProjectAgentsContext].
  const ProjectAgentsContext({
    this.primaryPath,
    this.sourceFiles = const <String>[],
    this.instructions = '',
  });

  /// Empty context when no project instructions file exists.
  static const ProjectAgentsContext empty = ProjectAgentsContext();

  /// Workspace-relative path of the primary instructions file (for example
  /// `AGENTS.md` or `.agents/AGENTS.md`).
  final String? primaryPath;

  /// All workspace-relative instruction files merged into [instructions].
  final List<String> sourceFiles;

  /// Combined instruction Markdown text ready for prompt injection & UI preview.
  final String instructions;

  /// Whether at least one instruction file with content was discovered.
  bool get hasInstructions => instructions.trim().isNotEmpty;
}

/// Discovers `AGENTS.md`, `.agents/AGENTS.md`, and `CLAUDE.md` files from
/// [workspaceRoot] (`dart:io` on desktop/mobile; empty on Web).
Future<ProjectAgentsContext> discoverProjectAgentsContext(
  String? workspaceRoot,
) => impl.discoverProjectAgentsContextImpl(workspaceRoot);

/// Discovers workspace MCP servers from `.agents/mcp.json`, `.mcp.json`,
/// `.vscode/mcp.json`, and `.agents/mcp/*.json` (`dart:io` on desktop/mobile;
/// empty on Web).
Future<List<McpServerConfig>> discoverProjectMcpConfigs(
  String? workspaceRoot,
) => impl.discoverProjectMcpConfigsImpl(workspaceRoot);

/// Resolves an executable command name (such as `dart`, `flutter`, `npx`,
/// `uvx`) across common macOS/Linux/Windows SDK locations and `PATH`, returning
/// `null` if not found (`null` on Web).
Future<String?> resolveHostExecutable(String command) =>
    impl.resolveHostExecutableImpl(command);

/// Returns an augmented environment map for `stdio` MCP subprocesses so GUI
/// `.app` launches still locate Homebrew, Flutter/Dart, Cargo, and npm bins.
Map<String, String>? buildMcpProcessEnvironment(
  Map<String, String> overrides,
) => impl.buildMcpProcessEnvironmentImpl(overrides);
