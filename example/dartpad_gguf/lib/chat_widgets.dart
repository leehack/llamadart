import 'package:llamadart/llamadart.dart';
import 'package:material_ui/material_ui.dart';

import 'chat_controller.dart';

class StatsBar extends StatelessWidget {
  const StatsBar({super.key, required this.stats, required this.generating});

  final ChatStats stats;
  final bool generating;

  @override
  Widget build(BuildContext context) {
    final backend = stats.backendName;
    if (backend == null) return const SizedBox.shrink();

    final elapsed = stats.elapsed;
    final tokens = stats.outputTokens;
    final rate = stats.tokensPerSecond;
    final text = [
      if (generating) 'Streaming…',
      if (tokens != null) '$tokens tok',
      if (rate != null) '${rate.toStringAsFixed(1)} tok/s',
      if (tokens == null && elapsed != null)
        '${(elapsed.inMilliseconds / 1000).toStringAsFixed(1)}s',
      backend,
    ].join(' · ');
    return Text(text, style: Theme.of(context).textTheme.bodySmall);
  }
}

class SettingsPanel extends StatelessWidget {
  const SettingsPanel({super.key, required this.chat});

  final ChatController chat;

  @override
  Widget build(BuildContext context) {
    final settings = chat.settings;
    final temperature = settings.temperature.toStringAsFixed(1);
    final maxTokens = settings.maxTokens;
    return ExpansionTile(
      title: const Text('Settings'),
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 12),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Temperature: $temperature'),
        Slider(
          value: settings.temperature,
          min: 0,
          max: 1.5,
          divisions: 15,
          label: temperature,
          onChanged: (value) => chat.updateSettings(temperature: value),
        ),
        Text('Max tokens: $maxTokens'),
        Slider(
          value: maxTokens.toDouble(),
          min: 64,
          max: 512,
          divisions: 7,
          label: '$maxTokens',
          onChanged: (value) => chat.updateSettings(maxTokens: value.round()),
        ),
        TextFormField(
          initialValue: settings.systemPrompt,
          maxLines: 2,
          decoration: const InputDecoration(
            labelText: 'System prompt',
            border: OutlineInputBorder(),
          ),
          onChanged: (value) => chat.updateSettings(systemPrompt: value),
        ),
      ],
    );
  }
}

class PresetChips extends StatelessWidget {
  const PresetChips({super.key, required this.onSelect});

  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        for (final preset in chatPresets)
          ActionChip(
            label: Text(preset.label),
            onPressed: () => onSelect(preset.prompt),
          ),
      ],
    );
  }
}

class TranscriptList extends StatelessWidget {
  const TranscriptList({super.key, required this.messages});

  final List<ChatMessage> messages;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        for (final message in messages)
          Align(
            alignment: message.role == LlamaChatRole.user
                ? AlignmentDirectional.centerEnd
                : AlignmentDirectional.centerStart,
            child: Card(
              color: message.role == LlamaChatRole.user
                  ? theme.colorScheme.primaryContainer
                  : theme.colorScheme.surfaceContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      message.role == LlamaChatRole.user ? 'You' : 'Assistant',
                      style: theme.textTheme.labelMedium,
                    ),
                    SelectableText(message.text),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class ComposerBar extends StatelessWidget {
  const ComposerBar({
    super.key,
    required this.chat,
    required this.prompt,
    required this.promptFocus,
    required this.onSend,
  });

  final ChatController chat;
  final TextEditingController prompt;
  final FocusNode promptFocus;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: prompt,
                  focusNode: promptFocus,
                  minLines: 1,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Prompt',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ValueListenableBuilder(
                valueListenable: prompt,
                builder: (context, value, _) {
                  final canSend = chat.ready && value.text.trim().isNotEmpty;
                  return FilledButton(
                    onPressed: chat.generating
                        ? chat.stop
                        : (canSend ? onSend : null),
                    child: Text(chat.generating ? 'Stop' : 'Send'),
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 4),
          Semantics(liveRegion: true, child: Text(chat.status)),
        ],
      ),
    );
  }
}
