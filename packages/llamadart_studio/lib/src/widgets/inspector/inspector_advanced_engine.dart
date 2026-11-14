part of 'session_inspector_panel.dart';

extension _InspectorAdvancedEngineExtension on _SessionInspectorPanelState {
  Widget _buildAdvancedEngineSection(
    BuildContext context,
    StudioDependencies deps,
    StudioPalette palette,
    StudioSettings settings,
  ) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        key: const Key('inspector_advanced_engine_tile'),
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(top: 6, bottom: 8),
        title: Text(
          'Advanced Engine Parameters',
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            color: palette.textPrimary,
          ),
        ),
        subtitle: Text(
          'Parallel sequences, KV unified, RoPE scaling, MoE CPU offload',
          style: TextStyle(fontSize: 11, color: palette.textMuted),
        ),
        children: <Widget>[
          _SliderControl(
            label: 'Max Parallel Sequences (n_seq_max)',
            valueLabel: '${settings.maxParallelSequences}',
            value: settings.maxParallelSequences.clamp(1, 16).toDouble(),
            min: 1,
            max: 16,
            divisions: 15,
            onChanged: (double v) => deps.shellController.updateSettings(
              (StudioSettings s) => s.copyWith(maxParallelSequences: v.round()),
            ),
          ),
          const SizedBox(height: 6),
          _SectionLabel(label: 'Unified KV Buffer (kv_unified)'),
          const SizedBox(height: 6),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<String>(
              showSelectedIcon: false,
              style: SegmentedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                padding: const EdgeInsets.symmetric(horizontal: 6),
              ),
              segments: const <ButtonSegment<String>>[
                ButtonSegment<String>(
                  value: 'auto',
                  label: Text('Auto', style: TextStyle(fontSize: 11)),
                ),
                ButtonSegment<String>(
                  value: 'on',
                  label: Text('On', style: TextStyle(fontSize: 11)),
                ),
                ButtonSegment<String>(
                  value: 'off',
                  label: Text('Off', style: TextStyle(fontSize: 11)),
                ),
              ],
              selected: <String>{
                settings.kvUnified == null
                    ? 'auto'
                    : (settings.kvUnified! ? 'on' : 'off'),
              },
              onSelectionChanged: (Set<String> next) {
                final pick = next.first;
                deps.shellController.updateSettings((StudioSettings s) {
                  if (pick == 'auto') {
                    return s.copyWith(clearKvUnified: true);
                  }
                  return s.copyWith(kvUnified: pick == 'on');
                });
              },
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  key: const Key('inspector_rope_freq_base'),
                  controller: _ropeBaseController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  style: const TextStyle(
                    fontSize: 12,
                    fontFamilyFallback: StudioTheme.monoFontFallback,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'RoPE Freq Base',
                    hintText: 'Metadata',
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 10,
                    ),
                  ),
                  onChanged: (String value) {
                    final trimmed = value.trim();
                    if (trimmed.isEmpty) {
                      deps.shellController.updateSettings(
                        (StudioSettings s) =>
                            s.copyWith(clearRopeFrequencyBase: true),
                      );
                      return;
                    }
                    final parsed = double.tryParse(trimmed);
                    if (parsed != null && parsed > 0) {
                      deps.shellController.updateSettings(
                        (StudioSettings s) =>
                            s.copyWith(ropeFrequencyBase: parsed),
                      );
                    }
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  key: const Key('inspector_rope_freq_scale'),
                  controller: _ropeScaleController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  style: const TextStyle(
                    fontSize: 12,
                    fontFamilyFallback: StudioTheme.monoFontFallback,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'RoPE Freq Scale',
                    hintText: 'Metadata',
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 10,
                    ),
                  ),
                  onChanged: (String value) {
                    final trimmed = value.trim();
                    if (trimmed.isEmpty) {
                      deps.shellController.updateSettings(
                        (StudioSettings s) =>
                            s.copyWith(clearRopeFrequencyScale: true),
                      );
                      return;
                    }
                    final parsed = double.tryParse(trimmed);
                    if (parsed != null && parsed > 0) {
                      deps.shellController.updateSettings(
                        (StudioSettings s) =>
                            s.copyWith(ropeFrequencyScale: parsed),
                      );
                    }
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _SliderControl(
            label: 'CPU MoE Offload Layers',
            valueLabel: settings.cpuMoeLayers < 0
                ? 'All (-1)'
                : (settings.cpuMoeLayers == 0
                      ? 'GPU (0)'
                      : '${settings.cpuMoeLayers}'),
            value: settings.cpuMoeLayers.clamp(-1, 64).toDouble(),
            min: -1,
            max: 64,
            divisions: 65,
            onChanged: (double v) {
              final nextLayers = v.round();
              deps.shellController.updateSettings(
                (StudioSettings s) => s.copyWith(
                  cpuMoeLayers: nextLayers,
                  moeCacheBytes: nextLayers == 0 ? 0 : s.moeCacheBytes,
                ),
              );
            },
          ),
          const SizedBox(height: 6),
          const _SectionLabel(label: 'MoE Host Cache Budget'),
          const SizedBox(height: 4),
          Text(
            settings.cpuMoeLayers == 0
                ? 'Enable CPU MoE Offload Layers above to bound MoE host cache.'
                : 'Caps host RAM used by cached CPU-offloaded MoE experts.',
            style: TextStyle(fontSize: 11, color: palette.textMuted),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children:
                <int>[
                  0,
                  512 * 1024 * 1024,
                  1024 * 1024 * 1024,
                  2 * 1024 * 1024 * 1024,
                  4 * 1024 * 1024 * 1024,
                ].map((int bytes) {
                  final selected = settings.moeCacheBytes == bytes;
                  final label = bytes == 0
                      ? 'Unlimited'
                      : (bytes < 1024 * 1024 * 1024
                            ? '${bytes ~/ (1024 * 1024)} MB'
                            : '${bytes ~/ (1024 * 1024 * 1024)} GB');
                  return ChoiceChip(
                    label: Text(label, style: const TextStyle(fontSize: 11.5)),
                    selected: selected,
                    onSelected: settings.cpuMoeLayers == 0
                        ? null
                        : (_) => deps.shellController.updateSettings(
                            (StudioSettings s) =>
                                s.copyWith(moeCacheBytes: bytes),
                          ),
                  );
                }).toList(),
          ),
        ],
      ),
    );
  }
}
