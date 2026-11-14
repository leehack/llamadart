part of 'session_inspector_panel.dart';

extension _InspectorHardwareTab on _SessionInspectorPanelState {
  Widget _buildHardwareTab(
    BuildContext context,
    StudioDependencies deps,
    StudioSettings settings,
    StudioRuntimeSnapshot runtime,
  ) {
    final palette = StudioPalette.of(context);
    final vramRatio = runtime.vramTotalBytes > 0
        ? ((runtime.vramTotalBytes - runtime.vramFreeBytes) /
                  runtime.vramTotalBytes)
              .clamp(0.0, 1.0)
        : null;
    final hasUnappliedChanges = runtime.hasUnappliedEngineChanges(
      settings,
      isWeb: deps.isWeb,
    );

    final activePreset = settings.activeHardwarePreset;
    final expertMode = settings.inspectorExpertMode;

    final list = ListView(
      key: const Key('inspector_hardware_list'),
      padding: const EdgeInsets.all(14),
      children: <Widget>[
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: palette.surfaceElevated,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: hasUnappliedChanges
                  ? palette.amber.withValues(alpha: 0.55)
                  : palette.borderSubtle,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  StatusPulseDot(
                    color: switch (runtime.phase) {
                      StudioEnginePhase.ready => palette.teal,
                      StudioEnginePhase.loading ||
                      StudioEnginePhase.unloading => palette.amber,
                      StudioEnginePhase.error => palette.danger,
                      StudioEnginePhase.unloaded => palette.textMuted,
                    },
                    pulsing: runtime.isLoading,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      runtime.activeModelLabel ?? 'No chat model loaded',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: palette.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: <Widget>[
                  StudioPillBadge(
                    label: 'Backend: ${runtime.backendName}',
                    monospace: true,
                  ),
                  if (runtime.resolvedContextSize != null)
                    StudioPillBadge(
                      label: 'ctx ${runtime.resolvedContextSize}',
                      monospace: true,
                    ),
                  if (runtime.resolvedGpuLayers != null)
                    StudioPillBadge(
                      label: 'ngl ${runtime.resolvedGpuLayers}',
                      monospace: true,
                    ),
                  if (hasUnappliedChanges)
                    StudioPillBadge(
                      label: 'Reload required',
                      icon: Icons.pending_actions_rounded,
                      foreground: palette.amber,
                    ),
                ],
              ),
              if (vramRatio != null) ...<Widget>[
                const SizedBox(height: 10),
                Text(
                  'Device Memory · ${_formatGiB(runtime.vramFreeBytes)} free of ${_formatGiB(runtime.vramTotalBytes)}',
                  style: TextStyle(fontSize: 11, color: palette.textSecondary),
                ),
                const SizedBox(height: 5),
                AnimatedScoreBar(fraction: vramRatio, color: palette.teal),
              ],
              if (runtime.activeDescriptor != null) ...<Widget>[
                const SizedBox(height: 10),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: hasUnappliedChanges
                          ? FilledButton.icon(
                              key: const Key('inspector_apply_reload_button'),
                              onPressed: runtime.isLoading
                                  ? null
                                  : () => deps.modelHubController
                                        .reloadActiveModel(),
                              icon: const Icon(Icons.refresh_rounded, size: 15),
                              label: const Text(
                                'Apply & Reload',
                                style: TextStyle(fontSize: 12),
                              ),
                            )
                          : OutlinedButton.icon(
                              key: const Key('inspector_apply_reload_button'),
                              onPressed: runtime.isLoading
                                  ? null
                                  : () => deps.modelHubController
                                        .reloadActiveModel(),
                              icon: const Icon(Icons.refresh_rounded, size: 15),
                              label: const Text(
                                'Apply & Reload',
                                style: TextStyle(fontSize: 12),
                              ),
                            ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: 'Unload model',
                      onPressed: runtime.isLoading
                          ? null
                          : () => deps.modelHubController.unloadActiveModel(),
                      icon: Icon(
                        Icons.eject_rounded,
                        size: 18,
                        color: palette.textSecondary,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        if (!expertMode) ...<Widget>[
          const SizedBox(height: 14),
          _SectionLabel(label: 'Performance Preset'),
          const SizedBox(height: 6),
          for (final preset in StudioHardwarePreset.values)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: InkWell(
                key: Key('inspector_preset_${preset.name}'),
                borderRadius: BorderRadius.circular(10),
                onTap: () => deps.shellController.updateSettings(
                  (StudioSettings s) => s.applyHardwarePreset(preset),
                ),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 11,
                    vertical: 9,
                  ),
                  decoration: BoxDecoration(
                    color: activePreset == preset
                        ? palette.accentMuted
                        : palette.surfaceElevated,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: activePreset == preset
                          ? palette.accent.withValues(alpha: 0.65)
                          : palette.borderSubtle,
                    ),
                  ),
                  child: Row(
                    children: <Widget>[
                      Icon(
                        switch (preset) {
                          StudioHardwarePreset.fast => Icons.bolt_rounded,
                          StudioHardwarePreset.balanced => Icons.tune_rounded,
                          StudioHardwarePreset.quality =>
                            Icons.auto_awesome_outlined,
                        },
                        size: 16,
                        color: activePreset == preset
                            ? palette.accent
                            : palette.textSecondary,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              preset.label,
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w700,
                                color: palette.textPrimary,
                              ),
                            ),
                            Text(
                              preset.subtitle,
                              style: TextStyle(
                                fontSize: 11,
                                color: palette.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (activePreset == preset)
                        Icon(
                          Icons.check_circle_rounded,
                          size: 16,
                          color: palette.accent,
                        ),
                    ],
                  ),
                ),
              ),
            ),
        ],
        const SizedBox(height: 8),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text(
            'Auto-Tune Layers & Context',
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            'Automatically fit GPU layers & context window to free VRAM',
            style: TextStyle(fontSize: 11, color: palette.textMuted),
          ),
          value: settings.autoTuneHardware,
          onChanged: (bool v) => deps.shellController.updateSettings(
            (StudioSettings s) => s.copyWith(autoTuneHardware: v),
          ),
        ),
        const SizedBox(height: 8),
        _SectionLabel(label: 'Compute Target'),
        const SizedBox(height: 6),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<ComputeDevice>(
            showSelectedIcon: false,
            style: SegmentedButton.styleFrom(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              padding: const EdgeInsets.symmetric(horizontal: 6),
            ),
            segments: const <ButtonSegment<ComputeDevice>>[
              ButtonSegment<ComputeDevice>(
                value: ComputeDevice.auto,
                label: Text('Auto', style: TextStyle(fontSize: 11)),
              ),
              ButtonSegment<ComputeDevice>(
                value: ComputeDevice.gpu,
                label: Text('GPU', style: TextStyle(fontSize: 11)),
              ),
              ButtonSegment<ComputeDevice>(
                value: ComputeDevice.npu,
                label: Text('NPU', style: TextStyle(fontSize: 11)),
              ),
              ButtonSegment<ComputeDevice>(
                value: ComputeDevice.cpu,
                label: Text('CPU', style: TextStyle(fontSize: 11)),
              ),
            ],
            selected: <ComputeDevice>{settings.computeDevice},
            onSelectionChanged: (Set<ComputeDevice> next) {
              deps.shellController.updateSettings(
                (StudioSettings s) => s.copyWith(computeDevice: next.first),
              );
            },
          ),
        ),
        const SizedBox(height: 14),
        _SectionLabel(label: 'Context Window (n_ctx)'),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: <int>[2048, 4096, 8192, 16384, 32768].map((int ctx) {
            final selected = settings.contextSize == ctx;
            return ChoiceChip(
              label: Text(
                ctx >= 1024 ? '${ctx ~/ 1024}K' : '$ctx',
                style: const TextStyle(fontSize: 11.5),
              ),
              selected: selected,
              onSelected: (_) => deps.shellController.updateSettings(
                (StudioSettings s) => s.copyWith(
                  contextSize: ctx,
                  requestedContextSize: ctx,
                  autoTuneHardware: false,
                ),
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 14),
        _SliderControl(
          label: 'GPU Layers (ngl)',
          valueLabel: settings.gpuLayers >= 99
              ? 'All (99)'
              : '${settings.gpuLayers}',
          value: settings.gpuLayers.clamp(0, 99).toDouble(),
          min: 0,
          max: 99,
          divisions: 99,
          onChanged: (double v) => deps.shellController.updateSettings(
            (StudioSettings s) =>
                s.copyWith(gpuLayers: v.round(), autoTuneHardware: false),
          ),
        ),
        if (!expertMode) ...<Widget>[
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text(
              'Auto-Load Last Model on Startup',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              'Protected by Safe-Boot OOM sentinel',
              style: TextStyle(fontSize: 11, color: palette.textMuted),
            ),
            value: settings.autoLoadLastModel,
            onChanged: (bool v) => deps.shellController.updateSettings(
              (StudioSettings s) => s.copyWith(autoLoadLastModel: v),
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => deps.shellController.updateSettings(
              (StudioSettings s) => s.copyWith(inspectorExpertMode: true),
            ),
            icon: const Icon(Icons.tune_rounded, size: 15),
            label: const Text(
              'Open Expert Engine Tuning',
              style: TextStyle(fontSize: 12),
            ),
          ),
        ] else ...<Widget>[
          const SizedBox(height: 10),
          _SectionLabel(label: 'KV Cache Quantization (K / V)'),
          const SizedBox(height: 6),
          Row(
            children: <Widget>[
              Expanded(
                child: DropdownButtonFormField<KvCacheType>(
                  initialValue: settings.cacheTypeK,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Cache K',
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 10,
                    ),
                  ),
                  items: KvCacheType.values
                      .map(
                        (KvCacheType t) => DropdownMenuItem<KvCacheType>(
                          value: t,
                          child: Text(
                            t.name.toUpperCase(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (KvCacheType? v) {
                    if (v != null) {
                      deps.shellController.updateSettings(
                        (StudioSettings s) => s.copyWith(cacheTypeK: v),
                      );
                    }
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: DropdownButtonFormField<KvCacheType>(
                  initialValue: settings.cacheTypeV,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Cache V',
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 10,
                    ),
                  ),
                  items: KvCacheType.values
                      .map(
                        (KvCacheType t) => DropdownMenuItem<KvCacheType>(
                          value: t,
                          child: Text(
                            t.name.toUpperCase(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (KvCacheType? v) {
                    if (v != null) {
                      deps.shellController.updateSettings(
                        (StudioSettings s) => s.copyWith(cacheTypeV: v),
                      );
                    }
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<FlashAttention>(
            initialValue: settings.flashAttention,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'FlashAttention'),
            items: FlashAttention.values
                .map(
                  (FlashAttention mode) => DropdownMenuItem<FlashAttention>(
                    value: mode,
                    child: Text(
                      mode.name.toUpperCase(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                )
                .toList(),
            onChanged: (FlashAttention? mode) {
              if (mode != null) {
                deps.shellController.updateSettings(
                  (StudioSettings s) => s.copyWith(flashAttention: mode),
                );
              }
            },
          ),
          const SizedBox(height: 12),
          _SectionLabel(label: 'Logical Batch Size (n_batch)'),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <int>[0, 512, 1024, 2048, 4096].map((int batch) {
              final selected = settings.batchSize == batch;
              return ChoiceChip(
                key: Key('inspector_batch_size_$batch'),
                label: Text(
                  batch == 0 ? 'Auto' : '$batch',
                  style: const TextStyle(fontSize: 11.5),
                ),
                selected: selected,
                onSelected: (_) => deps.shellController.updateSettings(
                  (StudioSettings s) => s.copyWith(batchSize: batch),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 12),
          _SectionLabel(label: 'Micro-Batch Size (n_ubatch)'),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <int>[0, 128, 256, 512, 1024].map((int ubatch) {
              final selected = settings.microBatchSize == ubatch;
              return ChoiceChip(
                key: Key('inspector_micro_batch_size_$ubatch'),
                label: Text(
                  ubatch == 0 ? 'Auto' : '$ubatch',
                  style: const TextStyle(fontSize: 11.5),
                ),
                selected: selected,
                onSelected: (_) => deps.shellController.updateSettings(
                  (StudioSettings s) => s.copyWith(microBatchSize: ubatch),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 12),
          _SliderControl(
            label: 'Decode Threads (n_threads)',
            valueLabel: settings.numberOfThreads <= 0
                ? 'Auto'
                : '${settings.numberOfThreads}',
            value: settings.numberOfThreads.clamp(0, 32).toDouble(),
            min: 0,
            max: 32,
            divisions: 32,
            onChanged: (double v) => deps.shellController.updateSettings(
              (StudioSettings s) => s.copyWith(numberOfThreads: v.round()),
            ),
          ),
          _SliderControl(
            label: 'Prompt/Batch Threads (n_threads_batch)',
            valueLabel: settings.numberOfThreadsBatch <= 0
                ? 'Auto'
                : '${settings.numberOfThreadsBatch}',
            value: settings.numberOfThreadsBatch.clamp(0, 32).toDouble(),
            min: 0,
            max: 32,
            divisions: 32,
            onChanged: (double v) => deps.shellController.updateSettings(
              (StudioSettings s) => s.copyWith(numberOfThreadsBatch: v.round()),
            ),
          ),
          const SizedBox(height: 4),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text(
              'Memory-Map Weights (use_mmap)',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              'Zero-copy weight paging from disk (recommended)',
              style: TextStyle(fontSize: 11, color: palette.textMuted),
            ),
            value: settings.useMmap,
            onChanged: (bool v) => deps.shellController.updateSettings(
              (StudioSettings s) => s.copyWith(useMmap: v),
            ),
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text(
              'Lock Weights in RAM (use_mlock)',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              'Prevent OS swap on host RAM-heavy setups',
              style: TextStyle(fontSize: 11, color: palette.textMuted),
            ),
            value: settings.useMlock,
            onChanged: (bool v) => deps.shellController.updateSettings(
              (StudioSettings s) => s.copyWith(useMlock: v),
            ),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<StudioSpeculativeMode>(
            initialValue: settings.speculativeMode,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Speculative Decoding',
            ),
            items: StudioSpeculativeMode.values
                .map(
                  (StudioSpeculativeMode m) =>
                      DropdownMenuItem<StudioSpeculativeMode>(
                        value: m,
                        child: Text(
                          m.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                )
                .toList(),
            onChanged: (StudioSpeculativeMode? mode) {
              if (mode != null) {
                deps.shellController.updateSettings(
                  (StudioSettings s) => s.copyWith(speculativeMode: mode),
                );
              }
            },
          ),
          const SizedBox(height: 6),
          Text(
            'Applies on compatible text-only turns. MTP requires model support and Apply & Reload.',
            style: TextStyle(fontSize: 11, color: palette.textMuted),
          ),
          const SizedBox(height: 8),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text(
              'Auto-Load Last Model on Startup',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              'Protected by Safe-Boot OOM sentinel',
              style: TextStyle(fontSize: 11, color: palette.textMuted),
            ),
            value: settings.autoLoadLastModel,
            onChanged: (bool v) => deps.shellController.updateSettings(
              (StudioSettings s) => s.copyWith(autoLoadLastModel: v),
            ),
          ),
          const SizedBox(height: 4),
          _buildAdvancedEngineSection(context, deps, palette, settings),
        ],
      ],
    );

    return Column(
      children: <Widget>[
        if (hasUnappliedChanges)
          Container(
            key: const Key('unapplied_engine_changes_badge'),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: palette.amber.withValues(alpha: 0.14),
              border: Border(
                bottom: BorderSide(
                  color: palette.amber.withValues(alpha: 0.38),
                ),
              ),
            ),
            child: Row(
              children: <Widget>[
                Icon(
                  Icons.pending_actions_rounded,
                  size: 15,
                  color: palette.amber,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Reload required to apply engine changes',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: palette.amber,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: runtime.isLoading
                      ? null
                      : () => deps.modelHubController.reloadActiveModel(),
                  child: const Text(
                    'Reload',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        Container(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: palette.borderSubtle)),
          ),
          child: Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: palette.canvas,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: palette.borderSubtle),
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: InkWell(
                    key: const Key('inspector_mode_simple'),
                    borderRadius: BorderRadius.circular(7),
                    onTap: () => deps.shellController.updateSettings(
                      (StudioSettings s) =>
                          s.copyWith(inspectorExpertMode: false),
                    ),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      decoration: BoxDecoration(
                        color: !expertMode
                            ? palette.accentMuted
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(7),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        'Simple',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: !expertMode
                              ? FontWeight.w700
                              : FontWeight.w500,
                          color: !expertMode
                              ? palette.accent
                              : palette.textSecondary,
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: InkWell(
                    key: const Key('inspector_mode_expert'),
                    borderRadius: BorderRadius.circular(7),
                    onTap: () => deps.shellController.updateSettings(
                      (StudioSettings s) =>
                          s.copyWith(inspectorExpertMode: true),
                    ),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      decoration: BoxDecoration(
                        color: expertMode
                            ? palette.accentMuted
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(7),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        'Expert',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: expertMode
                              ? FontWeight.w700
                              : FontWeight.w500,
                          color: expertMode
                              ? palette.accent
                              : palette.textSecondary,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Expanded(child: list),
      ],
    );
  }
}
