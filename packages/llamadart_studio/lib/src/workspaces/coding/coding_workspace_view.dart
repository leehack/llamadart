import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

import '../../app/studio_dependencies.dart';
import '../../app/studio_file_actions.dart';
import '../../app/studio_theme.dart';
import '../../widgets/code_syntax_highlighter.dart';
import '../../widgets/mcp_skills/mcp_and_skills_sheet.dart';
import '../../widgets/model_load_progress_banner.dart';
import '../../widgets/store_widgets.dart';
import '../../widgets/studio_motion.dart';
import '../../widgets/studio_selectable_text.dart';
import '../../widgets/tool_availability_notice_card.dart';

part 'coding_agent_chat_pane.dart';
part 'coding_explorer_changes_pane.dart';
part 'coding_workspace_header.dart';

enum _CompactCodingSection { agent, files, edits }

/// Dedicated local Coding Agent workspace featuring a sandboxed repository
/// explorer, syntax-highlighted code & diff preview, explicit `pi.dev`-style
/// tools (`read`, `write`, `edit`, `grep`, `ls`, gated `bash`), `mcp_dart`
/// tools (`Dart & Flutter MCP` + project `.agents/mcp.json`), `AGENTS.md`, and
/// `SKILL.md` skills.
class CodingWorkspaceView extends StatefulWidget {
  /// Creates a [CodingWorkspaceView].
  const CodingWorkspaceView({super.key});

  @override
  State<CodingWorkspaceView> createState() => _CodingWorkspaceViewState();
}

class _CodingWorkspaceViewState extends State<CodingWorkspaceView> {
  final TextEditingController _promptCtrl = TextEditingController();
  late final FocusNode _promptFocusNode;
  final ScrollController _chatScrollCtrl = ScrollController();

  StudioDependencies? _deps;
  String? _draftWorkspaceRoot;
  StreamSubscription<CodingWorkspaceState>? _codingSub;
  StreamSubscription<ActiveTurnStreamState>? _streamSub;
  bool _stickToBottom = true;
  bool _isProgrammaticScroll = false;
  bool _scrollFrameScheduled = false;
  double? _lastMaxScrollExtent;
  int _lastMessageCount = 0;
  bool _wasGenerating = false;

  _CompactCodingSection _compactSection = _CompactCodingSection.agent;
  bool _showEditsInExplorer = false;
  bool _showFileDetail = false;
  bool _compactLayout = false;
  bool _shortCodingPane = false;
  bool _showSetup = false;
  bool _showExplorer = false;
  StudioModelDescriptor? _pendingModel;
  String? _modelLoadError;

  @override
  void initState() {
    super.initState();
    _promptFocusNode = FocusNode(onKeyEvent: _handlePromptKey);
    _promptCtrl.addListener(_savePromptDraft);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextDeps = StudioScope.of(context);
    if (identical(_deps, nextDeps)) {
      return;
    }
    _codingSub?.cancel();
    _streamSub?.cancel();
    _deps = nextDeps;
    _draftWorkspaceRoot = nextDeps.codingController.state.workspaceRoot;
    _promptCtrl.text = nextDeps.codingController.promptDraftForWorkspace(
      _draftWorkspaceRoot,
    );

    _lastMessageCount = nextDeps.codingController.state.messages.length;
    _wasGenerating =
        nextDeps.codingController.activeStreamStore.state.isGenerating;
    _codingSub = nextDeps.codingController.store.stream.listen(
      _onCodingStateChanged,
    );
    _streamSub = nextDeps.codingController.activeStreamStore.stream.listen(
      _onStreamStateChanged,
    );
  }

  void _savePromptDraft() {
    _deps?.codingController.setPromptDraftForWorkspace(
      _draftWorkspaceRoot,
      _promptCtrl.text,
    );
  }

  void _restoreWorkspaceDraft(String? workspaceRoot) {
    _draftWorkspaceRoot = workspaceRoot;
    final draft = _deps!.codingController.promptDraftForWorkspace(
      workspaceRoot,
    );
    if (_promptCtrl.text != draft) _promptCtrl.text = draft;
  }

