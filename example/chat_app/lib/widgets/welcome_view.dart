import 'package:flutter/material.dart';

class WelcomeView extends StatelessWidget {
  static const String recommendedQuickStartModel = 'Qwen3.5-0.8B-Q4_K_M.gguf';

  final bool isInitializing;
  final String? error;
  final String? modelPath;
  final bool isLoaded;
  final double loadingProgress;
  final VoidCallback onRetry;
  final VoidCallback? onSelectModel;
  final ValueChanged<String>? onQuickStartModel;

  const WelcomeView({
    super.key,
    required this.isInitializing,
    required this.error,
    required this.modelPath,
    required this.isLoaded,
    this.loadingProgress = 0.0,
    required this.onRetry,
    required this.onSelectModel,
    this.onQuickStartModel,
  });

  @override
  Widget build(BuildContext context) {
    if (isInitializing) {
      return _ScrollableWelcomeContent(
        maxWidth: 420,
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
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.secondary,
              ),
            ),
          ],
        ),
      );
    }

    final colorScheme = Theme.of(context).colorScheme;
    final selectedModelName = _displayModelName(modelPath);

    if (error != null) {
      return _ScrollableWelcomeContent(
        maxWidth: 520,
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: colorScheme.errorContainer.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: colorScheme.error.withValues(alpha: 0.2)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_rounded, size: 40, color: colorScheme.error),
              const SizedBox(height: 14),
              Text(
                'Model failed to load',
                style: TextStyle(
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
      );
    }

    final canSelectModel = onSelectModel != null;

    if (modelPath == null) {
      return _ScrollableWelcomeContent(
        maxWidth: 540,
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
                Icons.auto_awesome_rounded,
                size: 38,
                color: colorScheme.primary,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Start with a model',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Text(
              'Download once, then run private AI directly on your device.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            if (canSelectModel) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest.withValues(
                    alpha: 0.45,
                  ),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: colorScheme.outlineVariant.withValues(alpha: 0.4),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: colorScheme.primary.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            'RECOMMENDED',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.5,
                              color: colorScheme.primary,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'GENERAL ASSISTANT',
                          style: TextStyle(
                            fontSize: 11,
                            color: colorScheme.secondary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'Qwen3.5 0.8B Instruct',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '720 MB base model • Tools and reasoning, with an optional vision asset.',
                      style: TextStyle(
                        fontSize: 13,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        FilledButton.icon(
                          onPressed: () {
                            if (onQuickStartModel != null) {
                              onQuickStartModel!(recommendedQuickStartModel);
                            } else if (onSelectModel != null) {
                              onSelectModel!();
                            }
                          },
                          icon: const Icon(Icons.download_rounded),
                          label: const Text('Choose Qwen3.5 0.8B'),
                        ),
                        OutlinedButton.icon(
                          onPressed: onSelectModel,
                          icon: const Icon(Icons.tune_rounded),
                          label: const Text('Browse all models'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      );
    }

    return _ScrollableWelcomeContent(
      maxWidth: 520,
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
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
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
                  Icons.sd_storage_outlined,
                  size: 18,
                  color: colorScheme.secondary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    selectedModelName ?? 'Selected model',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: colorScheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          if (!isLoaded)
            Wrap(
              spacing: 10,
              runSpacing: 10,
              alignment: WrapAlignment.center,
              children: [
                FilledButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.power_settings_new_rounded),
                  label: const Text('Load model'),
                ),
                if (canSelectModel)
                  OutlinedButton.icon(
                    onPressed: onSelectModel,
                    icon: const Icon(Icons.tune_rounded),
                    label: const Text('Change model'),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  String? _displayModelName(String? pathOrUrl) {
    if (pathOrUrl == null || pathOrUrl.isEmpty) {
      return null;
    }

    final withoutSensitiveSuffix = pathOrUrl.split('?').first.split('#').first;
    final normalized = withoutSensitiveSuffix.replaceAll('\\', '/');
    final parts = normalized.split('/').where((part) => part.isNotEmpty);
    return parts.isEmpty ? 'Selected model' : parts.last;
  }
}

class _ScrollableWelcomeContent extends StatelessWidget {
  final double maxWidth;
  final Widget child;

  const _ScrollableWelcomeContent({
    required this.maxWidth,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final minHeight = constraints.hasBoundedHeight
            ? (constraints.maxHeight - 48).clamp(0.0, double.infinity)
            : 0.0;

        return SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: minHeight),
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxWidth),
                child: child,
              ),
            ),
          ),
        );
      },
    );
  }
}
