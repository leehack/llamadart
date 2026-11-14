import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

import '../../app/platform_file_helper.dart';
import '../../app/studio_dependencies.dart';
import '../../app/studio_theme.dart';
import '../../widgets/model_load_progress_banner.dart';
import '../../widgets/store_widgets.dart';
import '../../widgets/studio_motion.dart';

/// Local Stable Diffusion Image Studio workspace (`SDXS-512` & `SD-Turbo`).
class ImageWorkspaceView extends StatefulWidget {
  /// Creates an [ImageWorkspaceView].
  const ImageWorkspaceView({super.key});

  @override
  State<ImageWorkspaceView> createState() => _ImageWorkspaceViewState();
}

class _ImageWorkspaceViewState extends State<ImageWorkspaceView> {
  final TextEditingController _promptCtrl = TextEditingController(
    text: 'Architectural studio desk overlooking neon-lit Seoul rain at dusk, minimal industrial design, crisp reflections, 35mm photograph',
  );
  final TextEditingController _negativeCtrl = TextEditingController(
    text: 'blurry, watermark, low quality, distorted',
  );
  final TextEditingController _seedCtrl = TextEditingController(text: '42');

  StudioModelDescriptor? _selectedCheckpoint;
  int _steps = 1;
  double _cfgScale = 1.0;
  bool _lockSeed = false;