  void _onCodingStateChanged(CodingWorkspaceState codingState) {
    _restoreWorkspaceDraft(codingState.workspaceRoot);
    final nextCount = codingState.messages.length;
    if (nextCount != _lastMessageCount) {
      final grew = nextCount > _lastMessageCount;
      _lastMessageCount = nextCount;
      if (grew &&
          codingState.messages.isNotEmpty &&
          codingState.messages.last.role == StudioRole.user) {
        _stickToBottom = true;
        _scheduleScrollToBottom();
      } else if (_stickToBottom) {
        _scheduleScrollToBottom();
      }
    }
  }

  void _onStreamStateChanged(ActiveTurnStreamState streamState) {
    final started = !_wasGenerating && streamState.isGenerating;
    _wasGenerating = streamState.isGenerating;
    if (started) {
      _stickToBottom = true;
      _scheduleScrollToBottom();
      return;
    }
    if (streamState.isGenerating && _stickToBottom) {
      _scheduleScrollToBottom();
    }
  }

  bool _handleCodingScrollNotification(ScrollNotification notification) {
    if (notification.depth != 0) {
      return false;
    }
    if (notification is ScrollMetricsNotification) {
      final nextMax = notification.metrics.maxScrollExtent;
      if (_lastMaxScrollExtent != null &&
          (nextMax - _lastMaxScrollExtent!).abs() < 0.5) {
        return false;
      }
      _lastMaxScrollExtent = nextMax;
      if (_stickToBottom &&
          (_deps?.codingController.activeStreamStore.state.isGenerating ??
              false)) {
        _scheduleScrollToBottom();
      }
      return false;
    }
    if (notification is ScrollUpdateNotification && !_isProgrammaticScroll) {
      final metrics = notification.metrics;
      final distance = (metrics.maxScrollExtent - metrics.pixels).clamp(
        0.0,
        double.infinity,
      );
      _stickToBottom = distance <= 72.0;
    }
    return false;
  }

