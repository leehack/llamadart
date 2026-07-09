import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../providers/chat_provider.dart';
import 'chat_screen.dart';
import 'manage_models_screen.dart';

class AppShellScreen extends StatefulWidget {
  const AppShellScreen({super.key});

  @override
  State<AppShellScreen> createState() => _AppShellScreenState();
}

class _AppShellScreenState extends State<AppShellScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  void _startNewConversation() {
    context.read<ChatProvider>().createConversation();
  }

  void _openSettingsPanel() {
    _scaffoldKey.currentState?.openEndDrawer();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isDesktop = constraints.maxWidth >= 1040;
        final showPinnedSettingsPanel = constraints.maxWidth >= 1360;
        final showSlidingSettings = !showPinnedSettingsPanel;

        return Scaffold(
          key: _scaffoldKey,
          drawer: isDesktop
              ? null
              : Drawer(
                  child: SafeArea(
                    child: _ShellSidebar(
                      onNewConversation: _startNewConversation,
                      onConversationActivated: () {
                        Navigator.of(context).pop();
                      },
                    ),
                  ),
                ),
          endDrawer: showSlidingSettings
              ? const Drawer(
                  child: SafeArea(
                    child: ManageModelsScreen(embeddedPanel: true),
                  ),
                )
              : null,
          body: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0xFF0A0E17),
                  Color(0xFF090D15),
                  Color(0xFF070B13),
                ],
              ),
            ),
            child: Column(
              children: [
                _ShellTopBar(
                  showMenuButton: !isDesktop,
                  showSettingsButton: showSlidingSettings,
                  onMenuPressed: () => _scaffoldKey.currentState?.openDrawer(),
                  onOpenSettings: _openSettingsPanel,
                ),
                Expanded(
                  child: Row(
                    children: [
                      if (isDesktop)
                        SizedBox(
                          width: 292,
                          child: _ShellSidebar(
                            onNewConversation: _startNewConversation,
                          ),
                        ),
                      if (isDesktop)
                        Container(
                          width: 1,
                          color: Theme.of(
                            context,
                          ).colorScheme.outlineVariant.withValues(alpha: 0.45),
                        ),
                      Expanded(
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(
                            isDesktop ? 20 : 10,
                            10,
                            isDesktop ? 20 : 10,
                            14,
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(
                              isDesktop ? 22 : 18,
                            ),
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .outlineVariant
                                      .withValues(alpha: 0.35),
                                ),
                                gradient: const LinearGradient(
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                  colors: [
                                    Color(0xCC101826),
                                    Color(0xCC0C1422),
                                  ],
                                ),
                              ),
                              child: ChatScreen(
                                onOpenModelSelection: showSlidingSettings
                                    ? _openSettingsPanel
                                    : null,
                                showModelSelectionAction: showSlidingSettings,
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (showPinnedSettingsPanel)
                        Container(
                          width: 1,
                          color: Theme.of(
                            context,
                          ).colorScheme.outlineVariant.withValues(alpha: 0.45),
                        ),
                      if (showPinnedSettingsPanel)
                        SizedBox(
                          width: 430,
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(12, 10, 14, 14),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(18),
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.surface.withValues(alpha: 0.55),
                                  border: Border.all(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .outlineVariant
                                        .withValues(alpha: 0.35),
                                  ),
                                ),
                                child: const ManageModelsScreen(
                                  embeddedPanel: true,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ShellTopBar extends StatelessWidget {
  final bool showMenuButton;
  final bool showSettingsButton;
  final VoidCallback onMenuPressed;
  final VoidCallback onOpenSettings;

  const _ShellTopBar({
    required this.showMenuButton,
    required this.showSettingsButton,
    required this.onMenuPressed,
    required this.onOpenSettings,
  });

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.paddingOf(context).top;

    return Container(
      padding: EdgeInsets.fromLTRB(12, topInset + 10, 12, 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.55),
        border: Border(
          bottom: BorderSide(
            color: Theme.of(
              context,
            ).colorScheme.outlineVariant.withValues(alpha: 0.35),
          ),
        ),
      ),
      child: Row(
        children: [
          if (showMenuButton)
            Semantics(
              button: true,
              label: 'Open navigation menu',
              child: IconButton(
                onPressed: onMenuPressed,
                icon: const Icon(Icons.menu_rounded),
                tooltip: 'Open navigation menu',
              ),
            ),
          const SizedBox(width: 6),
          Text(
            'llamadart chat',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
              letterSpacing: 0,
            ),
          ),
          const Spacer(),
          if (showSettingsButton)
            Semantics(
              button: true,
              label: 'Open model and inference settings',
              child: IconButton(
                onPressed: onOpenSettings,
                tooltip: 'Open model and inference settings',
                icon: const Icon(Icons.tune_rounded),
              ),
            ),
        ],
      ),
    );
  }
}

class _ShellSidebar extends StatelessWidget {
  static final Uri _githubUri = Uri.parse(
    'https://github.com/leehack/llamadart',
  );
  static final Uri _pubDevUri = Uri.parse('https://pub.dev/packages/llamadart');

  final VoidCallback onNewConversation;
  final VoidCallback? onConversationActivated;

  const _ShellSidebar({
    required this.onNewConversation,
    this.onConversationActivated,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      color: colorScheme.surface.withValues(alpha: 0.35),
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FilledButton.tonalIcon(
            onPressed: onNewConversation,
            icon: const Icon(Icons.add_rounded),
            label: const Text('New conversation'),
          ),
          const SizedBox(height: 14),
          Text(
            'Conversations',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Consumer<ChatProvider>(
              builder: (context, provider, _) {
                final conversations = provider.conversations;
                if (conversations.isEmpty) {
                  return const SizedBox.shrink();
                }

                return ListView.separated(
                  itemCount: conversations.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 6),
                  itemBuilder: (context, index) {
                    final conversation = conversations[index];
                    return _ConversationTile(
                      title: conversation.title,
                      selected:
                          provider.activeConversationId == conversation.id,
                      canDelete: true,
                      onTap: () {
                        unawaited(provider.switchConversation(conversation.id));
                        onConversationActivated?.call();
                      },
                      onDelete: () => unawaited(
                        provider.deleteConversation(conversation.id),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          Divider(
            color: colorScheme.outlineVariant.withValues(alpha: 0.35),
            height: 1,
          ),
          const SizedBox(height: 10),
          _ExternalLinkButton(
            icon: Icons.code_rounded,
            label: 'GitHub',
            uri: _githubUri,
          ),
          const SizedBox(height: 6),
          _ExternalLinkButton(
            icon: Icons.open_in_new_rounded,
            label: 'pub.dev',
            uri: _pubDevUri,
          ),
        ],
      ),
    );
  }
}

class _ExternalLinkButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Uri uri;

  const _ExternalLinkButton({
    required this.icon,
    required this.label,
    required this.uri,
  });

  Future<void> _open(BuildContext context) async {
    final launched = await launchUrl(uri, mode: LaunchMode.platformDefault);
    if (!launched && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not open $label link.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: () => unawaited(_open(context)),
        icon: Icon(icon, size: 18),
        label: Text(label),
        style: TextButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        ),
      ),
    );
  }
}

class _ConversationTile extends StatefulWidget {
  final String title;
  final bool selected;
  final VoidCallback onTap;
  final bool canDelete;
  final VoidCallback onDelete;

  const _ConversationTile({
    required this.title,
    required this.selected,
    required this.onTap,
    required this.canDelete,
    required this.onDelete,
  });

  @override
  State<_ConversationTile> createState() => _ConversationTileState();
}

class _ConversationTileState extends State<_ConversationTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final title = widget.title;
    final resolvedTitle = title.length > 42
        ? '${title.substring(0, 42)}...'
        : title;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          decoration: BoxDecoration(
            color: widget.selected
                ? colorScheme.surfaceContainerHighest.withValues(alpha: 0.75)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  resolvedTitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              if (widget.canDelete)
                AnimatedOpacity(
                  opacity: (_hovered || widget.selected) ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 120),
                  child: Semantics(
                    button: true,
                    label: 'Delete conversation',
                    child: IconButton(
                      onPressed: widget.onDelete,
                      visualDensity: VisualDensity.compact,
                      iconSize: 17,
                      tooltip: 'Delete conversation',
                      icon: Icon(
                        Icons.delete_outline_rounded,
                        color: colorScheme.error,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
