import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../models/downloadable_model.dart';
import '../services/model_service_base.dart';

enum _ModelCardMenuAction { removeFromLibrary, deleteCachedAssets }

class ModelCard extends StatelessWidget {
  final DownloadableModel model;
  final bool isDownloaded;
  final ModelProfileCacheState? cacheState;
  final bool isDownloading;
  final bool isQueued;
  final int? queuePosition;
  final double progress;
  final String? downloadStatusLabel;
  final String? downloadTransferLabel;
  final bool isWeb;
  final bool isAvailableOnCurrentPlatform;
  final bool isSelected;
  final int gpuLayers;
  final int contextSize;
  final ValueChanged<int> onGpuLayersChanged;
  final ValueChanged<int> onContextSizeChanged;
  final VoidCallback? onSelect;
  final VoidCallback onDownload;
  final VoidCallback onDelete;
  final bool isCustom;
  final VoidCallback? onRemoveFromLibrary;
  final VoidCallback? onCancel;
  final bool includeProjector;
  final ValueChanged<bool>? onIncludeProjectorChanged;

  const ModelCard({
    super.key,
    required this.model,
    required this.isDownloaded,
    this.cacheState,
    required this.isDownloading,
    this.isQueued = false,
    this.queuePosition,
    required this.progress,
    this.downloadStatusLabel,
    this.downloadTransferLabel,
    required this.isWeb,
    this.isAvailableOnCurrentPlatform = true,
    required this.isSelected,
    required this.gpuLayers,
    required this.contextSize,
    required this.onGpuLayersChanged,
    required this.onContextSizeChanged,
    required this.onSelect,
    required this.onDownload,
    required this.onDelete,
    this.isCustom = false,
    this.onRemoveFromLibrary,
    this.onCancel,
    this.includeProjector = true,
    this.onIncludeProjectorChanged,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    const webLargeModelWarningThresholdBytes = 1900 * 1024 * 1024;
    final isWebLiteRtLmModel = isWeb && _isLiteRtLmModel(model);
    final isModelCached =
        isDownloaded || (cacheState?.model.isAvailable ?? false);
    final projectorSource = model.multimodalProjectorSourceFor(web: isWeb);
    final hasProjector = projectorSource != null;
    final isProjectorCached =
        cacheState?.multimodalProjector?.isAvailable ?? false;
    final isProjectorMissing = hasProjector && !isProjectorCached;
    final requiresProjector =
        model.supportsSpeechToTextFor(web: isWeb) ||
        model.supportsTextToSpeechFor(web: isWeb);
    final canLoadModel =
        (isModelCached && (!requiresProjector || !isProjectorMissing)) ||
        isWebLiteRtLmModel;
    final effectiveModelSizeBytes = model.sizeBytesFor(web: isWeb);
    final showWebLargeModelWarning =
        isWeb && effectiveModelSizeBytes >= webLargeModelWarningThresholdBytes;
    final partialCacheMessage = _partialCacheMessage(cacheState, isWeb: isWeb);
    final hasPartialCache = partialCacheMessage != null;
    final hasAnyCachedAsset =
        isDownloaded || (cacheState?.availableAssetLabels.isNotEmpty ?? false);
    final showMobileDownloadGuidance =
        isDownloading &&
        !isWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    final shouldShowProjectorOption =
        isAvailableOnCurrentPlatform &&
        isProjectorMissing &&
        !isDownloading &&
        onIncludeProjectorChanged != null &&
        !requiresProjector &&
        !isWebLiteRtLmModel;
    final shouldShowProjectorDownloadAction =
        canLoadModel && isProjectorMissing && includeProjector;
    final willLoadTextOnly = canLoadModel && isProjectorMissing;
    final clampedProgress = progress.clamp(0.0, 1.0).toDouble();
    final deleteActionLabel = progress > 0 && !isDownloaded
        ? 'Cancel & Discard'
        : hasPartialCache
        ? 'Delete cached assets'
        : model.multimodalProjectorSourceFor(web: isWeb) == null
        ? 'Delete Model'
        : 'Delete model and mmproj';
    final downloadToggleLabel = isDownloading
        ? 'Pause Download'
        : 'Resume Download';
    final platformLabel = switch (model.availability) {
      ModelAvailability.all => 'All platforms',
      ModelAvailability.native => 'Native platforms',
      ModelAvailability.nativeDesktop => 'Desktop',
    };
    final unavailableLabel = switch (model.availability) {
      ModelAvailability.all => 'Unavailable on this platform',
      ModelAvailability.native => 'Available on native platforms',
      ModelAvailability.nativeDesktop => 'Available on desktop',
    };

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isSelected
              ? colorScheme.primary.withValues(alpha: 0.55)
              : colorScheme.outlineVariant.withValues(alpha: 0.38),
        ),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      model.name,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: colorScheme.onSurface,
                      ),
                    ),
                    if (model.distribution case final distribution?) ...[
                      const SizedBox(height: 3),
                      Text(
                        '$distribution distribution',
                        style: TextStyle(
                          fontSize: 12,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    if (isSelected || isDownloaded) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          if (isSelected)
                            _buildStatusChip(
                              context,
                              icon: Icons.check_circle_rounded,
                              label: 'Selected',
                              emphasize: true,
                            ),
                          if (isDownloaded)
                            _buildStatusChip(
                              context,
                              icon: Icons.download_done_rounded,
                              label: isWeb ? 'Cached' : 'Downloaded',
                            ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        _buildMetaChip(
                          context,
                          icon: Icons.sd_storage_outlined,
                          label: model.sizeLabelFor(web: isWeb),
                        ),
                        _buildMetaChip(
                          context,
                          icon: Icons.memory_rounded,
                          label: '${model.minRamGb} GB RAM',
                        ),
                        _buildMetaChip(
                          context,
                          icon: switch (model.availability) {
                            ModelAvailability.all => Icons.devices_rounded,
                            ModelAvailability.native =>
                              Icons.devices_other_rounded,
                            ModelAvailability.nativeDesktop =>
                              Icons.desktop_mac_outlined,
                          },
                          label: platformLabel,
                        ),
                      ],
                    ),
                    if (cacheState != null && cacheState!.hasPartialAssets) ...[
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _buildCapabilityChip(
                            context,
                            icon: Icons.inventory_2_outlined,
                            label: cacheState!.model.isAvailable
                                ? 'Model cached'
                                : 'Model missing',
                            supported: cacheState!.model.isAvailable,
                          ),
                          if (cacheState!.multimodalProjector != null)
                            _buildCapabilityChip(
                              context,
                              icon: Icons.visibility_outlined,
                              label:
                                  cacheState!.multimodalProjector!.isAvailable
                                  ? 'mmproj cached'
                                  : 'mmproj missing',
                              supported:
                                  cacheState!.multimodalProjector!.isAvailable,
                            ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (model.supportsToolCalling)
                          _buildCapabilityChip(
                            context,
                            icon: Icons.build_circle_outlined,
                            label: 'Tools',
                            supported: true,
                          ),
                        if (model.supportsThinking)
                          _buildCapabilityChip(
                            context,
                            icon: Icons.psychology_alt_outlined,
                            label: 'Thinking',
                            supported: true,
                          ),
                        if (model.supportsVisionFor(web: isWeb))
                          _buildCapabilityChip(
                            context,
                            icon: Icons.visibility_outlined,
                            label: 'Vision',
                            supported: true,
                          ),
                        if (model.supportsAudioFor(web: isWeb))
                          _buildCapabilityChip(
                            context,
                            icon: Icons.mic_none_rounded,
                            label: 'Audio',
                            supported: true,
                          ),
                        if (model.supportsSpeechToTextFor(web: isWeb))
                          _buildCapabilityChip(
                            context,
                            icon: Icons.transcribe_outlined,
                            label: 'Speech-to-text',
                            supported: true,
                          ),
                        if (model.supportsTextToSpeechFor(web: isWeb))
                          _buildCapabilityChip(
                            context,
                            icon: Icons.graphic_eq_rounded,
                            label: 'Text-to-speech',
                            supported: true,
                          ),
                        if (model.supportsVideoFor(web: isWeb))
                          _buildCapabilityChip(
                            context,
                            icon: Icons.videocam_outlined,
                            label: 'Video',
                            supported: true,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              if (!isQueued && progress > 0 && !isDownloaded)
                IconButton(
                  icon: Icon(
                    Icons.delete_outline_rounded,
                    color: colorScheme.error,
                    semanticLabel: kIsWeb ? null : deleteActionLabel,
                  ),
                  onPressed: onDelete,
                  tooltip: deleteActionLabel,
                )
              else if (!isDownloading && !isQueued && isCustom)
                PopupMenuButton<_ModelCardMenuAction>(
                  tooltip: 'Model actions',
                  icon: const Icon(Icons.more_horiz_rounded),
                  onSelected: (action) {
                    if (action == _ModelCardMenuAction.removeFromLibrary) {
                      onRemoveFromLibrary?.call();
                    } else {
                      onDelete();
                    }
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                      value: _ModelCardMenuAction.removeFromLibrary,
                      child: _ModelMenuItem(
                        icon: Icons.remove_circle_outline_rounded,
                        label: 'Remove from library',
                      ),
                    ),
                    if (hasAnyCachedAsset)
                      const PopupMenuItem(
                        value: _ModelCardMenuAction.deleteCachedAssets,
                        child: _ModelMenuItem(
                          icon: Icons.delete_outline_rounded,
                          label: 'Delete downloaded files',
                          destructive: true,
                        ),
                      ),
                  ],
                )
              else if (hasAnyCachedAsset)
                IconButton(
                  icon: Icon(
                    Icons.delete_outline_rounded,
                    color: colorScheme.error,
                    semanticLabel: kIsWeb ? null : deleteActionLabel,
                  ),
                  onPressed: onDelete,
                  tooltip: deleteActionLabel,
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            model.description,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: colorScheme.onSurfaceVariant,
              fontSize: 14,
              height: 1.4,
            ),
          ),
          if (!isAvailableOnCurrentPlatform) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.55,
                ),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    size: 17,
                    color: colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '$unavailableLabel. Switch platforms to use this model.',
                      style: TextStyle(
                        fontSize: 12,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (partialCacheMessage != null) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: colorScheme.secondaryContainer.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: colorScheme.outlineVariant.withValues(alpha: 0.45),
                ),
              ),
              child: Text(
                partialCacheMessage,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.3,
                  color: colorScheme.onSecondaryContainer,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
          if (showWebLargeModelWarning) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: Colors.orange.withValues(alpha: 0.35),
                ),
              ),
              child: Text(
                isWebLiteRtLmModel
                    ? 'Web warning: very large LiteRT-LM model. Browser memory limits may still prevent engine initialization.'
                    : 'Web warning: very large model. Download can succeed, but browser memory limits may still prevent loading.',
                style: TextStyle(
                  fontSize: 12,
                  height: 1.3,
                  color: colorScheme.onSurface,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          if (shouldShowProjectorOption) ...[
            Divider(
              height: 1,
              color: colorScheme.outlineVariant.withValues(alpha: 0.35),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(
                  Icons.visibility_outlined,
                  size: 18,
                  color: colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    isWeb ? 'Cache projector for media' : 'Download projector',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: colorScheme.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Switch(
                  value: includeProjector,
                  onChanged: onIncludeProjectorChanged,
                ),
              ],
            ),
            Text(
              'Off keeps this model text-only and skips the mmproj file.',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                height: 1.25,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
          ],
          Row(
            children: [
              Icon(
                Icons.tune_rounded,
                size: 15,
                color: colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  'Recommended · ${_formatTokenCount(model.preset.contextSize)} context · ${_formatTokenCount(model.preset.maxTokens)} output',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (isQueued) ...[
            Container(
              padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
              decoration: BoxDecoration(
                color: colorScheme.secondaryContainer.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: colorScheme.outlineVariant.withValues(alpha: 0.45),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.format_list_numbered_rounded,
                    size: 18,
                    color: colorScheme.onSecondaryContainer,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      queuePosition == null
                          ? 'Queued for download'
                          : 'Queued for download • Position $queuePosition',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: colorScheme.onSecondaryContainer,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: onCancel,
                    tooltip: 'Remove from download queue',
                    icon: Icon(
                      Icons.close_rounded,
                      size: 18,
                      color: colorScheme.onSecondaryContainer,
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (isDownloading || (progress > 0 && !isDownloaded)) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: clampedProgress,
                backgroundColor: colorScheme.surfaceContainerHighest,
                minHeight: 7,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    isDownloading
                        ? (downloadStatusLabel ??
                              (isWeb ? 'Caching model...' : 'Downloading...'))
                        : 'Paused',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.2,
                      color: isDownloading
                          ? colorScheme.primary
                          : Colors.orange,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${(clampedProgress * 100).toStringAsFixed(0)}%',
                      style: TextStyle(
                        fontSize: 12,
                        color: isDownloading
                            ? colorScheme.primary
                            : Colors.orange,
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      height: 24,
                      width: 24,
                      child: IconButton(
                        padding: EdgeInsets.zero,
                        iconSize: 18,
                        icon: Icon(
                          isDownloading
                              ? Icons.pause_circle_outline_rounded
                              : Icons.play_circle_outline_rounded,
                          color: isDownloading
                              ? colorScheme.primary
                              : Colors.orange,
                          semanticLabel: kIsWeb ? null : downloadToggleLabel,
                        ),
                        onPressed: isDownloading ? onCancel : onDownload,
                        tooltip: downloadToggleLabel,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            if (downloadTransferLabel != null) ...[
              const SizedBox(height: 6),
              Text(
                downloadTransferLabel!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (showMobileDownloadGuidance) ...[
              const SizedBox(height: 6),
              Text(
                'Keep the app open until the download finishes. On phones, if Android or iOS interrupts it, starting again reuses the partial file when supported.',
                style: TextStyle(
                  fontSize: 11,
                  height: 1.3,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
          if (!isDownloading && !isQueued) ...[
            if (isDownloaded && !isWeb && isSelected) ...[
              const SizedBox(height: 16),
              Theme(
                data: Theme.of(context).copyWith(
                  dividerTheme: const DividerThemeData(thickness: 0.5),
                ),
                child: ExpansionTile(
                  title: Text(
                    'Advanced Settings (Selected)',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.only(bottom: 16),
                  shape: const RoundedRectangleBorder(),
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'GPU Offloading (Layers)',
                              style: const TextStyle(fontSize: 13),
                            ),
                            Text(
                              gpuLayers >= 99 ? 'Max' : gpuLayers.toString(),
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: colorScheme.primary,
                              ),
                            ),
                          ],
                        ),
                        Slider(
                          value: gpuLayers >= 99
                              ? 99.0
                              : gpuLayers.clamp(0, 98).toDouble(),
                          min: 0,
                          max: 99,
                          divisions: 99,
                          label: gpuLayers >= 99 ? 'Max' : gpuLayers.toString(),
                          onChanged: (v) => onGpuLayersChanged(v.round()),
                        ),
                        Text(
                          'Max requests full GPU offload',
                          style: TextStyle(
                            fontSize: 11,
                            color: colorScheme.onSurfaceVariant.withValues(
                              alpha: 0.75,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Context Size (Tokens)',
                              style: const TextStyle(fontSize: 13),
                            ),
                            Text(
                              contextSize.toString(),
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: colorScheme.primary,
                              ),
                            ),
                          ],
                        ),
                        Slider(
                          value: contextSize.clamp(512, 32768).toDouble(),
                          min: 512,
                          max: 32768,
                          divisions: 63, // 512 steps
                          label: contextSize.toString(),
                          onChanged: (v) => onContextSizeChanged(v.round()),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(top: 8.0),
                          child: Text(
                            'Note: Higher values use more VRAM/RAM and may cause crashes if exceeding system limits.',
                            style: TextStyle(
                              fontSize: 11,
                              color: colorScheme.onSurfaceVariant.withValues(
                                alpha: 0.7,
                              ),
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: !isAvailableOnCurrentPlatform
                  ? OutlinedButton.icon(
                      onPressed: null,
                      icon: const Icon(Icons.block_rounded, size: 18),
                      label: Text(unavailableLabel),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    )
                  : canLoadModel
                  ? FilledButton.icon(
                      onPressed: onSelect,
                      icon: Icon(
                        isSelected
                            ? Icons.check_circle_outline_rounded
                            : Icons.auto_awesome_rounded,
                        size: 18,
                      ),
                      label: Text(
                        isWebLiteRtLmModel
                            ? (isSelected
                                  ? isModelCached
                                        ? 'Reload Cached Model'
                                        : 'Reload Web Model'
                                  : isModelCached
                                  ? 'Use Cached Model'
                                  : 'Load & Cache Model')
                            : isWeb
                            ? (isSelected
                                  ? 'Reload Cached Model'
                                  : willLoadTextOnly
                                  ? 'Use Text Only'
                                  : 'Use Cached Model')
                            : (isSelected
                                  ? 'Reload Selected Model'
                                  : willLoadTextOnly
                                  ? 'Use Text Only'
                                  : 'Use this model'),
                      ),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    )
                  : OutlinedButton.icon(
                      onPressed: onDownload,
                      icon: Icon(
                        progress > 0
                            ? Icons.play_arrow_rounded
                            : Icons.download_rounded,
                        size: 18,
                      ),
                      label: Text(
                        isWeb
                            ? (progress > 0
                                  ? 'Resume Cache'
                                  : hasPartialCache
                                  ? 'Cache Missing Assets'
                                  : isProjectorMissing && !includeProjector
                                  ? 'Cache Model Only'
                                  : isProjectorMissing
                                  ? 'Cache Model + Projector'
                                  : 'Cache Model')
                            : (progress > 0
                                  ? 'Resume Download'
                                  : hasPartialCache
                                  ? 'Download Missing Assets'
                                  : isProjectorMissing && !includeProjector
                                  ? 'Download Model Only'
                                  : isProjectorMissing
                                  ? 'Download Model + Projector'
                                  : 'Download'),
                      ),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
            ),
            if (shouldShowProjectorDownloadAction) ...[
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: onDownload,
                  icon: const Icon(Icons.visibility_outlined, size: 18),
                  label: Text(isWeb ? 'Cache Projector' : 'Download Projector'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  bool _isLiteRtLmModel(DownloadableModel model) {
    return model.filenameFor(web: true).toLowerCase().endsWith('.litertlm');
  }

  String? _partialCacheMessage(
    ModelProfileCacheState? state, {
    required bool isWeb,
  }) {
    if (state == null || !state.hasPartialAssets) {
      return null;
    }
    final available = _joinAssetLabels(state.availableAssetLabels);
    final missing = _joinAssetLabels(state.missingAssetLabels);
    final action = isWeb ? 'Cache' : 'Download';
    return '${_capitalize(available)} cached; $missing missing. $action will fetch only missing assets.';
  }

  String _joinAssetLabels(List<String> labels) {
    if (labels.isEmpty) {
      return 'asset';
    }
    if (labels.length == 1) {
      return labels.single;
    }
    return '${labels.take(labels.length - 1).join(', ')} and ${labels.last}';
  }

  String _capitalize(String value) {
    if (value.isEmpty) {
      return value;
    }
    return value[0].toUpperCase() + value.substring(1);
  }

  String _formatTokenCount(int value) {
    if (value >= 1024 && value % 1024 == 0) {
      return '${value ~/ 1024}K';
    }
    return value.toString();
  }

  Widget _buildStatusChip(
    BuildContext context, {
    required IconData icon,
    required String label,
    bool emphasize = false,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final background = emphasize
        ? colorScheme.primaryContainer
        : colorScheme.tertiaryContainer.withValues(alpha: 0.65);
    final foreground = emphasize
        ? colorScheme.onPrimaryContainer
        : colorScheme.onTertiaryContainer;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: foreground),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: foreground,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMetaChip(
    BuildContext context, {
    required IconData icon,
    required String label,
    bool emphasize = false,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final background = emphasize
        ? colorScheme.primaryContainer.withValues(alpha: 0.75)
        : colorScheme.secondaryContainer.withValues(alpha: 0.5);
    final foreground = emphasize
        ? colorScheme.onPrimaryContainer
        : colorScheme.onSecondaryContainer;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: foreground),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: foreground,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCapabilityChip(
    BuildContext context, {
    required IconData icon,
    required String label,
    required bool supported,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final background = supported
        ? colorScheme.primaryContainer.withValues(alpha: 0.65)
        : colorScheme.surfaceContainerHighest.withValues(alpha: 0.45);
    final foreground = supported
        ? colorScheme.onPrimaryContainer
        : colorScheme.onSurfaceVariant;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(6),
        border: supported
            ? null
            : Border.all(
                color: colorScheme.outlineVariant.withValues(alpha: 0.5),
              ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: foreground),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: foreground,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ModelMenuItem extends StatelessWidget {
  const _ModelMenuItem({
    required this.icon,
    required this.label,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final color = destructive ? Theme.of(context).colorScheme.error : null;
    return Row(
      children: [
        Icon(icon, size: 19, color: color),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: color),
          ),
        ),
      ],
    );
  }
}
