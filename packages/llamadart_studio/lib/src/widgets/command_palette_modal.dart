// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

import '../app/studio_dependencies.dart';
import '../app/studio_theme.dart';
import 'mcp_skills/mcp_and_skills_sheet.dart';

/// Opens the searchable `Cmd/Ctrl+K` Command Palette modal.
Future<void> showStudioCommandPalette(BuildContext context) async {
  final deps = StudioScope.of(context);
  deps.shellController.setCommandPaletteOpen(true);
  try {
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      builder: (BuildContext dialogContext) =>
          StudioScope(deps: deps, child: const StudioCommandPaletteModal()),
    );
  } finally {
    deps.shellController.setCommandPaletteOpen(false);
  }
}

class _PaletteAction {
  const _PaletteAction({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.onInvoke,
    this.shortcutHint,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final String? shortcutHint;
  final Future<void> Function() onInvoke;
}

/// Searchable keyboard-first Command Palette (`Cmd/Ctrl+K`) for Studio actions.
class StudioCommandPaletteModal extends StatefulWidget {
  /// Creates a [StudioCommandPaletteModal].
  const StudioCommandPaletteModal({super.key});

  @override
  State<StudioCommandPaletteModal> createState() =>
      _StudioCommandPaletteModalState();
}

class _StudioCommandPaletteModalState extends State<StudioCommandPaletteModal> {
  final TextEditingController _queryController = TextEditingController();
  int _highlightedIndex = 0;

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  List<_PaletteAction> _buildActions(BuildContext context) {
    final deps = StudioScope.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final chatStreaming =
        deps.chatController.activeStreamStore.state.isGenerating;
    final codingStreaming =
        deps.codingController.activeStreamStore.state.isGenerating;

    return <_PaletteAction>[
      if (chatStreaming || codingStreaming)
        _PaletteAction(
          title: 'Stop Active Generation',
          subtitle: 'Immediately cancel the active streaming turn',
          icon: Icons.stop_circle_outlined,
          onInvoke: () async {
            if (chatStreaming) {
              deps.chatController.stopGeneration();
            }
            if (codingStreaming) {
              deps.codingController.cancelGeneration();
            }
          },
        ),
      _PaletteAction(
        title: 'New Chat Session',
        subtitle: 'Start a clean conversation branch',
        icon: Icons.add_comment_outlined,
        shortcutHint: deps.isMobile
            ? null
            : StudioTheme.shortcutLabel(context, 'N'),
        onInvoke: () async {
          await deps.chatController.createConversation();
          deps.shellController.selectWorkspace(StudioWorkspace.chat);
        },
      ),
      for (final workspace in StudioWorkspace.values)
        _PaletteAction(
          title: 'Go to ${workspace.label}',
          subtitle: workspace.subtitle,
          icon: _workspaceIcon(workspace),
          shortcutHint: deps.isMobile
              ? null
              : StudioTheme.shortcutLabel(
                  context,
                  '${workspace.shortcutDigit}',
                ),
          onInvoke: () async {
            deps.shellController.selectWorkspace(workspace);
          },
        ),
      for (final preset in StudioPreset.builtInPresets)
        _PaletteAction(
          title: 'Apply Preset · ${preset.name}',
          subtitle: preset.description,
          icon: Icons.auto_awesome_outlined,
          onInvoke: () async {
            await deps.chatController.applyPreset(preset);
            deps.shellController.selectWorkspace(StudioWorkspace.chat);
            messenger?.showSnackBar(
              SnackBar(content: Text('Applied preset "${preset.name}"')),
            );
          },
        ),
      _PaletteAction(
        title: 'Toggle Session Inspector',
        subtitle: 'Show or hide Hardware, Prompt, Sampling & Tool controls',
        icon: Icons.tune_rounded,
        shortcutHint: deps.isMobile
            ? null
            : StudioTheme.shortcutLabel(context, 'I'),
        onInvoke: () => deps.shellController.toggleInspector(),
      ),
      _PaletteAction(
        title: 'Manage MCP Servers & Agent Skills',
        subtitle: 'Configure mcp_dart servers, .agents/skills, and AGENTS.md',
        icon: Icons.extension_outlined,
        onInvoke: () => showMcpAndSkillsSheet(context),
      ),
      _PaletteAction(
        title: 'Inspect AGENTS.md & .agents Context',
        subtitle:
            'View workspace instructions, project MCPs & discovered skills',
        icon: Icons.article_outlined,
        onInvoke: () => showMcpAndSkillsSheet(context, initialTab: 2),
      ),
      _PaletteAction(
        title: 'Switch Theme · Dark',
        subtitle: 'Use high-contrast dark graphite Studio palette',
        icon: Icons.dark_mode_outlined,
        onInvoke: () =>
            deps.shellController.setAppearance(StudioAppearance.dark),
      ),
      _PaletteAction(
        title: 'Switch Theme · Light',
        subtitle: 'Use crisp daylight Studio palette',
        icon: Icons.light_mode_outlined,
        onInvoke: () =>
            deps.shellController.setAppearance(StudioAppearance.light),
      ),
      _PaletteAction(
        title: 'Switch Theme · System',
        subtitle: 'Follow host operating system appearance',
        icon: Icons.brightness_auto_outlined,
        onInvoke: () =>
            deps.shellController.setAppearance(StudioAppearance.system),
      ),
      _PaletteAction(
        title: 'Copy Active Transcript as Markdown',
        subtitle: 'Copies messages, reasoning blocks, and metrics to clipboard',
        icon: Icons.description_outlined,
        onInvoke: () async {
          final md = deps.chatController.exportActiveAsMarkdown();
          await Clipboard.setData(ClipboardData(text: md));
          messenger?.showSnackBar(
            const SnackBar(content: Text('Copied Markdown transcript')),
          );
        },
      ),
      _PaletteAction(
        title: 'Copy Active Session Tree as JSON',
        subtitle: 'Exports all non-destructive branches to JSON',
        icon: Icons.data_object_rounded,
        onInvoke: () async {
          try {
            final json = await deps.chatController.exportActiveAsJson();
            await Clipboard.setData(ClipboardData(text: json));
            messenger?.showSnackBar(
              const SnackBar(content: Text('Copied session JSON to clipboard')),
            );
          } on FormatException catch (error) {
            messenger?.showSnackBar(SnackBar(content: Text(error.message)));
          }
        },
      ),
      _PaletteAction(
        title: 'Unload Active Chat Model',
        subtitle: 'Release native GPU/RAM weights immediately',
        icon: Icons.eject_outlined,
        onInvoke: () async {
          await deps.modelHubController.unloadActiveModel();
          messenger?.showSnackBar(
            const SnackBar(content: Text('Unloaded active chat model')),
          );
        },
      ),
    ];
  }

  static IconData _workspaceIcon(StudioWorkspace workspace) {
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

  @override
  Widget build(BuildContext context) {
    final palette = StudioPalette.of(context);
    final allActions = _buildActions(context);
    final query = _queryController.text.trim().toLowerCase();
    final filtered = query.isEmpty
        ? allActions
        : allActions
              .where(
                (_PaletteAction a) =>
                    a.title.toLowerCase().contains(query) ||
                    a.subtitle.toLowerCase().contains(query),
              )
              .toList(growable: false);

    final safeIndex = filtered.isEmpty
        ? 0
        : _highlightedIndex.clamp(0, filtered.length - 1);

    Future<void> trigger(_PaletteAction action) async {
      Navigator.of(context).pop();
      await action.onInvoke();
    }

    return Dialog(
      backgroundColor: palette.sidebar,
      alignment: const Alignment(0, -0.45),
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: palette.borderStrong),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 580, maxHeight: 460),
        child: CallbackShortcuts(
          bindings: <ShortcutActivator, VoidCallback>{
            const SingleActivator(LogicalKeyboardKey.arrowDown): () {
              if (filtered.isNotEmpty) {
                setState(
                  () => _highlightedIndex = (safeIndex + 1) % filtered.length,
                );
              }
            },
            const SingleActivator(LogicalKeyboardKey.arrowUp): () {
              if (filtered.isNotEmpty) {
                setState(
                  () => _highlightedIndex =
                      (safeIndex - 1 + filtered.length) % filtered.length,
                );
              }
            },
            const SingleActivator(LogicalKeyboardKey.enter): () {
              if (filtered.isNotEmpty) {
                trigger(filtered[safeIndex]);
              }
            },
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                child: TextField(
                  key: const Key('command_palette_search_field'),
                  controller: _queryController,
                  autofocus: true,
                  onChanged: (_) => setState(() => _highlightedIndex = 0),
                  onSubmitted: (_) {
                    if (filtered.isNotEmpty) {
                      trigger(filtered[safeIndex]);
                    }
                  },
                  decoration: InputDecoration(
                    hintText: 'Type a command, workspace, or preset (↑↓ to navigate)...',
                    prefixIcon: Icon(
                      Icons.search_rounded,
                      size: 19,
                      color: palette.accent,
                    ),
                    suffixIcon: Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: UnconstrainedBox(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(5),
                            border: Border.all(color: palette.borderSubtle),
                          ),
                          child: Text(
                            'ESC',
                            style: TextStyle(
                              fontSize: 10,
                              color: palette.textMuted,
                              fontFamilyFallback: StudioTheme.monoFontFallback,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Divider(height: 1, color: palette.borderSubtle),
              Flexible(
                child: filtered.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(28),
                        child: Text(
                          'No matching commands found.',
                          style: TextStyle(color: palette.textMuted),
                        ),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        itemCount: filtered.length,
                        itemBuilder: (BuildContext context, int index) {
                          final action = filtered[index];
                          final selected = index == safeIndex;
                          return InkWell(
                            borderRadius: BorderRadius.circular(10),
                            onTap: () => trigger(action),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                              decoration: BoxDecoration(
                                color: selected
                                    ? palette.accentMuted
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Row(
                                children: <Widget>[
                                  Icon(
                                    action.icon,
                                    size: 18,
                                    color: selected
                                        ? palette.accent
                                        : palette.textSecondary,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: <Widget>[
                                        Text(
                                          action.title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600,
                                            color: palette.textPrimary,
                                          ),
                                        ),
                                        const SizedBox(height: 1),
                                        Text(
                                          action.subtitle,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 11.5,
                                            color: palette.textMuted,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (action.shortcutHint != null) ...<Widget>[
                                    const SizedBox(width: 8),
                                    Text(
                                      action.shortcutHint!,
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: palette.textMuted,
                                        fontFamilyFallback:
                                            StudioTheme.monoFontFallback,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
