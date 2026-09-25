import 'package:flutter/material.dart';

import '../intents.dart';
import '../slots.dart';

/// Icon of each intent.
IconData intentIcon(CommandIntent intent) => switch (intent) {
  CommandIntent.search => Icons.search,
  CommandIntent.task => Icons.check_box_outlined,
  CommandIntent.event => Icons.event_outlined,
  CommandIntent.reminder => Icons.notifications_none,
  CommandIntent.message => Icons.chat_bubble_outline,
  CommandIntent.calculate => Icons.calculate_outlined,
  CommandIntent.ask => Icons.auto_awesome_outlined,
  CommandIntent.settings => Icons.tune,
};

/// Files and notes the search panel finds, besides the activity list.
const List<String> sampleLibrary = [
  'Q3 budget notes',
  'Passport scan.pdf',
  'Lisbon trip photos',
  'Wifi password',
  'Invoice March.pdf',
  'Lease agreement.pdf',
  'Recipe: pancakes',
  'Design team sync notes',
];

/// What the bar shows below the text for [intent].
class IntentPanel extends StatelessWidget {
  /// Creates a panel.
  const IntentPanel({
    super.key,
    required this.intent,
    required this.text,
    required this.slots,
    required this.searchable,
    required this.settings,
    required this.onRun,
    required this.onSetting,
  });

  /// The shown intent.
  final CommandIntent intent;

  /// The typed text.
  final String text;

  /// Details parsed from [text].
  final CommandSlots slots;

  /// Titles the search panel matches.
  final List<String> searchable;

  /// Current app settings.
  final Map<AppSetting, bool> settings;

  /// Runs the command, as Enter does.
  final VoidCallback onRun;

  /// Changes one setting.
  final void Function(AppSetting setting, bool on) onSetting;

  @override
  Widget build(BuildContext context) {
    final body = switch (intent) {
      CommandIntent.reminder => _chips(context, [
        _timeChip(context),
        _dayChip(context),
        if (slots.person != null)
          _chip(context, Icons.person_outline, slots.person!),
      ], 'Set reminder'),
      CommandIntent.event => _chips(context, [
        _dayChip(context),
        _timeChip(context),
        if (slots.person != null)
          _chip(context, Icons.person_outline, slots.person!),
      ], 'Create event'),
      CommandIntent.message => _chips(context, [
        slots.person == null
            ? _chip(context, Icons.person_add_alt, 'Add recipient', muted: true)
            : _chip(context, Icons.person_outline, slots.person!),
        if (messageBody(text) case final body?)
          _chip(context, Icons.format_quote, body),
      ], 'Send'),
      CommandIntent.calculate => _calculation(context),
      CommandIntent.search => _search(context),
      CommandIntent.task => _chips(context, [
        _chip(context, Icons.check_box_outline_blank, text.trim()),
      ], 'Add task'),
      CommandIntent.ask => _chips(context, [
        Text(
          'A chat model would answer this; the demo stops at routing.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ], 'Send to assistant'),
      CommandIntent.settings => _settings(context),
    };
    return Material(
      type: MaterialType.transparency,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        child: body,
      ),
    );
  }

  Widget _chips(BuildContext context, List<Widget> chips, String action) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(child: Wrap(spacing: 8, runSpacing: 8, children: chips)),
        const SizedBox(width: 12),
        FilledButton.tonalIcon(
          onPressed: onRun,
          icon: Icon(intentIcon(intent), size: 18),
          label: Text(action),
        ),
      ],
    );
  }

  Widget _chip(
    BuildContext context,
    IconData icon,
    String label, {
    bool muted = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Chip(
      avatar: Icon(icon, size: 16),
      label: Text(label, overflow: TextOverflow.ellipsis),
      visualDensity: VisualDensity.compact,
      backgroundColor: muted ? null : scheme.secondaryContainer,
      side: muted ? null : BorderSide.none,
    );
  }

  Widget _timeChip(BuildContext context) => slots.time == null
      ? _chip(context, Icons.schedule, 'Add time', muted: true)
      : _chip(
          context,
          slots.time!.isDuration ? Icons.timer_outlined : Icons.schedule,
          slots.time!.label,
        );

  Widget _dayChip(BuildContext context) => slots.day == null
      ? _chip(context, Icons.calendar_today_outlined, 'Today', muted: true)
      : _chip(context, Icons.calendar_today_outlined, slots.day!);

  Widget _calculation(BuildContext context) {
    final value = slots.value;
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 120),
            child: Text(
              value == null ? 'Keep typing an expression' : '= ${value.label}',
              key: ValueKey(value?.label),
              style: value == null
                  ? theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    )
                  : theme.textTheme.headlineSmall,
            ),
          ),
        ),
        if (value != null)
          FilledButton.tonalIcon(
            onPressed: onRun,
            icon: const Icon(Icons.calculate_outlined, size: 18),
            label: const Text('Keep'),
          ),
      ],
    );
  }

  Widget _search(BuildContext context) {
    final words = text
        .toLowerCase()
        .split(RegExp(r'\W+'))
        .where((w) => w.length > 2 && !_stopWords.contains(w))
        .toList();
    final hits = [
      for (final title in searchable)
        if (words.any(title.toLowerCase().contains)) title,
    ].take(4).toList();
    if (hits.isEmpty) {
      return Text(
        'No matches yet',
        style: Theme.of(context).textTheme.bodySmall,
      );
    }
    return Column(
      children: [
        for (final hit in hits)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.description_outlined, size: 20),
            title: Text(hit),
            onTap: onRun,
          ),
      ],
    );
  }

  Widget _settings(BuildContext context) {
    final change = slots.setting;
    final shown = change == null ? AppSetting.values : [change.setting];
    return Column(
      children: [
        for (final setting in shown)
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.tune, size: 20),
            title: Text(setting.title),
            subtitle: change == null
                ? null
                : Text('Enter turns it ${change.on ? 'on' : 'off'}'),
            value: settings[setting] ?? false,
            onChanged: (on) => onSetting(setting, on),
          ),
      ],
    );
  }
}

const _stopWords = {
  'find',
  'show',
  'search',
  'look',
  'the',
  'my',
  'about',
  'for',
  'from',
  'where',
  'did',
  'save',
  'files',
  'notes',
  'tagged',
};
