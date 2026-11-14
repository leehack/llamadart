// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

import '../app/studio_dependencies.dart';
import '../app/studio_theme.dart';
import 'store_widgets.dart';

/// Keeps model transfers visible while navigating between workspaces.
class DownloadActivityBar extends StatefulWidget {
  /// Creates the shell's compact download activity strip.
  const DownloadActivityBar({super.key});

  @override
  State<DownloadActivityBar> createState() => _DownloadActivityBarState();
}

class _DownloadActivityBarState extends State<DownloadActivityBar> {
  final Map<String, StudioModelDownloadProgress> _dismissed =
      <String, StudioModelDownloadProgress>{};

  List<StudioModelDownloadProgress> _visible(ModelHubState state) => state
      .downloadsByModelId
      .values
      .where(
        (p) =>
            p.stage != ModelDownloadTaskStage.idle &&
            (p.isActive || !identical(_dismissed[p.modelId], p)),
      )
      .toList();

  String _modelName(ModelHubState state, String id) {
    for (final model in <StudioModelDescriptor>[
      ...CuratedModelCatalog.models,
      ...state.localModels,
      ...state.expandedRepoFiles,
      if (state.activatingDescriptor != null) state.activatingDescriptor!,
    ]) {
      if (model.id == id) return model.name;
    }
    return id;
  }

  String _stage(StudioModelDownloadProgress p) => switch (p.stage) {
    ModelDownloadTaskStage.idle => 'Waiting',
    ModelDownloadTaskStage.resolving => 'Preparing download',
    ModelDownloadTaskStage.checkingCache => 'Checking cache',
    ModelDownloadTaskStage.downloading => 'Downloading',
    ModelDownloadTaskStage.verifying => 'Verifying files',
    ModelDownloadTaskStage.ready => 'Ready',
    ModelDownloadTaskStage.failed => 'Download failed',
    ModelDownloadTaskStage.cancelled => 'Cancelled',
  };

  double? _fraction(StudioModelDownloadProgress p) =>
      p.stage == ModelDownloadTaskStage.downloading && p.fraction != null
      ? p.fraction!.clamp(0, 1)
      : null;

  String _bytes(int value) => value >= 1024 * 1024 * 1024
      ? '${(value / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB'
      : '${(value / (1024 * 1024)).toStringAsFixed(1)} MB';

  void _showDetails(BuildContext context) {
    final controller = StudioScope.of(context).modelHubController;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (BuildContext context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .65,
          child: StoreBuilder<ModelHubState>(
            store: controller.store,
            builder: (BuildContext context, ModelHubState state) {
              final entries = _visible(state);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 12, 12),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            'Model downloads',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                        IconButton(
                          tooltip: 'Close downloads',
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ListView.separated(
                      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                      itemCount: entries.length,
                      separatorBuilder: (_, _) => const Divider(height: 32),
                      itemBuilder: (BuildContext context, int index) {
                        final p = entries[index];
                        final fraction = _fraction(p);
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Row(
                              children: <Widget>[
                                Expanded(
                                  child: Text(
                                    _modelName(state, p.modelId),
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleSmall,
                                  ),
                                ),
                                if (p.isActive)
                                  IconButton(
                                    key: Key('cancel_download_${p.modelId}'),
                                    tooltip: 'Cancel download',
                                    onPressed: () =>
                                        controller.cancelDownload(p.modelId),
                                    icon: const Icon(Icons.close_rounded),
                                  ),
                              ],
                            ),
                            Text(_stage(p)),
                            if (p.isActive) ...<Widget>[
                              const SizedBox(height: 10),
                              LinearProgressIndicator(value: fraction),
                              const SizedBox(height: 8),
                              Text(
                                '${fraction == null ? '' : '${(fraction * 100).round()}% · '}${_bytes(p.receivedBytes)}${p.totalBytes > 0 ? ' / ${_bytes(p.totalBytes)}' : ''}',
                              ),
                            ],
                            if (p.statusLabel?.isNotEmpty ?? false)
                              Text(p.statusLabel!),
                            if (p.stage == ModelDownloadTaskStage.failed &&
                                p.errorMessage != null)
                              Text(
                                p.errorMessage!,
                                style: TextStyle(
                                  color: StudioPalette.of(context).danger,
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = StudioScope.of(context).modelHubController;
    final palette = StudioPalette.of(context);
    return StoreBuilder<ModelHubState>(
      store: controller.store,
      builder: (BuildContext context, ModelHubState state) {
        final entries = _visible(state);
        if (entries.isEmpty) return const SizedBox.shrink();
        final active = entries.where((p) => p.isActive).toList();
        final failed = entries
            .where((p) => p.stage == ModelDownloadTaskStage.failed)
            .length;
        final primary = active.isEmpty ? entries.last : active.first;
        final fraction = active.length == 1 ? _fraction(primary) : null;
        final summary = active.length > 1
            ? '${active.length} model downloads in progress'
            : active.length == 1
            ? '${_stage(primary)} · ${_modelName(state, primary.modelId)}'
            : failed > 0
            ? '$failed model download${failed == 1 ? '' : 's'} failed'
            : entries.length == 1
            ? '${_stage(primary)} · ${_modelName(state, primary.modelId)}'
            : '${entries.length} model downloads finished';
        return Material(
          key: const Key('download_activity_bar'),
          color: palette.accent.withValues(alpha: .08),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                children: <Widget>[
                  const SizedBox(width: 12),
                  Icon(
                    failed > 0
                        ? Icons.error_outline
                        : active.isEmpty
                        ? Icons.download_done_rounded
                        : Icons.downloading_rounded,
                    size: 19,
                    color: failed > 0 ? palette.danger : palette.accent,
                  ),
                  Expanded(
                    child: TextButton(
                      key: const Key('open_downloads'),
                      style: TextButton.styleFrom(
                        alignment: Alignment.centerLeft,
                      ),
                      onPressed: () => _showDetails(context),
                      child: Text(
                        summary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  if (fraction != null) Text('${(fraction * 100).round()}%'),
                  IconButton(
                    tooltip: 'Download details',
                    onPressed: () => _showDetails(context),
                    icon: const Icon(Icons.expand_more_rounded),
                  ),
                  if (entries.any((p) => !p.isActive))
                    IconButton(
                      tooltip: 'Dismiss finished downloads',
                      onPressed: () => setState(() {
                        for (final p in entries.where((p) => !p.isActive)) {
                          _dismissed[p.modelId] = p;
                        }
                      }),
                      icon: const Icon(Icons.close_rounded, size: 18),
                    ),
                ],
              ),
              if (active.isNotEmpty)
                LinearProgressIndicator(value: fraction, minHeight: 2),
            ],
          ),
        );
      },
    );
  }
}
