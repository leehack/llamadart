import 'dart:async';
import 'dart:ui';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:llamadart/llamadart.dart';

import '../models/image_model_profile.dart';
import '../providers/image_generation_provider.dart';

/// On-device text-to-image generation with the experimental
/// `ImageGenerationEngine`.
class ImageGenerationScreen extends StatefulWidget {
  /// Injected state for tests; the screen creates and disposes its own
  /// otherwise.
  final ImageGenerationProvider? provider;

  /// Whether a chat model is loaded, for the unload offer after a memory
  /// refusal.
  final bool Function()? isChatModelLoaded;

  /// Unloads the chat model.
  final Future<void> Function()? unloadChatModel;

  /// Creates the image-generation screen.
  const ImageGenerationScreen({
    super.key,
    this.provider,
    this.isChatModelLoaded,
    this.unloadChatModel,
  });

  @override
  State<ImageGenerationScreen> createState() => _ImageGenerationScreenState();
}

class _ImageGenerationScreenState extends State<ImageGenerationScreen> {
  late final ImageGenerationProvider _provider;
  late final bool _ownsProvider;
  late final AppLifecycleListener _lifecycle;
  final TextEditingController _prompt = TextEditingController(
    text: 'a red fox in autumn leaves, detailed photo',
  );
  final TextEditingController _negativePrompt = TextEditingController();
  final TextEditingController _seed = TextEditingController();

  @override
  void initState() {
    super.initState();
    _ownsProvider = widget.provider == null;
    _provider =
        widget.provider ??
        ImageGenerationProvider(
          isChatModelLoaded: widget.isChatModelLoaded,
          unloadChatModel: widget.unloadChatModel,
        );
    // A backgrounded mobile app cannot keep the GPU busy, so a running
    // generation is cancelled; the loaded model stays for the next one.
    // Desktop quit skips dispose, and a model still loaded at exit aborts
    // the process on macOS Metal, so it is freed before the app exits.
    _lifecycle = AppLifecycleListener(
      onPause: _provider.cancelGeneration,
      onExitRequested: () async {
        await _provider.shutdown();
        return AppExitResponse.exit;
      },
    );
    if (!_provider.isInitialized) {
      unawaited(_provider.initialize());
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    if (_ownsProvider) {
      _provider.dispose();
    }
    _prompt.dispose();
    _negativePrompt.dispose();
    _seed.dispose();
    super.dispose();
  }

  void _generate() {
    final prompt = _prompt.text.trim();
    if (prompt.isEmpty) {
      _showMessage('Enter a prompt.');
      return;
    }
    final seedText = _seed.text.trim();
    final seed = seedText.isEmpty ? null : int.tryParse(seedText);
    if (seedText.isNotEmpty && (seed == null || seed < 0)) {
      _showMessage('The seed must be a whole number of 0 or more.');
      return;
    }
    unawaited(
      _provider.generate(
        prompt: prompt,
        negativePrompt: _negativePrompt.text.trim(),
        seed: seed,
      ),
    );
  }

  Future<void> _save(GeneratedImageOutput output) async {
    try {
      final savedPath = await FilePicker.platform.saveFile(
        dialogTitle: 'Save generated image',
        fileName: 'llamadart-image-${output.seed}.png',
        type: FileType.custom,
        allowedExtensions: const <String>['png'],
        bytes: output.png,
      );
      if (mounted && savedPath != null) {
        _showMessage('Saved $savedPath');
      }
    } catch (_) {
      _showMessage('Could not save the PNG file.');
    }
  }

  Future<void> _confirmDelete(ImageModelProfile profile) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${profile.name}?'),
        content: Text('Its ${profile.sizeLabel} of files will be removed.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _provider.deleteModel(profile);
    }
  }

