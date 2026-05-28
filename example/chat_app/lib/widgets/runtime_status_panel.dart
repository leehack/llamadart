import 'package:flutter/material.dart';
import 'package:llamadart/llamadart.dart';
import 'package:provider/provider.dart';

import '../providers/chat_provider.dart';

class RuntimeStatusPanel extends StatelessWidget {
  const RuntimeStatusPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return Selector<
      ChatProvider,
      (
        bool,
        String,
        String,
        int,
        int,
        double?,
        double?,
        int?,
        int?,
        int?,
        int?,
        int?,
        int?,
        int?,
        int?,
        int?,
        int?,
        int?,
        bool,
        bool,
        String?,
        String?,
        String?,
        String?,
        String?,
        String?,
      )
    >(
      selector: (_, provider) => (
        provider.isReady,
        provider.activeBackend,
        provider.activeModelName,
        provider.currentTokens,
        provider.contextLimit,
        provider.lastTokensPerSecond,
        provider.lastDecodeTokensPerSecond,
        provider.lastFirstTokenLatencyMs,
        provider.lastGenerationLatencyMs,
        provider.lastNativePromptEvalMs,
        provider.lastNativeEvalMs,
        provider.lastNativeSampleMs,
        provider.lastNativePromptEvalTokens,
        provider.lastNativeEvalTokens,
        provider.lastNativeReusedGraphs,
        provider.runtimeGpuLayers,
        provider.runtimeThreads,
        provider.runtimeThreadPoolSize,
        provider.hasConfiguredMmproj,
        provider.isMmprojLoaded,
        provider.runtimeExecution,
        provider.runtimeCoreVariant,
        provider.runtimeWorkerFallbackReason,
        provider.runtimeModelSource,
        provider.runtimeModelCacheState,
        provider.runtimeNotes,
      ),
      builder: (context, data, _) {
        final (
          isReady,
          activeBackend,
          activeModelName,
          currentTokens,
          contextLimit,
          tokensPerSecond,
          decodeTokensPerSecond,
          firstTokenLatencyMs,
          generationLatencyMs,
          nativePromptEvalMs,
          nativeEvalMs,
          nativeSampleMs,
          nativePromptEvalTokens,
          nativeEvalTokens,
          nativeReusedGraphs,
          runtimeGpuLayers,
          runtimeThreads,
          runtimeThreadPoolSize,
          hasConfiguredMmproj,
          isMmprojLoaded,
          runtimeExecution,
          runtimeCoreVariant,
          runtimeWorkerFallbackReason,
          runtimeModelSource,
          runtimeModelCacheState,
          runtimeNotes,
        ) = data;

        if (!isReady) {
          return const SizedBox.shrink();
        }
        final isLiteRtLmModel = activeModelName.toLowerCase().endsWith(
          '.litertlm',
        );

        return Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _chip(context, icon: Icons.memory_rounded, text: activeBackend),
              _chip(
                context,
                icon: Icons.model_training_outlined,
                text: activeModelName,
              ),
              _chip(
                context,
                icon: Icons.data_usage_rounded,
                text: '$currentTokens/$contextLimit tok',
              ),
              if (tokensPerSecond != null)
                _chip(
                  context,
                  icon: Icons.speed_rounded,
                  text: 'avg ${tokensPerSecond.toStringAsFixed(1)} tok/s',
                ),
              if (decodeTokensPerSecond != null)
                _chip(
                  context,
                  icon: Icons.rocket_launch_rounded,
                  text:
                      'decode ${decodeTokensPerSecond.toStringAsFixed(1)} tok/s',
                ),
              if (firstTokenLatencyMs != null)
                _chip(
                  context,
                  icon: Icons.bolt_rounded,
                  text: 'first ${firstTokenLatencyMs}ms',
                ),
              if (generationLatencyMs != null)
                _chip(
                  context,
                  icon: Icons.timer_outlined,
                  text: 'total ${generationLatencyMs}ms',
                ),
              if (nativePromptEvalMs != null)
                _chip(
                  context,
                  icon: Icons.input_rounded,
                  text: nativePromptEvalTokens != null
                      ? 'p_eval ${nativePromptEvalMs}ms/$nativePromptEvalTokens tok'
                      : 'p_eval ${nativePromptEvalMs}ms',
                ),
              if (nativeEvalMs != null)
                _chip(
                  context,
                  icon: Icons.auto_awesome_rounded,
                  text: nativeEvalTokens != null
                      ? 'eval ${nativeEvalMs}ms/$nativeEvalTokens tok'
                      : 'eval ${nativeEvalMs}ms',
                ),
              if (nativeSampleMs != null)
                _chip(
                  context,
                  icon: Icons.tune_rounded,
                  text: 'sample ${nativeSampleMs}ms',
                ),
              if (nativeReusedGraphs != null)
                _chip(
                  context,
                  icon: Icons.repeat_rounded,
                  text: 'reuse $nativeReusedGraphs',
                ),
              if (runtimeGpuLayers != null)
                _chip(
                  context,
                  icon: Icons.layers_rounded,
                  text:
                      isLiteRtLmModel &&
                          runtimeGpuLayers >= ModelParams.maxGpuLayers
                      ? 'gpu max'
                      : 'layers $runtimeGpuLayers',
                ),
              if (runtimeThreads != null)
                _chip(
                  context,
                  icon: Icons.alt_route_rounded,
                  text: 'threads $runtimeThreads',
                ),
              if (runtimeThreadPoolSize != null)
                _chip(
                  context,
                  icon: Icons.hub_outlined,
                  text: 'pool $runtimeThreadPoolSize',
                ),
              if (isMmprojLoaded)
                _chip(
                  context,
                  icon: Icons.visibility_rounded,
                  text: 'mmproj loaded',
                )
              else if (hasConfiguredMmproj)
                _chip(
                  context,
                  icon: Icons.visibility_outlined,
                  text: 'mmproj cfg',
                ),
              if (runtimeExecution != null)
                _chip(
                  context,
                  icon: Icons.settings_ethernet_rounded,
                  text: 'exec ${_shortText(runtimeExecution)}',
                ),
              if (runtimeCoreVariant != null)
                _chip(
                  context,
                  icon: Icons.developer_board_rounded,
                  text: 'core ${_shortText(runtimeCoreVariant)}',
                ),
              if (runtimeModelSource != null)
                _chip(
                  context,
                  icon: Icons.cloud_queue_rounded,
                  text: 'src ${_shortText(runtimeModelSource)}',
                ),
              if (runtimeModelCacheState != null)
                _chip(
                  context,
                  icon: Icons.inventory_2_outlined,
                  text: 'cache ${_shortText(runtimeModelCacheState)}',
                ),
              if (runtimeWorkerFallbackReason != null)
                _chip(
                  context,
                  icon: Icons.warning_amber_rounded,
                  text: 'worker ${_shortText(runtimeWorkerFallbackReason)}',
                ),
              if (runtimeNotes != null)
                _chip(
                  context,
                  icon: Icons.info_outline_rounded,
                  text: 'notes ${_shortText(runtimeNotes)}',
                ),
            ],
          ),
        );
      },
    );
  }

  String _shortText(String text, {int maxLength = 42}) {
    final normalized = text
        .replaceAll(';', ', ')
        .replaceAll('_', ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (normalized.length <= maxLength) {
      return normalized;
    }

    return '${normalized.substring(0, maxLength - 3)}...';
  }

  Widget _chip(
    BuildContext context, {
    required IconData icon,
    required String text,
  }) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: 0.45),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: colorScheme.onSurfaceVariant),
          const SizedBox(width: 5),
          Text(
            text,
            style: TextStyle(
              fontSize: 11,
              height: 1,
              fontWeight: FontWeight.w600,
              color: colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}
