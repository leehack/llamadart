import 'dart:async';

import 'package:llamadart/llamadart.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../../adapters/curated_studio_model_catalog.dart';
import '../../domain/curated_model_catalog.dart';
import '../../domain/studio_message.dart';
import '../../domain/studio_model_descriptor.dart';
import '../../ports/inference_port.dart';
import '../../ports/key_value_store.dart';
import '../../ports/studio_context_ports.dart';
import '../../reactive/state_store.dart';
import '../../services/coding/coding_workspace_fs.dart';
import '../../services/skills/project_context_discovery.dart';
import '../../services/studio_error_formatter.dart';
import '../chat/chat_workspace_controller.dart';

part 'coding_workspace_state.dart';
part 'coding_workspace_tools.dart';

/// Manages local repository browsing, explicit `pi.dev`-style sandboxed tools
/// (`read`, `write`, `edit`, `grep`, `ls`, gated `bash`), `mcp_dart` server
/// tool bridging, `AGENTS.md` context, Agent Skills injection, and multi-round
/// coding agent turns.
class CodingWorkspaceController {
  /// Creates a [CodingWorkspaceController].
  CodingWorkspaceController({
    required StudioInferencePort inferencePort,
    required StudioSettingsReader shellController,
    required KeyValueStore keyValueStore,
    required StudioWorkspaceMcpCoordinator mcpManager,
    required StudioWorkspaceSkillCoordinator skillRegistry,
    StudioModelCatalog modelCatalog = const CuratedStudioModelCatalog(),
    Future<bool> Function()? ensureModelReady,
    bool autoConnectWorkspaceMcp = true,
  }) : _inference = inferencePort,
       _shell = shellController,
       _kv = keyValueStore,
       _mcp = mcpManager,
       _skills = skillRegistry,
       _catalog = modelCatalog,
       _ensureModelReady = ensureModelReady,
       _autoConnectWorkspaceMcp = autoConnectWorkspaceMcp;

  static const String _workspaceRootKey = 'studio.coding.workspace_root.v1';

  final StudioInferencePort _inference;
  final StudioSettingsReader _shell;
  final KeyValueStore _kv;
  final StudioWorkspaceMcpCoordinator _mcp;
  final StudioWorkspaceSkillCoordinator _skills;
  final StudioModelCatalog _catalog;
  final Future<bool> Function()? _ensureModelReady;
  final bool _autoConnectWorkspaceMcp;

  final StateStore<CodingWorkspaceState> _store =
      StateStore<CodingWorkspaceState>(const CodingWorkspaceState());
  final StateStore<ActiveTurnStreamState> _activeStreamStore =
      StateStore<ActiveTurnStreamState>(ActiveTurnStreamState.idle);

  static const Duration _streamPublishInterval = Duration(milliseconds: 40);

  int _idCounter = 0;
  int _workspaceEpoch = 0;
  int _workspaceSelection = 0;
  Timer? _streamFlushTimer;
  ActiveTurnStreamState? _pendingStreamState;
  DateTime? _lastStreamEmitAt;
  Completer<bool>? _pendingShellCompleter;

  /// Reactive Coding workspace store.
  ReadOnlyStore<CodingWorkspaceState> get store => _store;

  /// Current snapshot.
  CodingWorkspaceState get state => _store.state;

  /// Isolated ~25fps streaming store for the active Coding assistant turn.
  ReadOnlyStore<ActiveTurnStreamState> get activeStreamStore =>
      _activeStreamStore;

  /// Recommended flagship and high-capability coding models from [StudioModelCatalog].
  List<StudioModelDescriptor> get codingModelRecommendations {
    const preferredIds = <String>[
      'qwen3.8-27b-ud-q4-k-xl',
      'qwen3.6-27b-ud-q4-k-xl',
      'qwen3.6-35b-a3b-ud-q4-k-s',
      'gemma-4-12b-it-q4-k-s',
      'qwen3.5-0.8b-q4-k-m',
    ];
    return <StudioModelDescriptor>[
      for (final id in preferredIds)
        if (_catalog.byId(id) != null) _catalog.byId(id)!,
    ];
  }

