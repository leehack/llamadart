import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class WelcomeView extends StatelessWidget {
  final bool isInitializing;
  final String? error;
  final String? modelPath;
  final bool isLoaded;
  final double loadingProgress;
  final VoidCallback onRetry;
  final VoidCallback? onSelectModel;

  const WelcomeView({
    super.key,
    required this.isInitializing,
    required this.error,
    required this.modelPath,
    required this.isLoaded,
    this.loadingProgress = 0.0,
    required this.onRetry,
    required this.onSelectModel,
  });

  @override
  Widget build(BuildContext context) {
    if (isInitializing) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (loadingProgress > 0)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: LinearProgressIndicator(
                      value: loadingProgress,
                      minHeight: 8,
                    ),
                  )
                else
                  const CircularProgressIndicator(),
                const SizedBox(height: 18),
                Text(
                  loadingProgress > 0
                      ? 'Loading model ${(loadingProgress * 100).toStringAsFixed(0)}%'
                      : 'Loading model...',
                  style: GoogleFonts.outfit(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.secondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final colorScheme = Theme.of(context).colorScheme;
    final selectedModelName = modelPath?.split('/').last;

    if (error != null) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Container(
            margin: const EdgeInsets.all(24),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: colorScheme.errorContainer.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: colorScheme.error.withValues(alpha: 0.2),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error_rounded, size: 40, color: colorScheme.error),
                const SizedBox(height: 14),
                Text(
                  'Model failed to load',
                  style: GoogleFonts.outfit(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: colorScheme.error,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: colorScheme.onErrorContainer),
                ),
                const SizedBox(height: 18),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  alignment: WrapAlignment.center,
                  children: [
                    FilledButton.icon(
                      onPressed: onRetry,
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('Retry'),
                    ),
                    if (onSelectModel != null)
                      OutlinedButton.icon(
                        onPressed: onSelectModel,
                        icon: const Icon(Icons.tune_rounded),
                        label: const Text('Change model'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }

    final canSelectModel = onSelectModel != null;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: colorScheme.primaryContainer.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: colorScheme.outlineVariant.withValues(alpha: 0.35),
                  ),
                ),
                child: Icon(
                  Icons.chat_bubble_outline_rounded,
                  size: 42,
                  color: colorScheme.primary,
                ),
              ),
              const SizedBox(height: 22),
              Text(
                isLoaded ? 'Ready to chat' : 'Load a model to begin',
                textAlign: TextAlign.center,
                style: GoogleFonts.outfit(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest.withValues(
                    alpha: 0.36,
                  ),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: colorScheme.outlineVariant.withValues(alpha: 0.35),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      selectedModelName == null
                          ? Icons.folder_open_rounded
                          : Icons.sd_storage_outlined,
                      size: 18,
                      color: colorScheme.secondary,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        selectedModelName ?? 'No model selected',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: colorScheme.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              if (!isLoaded && (canSelectModel || modelPath != null))
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  alignment: WrapAlignment.center,
                  children: [
                    FilledButton.icon(
                      onPressed: modelPath == null ? onSelectModel : onRetry,
                      icon: Icon(
                        modelPath == null
                            ? Icons.file_open_rounded
                            : Icons.power_settings_new_rounded,
                      ),
                      label: Text(
                        modelPath == null ? 'Select model' : 'Load model',
                      ),
                    ),
                    if (modelPath != null && canSelectModel)
                      OutlinedButton.icon(
                        onPressed: onSelectModel,
                        icon: const Icon(Icons.tune_rounded),
                        label: const Text('Change model'),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