  PageStorageBucket? _draftBucket;
  bool _draftRestored = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _draftBucket = PageStorage.maybeOf(context);
    if (_draftRestored) return;
    _draftRestored = true;
    final draft = _draftBucket?.readState(
      context,
      identifier: 'image_draft',
    ) as Map<String, Object?>?;
    if (draft == null) return;
    _promptCtrl.value = draft['_promptCtrl']! as TextEditingValue;
    _negativeCtrl.value = draft['_negativeCtrl']! as TextEditingValue;
    _seedCtrl.value = draft['_seedCtrl']! as TextEditingValue;
    _selectedCheckpoint =
        draft['_selectedCheckpoint'] as StudioModelDescriptor?;
    _steps = draft['_steps'] as int;
    _cfgScale = draft['_cfgScale'] as double;
    _lockSeed = draft['_lockSeed'] as bool;
  }

  @override
  void deactivate() {
    _draftBucket?.writeState(context, <String, Object?>{
      '_promptCtrl': _promptCtrl.value,
      '_negativeCtrl': _negativeCtrl.value,
      '_seedCtrl': _seedCtrl.value,
      '_selectedCheckpoint': _selectedCheckpoint,
      '_steps': _steps,
      '_cfgScale': _cfgScale,
      '_lockSeed': _lockSeed,
    }, identifier: 'image_draft');
    super.deactivate();
  }

  @override
  void dispose() {
    _promptCtrl.dispose();
    _negativeCtrl.dispose();
    _seedCtrl.dispose();
    super.dispose();
  }

  Future<void> _savePng(StudioGeneratedImageItem item) async {
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Save Generated Image',
      fileName: '${item.id}.png',
      bytes: item.pngBytes,
    );
    if (path != null && path.isNotEmpty) {
      await StudioPlatformFileHelper.writeBytesToPath(path, item.pngBytes);
    }
  }

  void _sendToVisionChat(BuildContext context, StudioGeneratedImageItem item) {
    final deps = StudioScope.of(context);
    deps.chatController.addPendingAttachment(
      StudioAttachment(
        id: 'gen_${item.id}',
        kind: StudioAttachmentKind.image,
        name: '${item.id}.png',
        mimeType: 'image/png',
        bytes: item.pngBytes,
        sizeBytes: item.pngBytes.length,
      ),
    );
    deps.shellController.selectWorkspace(StudioWorkspace.chat);
  }

  @override
  Widget build(BuildContext context) {
    final deps = StudioScope.of(context);
    final palette = StudioPalette.of(context);

    return StoreBuilder<ModelHubState>(
      store: deps.modelHubController.store,
      builder: (BuildContext context, ModelHubState hubState) {
        final checkpoints = deps.imageController.availableModels;
        final cachedIds = hubState.cachedModelIds;
        if (_selectedCheckpoint == null ||
            !checkpoints.any(
              (StudioModelDescriptor m) => m.id == _selectedCheckpoint!.id,
            )) {
          _selectedCheckpoint =
              checkpoints
                  .where((StudioModelDescriptor m) => cachedIds.contains(m.id))
                  .firstOrNull ??
              checkpoints.firstOrNull;
        } else {
          _selectedCheckpoint = checkpoints.firstWhere(
            (StudioModelDescriptor m) => m.id == _selectedCheckpoint!.id,
          );
        }

        return StoreBuilder<ImageWorkspaceState>(
          store: deps.imageController.store,
          builder: (BuildContext context, ImageWorkspaceState imageState) {
            final unsupported =
                imageState.runtimeCapabilities?.isSupported == false;
            final fraction = imageState.totalSteps > 0
                ? (imageState.step / imageState.totalSteps).clamp(0.0, 1.0)
                : 0.0;

            return ListView(
              padding: const EdgeInsets.all(22),
              children: <Widget>[
                Text(
                  'Image Studio',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: palette.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'On-device 1-step & few-step Stable Diffusion with TAESD latent decoding and vision-chat handoff.',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: palette.textSecondary,
                  ),
                ),
                if (unsupported) ...<Widget>[
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: palette.amber.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      imageState.runtimeCapabilities?.unsupportedReason ??
                          'Image generation is unavailable on this runtime.',
                      style: TextStyle(fontSize: 12.5, color: palette.amber),
                    ),
                  ),
                ],
                if (imageState.loadingModel != null) ...<Widget>[
                  const SizedBox(height: 12),
                  ModelLoadProgressBanner(descriptor: imageState.loadingModel!),
                ],
                if (imageState.errorMessage != null) ...<Widget>[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: palette.danger.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      imageState.errorMessage!,
                      style: TextStyle(fontSize: 12, color: palette.danger),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: palette.surfaceElevated,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: palette.borderSubtle),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      if (checkpoints.isNotEmpty)
                        LayoutBuilder(
                          builder: (BuildContext context, BoxConstraints cpBox) {
                            final stackCheckpoint = cpBox.maxWidth < 430;
                            final dropdown =
                                DropdownButtonFormField<StudioModelDescriptor>(
                                  key: ValueKey<String?>(
                                    _selectedCheckpoint?.id,
                                  ),
                                  initialValue: _selectedCheckpoint,
                                  isExpanded: true,
                                  decoration: const InputDecoration(
                                    labelText: 'Diffusion Checkpoint',
                                  ),
                                  items: checkpoints
                                      .map(
                                        (StudioModelDescriptor m) =>
                                            DropdownMenuItem<
                                              StudioModelDescriptor
                                            >(
                                              value: m,
                                              child: Text(
                                                '${m.name} (${m.sizeLabel(isWeb: deps.isWeb)})${cachedIds.contains(m.id) ? ' · Installed' : ''}',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  fontSize: 12.5,
                                                ),
                                              ),
                                            ),
                                      )
                                      .toList(),
                                  onChanged: (StudioModelDescriptor? next) {
                                    if (next != null) {
                                      setState(() {
                                        _selectedCheckpoint = next;
                                        _steps = next.preset.imageSteps;
                                        _cfgScale =
                                            next.preset.imageGuidanceScale;
                                      });
                                    }
                                  },
                                );
                            final loadBtn = FilledButton.tonal(
                              key: const Key('load_image_pipeline_button'),
                              onPressed:
                                  unsupported ||
                                      imageState.isLoadingModel ||
                                      _selectedCheckpoint == null
                                  ? null
                                  : () => deps.imageController.loadModel(
                                      _selectedCheckpoint!,
                                    ),
                              child: Text(
                                imageState.isLoadingModel
                                    ? 'Loading...'
                                    : (imageState.activeModel?.id ==
                                              _selectedCheckpoint?.id
                                          ? 'Loaded'
                                          : 'Load Checkpoint'),
                              ),
                            );
                            if (stackCheckpoint) {
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: <Widget>[
                                  dropdown,
                                  const SizedBox(height: 8),
                                  loadBtn,
                                ],
                              );
                            }
                            return Row(
                              children: <Widget>[
                                Expanded(child: dropdown),
                                const SizedBox(width: 10),
                                loadBtn,
                              ],
                            );
                          },
                        ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _promptCtrl,
                        maxLines: 3,
                        decoration: const InputDecoration(
                          labelText: 'Positive Prompt',
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _negativeCtrl,
                        maxLines: 1,
                        decoration: const InputDecoration(
                          labelText: 'Negative Prompt',
                        ),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 18,
                        runSpacing: 10,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: <Widget>[
                          ConstrainedBox(
                            constraints: const BoxConstraints(
                              minWidth: 150,
                              maxWidth: 220,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  'Steps: $_steps',
                                  style: const TextStyle(fontSize: 12),
                                ),
                                Slider(
                                  value: _steps.toDouble(),
                                  min: 1,
                                  max: 16,
                                  divisions: 15,
                                  onChanged: (double v) =>
                                      setState(() => _steps = v.round()),
                                ),
                              ],
                            ),
                          ),
                          ConstrainedBox(
                            constraints: const BoxConstraints(
                              minWidth: 150,
                              maxWidth: 220,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  'CFG: ${_cfgScale.toStringAsFixed(1)}',
                                  style: const TextStyle(fontSize: 12),
                                ),
                                Slider(
                                  value: _cfgScale,
                                  min: 1.0,
                                  max: 8.0,
                                  divisions: 14,
                                  onChanged: (double v) =>
                                      setState(() => _cfgScale = v),
                                ),
                              ],
                            ),
                          ),
                          SizedBox(
                            width: 130,
                            child: TextField(
                              controller: _seedCtrl,
                              enabled: _lockSeed,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                labelText: 'Seed',
                              ),
                            ),
                          ),
                          FilterChip(
                            label: const Text('Lock Seed'),
                            selected: _lockSeed,
                            onSelected: (bool v) =>
                                setState(() => _lockSeed = v),
                          ),
                        ],
                      ),
                      if (imageState.isGenerating) ...<Widget>[
                        const SizedBox(height: 12),
                        Text(
                          imageState.phaseLabel ?? 'Sampling latents...',
                          style: TextStyle(fontSize: 12, color: palette.teal),
                        ),
                        const SizedBox(height: 6),
                        AnimatedScoreBar(
                          fraction: fraction > 0 ? fraction : 0.25,
                          color: palette.teal,
                        ),
                      ],
                      const SizedBox(height: 12),
                      Align(
                        alignment: Alignment.centerRight,
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          alignment: WrapAlignment.end,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: <Widget>[
                            if (imageState.isGenerating)
                              TextButton(
                                onPressed:
                                    deps.imageController.cancelGeneration,
                                child: const Text('Cancel'),
                              ),
                            FilledButton.icon(
                              key: const Key('generate_image_button'),
                              onPressed: unsupported || imageState.isGenerating
                                  ? null
                                  : () => deps.imageController.generate(
                                      prompt: _promptCtrl.text,
                                      negativePrompt: _negativeCtrl.text,
                                      steps: _steps,
                                      guidanceScale: _cfgScale,
                                      seed: _lockSeed
                                          ? int.tryParse(_seedCtrl.text.trim())
                                          : null,
                                    ),
                              icon: const Icon(
                                Icons.auto_fix_high_rounded,
                                size: 16,
                              ),
                              label: const Text('Generate 512×512'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                if (imageState.gallery.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 20),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          'GENERATED GALLERY (${imageState.gallery.length})',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.7,
                            color: palette.textMuted,
                          ),
                        ),
                      ),
                      TextButton.icon(
                        key: const Key('clear_image_gallery_button'),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                        onPressed: deps.imageController.clearGallery,
                        icon: const Icon(Icons.delete_sweep_outlined, size: 15),
                        label: const Text('Clear Gallery'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  LayoutBuilder(
                    builder: (BuildContext context, BoxConstraints galleryBox) {
                      final cardW = math.min(280.0, galleryBox.maxWidth);
                      return Wrap(
                        spacing: 16,
                        runSpacing: 16,
                        children: imageState.gallery.map((
                          StudioGeneratedImageItem item,
                        ) {
                          return FadeSlideEntry(
                            child: Container(
                              width: cardW,
                              decoration: BoxDecoration(
                                color: palette.surfaceElevated,
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(color: palette.borderSubtle),
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: Material(
                                type: MaterialType.transparency,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    AspectRatio(
                                      aspectRatio: 1,
                                      child: Image.memory(
                                        item.pngBytes,
                                        fit: BoxFit.cover,
                                        errorBuilder: (_, _, _) => ColoredBox(
                                          color: palette.canvas,
                                          child: Icon(
                                            Icons.broken_image_outlined,
                                            color: palette.textMuted,
                                          ),
                                        ),
                                      ),
                                    ),
                                    Padding(
                                      padding: const EdgeInsets.all(12),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: <Widget>[
                                          Text(
                                            item.prompt,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontSize: 12,
                                            ),
                                          ),
                                          const SizedBox(height: 8),
                                          Row(
                                            children: <Widget>[
                                              Expanded(
                                                child: Align(
                                                  alignment:
                                                      Alignment.centerLeft,
                                                  child: StudioPillBadge(
                                                    label:
                                                        '${(item.elapsedMs / 1000).toStringAsFixed(1)}s · seed ${item.seed}',
                                                    monospace: true,
                                                  ),
                                                ),
                                              ),
                                              IconButton(
                                                tooltip: 'Send to Vision Chat',
                                                visualDensity:
                                                    VisualDensity.compact,
                                                onPressed: () =>
                                                    _sendToVisionChat(
                                                      context,
                                                      item,
                                                    ),
                                                icon: const Icon(
                                                  Icons.chat_outlined,
                                                  size: 16,
                                                ),
                                              ),
                                              IconButton(
                                                tooltip: 'Save PNG',
                                                visualDensity:
                                                    VisualDensity.compact,
                                                onPressed: () => _savePng(item),
                                                icon: const Icon(
                                                  Icons.download_rounded,
                                                  size: 17,
                                                ),
                                              ),
                                              IconButton(
                                                key: Key(
                                                  'remove_image_${item.id}',
                                                ),
                                                tooltip: 'Remove from gallery',
                                                visualDensity:
                                                    VisualDensity.compact,
                                                onPressed: () => deps
                                                    .imageController
                                                    .removeGalleryItem(item.id),
                                                icon: Icon(
                                                  Icons.delete_outline_rounded,
                                                  size: 16,
                                                  color: palette.textMuted,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      );
                    },
                  ),
                ],
              ],
            );
          },
        );
      },
    );
  }
}