  /// Recommended flagship and high-capability coding models from the catalog
  /// (highlighting Qwen 3.8 27B, Qwen 3.6 27B, Qwen 3.6 35B MoE, Gemma 4 12B, Qwen 3.5).
  static List<StudioModelDescriptor> get recommendedCodingModels {
    const preferredIds = <String>[
      'qwen3.8-27b-ud-q4-k-xl',
      'qwen3.6-27b-ud-q4-k-xl',
      'qwen3.6-35b-a3b-ud-q4-k-s',
      'gemma-4-12b-it-q4-k-s',
      'qwen3.5-0.8b-q4-k-m',
    ];
    return <StudioModelDescriptor>[
      for (final id in preferredIds)
        if (CuratedModelCatalog.byId(id) != null) CuratedModelCatalog.byId(id)!,
    ];
  }

  /// Restores last workspace folder (or detects cwd on desktop) and scans files.
  Future<void> initialize({bool autoDetectDefaultRoot = true}) async {
    final saved = await _kv.readString(_workspaceRootKey);
    final candidate = (saved != null && saved.trim().isNotEmpty)
        ? saved.trim()
        : (autoDetectDefaultRoot
              ? await CodingWorkspaceFs.detectDefaultWorkspaceRoot()
              : null);
    if (candidate != null) {
      await setWorkspaceRoot(candidate);
    }
  }

  /// Sets the sandboxed workspace root folder and refreshes files, `AGENTS.md`,
  /// project skills (`.agents/skills`), and project MCP configs (`.agents/mcp.json`).
  Future<void> setWorkspaceRoot(String path) async {
    if (path.trim().isEmpty) {
      return;
    }
    final trimmed = p.canonicalize(path.trim());
    final selection = ++_workspaceSelection;
    try {
      final entries = await CodingWorkspaceFs.listFiles(trimmed);
      final agentsContext = await discoverProjectAgentsContext(trimmed);
      if (selection != _workspaceSelection) return;
      await _kv.writeString(_workspaceRootKey, trimmed);
      if (selection != _workspaceSelection) return;
      final changed = _store.state.workspaceRoot != trimmed;
      if (changed) {
        _workspaceEpoch++;
        cancelGeneration();
        _resetStreamThrottle();
      }
      _store.update(
        (CodingWorkspaceState s) => s.copyWith(
          workspaceRoot: trimmed,
          currentSubdir: '',
          recentChanges: changed ? const <CodingFileChange>[] : null,
          messages: changed ? const <StudioMessage>[] : null,
          files: entries,
          agentsContext: agentsContext,
          clearSelectedFile: true,
          clearLastError: true,
        ),
      );
      await Future.wait(<Future<void>>[
        _skills.refreshDiscoveredSkills(workspaceRoot: trimmed),
        _mcp.syncWorkspaceServers(
          trimmed,
          autoConnect: _autoConnectWorkspaceMcp,
        ),
      ]);
    } catch (error) {
      if (selection != _workspaceSelection) return;
      _store.update(
        (CodingWorkspaceState s) =>
            s.copyWith(lastError: humanizeStudioError(error)),
      );
    }
  }

  /// Explicitly trusts the current [CodingWorkspaceState.workspaceRoot] to
  /// spawn discovered `.mcp.json` / `.agents/mcp.json` servers and connects them.
  Future<void> trustActiveWorkspaceMcp() async {
    final root = _store.state.workspaceRoot;
    if (root == null || root.trim().isEmpty) {
      return;
    }
    await _mcp.trustWorkspace(root, connectServers: true);
  }

  /// Navigates into [subdir] relative to the workspace root.
  Future<void> openDirectory(String subdir) async {
    final epoch = _workspaceEpoch;
    final root = _store.state.workspaceRoot;
    if (root == null) {
      return;
    }
    try {
      final entries = await CodingWorkspaceFs.listFiles(root, subdir: subdir);
      if (epoch != _workspaceEpoch) return;
      _store.update(
        (CodingWorkspaceState s) => s.copyWith(
          currentSubdir: subdir,
          files: entries,
          clearLastError: true,
        ),
      );
    } catch (error) {
      if (epoch != _workspaceEpoch) return;
      _store.update(
        (CodingWorkspaceState s) =>
            s.copyWith(lastError: humanizeStudioError(error)),
      );
    }
  }

