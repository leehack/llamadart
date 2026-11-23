import 'package:flutter/foundation.dart';
import 'package:llamadart/llamadart.dart';
import 'package:material_ui/material_ui.dart';

import 'chat_controller.dart';

class ModelPicker extends StatelessWidget {
  const ModelPicker({
    super.key,
    required this.selected,
    required this.enabled,
    required this.showWarning,
    required this.onSelected,
  });

  final GgufModelOption selected;
  final bool enabled;
  final bool showWarning;
  final ValueChanged<GgufModelOption> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final warning = selected.warning;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InputDecorator(
          decoration: InputDecoration(
            labelText: 'Model',
            border: const OutlineInputBorder(),
            enabled: enabled,
            isDense: true,
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<GgufModelOption>(
              value: selected,
              isExpanded: true,
              isDense: true,
              items: [
                for (final model in ggufModels)
                  DropdownMenuItem(
                    value: model,
                    child: Text(
                      '${model.label} (${model.sizeLabel})',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: enabled
                  ? (model) {
                      if (model != null) onSelected(model);
                    }
                  : null,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(selected.note, style: theme.textTheme.bodySmall),
        if (showWarning && warning != null) ...[
          const SizedBox(height: 8),
          DecoratedBox(
            decoration: BoxDecoration(
              color: theme.colorScheme.tertiaryContainer,
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
                    color: theme.colorScheme.onTertiaryContainer,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      warning,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onTertiaryContainer,
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

class StatsBar extends StatelessWidget {
  const StatsBar({super.key, required this.stats, required this.generating});

  final ValueListenable<ChatStats> stats;
  final bool generating;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ChatStats>(
      valueListenable: stats,
      builder: (context, value, _) {
        final backend = value.backendName;
        if (backend == null) return const SizedBox.shrink();

        final elapsed = value.elapsed;
        final tokens = value.outputTokens;
        final rate = value.tokensPerSecond;
        final text = [
          if (generating) 'Streaming…',
          if (tokens != null) '$tokens tok',
          if (rate != null) '${rate.toStringAsFixed(1)} tok/s',
          if (tokens == null && elapsed != null)
            '${(elapsed.inMilliseconds / 1000).toStringAsFixed(1)}s',
          backend,
        ].join(' · ');
        return Text(text, style: Theme.of(context).textTheme.bodySmall);
      },
    );
  }
}

class SettingsPanel extends StatelessWidget {
  const SettingsPanel({super.key, required this.chat, required this.enabled});

  final ChatController chat;
  final bool enabled;

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
        MergeSemantics(
          child: Semantics(
            label: 'Temperature',
            child: Slider(
              value: settings.temperature,
              min: 0,
              max: 1.5,
              divisions: 15,
              label: temperature,
              semanticFormatterCallback: (value) => value.toStringAsFixed(1),
              onChanged: enabled
                  ? (value) => chat.updateSettings(temperature: value)
                  : null,
            ),
          ),
        ),
        Text('Max tokens: $maxTokens'),
        MergeSemantics(
          child: Semantics(
            label: 'Max tokens',
            child: Slider(
              value: maxTokens.toDouble(),
              min: 64,
              max: 512,
              divisions: 7,
              label: '$maxTokens',
              semanticFormatterCallback: (value) => '${value.round()} tokens',
              onChanged: enabled
                  ? (value) => chat.updateSettings(maxTokens: value.round())
                  : null,
            ),
          ),
        ),
        TextFormField(
          initialValue: settings.systemPrompt,
          enabled: enabled,
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
  const TranscriptList({
    super.key,
    required this.messages,
    required this.streamingText,
  });

  final List<ChatMessage> messages;
  final ValueListenable<String?> streamingText;

  @override
  Widget build(BuildContext context) {
    return SelectionArea(
      child: Column(
        children: [
          for (final message in messages) _MessageBubble(message: message),
          ValueListenableBuilder<String?>(
            valueListenable: streamingText,
            builder: (context, text, _) {
              if (text == null) return const SizedBox.shrink();
              return _MessageBubble(
                message: ChatMessage(LlamaChatRole.assistant, text),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUser = message.role == LlamaChatRole.user;
    final foreground = isUser
        ? theme.colorScheme.onPrimaryContainer
        : theme.colorScheme.onSurface;
    return Align(
      alignment: isUser
          ? AlignmentDirectional.centerEnd
          : AlignmentDirectional.centerStart,
      child: Card(
        color: isUser
            ? theme.colorScheme.primaryContainer
            : theme.colorScheme.surfaceContainer,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isUser ? 'You' : 'Assistant',
                style: theme.textTheme.labelMedium?.copyWith(color: foreground),
              ),
              Text(
                message.text,
                style: theme.textTheme.bodyMedium?.copyWith(color: foreground),
              ),
            ],
          ),
        ),
      ),
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
          ValueListenableBuilder<String>(
            valueListenable: chat.status,
            builder: (context, status, _) =>
                Semantics(liveRegion: true, child: Text(status)),
          ),
        ],
      ),
    );
  }
}
