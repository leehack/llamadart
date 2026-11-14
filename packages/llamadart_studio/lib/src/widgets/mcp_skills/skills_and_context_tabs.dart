part of 'mcp_and_skills_sheet.dart';

class _AgentSkillsTab extends StatefulWidget {
  const _AgentSkillsTab();

  @override
  State<_AgentSkillsTab> createState() => _AgentSkillsTabState();
}

class _AgentSkillsTabState extends State<_AgentSkillsTab> {
  final TextEditingController _markdownCtrl = TextEditingController();
  bool _showCreateForm = false;
  String? _expandedSkillId;

  @override
  void dispose() {
    _markdownCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickSkillDirectory() async {
    final deps = StudioScope.of(context);
    String? chosen;
    if (!deps.isWeb) {
      chosen = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Select SKILL.md Folder',
      );
    }
    if (chosen == null || chosen.trim().isEmpty) {
      return;
    }
    await deps.skillRegistry.addSkillDirectory(chosen);
  }

  Future<void> _addSkillDirectoryManual() async {
    final deps = StudioScope.of(context);
    var draftPath = '';
    final path = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          scrollable: true,
          title: const Text('Add SKILL.md Folder Path'),
          content: TextFormField(
            autofocus: true,
            onChanged: (String v) => draftPath = v,
            onFieldSubmitted: (String v) =>
                Navigator.of(dialogContext).pop(v.trim()),
            decoration: const InputDecoration(
              labelText: 'Directory containing SKILL.md subfolders',
              hintText: '/path/to/skills',
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(draftPath.trim()),
              child: const Text('Add'),
            ),
          ],
        );
      },
    );
    if (path != null && path.isNotEmpty) {
      await deps.skillRegistry.addSkillDirectory(path);
    }
  }

  Future<void> _saveMarkdownSkill() async {
    final deps = StudioScope.of(context);
    final raw = _markdownCtrl.text.trim();
    if (raw.isEmpty) {
      return;
    }
    await deps.skillRegistry.importSkillMarkdown(raw);
    _markdownCtrl.clear();
    if (mounted) {
      setState(() => _showCreateForm = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final deps = StudioScope.of(context);
    final palette = StudioPalette.of(context);

    return StoreBuilder<SkillRegistryState>(
      store: deps.skillRegistry.store,
      builder: (BuildContext context, SkillRegistryState skillState) {
        return ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: palette.surfaceElevated,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: palette.borderSubtle),
              ),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  StudioPillBadge(
                    label:
                        '${skillState.activeSkills.length} active in context',
                    foreground: palette.teal,
                    monospace: true,
                  ),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: <Widget>[
                      if (!deps.isWeb) ...<Widget>[
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                          ),
                          onPressed: _pickSkillDirectory,
                          icon: const Icon(
                            Icons.create_new_folder_outlined,
                            size: 16,
                          ),
                          label: const Text('Add Folder'),
                        ),
                        IconButton(
                          key: const Key('skills_manual_dir_button'),
                          tooltip: 'Enter skill folder path manually',
                          visualDensity: VisualDensity.compact,
                          onPressed: _addSkillDirectoryManual,
                          icon: const Icon(
                            Icons.edit_location_alt_outlined,
                            size: 18,
                          ),
                        ),
                        IconButton(
                          tooltip: 'Rescan .agents/skills & ~/.agents/skills',
                          visualDensity: VisualDensity.compact,
                          onPressed: () =>
                              deps.skillRegistry.refreshDiscoveredSkills(),
                          icon: const Icon(Icons.refresh_rounded, size: 18),
                        ),
                      ],
                      FilledButton.icon(
                        key: const Key('skills_toggle_create_button'),
                        style: FilledButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                        onPressed: () =>
                            setState(() => _showCreateForm = !_showCreateForm),
                        icon: Icon(
                          _showCreateForm
                              ? Icons.close_rounded
                              : Icons.add_rounded,
                          size: 16,
                        ),
                        label: Text(
                          _showCreateForm ? 'Cancel' : 'New SKILL.md',
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (skillState.customDirectories.isNotEmpty) ...<Widget>[
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: <Widget>[
                  for (final dir in skillState.customDirectories)
                    Chip(
                      label: Text(
                        dir,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11),
                      ),
                      onDeleted: () =>
                          deps.skillRegistry.removeSkillDirectory(dir),
                    ),
                ],
              ),
            ],
            if (_showCreateForm) ...<Widget>[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: palette.surfaceElevated,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: palette.borderStrong),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    TextField(
                      key: const Key('skill_markdown_input'),
                      controller: _markdownCtrl,
                      maxLines: 7,
                      style: const TextStyle(
                        fontSize: 12,
                        fontFamilyFallback: StudioTheme.monoFontFallback,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'SKILL.md (YAML Frontmatter + Instructions)',
                        hintText: '---\nname: test-first-refactor\ndescription: Write failing tests before refactoring.\n---\nAlways add targeted unit tests first.',
                      ),
                    ),
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton.icon(
                        key: const Key('skill_save_markdown_button'),
                        onPressed: _saveMarkdownSkill,
                        icon: const Icon(Icons.save_outlined, size: 16),
                        label: const Text('Save & Enable Skill'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 12),
            for (final skill in skillState.skills)
              Container(
                key: Key('skill_card_${skill.id}'),
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: palette.surfaceElevated,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: skill.enabled
                        ? palette.accent.withValues(alpha: 0.45)
                        : palette.borderSubtle,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Wrap(
                                spacing: 8,
                                runSpacing: 4,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: <Widget>[
                                  Text(
                                    skill.name,
                                    style: TextStyle(
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w700,
                                      color: palette.textPrimary,
                                    ),
                                  ),
                                  StudioPillBadge(
                                    label: skill.isBuiltIn
                                        ? 'Built-in'
                                        : (skill.isDiscovered
                                              ? (skill.sourcePath?.contains(
                                                          '.agents',
                                                        ) ==
                                                        true
                                                    ? '.agents/skills'
                                                    : 'Disk SKILL.md')
                                              : 'Custom'),
                                    foreground: skill.isDiscovered
                                        ? palette.teal
                                        : palette.textSecondary,
                                    monospace: true,
                                  ),
                                ],
                              ),
                              if (skill.description.isNotEmpty) ...<Widget>[
                                const SizedBox(height: 3),
                                Text(
                                  skill.description,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: palette.textSecondary,
                                  ),
                                ),
                              ],
                              if (skill.sourcePath != null &&
                                  skill.sourcePath!.isNotEmpty) ...<Widget>[
                                const SizedBox(height: 3),
                                Text(
                                  skill.sourcePath!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    color: palette.textMuted,
                                    fontFamilyFallback:
                                        StudioTheme.monoFontFallback,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        Transform.scale(
                          scale: 0.85,
                          child: Switch.adaptive(
                            key: Key('skill_toggle_${skill.id}'),
                            value: skill.enabled,
                            onChanged: (bool v) =>
                                deps.skillRegistry.setSkillEnabled(skill.id, v),
                          ),
                        ),
                        if (!skill.isBuiltIn && !skill.isDiscovered)
                          IconButton(
                            tooltip: 'Delete custom skill',
                            visualDensity: VisualDensity.compact,
                            onPressed: () =>
                                deps.skillRegistry.deleteCustomSkill(skill.id),
                            icon: Icon(
                              Icons.delete_outline_rounded,
                              size: 17,
                              color: palette.textMuted,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    InkWell(
                      onTap: () => setState(() {
                        _expandedSkillId = _expandedSkillId == skill.id
                            ? null
                            : skill.id;
                      }),
                      child: Text(
                        _expandedSkillId == skill.id
                            ? 'Hide SKILL.md instructions ▲'
                            : 'View SKILL.md instructions ▼',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: palette.accent,
                        ),
                      ),
                    ),
                    if (_expandedSkillId == skill.id) ...<Widget>[
                      const SizedBox(height: 8),
                      Container(
                        width: double.infinity,
                        constraints: const BoxConstraints(maxHeight: 240),
                        decoration: BoxDecoration(
                          color: palette.canvas,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: palette.borderSubtle),
                        ),
                        child: SyntaxCodeView(
                          code: skill.instructions,
                          language: 'markdown',
                          showLineNumbers: false,
                          fontSize: 11.5,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

class _AgentsContextTab extends StatelessWidget {
  const _AgentsContextTab();

  @override
  Widget build(BuildContext context) {
    final deps = StudioScope.of(context);
    final palette = StudioPalette.of(context);

    return StoreBuilder<CodingWorkspaceState>(
      store: deps.codingController.store,
      builder: (BuildContext context, CodingWorkspaceState codingState) {
        final ctx = codingState.agentsContext;

        return ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: palette.surfaceElevated,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: palette.borderSubtle),
              ),
              child: Wrap(
                spacing: 10,
                runSpacing: 8,
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: <Widget>[
                      StudioPillBadge(
                        label: !ctx.hasInstructions
                            ? 'No AGENTS.md detected'
                            : '${ctx.sourceFiles.length} instruction file(s) active',
                        foreground: !ctx.hasInstructions
                            ? palette.amber
                            : palette.teal,
                        monospace: true,
                      ),
                      if (codingState.workspaceRoot != null)
                        StudioPillBadge(
                          label: codingState.workspaceRoot!,
                          monospace: true,
                        ),
                    ],
                  ),
                  if (!deps.isWeb && codingState.workspaceRoot != null)
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: () => deps.codingController.setWorkspaceRoot(
                        codingState.workspaceRoot!,
                      ),
                      icon: const Icon(Icons.refresh_rounded, size: 15),
                      label: const Text('Reload Project Context'),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            if (!ctx.hasInstructions)
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: palette.surfaceElevated,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: palette.borderSubtle),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Project Instructions & .agents Discovery',
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: palette.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'When you open a project folder in Coding, Studio automatically reads:\n'
                      '• AGENTS.md, .agents/AGENTS.md, and CLAUDE.md (injected into Coding & Chat)\n'
                      '• .agents/skills/* and ~/.agents/skills/* (SKILL.md bundles)\n'
                      '• .agents/mcp.json, .mcp.json, and .vscode/mcp.json (project MCP servers)',
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.5,
                        color: palette.textSecondary,
                      ),
                    ),
                  ],
                ),
              )
            else
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: palette.surfaceElevated,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: palette.borderSubtle),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                      child: Row(
                        children: <Widget>[
                          Icon(
                            Icons.description_outlined,
                            size: 16,
                            color: palette.teal,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              ctx.sourceFiles.join(', '),
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w700,
                                color: palette.textPrimary,
                                fontFamilyFallback:
                                    StudioTheme.monoFontFallback,
                              ),
                            ),
                          ),
                          StudioPillBadge(
                            label: 'Injected',
                            foreground: palette.teal,
                            monospace: true,
                          ),
                        ],
                      ),
                    ),
                    Divider(height: 1, color: palette.borderSubtle),
                    Container(
                      width: double.infinity,
                      constraints: const BoxConstraints(maxHeight: 340),
                      color: palette.canvas,
                      child: SyntaxCodeView(
                        code: ctx.instructions,
                        language: 'markdown',
                        showLineNumbers: true,
                        showHeader: true,
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}