  /// Opens a workspace-relative file in the code viewer.
  Future<void> openFile(String relativePath) async {
    final epoch = _workspaceEpoch;
    final root = _store.state.workspaceRoot;
    if (root == null) {
      return;
    }
    try {
      final slice = await CodingWorkspaceFs.readFile(
        root,
        relativePath,
        maxLines: 300,
      );
      if (epoch != _workspaceEpoch) return;
      _store.update(
        (CodingWorkspaceState s) => s.copyWith(
          selectedFilePath: slice.relativePath,
          selectedFileSlice: slice,
          clearLastError: true,
        ),
      );
    } catch (error) {
      if (epoch != _workspaceEpoch) return;
      _store.update(
        (CodingWorkspaceState s) =>
            s.copyWith(lastError: humanizeStudioError(error)),
      );
    }
  }

  /// Refreshes the current directory listing and active open file preview.
  Future<void> refreshExplorer() async {
    final epoch = _workspaceEpoch;
    final root = _store.state.workspaceRoot;
    if (root == null) {
      return;
    }
    try {
      final entries = await CodingWorkspaceFs.listFiles(
        root,
        subdir: _store.state.currentSubdir,
      );
      WorkspaceFileSlice? refreshedSlice;
      final selected = _store.state.selectedFilePath;
      if (selected != null) {
        try {
          refreshedSlice = await CodingWorkspaceFs.readFile(
            root,
            selected,
            maxLines: 300,
          );
        } catch (_) {}
      }
      if (epoch != _workspaceEpoch) return;
      _store.update(
        (CodingWorkspaceState s) => s.copyWith(
          files: entries,
          selectedFileSlice: refreshedSlice ?? s.selectedFileSlice,
          clearLastError: true,
        ),
      );
    } catch (error) {
      if (epoch != _workspaceEpoch) return;
      _store.update(
        (CodingWorkspaceState s) =>
            s.copyWith(lastError: humanizeStudioError(error)),
      );
    }
  }

  /// Updates the explorer filename filter string.
  void setFileFilter(String query) {
    _store.update((CodingWorkspaceState s) => s.copyWith(fileFilter: query));
  }

  /// Toggles whether the open file snippet is added to prompt context.
  void setIncludeSelectedFileContext(bool value) {
    _store.update(
      (CodingWorkspaceState s) => s.copyWith(includeSelectedFileContext: value),
    );
  }

  /// Toggles whether the agent may execute the gated `bash` tool.
  void setAllowShellCommandTool(bool allowed) {
    if (!allowed) {
      resolveShellCommandApproval(false);
    }
    _store.update(
      (CodingWorkspaceState s) => s.copyWith(allowShellCommandTool: allowed),
    );
  }

  /// Toggles whether `bash` tool invocations require explicit per-command user
  /// confirmation before running.
  void setConfirmShellCommands(bool confirm) {
    _store.update(
      (CodingWorkspaceState s) => s.copyWith(confirmShellCommands: confirm),
    );
  }

  /// Resolves an active [CodingWorkspaceState.pendingShellApproval] request.
  void resolveShellCommandApproval(bool approved) {
    final completer = _pendingShellCompleter;
    _pendingShellCompleter = null;
    if (_store.state.pendingShellApproval != null) {
      _store.update(
        (CodingWorkspaceState s) => s.copyWith(clearPendingShellApproval: true),
      );
    }
    if (completer != null && !completer.isCompleted) {
      completer.complete(approved);
    }
  }

  /// Reverts an agent-produced [CodingFileChange] by restoring its prior
  /// content or deleting newly created files.
  Future<bool> revertChange(String changeId) async {
    final epoch = _workspaceEpoch;
    final root = _store.state.workspaceRoot;
    if (root == null) {
      return false;
    }
    final idx = _store.state.recentChanges.indexWhere(
      (CodingFileChange c) => c.id == changeId && c.canRevert,
    );
    if (idx < 0) {
      return false;
    }
    final target = _store.state.recentChanges[idx];
    try {
      if (target.kind == CodingChangeKind.created) {
        await CodingWorkspaceFs.deleteFile(root, target.relativePath);
      } else if (target.previousContent != null) {
        await CodingWorkspaceFs.writeFile(
          root,
          target.relativePath,
          target.previousContent!,
        );
      } else {
        return false;
      }

      if (epoch != _workspaceEpoch) return false;
      final updated = List<CodingFileChange>.of(_store.state.recentChanges);
      final currentIndex = updated.indexWhere(
        (change) => change.id == target.id,
      );
      if (currentIndex < 0) return false;
      updated[currentIndex] = target.copyWith(reverted: true);
      _store.update(
        (CodingWorkspaceState s) => s.copyWith(
          recentChanges: List<CodingFileChange>.unmodifiable(updated),
          clearSelectedFile:
              target.kind == CodingChangeKind.created &&
              s.selectedFilePath == target.relativePath,
          clearLastError: true,
        ),
      );
      await refreshExplorer();
      return true;
    } catch (error) {
      if (epoch != _workspaceEpoch) return false;
      _store.update(
        (CodingWorkspaceState s) =>
            s.copyWith(lastError: humanizeStudioError(error)),
      );
      return false;
    }
  }