  @override
  void dispose() {
    _codingSub?.cancel();
    _streamSub?.cancel();
    _promptCtrl.dispose();
    _promptFocusNode.dispose();
    _chatScrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _activateCodingModel(
    StudioDependencies deps,
    StudioModelDescriptor model,
  ) async {
    setState(() {
      _pendingModel = model;
      _modelLoadError = null;
    });
    try {
      await deps.modelHubController.activateChatModel(model);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _modelLoadError = humanizeStudioError(error);
      });
    } finally {
      if (mounted) {
        setState(() {
          _pendingModel = null;
        });
      }
    }
  }

  KeyEventResult _handlePromptKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter &&
        !HardwareKeyboard.instance.isShiftPressed) {
      _submitPrompt();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _submitPrompt() async {
    final deps = StudioScope.of(context);
    if (deps.codingController.activeStreamStore.state.isGenerating) {
      return;
    }
    _restoreWorkspaceDraft(deps.codingController.state.workspaceRoot);
    final text = _promptCtrl.text.trim();
    if (text.isEmpty) {
      return;
    }
    _promptCtrl.clear();
    _stickToBottom = true;
    _scheduleScrollToBottom();
    await deps.codingController.sendCodingPrompt(text);
    _scheduleScrollToBottom();
  }

  void _scheduleScrollToBottom() {
    if (_scrollFrameScheduled || !mounted) {
      return;
    }
    _scrollFrameScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollFrameScheduled = false;
      if (!mounted || !_stickToBottom || !_chatScrollCtrl.hasClients) {
        return;
      }
      final target = _chatScrollCtrl.position.maxScrollExtent;
      _lastMaxScrollExtent = target;
      if ((target - _chatScrollCtrl.offset).abs() > 0.5) {
        _isProgrammaticScroll = true;
        try {
          _chatScrollCtrl.jumpTo(target);
        } finally {
          _isProgrammaticScroll = false;
        }
      }
    });
  }

  Future<void> _openFileAndReveal(String path) async {
    final controller = _deps!.codingController;
    final root = controller.state.workspaceRoot;
    final opened = await controller.openFile(path);
    if (!opened ||
        !mounted ||
        controller.state.workspaceRoot != root ||
        controller.state.lastError != null ||
        controller.state.selectedFileSlice == null) {
      return;
    }
    setState(() {
      _compactSection = _CompactCodingSection.files;
      _showFileDetail = true;
      _showExplorer = true;
      _showEditsInExplorer = false;
    });
  }

  void _showErrorDetails(String error, {required bool needsModel}) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        scrollable: true,
        title: const Text('Coding needs attention'),
        content: StudioSelectableText(error),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Close'),
          ),
          if (needsModel)
            FilledButton(
              onPressed: () {
                Navigator.pop(dialogContext);
                _deps!.shellController.selectWorkspace(StudioWorkspace.models);
              },
              child: const Text('Model Hub'),
            ),
          if (!needsModel && !_deps!.isWeb)
            FilledButton(
              onPressed: () {
                Navigator.pop(dialogContext);
                _pickFolder();
              },
              child: const Text('Choose folder'),
            ),
        ],
      ),
    );
  }

  Future<void> _pickFolder() async {
    await runStudioFileAction(
      context,
      'Could not select workspace folder',
      () async {
        final deps = StudioScope.of(context);
        if (deps.isWeb) {
          return;
        }
        final picked = await FilePicker.platform.getDirectoryPath(
          dialogTitle: 'Select Project Workspace Folder',
        );
        if (!context.mounted) return;
        if (picked != null && picked.trim().isNotEmpty) {
          await deps.codingController.setWorkspaceRoot(picked);
        }
      },
    );
  }

  Future<void> _openManualPathDialog() async {
    final deps = StudioScope.of(context);
    var draftPath = deps.codingController.state.workspaceRoot ?? '';
    final entered = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          scrollable: true,
          title: const Text('Set Coding Workspace Folder'),
          content: TextFormField(
            key: const Key('coding_manual_path_field'),
            initialValue: draftPath,
            autofocus: true,
            onChanged: (String v) => draftPath = v,
            onFieldSubmitted: (String v) =>
                Navigator.of(dialogContext).pop(v.trim()),
            decoration: const InputDecoration(
              labelText: 'Repository Root Path',
              hintText: '/Users/you/projects/my_app',
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const Key('coding_manual_path_confirm'),
              onPressed: () =>
                  Navigator.of(dialogContext).pop(draftPath.trim()),
              child: const Text('Open'),
            ),
          ],
        );
      },
    );
    if (entered != null && entered.isNotEmpty) {
      await deps.codingController.setWorkspaceRoot(entered);
    }
  }

  @override
  Widget build(BuildContext context) {
    final deps = StudioScope.of(context);
    final palette = StudioPalette.of(context);

    return StoreBuilder<CodingWorkspaceState>(
      store: deps.codingController.store,
      builder: (BuildContext context, CodingWorkspaceState codingState) {
        return StoreBuilder<McpManagerState>(
          store: deps.mcpManager.store,
          builder: (BuildContext context, McpManagerState mcpState) {
            return StoreBuilder<SkillRegistryState>(
              store: deps.skillRegistry.store,
              builder: (BuildContext context, SkillRegistryState skillState) {
                return StoreBuilder<ModelHubState>(
                  store: deps.modelHubController.store,
                  builder: (BuildContext context, ModelHubState hubState) {
                    return StoreBuilder<StudioRuntimeSnapshot>(
                      store: deps.modelHubController.runtimeStore,
                      builder: (BuildContext context, StudioRuntimeSnapshot runtime) {
                        return LayoutBuilder(
                          builder: (BuildContext context, BoxConstraints rootBox) {
                            final compactWidth = rootBox.maxWidth < 900;
                            _compactLayout = compactWidth;
                            _shortCodingPane = rootBox.maxHeight < 500;

                            final header = _buildHeader(
                              context,
                              deps,
                              palette,
                              codingState,
                              mcpState,
                              skillState,
                              hubState,
                              runtime,
                              compact: compactWidth,
                            );

                            final loadingDescriptor = runtime.isLoading
                                ? (_pendingModel ?? runtime.activeDescriptor)
                                : _pendingModel;
                            final loadBanner = loadingDescriptor == null
                                ? null
                                : Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.fromLTRB(
                                      16,
                                      10,
                                      16,
                                      10,
                                    ),
                                    decoration: BoxDecoration(
                                      color: palette.canvas,
                                      border: Border(
                                        bottom: BorderSide(
                                          color: palette.borderSubtle,
                                        ),
                                      ),
                                    ),
                                    child: ModelLoadProgressBanner(
                                      descriptor: loadingDescriptor,
                                    ),
                                  );

                            final activeError =
                                _modelLoadError ??
                                codingState.lastError ??
                                runtime.errorMessage;
                            final errorBanner = activeError == null
                                ? null
                                : Container(
                                    key: const Key('coding_error_banner'),
                                    width: double.infinity,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 8,
                                    ),
                                    decoration: BoxDecoration(
                                      color: palette.danger.withValues(
                                        alpha: 0.14,
                                      ),
                                      border: Border(
                                        bottom: BorderSide(
                                          color: palette.danger.withValues(
                                            alpha: 0.35,
                                          ),
                                        ),
                                      ),
                                    ),
                                    child: Row(
                                      children: <Widget>[
                                        Icon(
                                          Icons.error_outline_rounded,
                                          size: 16,
                                          color: palette.danger,
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            activeError,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: palette.danger,
                                            ),
                                          ),
                                        ),
                                        TextButton(
                                          onPressed: () => _showErrorDetails(
                                            activeError,
                                            needsModel: !runtime.isReady,
                                          ),
                                          child: const Text('Details'),
                                        ),
                                        if (_modelLoadError != null)
                                          IconButton(
                                            tooltip: 'Dismiss',
                                            visualDensity:
                                                VisualDensity.compact,
                                            onPressed: () => setState(
                                              () => _modelLoadError = null,
                                            ),
                                            icon: Icon(
                                              Icons.close_rounded,
                                              size: 15,
                                              color: palette.danger,
                                            ),
                                          ),
                                      ],
                                    ),
                                  );

                            final untrustedProjectServers = mcpState
                                .untrustedProjectServersFor(
                                  codingState.workspaceRoot,
                                );
                            final untrustedMcpBanner =
                                untrustedProjectServers.isEmpty
                                ? null
                                : Container(
                                    key: const Key(
                                      'coding_untrusted_mcp_banner',
                                    ),
                                    width: double.infinity,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 8,
                                    ),
                                    decoration: BoxDecoration(
                                      color: palette.amber.withValues(
                                        alpha: 0.14,
                                      ),
                                      border: Border(
                                        bottom: BorderSide(
                                          color: palette.amber.withValues(
                                            alpha: 0.35,
                                          ),
                                        ),
                                      ),
                                    ),
                                    child: Wrap(
                                      spacing: 10,
                                      runSpacing: 8,
                                      alignment: WrapAlignment.spaceBetween,
                                      crossAxisAlignment:
                                          WrapCrossAlignment.center,
                                      children: <Widget>[
                                        Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: <Widget>[
                                            Icon(
                                              Icons.shield_outlined,
                                              size: 16,
                                              color: palette.amber,
                                            ),
                                            const SizedBox(width: 8),
                                            Flexible(
                                              child: Text(
                                                'Project MCP servers paused until workspace is trusted: '
                                                '${untrustedProjectServers.map((McpServerRuntimeState s) => '${s.config.name} (${s.config.command ?? s.config.url ?? 'stdio'})').join(', ')}',
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  fontSize: 12,
                                                  color: palette.textPrimary,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                        Wrap(
                                          spacing: 8,
                                          runSpacing: 6,
                                          children: <Widget>[
                                            TextButton(
                                              style: TextButton.styleFrom(
                                                visualDensity:
                                                    VisualDensity.compact,
                                              ),
                                              onPressed: () =>
                                                  showMcpAndSkillsSheet(
                                                    context,
                                                  ),
                                              child: const Text('Inspect'),
                                            ),
                                            FilledButton.tonalIcon(
                                              key: const Key(
                                                'trust_workspace_mcp_button',
                                              ),
                                              style: FilledButton.styleFrom(
                                                visualDensity:
                                                    VisualDensity.compact,
                                              ),
                                              onPressed: () => deps
                                                  .codingController
                                                  .trustActiveWorkspaceMcp(),
                                              icon: const Icon(
                                                Icons.verified_user_outlined,
                                                size: 15,
                                              ),
                                              label: const Text(
                                                'Trust & Connect',
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  );

                            Widget buildMainBody() {
                              if (!compactWidth) {
                                return Row(
                                  children: <Widget>[
                                    if (_showExplorer)
                                      SizedBox(
                                        width: 320,
                                        child: _buildExplorerPane(
                                          context,
                                          deps,
                                          palette,
                                          codingState,
                                        ),
                                      ),
                                    Expanded(
                                      child: _buildAgentPane(
                                        context,
                                        deps,
                                        palette,
                                        codingState,
                                        mcpState,
                                        skillState,
                                      ),
                                    ),
                                  ],
                                );
                              }
                              return Column(
                                key: const Key('coding_compact_body'),
                                children: <Widget>[
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      14,
                                      8,
                                      14,
                                      4,
                                    ),
                                    child: SegmentedButton<_CompactCodingSection>(
                                      showSelectedIcon: false,
                                      style: SegmentedButton.styleFrom(
                                        visualDensity: VisualDensity.compact,
                                      ),
                                      segments: <ButtonSegment<_CompactCodingSection>>[
                                        const ButtonSegment<
                                          _CompactCodingSection
                                        >(
                                          value: _CompactCodingSection.agent,
                                          label: Text('Agent', maxLines: 1),
                                        ),
                                        ButtonSegment<_CompactCodingSection>(
                                          value: _CompactCodingSection.files,
                                          label: Text(
                                            'Files (${codingState.files.length})',
                                            maxLines: 1,
                                          ),
                                        ),
                                        ButtonSegment<_CompactCodingSection>(
                                          value: _CompactCodingSection.edits,
                                          label: Text(
                                            'Edits (${codingState.recentChanges.length})',
                                            maxLines: 1,
                                          ),
                                        ),
                                      ],
                                      selected: <_CompactCodingSection>{
                                        _compactSection,
                                      },
                                      onSelectionChanged:
                                          (Set<_CompactCodingSection> next) {
                                            setState(() {
                                              _compactSection = next.first;
                                            });
                                          },
                                    ),
                                  ),
                                  Expanded(
                                    child:
                                        codingState.pendingShellApproval != null
                                        ? _buildApproval(deps, codingState)
                                        : IndexedStack(
                                            index: _compactSection.index,
                                            children: [
                                              _buildAgentPane(
                                                context,
                                                deps,
                                                palette,
                                                codingState,
                                                mcpState,
                                                skillState,
                                                includeControls: false,
                                              ),
                                              _buildExplorerPane(
                                                context,
                                                deps,
                                                palette,
                                                codingState,
                                                forceChangesTab: false,
                                              ),
                                              _buildExplorerPane(
                                                context,
                                                deps,
                                                palette,
                                                codingState,
                                                forceChangesTab: true,
                                              ),
                                            ],
                                          ),
                                  ),
                                  if (codingState.pendingShellApproval == null)
                                    _buildComposer(
                                      context,
                                      deps,
                                      palette,
                                      codingState,
                                    ),
                                ],
                              );
                            }

                            return Column(
                              children: <Widget>[
                                header,
                                if (loadBanner != null ||
                                    errorBanner != null ||
                                    untrustedMcpBanner != null)
                                  ConstrainedBox(
                                    constraints: BoxConstraints(
                                      maxHeight: rootBox.maxHeight * 0.2,
                                    ),
                                    child: SingleChildScrollView(
                                      child: Column(
                                        children: [
                                          ?loadBanner,
                                          ?errorBanner,
                                          ?untrustedMcpBanner,
                                        ],
                                      ),
                                    ),
                                  ),
                                Expanded(child: buildMainBody()),
                              ],
                            );
                          },
                        );
                      },
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  void _updateState(VoidCallback fn) {
    if (mounted) {
      setState(fn);
    }
  }
}
