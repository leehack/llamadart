// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

import '../app/studio_dependencies.dart';
import '../app/studio_theme.dart';
import 'store_widgets.dart';
import 'studio_motion.dart';

/// Displays live download progress (percentage, MB transferred, stage label,
/// and a Cancel action) while [descriptor] is downloading, or an indeterminate
/// memory-initialization bar once cached weights are loading into native memory.
class ModelLoadProgressBanner extends StatelessWidget {
  /// Creates a [ModelLoadProgressBanner].
  const ModelLoadProgressBanner({
    super.key,
    required this.descriptor,
    this.onCancel,
    this.preparing = false,
  });

  /// Model currently being downloaded or initialized in memory.
  final StudioModelDescriptor descriptor;

  /// Optional custom cancel callback; defaults to cancelling the active storage
  /// download via [ModelHubController.cancelDownload].
  final VoidCallback? onCancel;

  /// Whether cached assets are being resolved before runtime initialization.
  final bool preparing;

  static String _formatMegabytes(int bytes) {
    if (bytes <= 0) {
      return '0 MB';
    }
    final mb = bytes / (1024 * 1024);
    if (mb >= 1024) {
      return '${(mb / 1024).toStringAsFixed(2)} GB';
    }
    return '${mb.toStringAsFixed(mb >= 100 ? 0 : 1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final deps = StudioScope.of(context);
    final palette = StudioPalette.of(context);

    return StoreBuilder<ModelHubState>(
      store: deps.modelHubController.store,
      builder: (BuildContext context, ModelHubState hubState) {
        final progress = hubState.downloadsByModelId[descriptor.id];
        final isDownloading = progress != null && progress.isActive;
        final fraction = isDownloading
            ? progress.fraction?.clamp(0.0, 1.0)
            : null;
        final accentColor = isDownloading ? palette.accent : palette.teal;

        final String title = isDownloading
            ? 'Downloading ${descriptor.name}'
            : preparing
            ? 'Preparing ${descriptor.name}...'
            : 'Loading ${descriptor.name} into memory...';

        String? detail;
        if (isDownloading) {
          if (progress.totalBytes > 0) {
            detail =
                '${_formatMegabytes(progress.receivedBytes)} / '
                '${_formatMegabytes(progress.totalBytes)}';
          } else if (progress.receivedBytes > 0) {
            detail = _formatMegabytes(progress.receivedBytes);
          }
          if (progress.statusLabel != null &&
              progress.statusLabel!.trim().isNotEmpty) {
            detail = detail == null
                ? progress.statusLabel!
                : '$detail · ${progress.statusLabel!}';
          }
        } else {
          detail = preparing
              ? 'Checking model files before initialization'
              : 'Initializing runtime weights (${descriptor.sizeLabel(isWeb: deps.isWeb)})';
        }

        return Container(
          key: Key('model_load_banner_${descriptor.id}'),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: accentColor.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: accentColor.withValues(alpha: 0.34)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  StatusPulseDot(color: accentColor, pulsing: true),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: palette.textPrimary,
                          ),
                        ),
                        if (detail != null) ...<Widget>[
                          const SizedBox(height: 2),
                          Text(
                            detail,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11.5,
                              color: palette.textSecondary,
                              fontFamilyFallback: StudioTheme.monoFontFallback,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (fraction != null) ...<Widget>[
                    const SizedBox(width: 8),
                    StudioPillBadge(
                      label: '${(fraction * 100).round()}%',
                      foreground: accentColor,
                      monospace: true,
                    ),
                  ],
                  if (isDownloading) ...<Widget>[
                    const SizedBox(width: 8),
                    TextButton(
                      key: Key('cancel_model_download_${descriptor.id}'),
                      onPressed:
                          onCancel ??
                          () => deps.modelHubController.cancelDownload(
                            descriptor.id,
                          ),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        foregroundColor: palette.danger,
                      ),
                      child: const Text('Cancel'),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: fraction,
                  minHeight: 5,
                  color: accentColor,
                  backgroundColor: palette.borderSubtle,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