  /// Clears the current Coding chat thread and edit audit log.
  void clearSession() {
    resolveShellCommandApproval(false);
    _store.update(
      (CodingWorkspaceState s) => s.copyWith(
        messages: const <StudioMessage>[],
        recentChanges: const <CodingFileChange>[],
        clearPendingShellApproval: true,
        clearLastError: true,
      ),
    );
  }

  /// Builds explicit `pi.dev`-style sandboxed workspace tools (`read`, `write`,
  /// `edit`, `grep`, `ls`, plus user-gated `bash`) and connected MCP tools.
  List<ToolDefinition> buildCodingTools() => _buildCodingToolsImpl();

  /// Sends a coding prompt through the active local model with workspace tools,
  /// `AGENTS.md` project instructions, active `mcp_dart` tools, and active
  /// `SKILL.md` skills injected.
  Future<void> sendCodingPrompt(String rawPrompt) async {
    if (_activeStreamStore.state.isGenerating) {
      return;
    }
    final prompt = rawPrompt.trim();
    if (prompt.isEmpty) {
      return;
    }

    final epoch = _workspaceEpoch;
    final userMsg = StudioMessage(
      id: _nextId('code_usr'),
      role: StudioRole.user,
      text: prompt,
      createdAt: DateTime.now(),
    );
    final history = <StudioMessage>[..._store.state.messages, userMsg];
    _store.update(
      (CodingWorkspaceState s) =>
          s.copyWith(messages: history, clearLastError: true),
    );

    final turnWatch = Stopwatch()..start();
    final textBuf = StringBuffer();
    final thinkingBuf = StringBuffer();
    final toolCalls = <StudioToolInvocation>[];
    var tokens = 0;
    StudioTurnResult? finalResult;

    final needsAutoLoad =
        !_inference.runtimeStore.state.isReady && _ensureModelReady != null;
    _activeStreamStore.set(
      ActiveTurnStreamState(
        isGenerating: true,
        conversationId: 'coding',
        parentMessageId: userMsg.id,
        statusLabel: needsAutoLoad ? 'Loading local coding model...' : null,
      ),
    );

    try {
      if (needsAutoLoad) {
        await _ensureModelReady();
        if (epoch != _workspaceEpoch) return;
        _activeStreamStore.set(
          ActiveTurnStreamState(
            isGenerating: true,
            conversationId: 'coding',
            parentMessageId: userMsg.id,
          ),
        );
      }

      final codingTools = buildCodingTools();
      final coreNames = _store.state.activeCoreTools;
      final mcpNames = _mcp.state.activeTools
          .map((t) => t.exposedToolName)
          .toList(growable: false);
      final agentsCtx = _store.state.agentsContext;
      final promptAgentsInstructions = _budgetAgentsForPrompt(
        agentsCtx.instructions,
      );
      final skillsContext = _skills.buildActiveSkillsSystemContext();
      final openFileSlice = _store.state.includeSelectedFileContext
          ? _store.state.selectedFileSlice
          : null;
      final extraContext = <String>[
        if (_store.state.workspaceRoot != null)
          'Active workspace root: ${_store.state.workspaceRoot}',
        if (agentsCtx.hasInstructions)
          '<project_instructions sources="${agentsCtx.sourceFiles.join(', ')}">\n$promptAgentsInstructions\n</project_instructions>',
        if (openFileSlice != null)
          'Currently open file (${openFileSlice.relativePath}, lines ${openFileSlice.startLine}-${openFileSlice.endLine} of ${openFileSlice.totalLines}):\n```\n${openFileSlice.content}\n```',
        if (skillsContext.isNotEmpty) skillsContext,
      ].join('\n\n');

      final activeToolSummary = <String>[
        ...coreNames,
        if (mcpNames.isNotEmpty) 'MCP(${mcpNames.join(', ')})',
      ].join(', ');

      final stream = _inference.streamTurn(
        StudioTurnRequest(
          history: history,
          settings: _shell.currentSettings,
          systemPrompt:
              'You are a focused local software engineering agent inside llamadart Studio. '
              'Follow the project instructions (`AGENTS.md`) and active `SKILL.md` skills strictly. '
              'Active tools: [$activeToolSummary]. '
              'Inspect real files with `read`, `grep`, and `ls` before editing with `edit` or `write`, '
              'and verify changes cleanly with minimal edits.',
          extraSystemContext: extraContext,
          extraTools: codingTools,
          includeBuiltInTools: false,
          toolsEnabledOverride: codingTools.isNotEmpty,
          maxToolRounds: 10,
        ),
      );

      final streamDone = Completer<void>();
      var streamFinished = false;
      late final StreamSubscription<StudioTurnEvent> streamSub;
      streamSub = stream.listen(
        (StudioTurnEvent event) {
          if (epoch != _workspaceEpoch) return;
          switch (event) {
            case StudioTextDeltaEvent(:final delta):
              textBuf.write(delta);
              tokens++;
              _publishStream(
                userMsg.id,
                textBuf.toString(),
                thinkingBuf.toString(),
                toolCalls,
                tokens,
                turnWatch.elapsedMilliseconds,
              );
            case StudioThinkingDeltaEvent(:final delta):
              thinkingBuf.write(delta);
              tokens++;
              _publishStream(
                userMsg.id,
                textBuf.toString(),
                thinkingBuf.toString(),
                toolCalls,
                tokens,
                turnWatch.elapsedMilliseconds,
              );
            case StudioToolInvocationEvent(:final invocation):
              final existingIdx = toolCalls.indexWhere(
                (StudioToolInvocation t) => t.id == invocation.id,
              );
              if (existingIdx >= 0) {
                toolCalls[existingIdx] = invocation;
              } else {
                toolCalls.add(invocation);
              }
              _publishStream(
                userMsg.id,
                textBuf.toString(),
                thinkingBuf.toString(),
                toolCalls,
                tokens,
                turnWatch.elapsedMilliseconds,
                immediate: true,
              );
            case StudioTurnCompletedEvent(:final result):
              finalResult = result;
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          streamFinished = true;
          if (!streamDone.isCompleted) {
            streamDone.completeError(error, stackTrace);
          }
        },
        onDone: () {
          streamFinished = true;
          if (!streamDone.isCompleted) {
            streamDone.complete();
          }
        },
        cancelOnError: true,
      );
      try {
        await streamDone.future;
      } finally {
        if (!streamFinished) {
          await streamSub.cancel();
        }
      }

      if (epoch != _workspaceEpoch) return;
      turnWatch.stop();
      final assistantMsg = StudioMessage(
        id: _nextId('code_ast'),
        parentId: userMsg.id,
        role: StudioRole.assistant,
        text: finalResult?.text ?? textBuf.toString(),
        thinkingText:
            finalResult?.thinkingText ??
            (thinkingBuf.isEmpty ? null : thinkingBuf.toString()),
        thinkingDurationMs: finalResult?.thinkingDurationMs,
        toolCalls: finalResult?.toolInvocations ?? toolCalls,
        metrics:
            finalResult?.metrics ??
            StudioTurnMetrics(
              generatedTokens: tokens,
              elapsedMs: turnWatch.elapsedMilliseconds,
              decodeElapsedMs: turnWatch.elapsedMilliseconds,
            ),
        createdAt: DateTime.now(),
      );
      _store.update(
        (CodingWorkspaceState s) =>
            s.copyWith(messages: <StudioMessage>[...s.messages, assistantMsg]),
      );
      if (_store.state.recentChanges.isNotEmpty) {
        await refreshExplorer();
      }
    } catch (error) {
      if (epoch != _workspaceEpoch) return;
      turnWatch.stop();
      final partial = textBuf.toString();
      final errText = humanizeStudioError(error);
      final assistantErr = StudioMessage(
        id: _nextId('code_err'),
        parentId: userMsg.id,
        role: StudioRole.assistant,
        text: partial.isNotEmpty ? partial : errText,
        thinkingText: thinkingBuf.isEmpty ? null : thinkingBuf.toString(),
        toolCalls: toolCalls,
        isError: partial.isEmpty,
        createdAt: DateTime.now(),
      );
      _store.update(
        (CodingWorkspaceState s) => s.copyWith(
          messages: <StudioMessage>[...s.messages, assistantErr],
          lastError: errText,
        ),
      );
    } finally {
      resolveShellCommandApproval(false);
      _resetStreamThrottle();
      _activeStreamStore.set(ActiveTurnStreamState.idle);
    }
  }

  Future<bool> _requestShellApproval(String root, String command) async {
    resolveShellCommandApproval(false);
    final completer = Completer<bool>();
    _pendingShellCompleter = completer;
    _store.update(
      (CodingWorkspaceState s) => s.copyWith(
        pendingShellApproval: PendingShellCommandApproval(
          id: _nextId('bash_req'),
          command: command,
          workspaceRoot: root,
          requestedAt: DateTime.now(),
        ),
      ),
    );
    return completer.future;
  }

  /// Cancels the currently streaming coding turn.
  void cancelGeneration() {
    resolveShellCommandApproval(false);
    _inference.cancelGeneration();
  }

  static String _budgetAgentsForPrompt(String instructions) {
    const maxChars = 3600;
    if (instructions.length <= maxChars) {
      return instructions;
    }
    return '${instructions.substring(0, maxChars)}\n'
        '...[truncated for fast prompt evaluation; call read(path: "AGENTS.md") if full project rules are needed]';
  }

  void _publishStream(
    String parentId,
    String text,
    String thinking,
    List<StudioToolInvocation> toolCalls,
    int tokens,
    int elapsedMs, {
    bool immediate = false,
  }) {
    final next = ActiveTurnStreamState(
      isGenerating: true,
      conversationId: 'coding',
      parentMessageId: parentId,
      text: text,
      thinkingText: thinking,
      toolInvocations: List<StudioToolInvocation>.unmodifiable(toolCalls),
      tokensGenerated: tokens,
      elapsedMs: elapsedMs,
    );
    final now = DateTime.now();
    if (immediate ||
        _lastStreamEmitAt == null ||
        now.difference(_lastStreamEmitAt!) >= _streamPublishInterval) {
      _streamFlushTimer?.cancel();
      _streamFlushTimer = null;
      _pendingStreamState = null;
      _lastStreamEmitAt = now;
      _activeStreamStore.set(next);
      return;
    }
    _pendingStreamState = next;
    _streamFlushTimer ??= Timer(
      _streamPublishInterval - now.difference(_lastStreamEmitAt!),
      () {
        _streamFlushTimer = null;
        final pending = _pendingStreamState;
        _pendingStreamState = null;
        if (pending != null) {
          _lastStreamEmitAt = DateTime.now();
          _activeStreamStore.set(pending);
        }
      },
    );
  }

  void _resetStreamThrottle() {
    _streamFlushTimer?.cancel();
    _streamFlushTimer = null;
    _pendingStreamState = null;
    _lastStreamEmitAt = null;
  }

  void _ensureWorkspaceScope(int epoch) {
    if (epoch != _workspaceEpoch) {
      throw LlamaStateException(
        'The active workspace changed. Request fresh tools before continuing.',
      );
    }
  }

  void _recordChange(CodingFileChange change, {required int workspaceEpoch}) {
    _ensureWorkspaceScope(workspaceEpoch);
    _store.update(
      (CodingWorkspaceState s) => s.copyWith(
        recentChanges: <CodingFileChange>[change, ...s.recentChanges],
      ),
    );
  }

  String _nextId(String prefix) {
    _idCounter++;
    return '${prefix}_${DateTime.now().microsecondsSinceEpoch}_$_idCounter';
  }

  /// Disposes internal stores.
  Future<void> dispose() async {
    resolveShellCommandApproval(false);
    _resetStreamThrottle();
    await _store.dispose();
    await _activeStreamStore.dispose();
  }
}
