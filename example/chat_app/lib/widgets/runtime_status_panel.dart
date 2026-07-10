import 'package:flutter/material.dart';
import 'package:llamadart/llamadart.dart';
import 'package:provider/provider.dart';

import '../providers/chat_provider.dart';

typedef _RuntimeStatus = ({
  bool isReady,
  String activeBackend,
  String activeModelName,
  int currentTokens,
  int contextLimit,
  double? tokensPerSecond,
  double? decodeTokensPerSecond,
  int? firstTokenLatencyMs,
  int? generationLatencyMs,
  int? nativePromptEvalMs,
  int? nativeEvalMs,
  int? nativeSampleMs,
  int? nativePromptEvalTokens,
  int? nativeEvalTokens,
  int? nativeReusedGraphs,
  int? runtimeGpuLayers,
  int? runtimeThreads,
  int? runtimeThreadPoolSize,
  bool hasConfiguredMmproj,
  bool isMmprojLoaded,
  String? runtimeExecution,
  String? runtimeCoreVariant,
  String? runtimeWorkerFallbackReason,
  String? runtimeModelSource,
  String? runtimeModelCacheState,
  String? runtimeNotes,
});

class RuntimeStatusPanel extends StatelessWidget {
  const RuntimeStatusPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return Selector<ChatProvider, _RuntimeStatus>(
      selector: (_, provider) => (
        isReady: provider.isReady,
        activeBackend: provider.activeBackend,
        activeModelName: provider.activeModelName,
        currentTokens: provider.currentTokens,
        contextLimit: provider.contextLimit,
        tokensPerSecond: provider.lastTokensPerSecond,
        decodeTokensPerSecond: provider.lastDecodeTokensPerSecond,
        firstTokenLatencyMs: provider.lastFirstTokenLatencyMs,
        generationLatencyMs: provider.lastGenerationLatencyMs,
        nativePromptEvalMs: provider.lastNativePromptEvalMs,
        nativeEvalMs: provider.lastNativeEvalMs,
        nativeSampleMs: provider.lastNativeSampleMs,
        nativePromptEvalTokens: provider.lastNativePromptEvalTokens,
        nativeEvalTokens: provider.lastNativeEvalTokens,
        nativeReusedGraphs: provider.lastNativeReusedGraphs,
        runtimeGpuLayers: provider.runtimeGpuLayers,
        runtimeThreads: provider.runtimeThreads,
        runtimeThreadPoolSize: provider.runtimeThreadPoolSize,
        hasConfiguredMmproj: provider.hasConfiguredMmproj,
        isMmprojLoaded: provider.isMmprojLoaded,
        runtimeExecution: provider.runtimeExecution,
        runtimeCoreVariant: provider.runtimeCoreVariant,
        runtimeWorkerFallbackReason: provider.runtimeWorkerFallbackReason,
        runtimeModelSource: provider.runtimeModelSource,
        runtimeModelCacheState: provider.runtimeModelCacheState,
        runtimeNotes: provider.runtimeNotes,
      ),
      builder: (context, status, _) {
        if (!status.isReady) {
          return const SizedBox.shrink();
        }

        return Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
          child: _RuntimeSummaryBar(
            status: status,
            onPressed: () =>
                _showRuntimeDetails(context, _buildMetrics(status)),
          ),
        );
      },
    );
  }

  List<_RuntimeMetric> _buildMetrics(_RuntimeStatus status) {
    final metrics = <_RuntimeMetric>[
      _RuntimeMetric(
        icon: Icons.memory_rounded,
        label: 'Backend',
        value: status.activeBackend,
      ),
      _RuntimeMetric(
        icon: Icons.model_training_outlined,
        label: 'Model',
        value: status.activeModelName,
      ),
      _RuntimeMetric(
        icon: Icons.data_usage_rounded,
        label: 'Context',
        value: '${status.currentTokens}/${status.contextLimit} tokens',
      ),
    ];

    void add(
      IconData icon,
      String label,
      Object? value, {
      String Function(Object value)? format,
    }) {
      if (value == null) return;
      metrics.add(
        _RuntimeMetric(
          icon: icon,
          label: label,
          value: format?.call(value) ?? value.toString(),
        ),
      );
    }

    add(
      Icons.speed_rounded,
      'Average speed',
      status.tokensPerSecond,
      format: (value) => '${(value as double).toStringAsFixed(1)} tok/s',
    );
    add(
      Icons.rocket_launch_rounded,
      'Decode speed',
      status.decodeTokensPerSecond,
      format: (value) => '${(value as double).toStringAsFixed(1)} tok/s',
    );
    add(
      Icons.bolt_rounded,
      'First token',
      status.firstTokenLatencyMs,
      format: (value) => '$value ms',
    );
    add(
      Icons.timer_outlined,
      'Generation',
      status.generationLatencyMs,
      format: (value) => '$value ms',
    );
    add(
      Icons.input_rounded,
      'Prompt evaluation',
      status.nativePromptEvalMs,
      format: (value) => status.nativePromptEvalTokens == null
          ? '$value ms'
          : '$value ms · ${status.nativePromptEvalTokens} tokens',
    );
    add(
      Icons.auto_awesome_rounded,
      'Native evaluation',
      status.nativeEvalMs,
      format: (value) => status.nativeEvalTokens == null
          ? '$value ms'
          : '$value ms · ${status.nativeEvalTokens} tokens',
    );
    add(
      Icons.tune_rounded,
      'Sampling',
      status.nativeSampleMs,
      format: (value) => '$value ms',
    );
    add(Icons.repeat_rounded, 'Reused graphs', status.nativeReusedGraphs);

    final isLiteRtLmModel = status.activeModelName.toLowerCase().endsWith(
      '.litertlm',
    );
    add(
      Icons.layers_rounded,
      'GPU layers',
      status.runtimeGpuLayers,
      format: (value) =>
          isLiteRtLmModel && (value as int) >= ModelParams.maxGpuLayers
          ? 'Maximum'
          : value.toString(),
    );
    add(Icons.alt_route_rounded, 'Runtime threads', status.runtimeThreads);
    add(Icons.hub_outlined, 'Thread pool', status.runtimeThreadPoolSize);

    if (status.isMmprojLoaded) {
      metrics.add(
        const _RuntimeMetric(
          icon: Icons.visibility_rounded,
          label: 'Multimodal projector',
          value: 'Loaded',
        ),
      );
    } else if (status.hasConfiguredMmproj) {
      metrics.add(
        const _RuntimeMetric(
          icon: Icons.visibility_outlined,
          label: 'Multimodal projector',
          value: 'Configured',
        ),
      );
    }

    add(
      Icons.settings_ethernet_rounded,
      'Execution',
      status.runtimeExecution,
      format: (value) => _normalizedText(value as String),
    );
    add(
      Icons.developer_board_rounded,
      'Core',
      status.runtimeCoreVariant,
      format: (value) => _normalizedText(value as String),
    );
    add(
      Icons.cloud_queue_rounded,
      'Model source',
      status.runtimeModelSource,
      format: (value) => _normalizedText(value as String),
    );
    add(
      Icons.inventory_2_outlined,
      'Model cache',
      status.runtimeModelCacheState,
      format: (value) => _normalizedText(value as String),
    );
    add(
      Icons.warning_amber_rounded,
      'Worker fallback',
      status.runtimeWorkerFallbackReason,
      format: (value) => _normalizedText(value as String),
    );
    add(
      Icons.info_outline_rounded,
      'Runtime notes',
      status.runtimeNotes,
      format: (value) => _normalizedText(value as String),
    );

    return metrics;
  }

  String _normalizedText(String text) {
    return text
        .replaceAll(';', ', ')
        .replaceAll('_', ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  Future<void> _showRuntimeDetails(
    BuildContext context,
    List<_RuntimeMetric> metrics,
  ) {
    final colorScheme = Theme.of(context).colorScheme;

    return showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: colorScheme.surface,
      builder: (context) => FractionallySizedBox(
        heightFactor: 0.72,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 4, 16, 16),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Runtime details',
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    tooltip: 'Close runtime details',
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                itemCount: metrics.length,
                separatorBuilder: (_, _) => Divider(
                  height: 1,
                  color: colorScheme.outlineVariant.withValues(alpha: 0.4),
                ),
                itemBuilder: (context, index) {
                  final metric = metrics[index];
                  return ListTile(
                    leading: Icon(
                      metric.icon,
                      size: 19,
                      color: colorScheme.primary,
                    ),
                    title: Text(metric.label),
                    subtitle: Text(metric.value),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RuntimeSummaryBar extends StatelessWidget {
  final _RuntimeStatus status;
  final VoidCallback onPressed;

  const _RuntimeSummaryBar({required this.status, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Semantics(
      button: true,
      onTap: onPressed,
      label: 'Open runtime details',
      value:
          '${status.activeBackend}, ${status.activeModelName}, '
          '${status.currentTokens} of ${status.contextLimit} tokens',
      child: ExcludeSemantics(
        child: Material(
          color: colorScheme.surfaceContainerLow,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(
              color: colorScheme.outlineVariant.withValues(alpha: 0.38),
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 9, 8, 9),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final showPerformance = constraints.maxWidth >= 620;
                  return Row(
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: colorScheme.primary,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: colorScheme.primary.withValues(alpha: 0.4),
                              blurRadius: 7,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Text(
                          '${status.activeBackend}  ·  ${status.activeModelName}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ),
                      if (showPerformance &&
                          status.tokensPerSecond != null) ...[
                        const SizedBox(width: 12),
                        Text(
                          '${status.tokensPerSecond!.toStringAsFixed(1)} tok/s',
                          style: Theme.of(context).textTheme.labelMedium
                              ?.copyWith(color: colorScheme.onSurfaceVariant),
                        ),
                      ],
                      const SizedBox(width: 12),
                      Text(
                        '${status.currentTokens}/${status.contextLimit}',
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                      ),
                      const SizedBox(width: 2),
                      Icon(
                        Icons.chevron_right_rounded,
                        size: 20,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RuntimeMetric {
  final IconData icon;
  final String label;
  final String value;

  const _RuntimeMetric({
    required this.icon,
    required this.label,
    required this.value,
  });
}
