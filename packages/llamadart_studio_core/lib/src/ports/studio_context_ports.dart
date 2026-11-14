import 'package:llamadart/llamadart.dart';

import '../domain/studio_model_descriptor.dart';
import '../domain/studio_settings.dart';
import '../domain/studio_workspace.dart';
import '../reactive/state_store.dart';
import '../services/boot_guard_service.dart';
import '../services/mcp/mcp_manager.dart';
import '../services/skills/skill_registry.dart';

/// Read-only access to the active [StudioSettings].
abstract interface class StudioSettingsReader {
  /// Current Studio runtime, sampling, and UX settings snapshot.
  StudioSettings get currentSettings;
}

/// Read-write access to persisted [StudioSettings].
abstract interface class StudioSettingsWriter implements StudioSettingsReader {
  /// Applies [transform] to [currentSettings] and persists the update.
  Future<void> updateSettings(
    StudioSettings Function(StudioSettings current) transform,
  );
}

/// Access to crash-safe native model load sentinel tracking.
abstract interface class StudioModelLoadGuard {
  /// Shared [BootGuardService] used before/after loading native models.
  BootGuardService get bootGuard;
}

/// Combined settings persistence and crash-guard contract required by
/// `ModelHubController`.
abstract interface class StudioModelHubSettingsPort
    implements StudioSettingsWriter, StudioModelLoadGuard {}

/// Navigation contract for switching active top-level Studio destinations.
abstract interface class StudioWorkspaceNavigator {
  /// Activates [workspace].
  void selectWorkspace(StudioWorkspace workspace);
}

/// Segregated read-only MCP tool provider port for prompt/turn execution.
abstract interface class StudioMcpToolProvider {
  /// Reactive MCP state store.
  ReadOnlyStore<McpManagerState> get store;

  /// Current MCP state snapshot.
  McpManagerState get state;

  /// Builds executable [ToolDefinition]s for all enabled, connected MCP tools.
  List<ToolDefinition> buildActiveToolDefinitions();
}

/// Extended MCP coordinator port used by workspaces that discover and trust
/// project-scoped `.agents/mcp.json` / `.mcp.json` servers.
abstract interface class StudioWorkspaceMcpCoordinator
    implements StudioMcpToolProvider {
  /// Synchronizes workspace-scoped MCP server definitions for [workspaceRoot].
  Future<void> syncWorkspaceServers(
    String? workspaceRoot, {
    bool autoConnect = true,
    bool requireTrustForAutoConnect = true,
  });

  /// Marks [workspaceRoot] as trusted and optionally connects its MCP servers.
  Future<void> trustWorkspace(
    String workspaceRoot, {
    bool connectServers = true,
  });
}

/// Segregated read-only Agent Skills provider port for prompt injection.
abstract interface class StudioSkillContextProvider {
  /// Reactive Agent Skills catalog store.
  ReadOnlyStore<SkillRegistryState> get store;

  /// Current Agent Skills catalog snapshot.
  SkillRegistryState get state;

  /// Renders active skill instructions for system-prompt injection.
  String buildActiveSkillsSystemContext();
}

/// Extended Agent Skills coordinator port used by workspace browsers to scan
/// project-local `SKILL.md` directories.
abstract interface class StudioWorkspaceSkillCoordinator
    implements StudioSkillContextProvider {
  /// Rescans built-in, custom, and [workspaceRoot]-scoped `SKILL.md` files.
  Future<void> refreshDiscoveredSkills({String? workspaceRoot});
}

/// Extensible model catalog port allowing alternative or augmented catalogs
/// without modifying `CuratedModelCatalog`.
abstract interface class StudioModelCatalog {
  /// All catalog model descriptors.
  List<StudioModelDescriptor> get models;

  /// Returns catalog entries matching [category] (`null` = all categories)
  /// supported on the target host.
  List<StudioModelDescriptor> forCategory(
    StudioModelCategory? category, {
    required bool isWeb,
    required bool isMobile,
  });

  /// Looks up a model descriptor by [id], or returns `null` when absent.
  StudioModelDescriptor? byId(String? id);
}
