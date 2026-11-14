part of 'model_hub_workspace_view.dart';

class _ModelDescriptorCard extends StatelessWidget {
  const _ModelDescriptorCard({
    required this.descriptor,
    required this.fit,
    required this.progress,
    required this.isCached,
    required this.isActive,
    required this.isLoading,
    required this.loadingStatus,
    required this.canActivate,
    required this.isWeb,
    required this.onActivate,
    required this.onCancelDownload,
    required this.onManageStorage,
  });

  final StudioModelDescriptor descriptor;
  final MemoryFitAssessment fit;
  final StudioModelDownloadProgress? progress;
  final bool isCached;
  final bool isActive;
  final bool isLoading;
  final String loadingStatus;
  final bool canActivate;
  final bool isWeb;
  final VoidCallback onActivate;
  final VoidCallback onCancelDownload;
  final VoidCallback onManageStorage;

  @override
  Widget build(BuildContext context) {
    final palette = StudioPalette.of(context);
    final fitColor = switch (fit.status) {
      MemoryFitStatus.fitsInVram => palette.teal,
      MemoryFitStatus.hybridCpuGpu => palette.accent,
      MemoryFitStatus.tightMemory => palette.amber,
      MemoryFitStatus.exceedsMemory => palette.danger,
      MemoryFitStatus.unknown => palette.textSecondary,
    };
    final downloading = progress?.isActive ?? false;
    final canDeleteManagedCache =
        isCached && !isWeb && descriptor.primarySource(isWeb: false).isRemote;

    return FadeSlideEntry(
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: palette.surfaceElevated,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isActive ? palette.teal : palette.borderSubtle,
            width: isActive ? 1.4 : 1.0,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: Text(
                    descriptor.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: palette.textPrimary,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  flex: 0,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 145),
                    child: Tooltip(
                      message:
                          '${fit.status.guidance} (${fit.estimatedFootprintLabel} est.)',
                      child: StudioPillBadge(
                        label: fit.status.badgeLabel,
                        foreground: fitColor,
                        monospace: true,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              descriptor.description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: palette.textSecondary),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                if (!isWeb && descriptor.primarySource(isWeb: false).isLocal)
                  const StudioPillBadge(label: 'Local file'),
                if (isCached && !isWeb)
                  StudioPillBadge(
                    label: 'Installed',
                    icon: Icons.check_circle_outline_rounded,
                    foreground: palette.teal,
                  ),
                if (descriptor.isRecommended)
                  StudioPillBadge(
                    label: 'Recommended',
                    icon: Icons.star_rounded,
                    foreground: palette.amber,
                  ),
                StudioPillBadge(
                  label: descriptor.sizeLabel(isWeb: isWeb),
                  monospace: true,
                ),
                for (final badge in descriptor.capabilityBadges(isWeb: isWeb))
                  StudioPillBadge(label: badge),
              ],
            ),
            if (downloading) ...<Widget>[
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      progress?.statusLabel ?? 'Downloading weights...',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: palette.textSecondary,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: onCancelDownload,
                    child: const Text('Cancel', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
              LinearProgressIndicator(value: progress?.fraction),
            ],
            if (isLoading) ...<Widget>[
              const SizedBox(height: 12),
              Text(loadingStatus),
              const SizedBox(height: 8),
              const LinearProgressIndicator(),
            ],
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    descriptor.publisher,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.5, color: palette.textMuted),
                  ),
                ),
                const SizedBox(width: 8),
                if (canDeleteManagedCache)
                  IconButton(
                    tooltip: 'Manage model storage',
                    visualDensity: VisualDensity.compact,
                    onPressed: onManageStorage,
                    icon: Icon(
                      Icons.storage_rounded,
                      size: 17,
                      color: palette.textMuted,
                    ),
                  ),
                FilledButton.tonalIcon(
                  key: Key('activate_model_${descriptor.id}'),
                  onPressed: downloading || !canActivate ? null : onActivate,
                  icon: Icon(
                    isActive
                        ? Icons.check_circle_outline_rounded
                        : (isCached || isWeb
                              ? Icons.bolt_rounded
                              : Icons.download_rounded),
                    size: 16,
                  ),
                  label: Text(
                    isLoading
                        ? 'Loading...'
                        : isActive
                        ? 'Active'
                        : (isCached || isWeb ? 'Load' : 'Download & Load'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _HuggingFaceRepoTile extends StatelessWidget {
  const _HuggingFaceRepoTile({
    required this.hit,
    required this.canActivate,
    required this.isExpanded,
    required this.files,
    required this.onTapRepo,
    required this.onActivateFile,
  });

  final HuggingFaceRepoHit hit;
  final bool canActivate;
  final bool isExpanded;
  final List<StudioModelDescriptor> files;
  final VoidCallback onTapRepo;
  final ValueChanged<StudioModelDescriptor> onActivateFile;

  @override
  Widget build(BuildContext context) {
    final palette = StudioPalette.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: palette.surfaceElevated,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.borderSubtle),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          children: <Widget>[
            ListTile(
              dense: true,
              onTap: onTapRepo,
              title: Text(
                hit.repoId,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: palette.textPrimary,
                  fontFamilyFallback: StudioTheme.monoFontFallback,
                ),
              ),
              subtitle: Text(
                '⬇ ${hit.downloads} · ♥ ${hit.likes}',
                style: TextStyle(fontSize: 11.5, color: palette.textMuted),
              ),
              trailing: Icon(
                isExpanded
                    ? Icons.expand_less_rounded
                    : Icons.expand_more_rounded,
                color: palette.textSecondary,
              ),
            ),
            if (isExpanded)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                child: files.isEmpty
                    ? Text(
                        'No standalone .gguf or .litertlm files found in main.',
                        style: TextStyle(
                          fontSize: 12,
                          color: palette.textMuted,
                        ),
                      )
                    : LayoutBuilder(
                        builder:
                            (BuildContext context, BoxConstraints fileBox) {
                              final stackFileRow = fileBox.maxWidth < 460;
                              return Column(
                                children: files.map((
                                  StudioModelDescriptor file,
                                ) {
                                  final actions = Wrap(
                                    spacing: 6,
                                    runSpacing: 6,
                                    crossAxisAlignment:
                                        WrapCrossAlignment.center,
                                    children: <Widget>[
                                      if (file.supportsVision)
                                        StudioPillBadge(
                                          label: '+mmproj',
                                          foreground: palette.teal,
                                        ),
                                      StudioPillBadge(
                                        label: file.sizeLabel(isWeb: false),
                                        monospace: true,
                                      ),
                                      OutlinedButton(
                                        style: OutlinedButton.styleFrom(
                                          visualDensity: VisualDensity.compact,
                                        ),
                                        onPressed: canActivate
                                            ? () => onActivateFile(file)
                                            : null,
                                        child: const Text(
                                          'Load',
                                          style: TextStyle(fontSize: 12),
                                        ),
                                      ),
                                    ],
                                  );
                                  final nameText = Text(
                                    file.filename,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: palette.textPrimary,
                                      fontFamilyFallback:
                                          StudioTheme.monoFontFallback,
                                    ),
                                  );
                                  return Padding(
                                    padding: const EdgeInsets.only(top: 8),
                                    child: stackFileRow
                                        ? Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: <Widget>[
                                              nameText,
                                              const SizedBox(height: 4),
                                              Align(
                                                alignment:
                                                    Alignment.centerRight,
                                                child: actions,
                                              ),
                                            ],
                                          )
                                        : Row(
                                            children: <Widget>[
                                              Expanded(child: nameText),
                                              const SizedBox(width: 8),
                                              actions,
                                            ],
                                          ),
                                  );
                                }).toList(),
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
