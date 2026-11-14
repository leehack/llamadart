part of 'coding_workspace_controller.dart';

/// Pending interactive user approval for an agent-requested shell command.
@immutable
class PendingShellCommandApproval {
  /// Creates a [PendingShellCommandApproval].
  const PendingShellCommandApproval({
    required this.id,
    required this.command,
    required this.workspaceRoot,
    required this.requestedAt,
  });

  /// Unique approval request ID.
  final String id;

  /// Shell command line requested by the coding agent.
  final String command;

  /// Workspace root directory where the command would run.
  final String workspaceRoot;

  /// Timestamp when approval was requested.
  final DateTime requestedAt;
}

/// Immutable state for Studio's dedicated Coding Workspace.
@immutable
class CodingWorkspaceState {
  /// Creates a [CodingWorkspaceState].
  const CodingWorkspaceState({
    this.workspaceRoot,
    this.currentSubdir = '',
    this.files = const <WorkspaceFileEntry>[],
    this.selectedFilePath,
    this.selectedFileSlice,
    this.fileFilter = '',
    this.includeSelectedFileContext = true,
    this.allowShellCommandTool = false,
    this.confirmShellCommands = true,
    this.pendingShellApproval,
    this.agentsContext = ProjectAgentsContext.empty,
    this.messages = const <StudioMessage>[],
    this.recentChanges = const <CodingFileChange>[],
    this.lastError,
  });

  /// Active sandboxed project folder path.
  final String? workspaceRoot;

  /// Current browsed directory relative to [workspaceRoot].
  final String currentSubdir;

  /// Listed entries inside [currentSubdir].
  final List<WorkspaceFileEntry> files;

  /// Currently opened workspace-relative file path.
  final String? selectedFilePath;

  /// Loaded content slice of [selectedFilePath].
  final WorkspaceFileSlice? selectedFileSlice;

  /// Explorer filename filter query.
  final String fileFilter;

  /// Whether the open file excerpt is automatically included with prompts.
  final bool includeSelectedFileContext;

  /// Whether the agent is permitted to invoke the gated `bash` tool.
  final bool allowShellCommandTool;

  /// Whether `bash` tool invocations pause for explicit user confirmation.
  final bool confirmShellCommands;

  /// Active shell command waiting for user Approve/Reject decision.
  final PendingShellCommandApproval? pendingShellApproval;

  /// Discovered `AGENTS.md` / `.agents/AGENTS.md` / `CLAUDE.md` context.
  final ProjectAgentsContext agentsContext;

  /// Ordered coding session transcript (user + assistant turns with tool calls).
  final List<StudioMessage> messages;

  /// Audit log of file writes/patches applied by the coding agent.
  final List<CodingFileChange> recentChanges;

  /// Optional error banner message.
  final String? lastError;

  /// Explicit `pi.dev`-style core tool primitives active for the current session.
  List<String> get activeCoreTools => workspaceRoot == null
      ? const <String>[]
      : <String>[
          'read',
          'write',
          'edit',
          'grep',
          'ls',
          if (allowShellCommandTool) 'bash',
        ];

  /// Filtered file entries matching [fileFilter].
  List<WorkspaceFileEntry> get filteredFiles {
    final q = fileFilter.trim().toLowerCase();
    if (q.isEmpty) {
      return files;
    }
    return files
        .where(
          (WorkspaceFileEntry e) =>
              e.name.toLowerCase().contains(q) ||
              e.relativePath.toLowerCase().contains(q),
        )
        .toList(growable: false);
  }

  /// Returns an updated copy of [CodingWorkspaceState].
  CodingWorkspaceState copyWith({
    String? workspaceRoot,
    bool clearWorkspaceRoot = false,
    String? currentSubdir,
    List<WorkspaceFileEntry>? files,
    String? selectedFilePath,
    bool clearSelectedFile = false,
    WorkspaceFileSlice? selectedFileSlice,
    String? fileFilter,
    bool? includeSelectedFileContext,
    bool? allowShellCommandTool,
    bool? confirmShellCommands,
    PendingShellCommandApproval? pendingShellApproval,
    bool clearPendingShellApproval = false,
    ProjectAgentsContext? agentsContext,
    List<StudioMessage>? messages,
    List<CodingFileChange>? recentChanges,
    String? lastError,
    bool clearLastError = false,
  }) {
    return CodingWorkspaceState(
      workspaceRoot: clearWorkspaceRoot
          ? null
          : (workspaceRoot ?? this.workspaceRoot),
      currentSubdir: currentSubdir ?? this.currentSubdir,
      files: files ?? this.files,
      selectedFilePath: clearSelectedFile
          ? null
          : (selectedFilePath ?? this.selectedFilePath),
      selectedFileSlice: clearSelectedFile
          ? null
          : (selectedFileSlice ?? this.selectedFileSlice),
      fileFilter: fileFilter ?? this.fileFilter,
      includeSelectedFileContext:
          includeSelectedFileContext ?? this.includeSelectedFileContext,
      allowShellCommandTool:
          allowShellCommandTool ?? this.allowShellCommandTool,
      confirmShellCommands: confirmShellCommands ?? this.confirmShellCommands,
      pendingShellApproval: clearPendingShellApproval
          ? null
          : (pendingShellApproval ?? this.pendingShellApproval),
      agentsContext: agentsContext ?? this.agentsContext,
      messages: messages ?? this.messages,
      recentChanges: recentChanges ?? this.recentChanges,
      lastError: clearLastError ? null : (lastError ?? this.lastError),
    );
  }
}