  void _showMessage(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Image generation')),
      body: ListenableBuilder(
        listenable: _provider,
        builder: (context, _) {
          if (!_provider.isInitialized) {
            return const _CheckingRuntimeView();
          }
          if (!_provider.isSupported) {
            return _UnsupportedView(reason: _provider.unsupportedReason!);
          }
          return Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                children: [
                  _SectionLabel(
                    'Model',
                    trailing: _provider.runtimeBackend == null
                        ? null
                        : 'Runtime: ${_provider.runtimeBackend}',
                  ),
                  for (final profile in _provider.profiles)
                    _ImageModelTile(
                      profile: profile,
                      provider: _provider,
                      onDelete: () => unawaited(_confirmDelete(profile)),
                    ),
                  const SizedBox(height: 16),
                  _buildPromptSection(context),
                  const SizedBox(height: 16),
                  _buildActions(context),
                  _buildFeedback(context),
                  if (_provider.output case final output?)
                    _OutputView(
                      output: output,
                      onUseSeed: () => _seed.text = output.seed.toString(),
                      onSave: kIsWeb ? null : () => unawaited(_save(output)),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildPromptSection(BuildContext context) {
    final enabled = !_provider.isBusy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          key: const ValueKey<String>('image_prompt_field'),
          controller: _prompt,
          enabled: enabled,
          minLines: 1,
          maxLines: 3,
          decoration: const InputDecoration(
            labelText: 'Prompt',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey<String>('image_negative_prompt_field'),
          controller: _negativePrompt,
          enabled: enabled,
          decoration: const InputDecoration(
            labelText: 'Negative prompt (optional)',
            helperText: 'Ignored at guidance 1, which SDXS and SD-Turbo use.',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 16,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SegmentedButton<int>(
              key: const ValueKey<String>('image_size_selector'),
              segments: [
                for (final size in ImageGenerationProvider.sizes)
                  ButtonSegment<int>(value: size, label: Text('$size px')),
              ],
              selected: <int>{_provider.size},
              onSelectionChanged: enabled
                  ? (selection) => _provider.setSize(selection.single)
                  : null,
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Steps'),
                const SizedBox(width: 8),
                DropdownButton<int>(
                  key: const ValueKey<String>('image_steps_selector'),
                  value: _provider.steps,
                  onChanged: enabled
                      ? (value) => _provider.setSteps(value!)
                      : null,
                  items: [
                    for (
                      var steps = 1;
                      steps <= ImageGenerationProvider.maxSteps;
                      steps++
                    )
                      DropdownMenuItem<int>(
                        value: steps,
                        child: Text(
                          steps == _provider.selectedProfile.defaults.steps
                              ? '$steps (default)'
                              : '$steps',
                        ),
                      ),
                  ],
                ),
              ],
            ),
            SizedBox(
              width: 180,
              child: TextField(
                key: const ValueKey<String>('image_seed_field'),
                controller: _seed,
                enabled: enabled,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  labelText: 'Seed',
                  hintText: 'Random',
                  isDense: true,
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    tooltip: 'Use a random seed',
                    onPressed: enabled ? _seed.clear : null,
                    icon: const Icon(Icons.shuffle_rounded),
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildActions(BuildContext context) {
    if (_provider.isBusy) {
      return FilledButton.tonalIcon(
        key: const ValueKey<String>('cancel_image_generation_button'),
        onPressed: _provider.cancelGeneration,
        icon: const Icon(Icons.stop_rounded),
        label: const Text('Cancel'),
      );
    }
    return FilledButton.icon(
      key: const ValueKey<String>('generate_image_button'),
      onPressed: _provider.canGenerate ? _generate : null,
      icon: const Icon(Icons.auto_awesome_rounded),
      label: Text(
        _provider.isSelectedInstalled
            ? 'Generate'
            : 'Download ${_provider.selectedProfile.name} to generate',
      ),
    );
  }

  Widget _buildFeedback(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final children = <Widget>[];
    if (_provider.isBusy) {
      final progress = _provider.progress;
      final value = progress == null || progress.steps <= 0
          ? null
          : (progress.step / progress.steps).clamp(0.0, 1.0);
      children.add(
        Semantics(
          liveRegion: true,
          child: Column(
            key: const ValueKey<String>('image_generation_progress'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_progressLabel()),
              const SizedBox(height: 8),
              LinearProgressIndicator(value: value),
            ],
          ),
        ),
      );
    }
    if (_provider.error case final error?) {
      children.add(
        Container(
          key: const ValueKey<String>('image_generation_error'),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: colorScheme.errorContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(
                error,
                style: TextStyle(color: colorScheme.onErrorContainer),
              ),
              if (_provider.canUnloadChatModel) ...[
                const SizedBox(height: 8),
                TextButton.icon(
                  key: const ValueKey<String>('unload_chat_model_button'),
                  onPressed: () => unawaited(_provider.unloadChatModel()),
                  icon: const Icon(Icons.eject_rounded),
                  label: const Text('Unload chat model'),
                ),
              ],
            ],
          ),
        ),
      );
    }
    if (_provider.status case final status?) {
      children.add(Text(status));
    }
    if (_provider.loadedEngineLabel case final label? when label.isNotEmpty) {
      children.add(
        Text(
          'Loaded: $label',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
        ),
      );
    }
    if (children.isEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final child in children) ...[
            child,
            if (child != children.last) const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }

  String _progressLabel() {
    if (_provider.stage == ImageGenerationStage.loadingModel) {
      return 'Loading ${_provider.selectedProfile.name}…';
    }
    final progress = _provider.progress;
    if (progress == null) {
      return 'Starting…';
    }
    return switch (progress.phase) {
      ImageGenerationPhase.loading =>
        'Loading weights ${progress.step}/${progress.steps}',
      ImageGenerationPhase.encodingPrompt => 'Encoding prompt…',
      ImageGenerationPhase.sampling =>
        'Sampling step ${progress.step}/${progress.steps}',
      ImageGenerationPhase.decoding => 'Decoding image…',
    };
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  final String? trailing;

  const _SectionLabel(this.text, {this.trailing});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (trailing != null)
            Text(
              trailing!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}

class _ImageModelTile extends StatelessWidget {
  final ImageModelProfile profile;
  final ImageGenerationProvider provider;
  final VoidCallback onDelete;

  const _ImageModelTile({
    required this.profile,
    required this.provider,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final installed = provider.isInstalled(profile);
    final selected = provider.selectedProfile.id == profile.id;
    final installing = provider.installingId == profile.id;
    final canSelect = installed && provider.canChangeModel;

    return Card(
      key: ValueKey<String>('image_model_${profile.id}'),
      margin: const EdgeInsets.only(bottom: 8),
      color: selected
          ? colorScheme.primaryContainer.withValues(alpha: 0.35)
          : colorScheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: selected ? colorScheme.primary : Colors.transparent,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: canSelect
            ? () => unawaited(provider.selectModel(profile))
            : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    selected
                        ? Icons.radio_button_checked_rounded
                        : Icons.radio_button_unchecked_rounded,
                    color: installed
                        ? colorScheme.primary
                        : colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                    semanticLabel: kIsWeb
                        ? null
                        : selected
                        ? 'Selected'
                        : 'Not selected',
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          profile.name,
                          style: textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          [
                            profile.sizeLabel,
                            if (profile.isRecommended) 'Recommended',
                            if (installed) 'Installed',
                          ].join(' · '),
                          style: textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (installing)
                    IconButton(
                      key: ValueKey<String>('cancel_install_${profile.id}'),
                      tooltip: 'Cancel download',
                      onPressed: provider.cancelInstall,
                      icon: const Icon(Icons.close_rounded),
                    )
                  else if (installed)
                    IconButton(
                      key: ValueKey<String>('delete_${profile.id}'),
                      tooltip: 'Delete model files',
                      onPressed: provider.canChangeModel ? onDelete : null,
                      icon: const Icon(Icons.delete_outline_rounded),
                    )
                  else
                    TextButton.icon(
                      key: ValueKey<String>('install_${profile.id}'),
                      onPressed: provider.installingId == null
                          ? () => unawaited(provider.installModel(profile))
                          : null,
                      icon: const Icon(Icons.download_rounded),
                      label: const Text('Download'),
                    ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(left: 36, top: 4, right: 8),
                child: Text(profile.description, style: textTheme.bodySmall),
              ),
              if (profile.memoryNote case final note?)
                Padding(
                  padding: const EdgeInsets.only(left: 36, top: 6, right: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.memory_rounded,
                        size: 16,
                        color: colorScheme.tertiary,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          note,
                          style: textTheme.bodySmall?.copyWith(
                            color: colorScheme.tertiary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              if (installing)
                Padding(
                  padding: const EdgeInsets.only(left: 36, top: 8, right: 8),
                  child: Semantics(
                    liveRegion: true,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          provider.isVerifyingInstall
                              ? 'Verifying…'
                              : 'Downloading · '
                                    '${(provider.installProgress * 100).round()}%',
                          style: textTheme.bodySmall,
                        ),
                        const SizedBox(height: 6),
                        LinearProgressIndicator(
                          value: provider.isVerifyingInstall
                              ? null
                              : provider.installProgress,
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OutputView extends StatelessWidget {
  final GeneratedImageOutput output;
  final VoidCallback onUseSeed;
  final VoidCallback? onSave;

  const _OutputView({
    required this.output,
    required this.onUseSeed,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    final seconds = output.elapsed.inMilliseconds / 1000;
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: AspectRatio(
              aspectRatio: output.width / output.height,
              child: Image.memory(
                output.png,
                key: const ValueKey<String>('generated_image'),
                gaplessPlayback: true,
                fit: BoxFit.contain,
                semanticLabel: 'Generated image',
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Seed ${output.seed} · ${output.width}×${output.height} · '
            '${seconds.toStringAsFixed(1)} s · ${output.profile.name}',
            key: const ValueKey<String>('generated_image_details'),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: onUseSeed,
                icon: const Icon(Icons.push_pin_outlined),
                label: const Text('Reuse seed'),
              ),
              if (onSave != null)
                FilledButton.tonalIcon(
                  key: const ValueKey<String>('save_image_button'),
                  onPressed: onSave,
                  icon: const Icon(Icons.save_alt_rounded),
                  label: const Text('Save PNG'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CheckingRuntimeView extends StatelessWidget {
  const _CheckingRuntimeView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          key: const ValueKey<String>('image_generation_checking_runtime'),
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              'Checking the image runtime…',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _UnsupportedView extends StatelessWidget {
  final String reason;

  const _UnsupportedView({required this.reason});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            key: const ValueKey<String>('image_generation_unsupported'),
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.image_not_supported_outlined,
                size: 40,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 12),
              Text(
                'Image generation is not available here',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              SelectableText(reason, textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }
}
