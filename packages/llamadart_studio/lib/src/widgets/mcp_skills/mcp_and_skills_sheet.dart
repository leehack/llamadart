import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

import '../../app/studio_dependencies.dart';
import '../../app/studio_theme.dart';
import '../code_syntax_highlighter.dart';
import '../store_widgets.dart';
import '../studio_motion.dart';

part 'mcp_servers_tab.dart';
part 'skills_and_context_tabs.dart';

/// Opens a polished modal managing live `mcp_dart` MCP servers
/// (`initialTab: 0`), `SKILL.md` Agent Skills (`initialTab: 1`), and
/// discovered `AGENTS.md` workspace context (`initialTab: 2`).
Future<void> showMcpAndSkillsSheet(
  BuildContext context, {
  int initialTab = 0,
}) async {
  final deps = StudioScope.of(context);
  await showDialog<void>(
    context: context,
    barrierColor: Colors.black54,
    builder: (BuildContext dialogContext) {
      final size = MediaQuery.sizeOf(dialogContext);
      final maxW = math.min(860.0, size.width - 24);
      final maxH = math.min(700.0, size.height - 40);
      final palette = StudioPalette.of(dialogContext);
      return StudioScope(
        deps: deps,
        child: Dialog(
          backgroundColor: palette.sidebar,
          insetPadding: const EdgeInsets.all(12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: palette.borderStrong),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: SizedBox(
              width: maxW,
              height: maxH,
              child: McpAndSkillsModalContent(initialTab: initialTab),
            ),
          ),
        ),
      );
    },
  );
}

/// Tabbed manager for `mcp_dart` servers, `SKILL.md` Agent Skills, and
/// `AGENTS.md` workspace instructions.
class McpAndSkillsModalContent extends StatefulWidget {
  /// Creates an [McpAndSkillsModalContent].
  const McpAndSkillsModalContent({super.key, this.initialTab = 0});

  /// Initial tab index (`0` = MCP Servers, `1` = Agent Skills, `2` = AGENTS.md).
  final int initialTab;

  @override
  State<McpAndSkillsModalContent> createState() =>
      _McpAndSkillsModalContentState();
}

class _McpAndSkillsModalContentState extends State<McpAndSkillsModalContent> {
  late int _activeTab;

  @override
  void initState() {
    super.initState();
    _activeTab = widget.initialTab.clamp(0, 2);
  }

  @override
  Widget build(BuildContext context) {
    final palette = StudioPalette.of(context);
    final deps = StudioScope.of(context);

    return Column(
      children: <Widget>[
        Container(
          padding: const EdgeInsets.fromLTRB(18, 14, 12, 12),
          decoration: BoxDecoration(
            color: palette.canvas.withValues(alpha: 0.55),
            border: Border(bottom: BorderSide(color: palette.borderSubtle)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: palette.accentMuted,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Icon(
                      Icons.extension_outlined,
                      size: 18,
                      color: palette.accent,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          'Tools, MCP Servers & Agent Context',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                            color: palette.textPrimary,
                          ),
                        ),
                        Text(
                          'Manage mcp_dart connections, SKILL.md bundles, and .agents / AGENTS.md workspace instructions.',
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
                  IconButton(
                    tooltip: 'Close',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded, size: 19),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              StoreBuilder<McpManagerState>(
                store: deps.mcpManager.store,
                builder: (BuildContext context, McpManagerState mcpState) {
                  return StoreBuilder<SkillRegistryState>(
                    store: deps.skillRegistry.store,
                    builder: (BuildContext context, SkillRegistryState skillState) {
                      return StoreBuilder<CodingWorkspaceState>(
                        store: deps.codingController.store,
                        builder: (BuildContext context, CodingWorkspaceState codingState) {
                          return SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: <Widget>[
                                _SheetTabPill(
                                  label:
                                      'MCP Servers (${mcpState.connectedCount}/${mcpState.servers.length})',
                                  icon: Icons.cable_rounded,
                                  selected: _activeTab == 0,
                                  onTap: () => setState(() => _activeTab = 0),
                                ),
                                const SizedBox(width: 8),
                                _SheetTabPill(
                                  label:
                                      'Agent Skills (${skillState.activeSkills.length})',
                                  icon: Icons.auto_fix_high_outlined,
                                  selected: _activeTab == 1,
                                  onTap: () => setState(() => _activeTab = 1),
                                ),
                                const SizedBox(width: 8),
                                _SheetTabPill(
                                  label:
                                      !codingState.agentsContext.hasInstructions
                                      ? 'AGENTS.md'
                                      : 'AGENTS.md (${codingState.agentsContext.sourceFiles.length})',
                                  icon: Icons.description_outlined,
                                  selected: _activeTab == 2,
                                  onTap: () => setState(() => _activeTab = 2),
                                ),
                              ],
                            ),
                          );
                        },
                      );
                    },
                  );
                },
              ),
            ],
          ),
        ),
        Expanded(
          child: switch (_activeTab) {
            0 => const _McpServersTab(),
            1 => const _AgentSkillsTab(),
            _ => const _AgentsContextTab(),
          },
        ),
      ],
    );
  }
}

class _SheetTabPill extends StatelessWidget {
  const _SheetTabPill({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = StudioPalette.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? palette.accentMuted : palette.surfaceElevated,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected
                ? palette.accent.withValues(alpha: 0.7)
                : palette.borderSubtle,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              icon,
              size: 15,
              color: selected ? palette.accent : palette.textSecondary,
            ),
            const SizedBox(width: 7),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? palette.textPrimary : palette.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
