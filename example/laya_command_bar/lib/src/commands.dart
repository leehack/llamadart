import 'intents.dart';
import 'slots.dart';

/// Something a command did, for the activity list.
class Activity {
  /// Creates an entry.
  const Activity(this.intent, this.title, this.detail);

  /// What kind of command it was.
  final CommandIntent intent;

  /// Main line.
  final String title;

  /// Second line.
  final String detail;
}

final _taskLead = RegExp(
  r'^(?:add\s+(?:to\s+(?:my\s+)?(?:list|to-?dos?)\s*)?:?|to-?do:?|(?:i\s+)?need\s+to)\s*',
  caseSensitive: false,
);
final _reminderLead = RegExp(
  r"^(?:remind\s+me\s*(?:to|about|that)?|don't\s+let\s+me\s+forget\s*(?:to|about)?|"
  r'alert\s+me\s*(?:when\s+it\s+is|about|to)?|wake\s+me\s+up|set\s+an?\s+(?:alarm|timer))\s*',
  caseSensitive: false,
);
final _eventLead = RegExp(
  r'^(?:schedule|book|create|add|block|set\s+up)\s+(?:an?\s+|my\s+)?',
  caseSensitive: false,
);

/// The activity that running [text] as [intent] records, using [slots] for
/// the details. Search and calculate record nothing they cannot show: a
/// calculation without a value returns null.
Activity? activityFor(CommandIntent intent, String text, CommandSlots slots) {
  final when = [?slots.day, ?slots.time?.label].join(' · ');
  switch (intent) {
    case CommandIntent.task:
      return Activity(
        intent,
        _title(text.replaceFirst(_taskLead, '')),
        'Added to your list',
      );
    case CommandIntent.reminder:
      final what = _title(stripWhen(text).replaceFirst(_reminderLead, ''));
      return Activity(
        intent,
        what.isEmpty ? 'Reminder' : what,
        when.isEmpty ? 'No time set' : when,
      );
    case CommandIntent.event:
      return Activity(
        intent,
        _title(stripWhen(text).replaceFirst(_eventLead, '')),
        when.isEmpty ? 'No time set' : when,
      );
    case CommandIntent.message:
      return Activity(
        intent,
        'To ${slots.person ?? 'someone'}',
        messageBody(text) ?? text,
      );
    case CommandIntent.calculate:
      final value = slots.value;
      return value == null
          ? null
          : Activity(intent, text.trim(), '= ${value.label}');
    case CommandIntent.search:
      return Activity(intent, text.trim(), 'Searched');
    case CommandIntent.ask:
      return Activity(intent, text.trim(), 'Sent to the assistant');
    case CommandIntent.settings:
      final change = slots.setting;
      return change == null
          ? null
          : Activity(
              intent,
              change.setting.title,
              change.on ? 'Turned on' : 'Turned off',
            );
  }
}

String _title(String s) {
  final t = s.trim();
  return t.isEmpty ? t : '${t[0].toUpperCase()}${t.substring(1)}';
}
