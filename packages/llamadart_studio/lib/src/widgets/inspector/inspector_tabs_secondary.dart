part of 'session_inspector_panel.dart';

extension _InspectorSecondaryTabs on _SessionInspectorPanelState {
  Widget _buildPromptTab(
    BuildContext context,
    StudioDependencies deps,
    StudioSettings settings,
    StudioConversation? activeConversation,
  ) {
    final palette = StudioPalette.of(context);
    final rawSchema = _jsonSchemaController.text.trim();
    bool? schemaSyntaxOk;
    if (rawSchema.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawSchema);
        schemaSyntaxOk = decoded is Map;
      } catch (_) {
        schemaSyntaxOk = false;
      }
    }

    return ListView(
      padding: const EdgeInsets.all(14),
      children: <Widget>[
        _SectionLabel(label: 'Built-in Persona Presets'),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: StudioPreset.builtInPresets.map((StudioPreset preset) {
            final selected = activeConversation?.presetId == preset.id;
            return ChoiceChip(
              label: Text(preset.name, style: const TextStyle(fontSize: 11.5)),
              selected: selected,
              onSelected: (_) async {
                await deps.chatController.applyPreset(preset);
                _systemPromptController.text = preset.systemPrompt;
                _jsonSchemaController.text = preset.jsonSchema ?? '';
              },
            );
          }).toList(),
        ),
        const SizedBox(height: 14),
        _SectionLabel(label: 'System Instruction'),
        const SizedBox(height: 6),
        TextField(
          controller: _systemPromptController,
          maxLines: 5,
          style: const TextStyle(fontSize: 12.5, height: 1.4),
          decoration: const InputDecoration(
            hintText: 'Define assistant persona, constraints, or tone...',
          ),
          onChanged: (String next) =>
              deps.chatController.updateActivePromptConfig(
                systemPrompt: next,
                jsonSchema: rawSchema.isEmpty ? null : rawSchema,
                clearJsonSchema: rawSchema.isEmpty,
              ),
        ),
        const SizedBox(height: 10),
        SwitchListTile.adaptive(
          key: const Key('chat_include_workspace_context_switch'),
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text(
            'Include Coding Workspace AGENTS.md',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            'Off by default so casual Chat avoids prefill overhead from large repo instructions',
            style: TextStyle(fontSize: 11, color: palette.textMuted),
          ),
          value: settings.includeWorkspaceContextInChat,
          onChanged: (bool v) => deps.shellController.updateSettings(
            (StudioSettings s) => s.copyWith(includeWorkspaceContextInChat: v),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: <Widget>[
            Expanded(
              child: _SectionLabel(label: 'Structured Output (JSON Schema)'),
            ),
            if (schemaSyntaxOk != null)
              StudioPillBadge(
                label: schemaSyntaxOk ? 'Valid JSON' : 'Invalid JSON',
                foreground: schemaSyntaxOk ? palette.teal : palette.danger,
                monospace: true,
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Leave empty for free-form Markdown, or provide a JSON Schema object for GBNF grammar-constrained output.',
          style: TextStyle(fontSize: 11, color: palette.textMuted),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _jsonSchemaController,
          maxLines: 8,
          style: const TextStyle(
            fontSize: 11.5,
            height: 1.35,
            fontFamilyFallback: StudioTheme.monoFontFallback,
          ),
          decoration: InputDecoration(
            hintText: '{"type": "object", "properties": {...}}',
            suffixIcon: _jsonSchemaController.text.isNotEmpty
                ? IconButton(
                    tooltip: 'Clear schema',
                    icon: const Icon(Icons.clear_rounded, size: 16),
                    onPressed: () {
                      _jsonSchemaController.clear();
                      deps.chatController.updateActivePromptConfig(
                        clearJsonSchema: true,
                      );
                      _updateState(() {});
                    },
                  )
                : null,
          ),
          onChanged: (String value) {
            _updateState(() {});
            final trimmed = value.trim();
            deps.chatController.updateActivePromptConfig(
              jsonSchema: trimmed.isEmpty ? null : trimmed,
              clearJsonSchema: trimmed.isEmpty,
            );
          },
        ),
      ],
    );
  }

  Widget _buildSamplingTab(
    BuildContext context,
    StudioDependencies deps,
    StudioSettings settings,
  ) {
    final palette = StudioPalette.of(context);
    return ListView(
      padding: const EdgeInsets.all(14),
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(child: _SectionLabel(label: 'Generation Sampling')),
            TextButton.icon(
              key: const Key('inspector_reset_sampling_button'),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              ),
              onPressed: () => deps.shellController.updateSettings(
                (StudioSettings s) => s.resetSamplingDefaults(),
              ),
              icon: const Icon(Icons.restart_alt_rounded, size: 14),
              label: const Text(
                'Reset Defaults',
                style: TextStyle(fontSize: 11.5),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        _SliderControl(
          label: 'Temperature',
          valueLabel: settings.temperature.toStringAsFixed(2),
          value: settings.temperature.clamp(0.0, 2.0),
          min: 0.0,
          max: 2.0,
          divisions: 40,
          onChanged: (double v) => deps.shellController.updateSettings(
            (StudioSettings s) => s.copyWith(temperature: v),
          ),
        ),
        _SliderControl(
          label: 'Top-P (Nucleus)',
          valueLabel: settings.topP.toStringAsFixed(2),
          value: settings.topP.clamp(0.05, 1.0),
          min: 0.05,
          max: 1.0,
          divisions: 38,
          onChanged: (double v) => deps.shellController.updateSettings(
            (StudioSettings s) => s.copyWith(topP: v),
          ),
        ),
        _SliderControl(
          label: 'Top-K',
          valueLabel: '${settings.topK}',
          value: settings.topK.clamp(1, 120).toDouble(),
          min: 1,
          max: 120,
          divisions: 119,
          onChanged: (double v) => deps.shellController.updateSettings(
            (StudioSettings s) => s.copyWith(topK: v.round()),
          ),
        ),
        _SliderControl(
          label: 'Min-P',
          valueLabel: settings.minP.toStringAsFixed(2),
          value: settings.minP.clamp(0.0, 0.5),
          min: 0.0,
          max: 0.5,
          divisions: 25,
          onChanged: (double v) => deps.shellController.updateSettings(
            (StudioSettings s) => s.copyWith(minP: v),
          ),
        ),
        _SliderControl(
          label: 'Repetition Penalty',
          valueLabel: settings.penalty.toStringAsFixed(2),
          value: settings.penalty.clamp(1.0, 1.5),
          min: 1.0,
          max: 1.5,
          divisions: 25,
          onChanged: (double v) => deps.shellController.updateSettings(
            (StudioSettings s) => s.copyWith(penalty: v),
          ),
        ),
        _SliderControl(
          label: 'Presence Penalty',
          valueLabel: settings.presencePenalty.toStringAsFixed(2),
          value: settings.presencePenalty.clamp(0.0, 2.0),
          min: 0.0,
          max: 2.0,
          divisions: 40,
          onChanged: (double v) => deps.shellController.updateSettings(
            (StudioSettings s) => s.copyWith(presencePenalty: v),
          ),
        ),
        _SliderControl(
          label: 'Max Completion Tokens',
          valueLabel: '${settings.maxTokens}',
          value: settings.maxTokens.clamp(128, 8192).toDouble(),
          min: 128,
          max: 8192,
          divisions: 63,
          onChanged: (double v) => deps.shellController.updateSettings(
            (StudioSettings s) => s.copyWith(maxTokens: v.round()),
          ),
        ),
        Divider(height: 24, color: palette.borderSubtle),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text(
            'Chain-of-Thought Reasoning',
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            'Stream expandable <think> blocks on Qwen3 / Gemma 4 / DeepSeek',
            style: TextStyle(fontSize: 11, color: palette.textMuted),
          ),
          value: settings.thinkingEnabled,
          onChanged: (bool v) => deps.shellController.updateSettings(
            (StudioSettings s) => s.copyWith(thinkingEnabled: v),
          ),
        ),
        if (settings.thinkingEnabled)
          _SliderControl(
            label: 'Thinking Token Budget',
            valueLabel: settings.thinkingBudgetTokens <= 0
                ? 'Auto (~55%)'
                : '${settings.thinkingBudgetTokens} tok',
            value: settings.thinkingBudgetTokens.clamp(0, 4096).toDouble(),
            min: 0,
            max: 4096,
            divisions: 32,
            onChanged: (double v) => deps.shellController.updateSettings(
              (StudioSettings s) => s.copyWith(thinkingBudgetTokens: v.round()),
            ),
          ),
      ],
    );
  }

  Widget _buildToolsTab(
    BuildContext context,
    StudioDependencies deps,
    StudioSettings settings,
  ) {
    final palette = StudioPalette.of(context);
    bool customValid = true;
    try {
      StudioToolRegistry.parseCustomDeclarations(_customToolsController.text);
    } catch (_) {
      customValid = false;
    }

    return ListView(
      padding: const EdgeInsets.all(14),
      children: <Widget>[
        StoreBuilder<McpManagerState>(
          store: deps.mcpManager.store,
          builder: (BuildContext context, McpManagerState mcpState) {
            return StoreBuilder<SkillRegistryState>(
              store: deps.skillRegistry.store,
              builder: (BuildContext context, SkillRegistryState skillState) {
                return Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: palette.surfaceElevated,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: palette.borderSubtle),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      _SectionLabel(label: 'MCP (mcp_dart) & Agent Skills'),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: <Widget>[
                          StudioPillBadge(
                            label: '${mcpState.connectedCount} MCP connected',
                            foreground: mcpState.connectedCount > 0
                                ? palette.teal
                                : palette.textSecondary,
                            monospace: true,
                          ),
                          StudioPillBadge(
                            label: '${mcpState.activeTools.length} MCP tools',
                            foreground: palette.accent,
                            monospace: true,
                          ),
                          StudioPillBadge(
                            label:
                                '${skillState.activeSkills.length} skills active',
                            foreground: palette.amber,
                            monospace: true,
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          key: const Key('inspector_open_mcp_skills_button'),
                          onPressed: () => showMcpAndSkillsSheet(context),
                          icon: const Icon(Icons.extension_outlined, size: 15),
                          label: const Text(
                            'Configure MCP & Skills',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        ),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text(
            'Enable Function / Tool Calling',
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            'Execute local tools automatically during chat turns',
            style: TextStyle(fontSize: 11, color: palette.textMuted),
          ),
          value: settings.toolsEnabled,
          onChanged: (bool v) => deps.shellController.updateSettings(
            (StudioSettings s) => s.copyWith(toolsEnabled: v),
          ),
        ),
        SwitchListTile.adaptive(
          key: const Key('chat_enable_mcp_switch'),
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text(
            'Bridge Connected MCP Tools in Chat',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            'Coding always bridges MCP tools; enable here to expose MCP schemas in casual Chat',
            style: TextStyle(fontSize: 11, color: palette.textMuted),
          ),
          value: settings.enableMcpInChat,
          onChanged: settings.toolsEnabled
              ? (bool v) => deps.shellController.updateSettings(
                  (StudioSettings s) => s.copyWith(enableMcpInChat: v),
                )
              : null,
        ),
        const SizedBox(height: 8),
        _SectionLabel(label: 'Built-in Local Tools'),
        const SizedBox(height: 6),
        for (final spec in StudioToolRegistry.builtInTools)
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            controlAffinity: ListTileControlAffinity.leading,
            value: settings.enabledBuiltInTools.contains(spec.name),
            title: Text(
              spec.title,
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            subtitle: Text(
              '${spec.name}() · ${spec.description}',
              style: TextStyle(fontSize: 11, color: palette.textMuted),
            ),
            onChanged: !settings.toolsEnabled
                ? null
                : (bool? checked) {
                    final next = settings.enabledBuiltInTools.toSet();
                    if (checked ?? false) {
                      next.add(spec.name);
                    } else {
                      next.remove(spec.name);
                    }
                    deps.shellController.updateSettings(
                      (StudioSettings s) =>
                          s.copyWith(enabledBuiltInTools: next.toList()),
                    );
                  },
          ),
        const SizedBox(height: 12),
        Row(
          children: <Widget>[
            Expanded(
              child: _SectionLabel(label: 'Custom JSON Tool Declarations'),
            ),
            StudioPillBadge(
              label: customValid ? 'Valid Array' : 'Syntax Error',
              foreground: customValid ? palette.teal : palette.danger,
              monospace: true,
            ),
          ],
        ),
        const SizedBox(height: 6),
        TextField(
          controller: _customToolsController,
          maxLines: 6,
          style: const TextStyle(
            fontSize: 11.5,
            fontFamilyFallback: StudioTheme.monoFontFallback,
          ),
          decoration: const InputDecoration(
            hintText: '[{"name": "lookupOrder", "parameters": {...}}]',
          ),
          onChanged: (String value) {
            _updateState(() {});
            deps.shellController.updateSettings(
              (StudioSettings s) =>
                  s.copyWith(customToolDeclarationsJson: value),
            );
          },
        ),
      ],
    );
  }
}
