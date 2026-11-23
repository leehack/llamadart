import 'dart:async';

import 'package:genkit/genkit.dart';
import 'package:material_ui/material_ui.dart';

import 'playground_controller.dart';

class PlaygroundView extends StatefulWidget {
  const PlaygroundView({super.key, required this.controller});

  final PlaygroundController controller;

  @override
  State<PlaygroundView> createState() => _PlaygroundViewState();
}

class _PlaygroundViewState extends State<PlaygroundView> {
  final _promptFocus = FocusNode();
  final _scroll = ScrollController();

  void _send() {
    unawaited(widget.controller.send());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  void dispose() {
    _promptFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Genkit model playground'),
        actions: [
          TextButton(
            onPressed: controller.busy || controller.messages.isEmpty
                ? null
                : controller.clearChat,
            child: const Text('Clear'),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _ProviderSelector(controller),
                    const SizedBox(height: 8),
                    if (controller.isGguf) ...[
                      _GgufModelPicker(controller),
                      const SizedBox(height: 8),
                    ],
                    if (!controller.ready) _ConnectionSection(controller),
                    if (controller.stats case final stats?) _StatsBar(stats),
                    if (controller.ready && !controller.supportsMultiTurn)
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text(singleTurnNotice),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  controller: _scroll,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  children: [
                    _SettingsPanel(controller),
                    _PresetChips(
                      onSelected: controller.generating
                          ? null
                          : (prompt) {
                              controller.prompt.text = prompt;
                              _promptFocus.requestFocus();
                            },
                    ),
                    const Divider(height: 24),
                    _TranscriptList(controller.messages),
                  ],
                ),
              ),
              _ComposerBar(controller, _promptFocus, _send),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProviderSelector extends StatelessWidget {
  const _ProviderSelector(this.controller);

  final PlaygroundController controller;

  @override
  Widget build(BuildContext context) => SegmentedButton<PlaygroundProvider>(
    showSelectedIcon: false,
    segments: [
      for (final provider in PlaygroundProvider.values)
        ButtonSegment(value: provider, label: Text(provider.label)),
    ],
    selected: {controller.provider},
    onSelectionChanged: controller.busy
        ? null
        : (value) => controller.select(value.single),
  );
}

class _GgufModelPicker extends StatelessWidget {
  const _GgufModelPicker(this.controller);

  final PlaygroundController controller;

  @override
  Widget build(BuildContext context) {
    final model = controller.ggufModel;
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InputDecorator(
          decoration: InputDecoration(
            labelText: 'GGUF model',
            enabled: !controller.busy,
            isDense: true,
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<GgufModelOption>(
              value: model,
              isExpanded: true,
              isDense: true,
              onChanged: controller.busy
                  ? null
                  : (selected) {
                      if (selected != null) {
                        unawaited(controller.selectGgufModel(selected));
                      }
                    },
              items: [
                for (final option in ggufModels)
                  DropdownMenuItem(
                    value: option,
                    child: Text('${option.label} (${option.sizeLabel})'),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(model.note, style: textTheme.bodySmall),
        if (!controller.ready && model.warning != null) ...[
          const SizedBox(height: 8),
          DecoratedBox(
            decoration: BoxDecoration(
              color: colors.tertiaryContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    size: 18,
                    color: colors.onTertiaryContainer,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      model.warning!,
                      style: textTheme.bodySmall?.copyWith(
                        color: colors.onTertiaryContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _ConnectionSection extends StatelessWidget {
  const _ConnectionSection(this.controller);

  final PlaygroundController controller;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (controller.isGemini && !controller.ready)
        TextField(
          controller: controller.apiKey,
          decoration: const InputDecoration(labelText: 'Gemini API key'),
          obscureText: true,
          autofillHints: null,
          autocorrect: false,
          enableSuggestions: false,
          enableIMEPersonalizedLearning: false,
        ),
      ValueListenableBuilder(
        valueListenable: controller.apiKey,
        builder: (_, key, _) => OutlinedButton(
          onPressed:
              controller.busy ||
                  (controller.isGemini && key.text.trim().isEmpty)
              ? null
              : controller.load,
          child: Text(controller.isGemini ? 'Connect' : 'Load'),
        ),
      ),
      if (controller.loading) const LinearProgressIndicator(),
    ],
  );
}

class _StatsBar extends StatelessWidget {
  const _StatsBar(this.stats);

  final String stats;

  @override
  Widget build(BuildContext context) =>
      Text(stats, style: Theme.of(context).textTheme.labelLarge);
}

class _SettingsPanel extends StatelessWidget {
  const _SettingsPanel(this.controller);

  final PlaygroundController controller;

  @override
  Widget build(BuildContext context) {
    final supportsSystemPrompt =
        !controller.ready || controller.supportsMultiTurn;
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      title: const Text('Settings'),
      children: [
        Text('Temperature ${controller.temperature.toStringAsFixed(1)}'),
        Slider(
          value: controller.temperature,
          max: 1.5,
          divisions: 15,
          label: controller.temperature.toStringAsFixed(1),
          onChanged: controller.busy ? null : controller.setTemperature,
        ),
        Text('Max tokens ${controller.maxTokens}'),
        Slider(
          value: controller.maxTokens.toDouble(),
          min: 64,
          max: 512,
          divisions: 7,
          label: controller.maxTokens.toString(),
          onChanged: controller.busy ? null : controller.setMaxTokens,
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: TextFormField(
            initialValue: controller.systemPrompt,
            enabled: !controller.busy && supportsSystemPrompt,
            maxLines: 2,
            decoration: InputDecoration(
              labelText: 'System prompt',
              helperText: supportsSystemPrompt
                  ? null
                  : 'This runtime does not accept system prompts.',
            ),
            onChanged: controller.setSystemPrompt,
          ),
        ),
      ],
    );
  }
}

const _presets = {
  'Summarize':
      'Summarize how WebGPU speeds up browser AI in 3 short bullet points.',
  'Translate':
      'Translate to Spanish and French: '
      '"Local AI runs privately in your browser."',
  'Explain code':
      'Explain what this Dart line does: '
      'final nums = [1, 2, 3].map((n) => n * 2).toList();',
  'Brainstorm': 'Give 3 concise app ideas that use an offline LLM on a phone.',
};

class _PresetChips extends StatelessWidget {
  const _PresetChips({required this.onSelected});

  final ValueChanged<String>? onSelected;

  @override
  Widget build(BuildContext context) {
    final select = onSelected;
    return Wrap(
      spacing: 8,
      children: [
        for (final preset in _presets.entries)
          ActionChip(
            label: Text(preset.key),
            onPressed: select == null ? null : () => select(preset.value),
          ),
      ],
    );
  }
}

class _TranscriptList extends StatelessWidget {
  const _TranscriptList(this.messages);

  final List<ChatTurn> messages;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SelectionArea(
      child: Column(
        children: [
          for (final message in messages)
            Align(
              alignment: message.role == Role.user
                  ? Alignment.centerRight
                  : Alignment.centerLeft,
              child: Card(
                color: message.role == Role.user
                    ? colors.primaryContainer
                    : colors.surfaceContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        message.role == Role.user ? 'You' : 'Assistant',
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                      Text(message.text),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ComposerBar extends StatelessWidget {
  const _ComposerBar(this.controller, this.promptFocus, this.onSend);

  final PlaygroundController controller;
  final FocusNode promptFocus;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller.prompt,
                  focusNode: promptFocus,
                  decoration: const InputDecoration(labelText: 'Prompt'),
                  maxLines: 3,
                  minLines: 1,
                ),
              ),
              const SizedBox(width: 8),
              ValueListenableBuilder(
                valueListenable: controller.prompt,
                builder: (_, prompt, _) => FilledButton(
                  onPressed: controller.generating
                      ? controller.stop
                      : controller.ready &&
                            !controller.loading &&
                            prompt.text.trim().isNotEmpty
                      ? onSend
                      : null,
                  child: Text(controller.generating ? 'Stop' : 'Send'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Semantics(
            liveRegion: true,
            label: controller.status,
            excludeSemantics: true,
            child: Text(controller.status),
          ),
        ],
      ),
    ),
  );
}
