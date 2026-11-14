import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import 'package:file_picker/file_picker.dart';
// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

import '../../app/platform_file_helper.dart';
import '../../app/studio_dependencies.dart';
import '../../app/studio_theme.dart';
import '../../widgets/command_palette_modal.dart';
import '../../widgets/download_activity_bar.dart';
import '../../widgets/inspector/session_inspector_panel.dart';
import '../../widgets/store_widgets.dart';
import '../../widgets/studio_motion.dart';
import '../chat/chat_workspace_view.dart';
import '../coding/coding_workspace_view.dart';
import '../image/image_workspace_view.dart';
import '../models/model_hub_workspace_view.dart';
import '../notes/notebook_workspace_view.dart';
import '../playground/playground_workspace_view.dart';
import '../speech/speech_workspace_view.dart';

part 'studio_active_engines_dialog.dart';
part 'studio_shell_sidebar.dart';
part 'studio_shell_topbar.dart';

/// Adaptive 3-zone cross-platform shell for `llamadart Studio`.
class StudioShellScreen extends StatefulWidget {
  /// Creates a [StudioShellScreen].
  const StudioShellScreen({super.key});

  @override
  State<StudioShellScreen> createState() => _StudioShellScreenState();
}

class _StudioShellScreenState extends State<StudioShellScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  AppLifecycleListener? _lifecycleListener;
  bool _usesInlineInspector = false;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleGlobalKeyEvent);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _lifecycleListener ??= AppLifecycleListener(
      onExitRequested: () async {
        final deps = StudioScope.of(context);
        await deps.lifecycleCoordinator.shutdownAll();
        return AppExitResponse.exit;
      },
    );
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleGlobalKeyEvent);
    _lifecycleListener?.dispose();
    super.dispose();
  }

  bool _handleGlobalKeyEvent(KeyEvent event) {
    if (!mounted || event is! KeyDownEvent) {
      return false;
    }
    final hw = HardwareKeyboard.instance;
    final key = event.logicalKey;
    final deps = StudioScope.of(context);
    final paletteOpen = deps.shellController.state.commandPaletteOpen;

    if (key == LogicalKeyboardKey.escape &&
        !paletteOpen &&
        (ModalRoute.of(context)?.isCurrent ?? true)) {
      var stopped = false;
      if (deps.chatController.activeStreamStore.state.isGenerating) {
        deps.chatController.stopGeneration();
        stopped = true;
      }
      if (deps.codingController.activeStreamStore.state.isGenerating) {
        deps.codingController.cancelGeneration();
        stopped = true;
      }
      if (stopped) {
        return true;
      }
    }

    if ((!hw.isMetaPressed && !hw.isControlPressed) || hw.isAltPressed) {
      return false;
    }

    if (key == LogicalKeyboardKey.keyK && !hw.isShiftPressed) {
      if (paletteOpen) {
        Navigator.of(context, rootNavigator: true).maybePop();
      } else if (ModalRoute.of(context)?.isCurrent ?? true) {
        unawaited(showStudioCommandPalette(context));
      }
      return true;
    }

    if (paletteOpen || !(ModalRoute.of(context)?.isCurrent ?? true)) {
      return false;
    }

    if (key == LogicalKeyboardKey.keyN && !hw.isShiftPressed) {
      unawaited(deps.chatController.createConversation());
      deps.shellController.selectWorkspace(StudioWorkspace.chat);
      return true;
    }
    if (key == LogicalKeyboardKey.keyI && !hw.isShiftPressed) {
      if (_usesInlineInspector) {
        deps.shellController.toggleInspector();
      } else {
        final scaffold = _scaffoldKey.currentState;
        if (scaffold?.isEndDrawerOpen ?? false) {
          scaffold?.closeEndDrawer();
        } else {
          scaffold?.openEndDrawer();
        }
      }
      return true;
    }

    final StudioWorkspace? targetWorkspace = switch (key) {
      LogicalKeyboardKey.digit1 ||
      LogicalKeyboardKey.numpad1 => StudioWorkspace.chat,
      LogicalKeyboardKey.digit2 ||
      LogicalKeyboardKey.numpad2 => StudioWorkspace.coding,
      LogicalKeyboardKey.digit3 ||
      LogicalKeyboardKey.numpad3 => StudioWorkspace.notes,
      LogicalKeyboardKey.digit4 ||
      LogicalKeyboardKey.numpad4 => StudioWorkspace.speech,
      LogicalKeyboardKey.digit5 ||
      LogicalKeyboardKey.numpad5 => StudioWorkspace.image,
      LogicalKeyboardKey.digit6 ||
      LogicalKeyboardKey.numpad6 => StudioWorkspace.playground,
      LogicalKeyboardKey.digit7 ||
      LogicalKeyboardKey.numpad7 => StudioWorkspace.models,
      _ => null,
    };
    if (targetWorkspace != null && !hw.isShiftPressed) {
      deps.shellController.selectWorkspace(targetWorkspace);
      return true;
    }
    return false;
  }

  static IconData _iconFor(StudioWorkspace workspace) {
    return switch (workspace) {
      StudioWorkspace.chat => Icons.chat_bubble_outline_rounded,
      StudioWorkspace.coding => Icons.code_rounded,
      StudioWorkspace.notes => Icons.auto_stories_outlined,
      StudioWorkspace.speech => Icons.graphic_eq_rounded,
      StudioWorkspace.image => Icons.palette_outlined,
      StudioWorkspace.playground => Icons.science_outlined,
      StudioWorkspace.models => Icons.hub_outlined,
    };
  }

  static String _compactNavLabel(StudioWorkspace workspace) {
    return switch (workspace) {
      StudioWorkspace.coding => 'Code',
      StudioWorkspace.playground => 'Lab',
      StudioWorkspace.models => 'Models',
      _ => workspace.label,
    };
  }

  static Widget _buildActiveWorkspace(StudioWorkspace workspace) {
    return switch (workspace) {
      StudioWorkspace.chat => const ChatWorkspaceView(
        key: ValueKey<StudioWorkspace>(StudioWorkspace.chat),
      ),
      StudioWorkspace.coding => const CodingWorkspaceView(
        key: ValueKey<StudioWorkspace>(StudioWorkspace.coding),
      ),
      StudioWorkspace.notes => const NotebookWorkspaceView(
        key: ValueKey<StudioWorkspace>(StudioWorkspace.notes),
      ),
      StudioWorkspace.speech => const SpeechWorkspaceView(
        key: ValueKey<StudioWorkspace>(StudioWorkspace.speech),
      ),
      StudioWorkspace.image => const ImageWorkspaceView(
        key: ValueKey<StudioWorkspace>(StudioWorkspace.image),
      ),
      StudioWorkspace.playground => const PlaygroundWorkspaceView(
        key: ValueKey<StudioWorkspace>(StudioWorkspace.playground),
      ),
      StudioWorkspace.models => const ModelHubWorkspaceView(
        key: ValueKey<StudioWorkspace>(StudioWorkspace.models),
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final deps = StudioScope.of(context);
    final palette = StudioPalette.of(context);

    return StoreBuilder<StudioShellState>(
      store: deps.shellController.store,
      builder: (BuildContext context, StudioShellState shellState) {
        return LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final width = constraints.maxWidth;
            final isWideDesktop = width >= 1120;
            _usesInlineInspector = isWideDesktop;
            final isTablet = width >= 720 && width < 1120;
            final isCompactMobile = width < 720;

            final workspaceBody = Column(
              children: <Widget>[
                _StudioTopBar(
                  isCompactMobile: isCompactMobile,
                  isWideDesktop: isWideDesktop,
                  onOpenLeftDrawer: () =>
                      _scaffoldKey.currentState?.openDrawer(),
                  onOpenInspectorDrawer: () =>
                      _scaffoldKey.currentState?.openEndDrawer(),
                ),
                const DownloadActivityBar(),
                if (shellState.bootRecoveryAlert != null)
                  _SafeBootRecoveryBanner(
                    alert: shellState.bootRecoveryAlert!,
                    onDismiss: deps.shellController.dismissBootRecoveryAlert,
                  ),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : const Duration(milliseconds: 200),
                    switchInCurve: Curves.easeOutCubic,
                    child: _buildActiveWorkspace(shellState.activeWorkspace),
                  ),
                ),
              ],
            );

            return Scaffold(
              key: _scaffoldKey,
              backgroundColor: palette.canvas,
              drawer: isWideDesktop
                  ? null
                  : Drawer(
                      width: math.min(288, width * 0.88),
                      backgroundColor: palette.sidebar,
                      child: SafeArea(
                        child: _StudioSidebarContent(
                          onNavigate: () => Navigator.of(context).maybePop(),
                        ),
                      ),
                    ),
              endDrawer: isWideDesktop
                  ? null
                  : Drawer(
                      width: math.min(340, width * 0.92),
                      backgroundColor: palette.sidebar,
                      child: SafeArea(
                        child: SessionInspectorPanel(
                          onClose: () => Navigator.of(context).maybePop(),
                        ),
                      ),
                    ),
              bottomNavigationBar: isCompactMobile
                  ? NavigationBarTheme(
                      data: NavigationBarThemeData(
                        labelTextStyle: WidgetStatePropertyAll<TextStyle>(
                          TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                            color: palette.textSecondary,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      child: NavigationBar(
                        height: 62,
                        backgroundColor: palette.sidebar,
                        selectedIndex: StudioWorkspace.values.indexOf(
                          shellState.activeWorkspace,
                        ),
                        onDestinationSelected: (int idx) => deps.shellController
                            .selectWorkspace(StudioWorkspace.values[idx]),
                        destinations: StudioWorkspace.values
                            .map(
                              (StudioWorkspace ws) => NavigationDestination(
                                icon: Icon(_iconFor(ws), size: 20),
                                tooltip: ws.label,
                                label: _compactNavLabel(ws),
                              ),
                            )
                            .toList(),
                      ),
                    )
                  : null,
              body: SafeArea(
                child: Row(
                  children: <Widget>[
                    if (isWideDesktop)
                      const SizedBox(width: 272, child: _StudioSidebarContent())
                    else if (isTablet)
                      LayoutBuilder(
                        builder:
                            (
                              BuildContext context,
                              BoxConstraints railConstraints,
                            ) {
                              return SingleChildScrollView(
                                child: ConstrainedBox(
                                  constraints: BoxConstraints(
                                    minHeight: railConstraints.maxHeight,
                                  ),
                                  child: IntrinsicHeight(
                                    child: NavigationRail(
                                      backgroundColor: palette.sidebar,
                                      leading: const Padding(
                                        padding: EdgeInsets.only(
                                          top: 8,
                                          bottom: 6,
                                        ),
                                        child: LlamadartBrandMark(size: 30),
                                      ),
                                      selectedIndex: StudioWorkspace.values
                                          .indexOf(shellState.activeWorkspace),
                                      labelType: NavigationRailLabelType.all,
                                      onDestinationSelected: (int idx) =>
                                          deps.shellController.selectWorkspace(
                                            StudioWorkspace.values[idx],
                                          ),
                                      destinations: StudioWorkspace.values
                                          .map(
                                            (StudioWorkspace ws) =>
                                                NavigationRailDestination(
                                                  icon: Icon(_iconFor(ws)),
                                                  label: Text(
                                                    ws.label,
                                                    style: const TextStyle(
                                                      fontSize: 11,
                                                    ),
                                                  ),
                                                ),
                                          )
                                          .toList(),
                                    ),
                                  ),
                                ),
                              );
                            },
                      ),
                    Expanded(child: workspaceBody),
                    if (isWideDesktop)
                      Builder(
                        builder: (BuildContext context) {
                          final inspectorPanel =
                              shellState.settings.inspectorOpen
                              ? SizedBox(
                                  width: 334,
                                  child: SessionInspectorPanel(
                                    onClose:
                                        deps.shellController.toggleInspector,
                                  ),
                                )
                              : const SizedBox.shrink();
                          if (MediaQuery.disableAnimationsOf(context)) {
                            return inspectorPanel;
                          }
                          return ClipRect(
                            child: AnimatedSize(
                              duration: const Duration(milliseconds: 220),
                              curve: Curves.easeOutCubic,
                              child: inspectorPanel,
                            ),
                          );
                        },
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}
