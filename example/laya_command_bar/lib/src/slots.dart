/// Rule-based details of a command: times, days, people and numbers. Laya
/// only picks the intent; these parsers fill in the controls it shows.
library;

/// A time of day or a duration from now.
class TimeSlot {
  /// Creates a slot.
  const TimeSlot(this.label, {this.isDuration = false});

  /// Display text, such as `7:00`, `6:30 PM` or `in 10 min`.
  final String label;

  /// Whether this is a duration from now rather than a clock time.
  final bool isDuration;
}

/// The details of [text] that the command bar shows.
class CommandSlots {
  /// Parses [text].
  factory CommandSlots.parse(String text) => CommandSlots._(
    time: parseTime(text),
    day: parseDay(text),
    person: parsePerson(text),
    value: evaluate(text),
    setting: parseSetting(text),
  );

  const CommandSlots._({
    this.time,
    this.day,
    this.person,
    this.value,
    this.setting,
  });

  /// A mentioned time, if any.
  final TimeSlot? time;

  /// A mentioned day, if any.
  final String? day;

  /// A mentioned person, if any.
  final String? person;

  /// The value of the text as arithmetic or a unit conversion, if it is one.
  final Computed? value;

  /// A recognized setting change, if any.
  final SettingChange? setting;
}

const _numberWords = {
  'a': 1,
  'an': 1,
  'one': 1,
  'two': 2,
  'three': 3,
  'four': 4,
  'five': 5,
  'ten': 10,
  'fifteen': 15,
  'twenty': 20,
  'thirty': 30,
};

final _duration = RegExp(
  r'\b(?:in|for|after)\s+(\d+|a|an|one|two|three|four|five|ten|fifteen|twenty|thirty)\s*'
  r'(seconds?|secs?|minutes?|mins?|hours?|hrs?)\b',
  caseSensitive: false,
);
final _timer = RegExp(
  r'\b(\d+)\s*(seconds?|secs?|minutes?|mins?|hours?|hrs?)\b',
  caseSensitive: false,
);
final _clock = RegExp(
  r'\b(?:(at)\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)?(?![\w:%.])',
  caseSensitive: false,
);
final _namedTime = RegExp(r'\b(noon|midnight)\b', caseSensitive: false);

/// A clock time such as `at 7`, `6:30` or `9pm`, a named time such as `noon`,
/// or a duration such as `in 10 minutes` or `timer 5 min`.
TimeSlot? parseTime(String text) {
  final named = _namedTime.firstMatch(text);
  if (named != null) {
    return TimeSlot(
      named[1]!.toLowerCase() == 'noon' ? '12:00 PM' : '12:00 AM',
    );
  }
  final duration = _duration.firstMatch(text) ?? _timerMatch(text);
  if (duration != null) {
    final amount =
        int.tryParse(duration[1]!) ?? _numberWords[duration[1]!.toLowerCase()]!;
    return TimeSlot('in $amount ${_unit(duration[2]!)}', isDuration: true);
  }
  for (final m in _clock.allMatches(text)) {
    final hour = int.parse(m[2]!);
    final minutes = m[3];
    final meridiem = m[4]?.replaceAll('.', '').toUpperCase();
    final hasAt = m[1] != null;
    if (!hasAt && minutes == null && meridiem == null) continue;
    if (hour > 23 || (meridiem != null && (hour < 1 || hour > 12))) continue;
    if (minutes != null && int.parse(minutes) > 59) continue;
    final label = '$hour:${minutes ?? '00'}';
    return TimeSlot(meridiem == null ? label : '$label $meridiem');
  }
  return null;
}

RegExpMatch? _timerMatch(String text) =>
    RegExp(r'\b(timer|alarm)\b', caseSensitive: false).hasMatch(text)
    ? _timer.firstMatch(text)
    : null;

String _unit(String unit) {
  final u = unit.toLowerCase();
  if (u.startsWith('s')) return 'sec';
  if (u.startsWith('m')) return 'min';
  return u.startsWith('hour') || u.startsWith('hr') ? 'h' : u;
}

const _weekdays = [
  'monday',
  'tuesday',
  'wednesday',
  'thursday',
  'friday',
  'saturday',
  'sunday',
];
const _months = [
  'january',
  'february',
  'march',
  'april',
  'may',
  'june',
  'july',
  'august',
  'september',
  'october',
  'november',
  'december',
];

final _relativeDay = RegExp(
  r'\b(today|tonight|tomorrow|this weekend|next week)\b',
  caseSensitive: false,
);
final _weekday = RegExp(
  r'\b(next\s+|this\s+)?(mon|tue|tues|wed|thu|thur|thurs|fri|sat|sun)'
  r'(?:day|nesday|sday|urday|rsday)?\b',
  caseSensitive: false,
);
final _ordinalDay = RegExp(
  r'\bon the (\d{1,2})(?:st|nd|rd|th)\b',
  caseSensitive: false,
);
final _monthDay = RegExp(
  r'\b(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?\s+(\d{1,2})\b',
  caseSensitive: false,
);

/// A day such as `tomorrow`, `next Tuesday`, `on the 1st` or `June 12`.
String? parseDay(String text) {
  final relative = _relativeDay.firstMatch(text);
  if (relative != null) return _capitalize(relative[1]!.toLowerCase());
  final monthDay = _monthDay.firstMatch(text);
  if (monthDay != null) {
    final prefix = monthDay[1]!.toLowerCase();
    final month = _months.firstWhere((m) => m.startsWith(prefix));
    return '${_capitalize(month).substring(0, 3)} ${monthDay[2]}';
  }
  final weekday = _weekday.firstMatch(text);
  if (weekday != null) {
    final prefix = weekday[2]!.toLowerCase();
    final day = _weekdays.firstWhere((d) => d.startsWith(prefix));
    final next = weekday[1]?.trim().toLowerCase() == 'next' ? 'Next ' : '';
    return '$next${_capitalize(day).substring(0, 3)}';
  }
  final ordinal = _ordinalDay.firstMatch(text);
  if (ordinal != null) return 'Day ${ordinal[1]}';
  return null;
}

const _relations = {
  'mom',
  'mum',
  'dad',
  'mother',
  'father',
  'wife',
  'husband',
  'sister',
  'brother',
  'boss',
  'grandma',
  'grandpa',
};
const _notNames = {
  'me',
  'my',
  'the',
  'a',
  'an',
  'that',
  'it',
  'i',
  'to',
  'about',
  'back',
  'up',
};

final _recipientVerb = RegExp(
  r'\b(?:text|tell|email|e-mail|message|msg|ping|call|reply to|send)\s+'
  r"((?:the|my)\s+)?([A-Za-z][\w'-]*)",
  caseSensitive: false,
);
final _withPerson = RegExp(
  r"\bwith\s+((?:the|my)\s+)?([A-Za-z][\w'-]*)",
  caseSensitive: false,
);

/// The person a command names: the word after `text`, `tell`, `email`,
/// `call` and similar verbs, or a name or relation after `with`, such as
/// `Sam`, `Mom` or `the landlord`.
String? parsePerson(String text) {
  for (final pattern in [_recipientVerb, _withPerson]) {
    for (final m in pattern.allMatches(text)) {
      final article = m[1]?.trim().toLowerCase();
      final word = m[2]!;
      final lower = word.toLowerCase();
      if (_notNames.contains(lower)) continue;
      final isName = word[0] == word[0].toUpperCase();
      if (pattern == _withPerson &&
          article == null &&
          !isName &&
          !_relations.contains(lower)) {
        continue;
      }
      if (article != null && !_relations.contains(lower)) {
        return 'the $lower';
      }
      return _capitalize(lower);
    }
  }
  return null;
}

/// A computed value and how it reads.
class Computed {
  /// Creates a value.
  const Computed(this.value, {this.unit = ''});

  /// The number.
  final double value;

  /// Unit of [value], or empty.
  final String unit;

  /// [value] with up to four decimals and no trailing zeros, then [unit].
  String get label {
    var s = value.toStringAsFixed(4);
    s = s.replaceFirst(RegExp(r'\.?0+$'), '');
    if (s == '-0') s = '0';
    return unit.isEmpty ? s : '$s $unit';
  }
}

final _percentOf = RegExp(
  r'^(-?\d+(?:\.\d+)?)\s*%\s*of\s+(-?\d+(?:\.\d+)?)$',
  caseSensitive: false,
);
final _conversion = RegExp(
  r'^(?:convert\s+)?(-?\d+(?:\.\d+)?)\s*([a-z°]+)\s+(?:to|in|into)\s+([a-z°]+)$',
  caseSensitive: false,
);
final _calcPrefix = RegExp(
  r"^(?:what(?:'s| is)|calculate|calc|compute|how much is)\s+",
  caseSensitive: false,
);

/// The value of [text] as arithmetic (`3.5 * 18 + 7`, `what is 12 * 9`),
/// a percentage (`15% of 240`) or a length, weight or temperature
/// conversion (`convert 5 miles to km`), or null.
Computed? evaluate(String text) {
  var s = text.trim().replaceAll(RegExp(r'[?=]+$'), '').trim();
  s = s.replaceFirst(_calcPrefix, '');
  if (s.isEmpty) return null;
  final percent = _percentOf.firstMatch(s);
  if (percent != null) {
    return Computed(
      double.parse(percent[1]!) / 100 * double.parse(percent[2]!),
    );
  }
  final conversion = _conversion.firstMatch(s);
  if (conversion != null) {
    return _convert(
      double.parse(conversion[1]!),
      conversion[2]!.toLowerCase(),
      conversion[3]!.toLowerCase(),
    );
  }
  if (!RegExp(r'\d').hasMatch(s) || !RegExp(r'[-+*/x×÷^]').hasMatch(s)) {
    return null;
  }
  final value = _Arithmetic(s).parse();
  return value == null || value.isNaN || value.isInfinite
      ? null
      : Computed(value);
}

const _units = <String, (String, String, double)>{
  'km': ('length', 'km', 1000),
  'kilometer': ('length', 'km', 1000),
  'kilometers': ('length', 'km', 1000),
  'm': ('length', 'm', 1),
  'meter': ('length', 'm', 1),
  'meters': ('length', 'm', 1),
  'cm': ('length', 'cm', 0.01),
  'mi': ('length', 'mi', 1609.344),
  'mile': ('length', 'mi', 1609.344),
  'miles': ('length', 'mi', 1609.344),
  'ft': ('length', 'ft', 0.3048),
  'feet': ('length', 'ft', 0.3048),
  'foot': ('length', 'ft', 0.3048),
  'in': ('length', 'in', 0.0254),
  'inch': ('length', 'in', 0.0254),
  'inches': ('length', 'in', 0.0254),
  'kg': ('mass', 'kg', 1),
  'kilograms': ('mass', 'kg', 1),
  'g': ('mass', 'g', 0.001),
  'grams': ('mass', 'g', 0.001),
  'lb': ('mass', 'lb', 0.45359237),
  'lbs': ('mass', 'lb', 0.45359237),
  'pounds': ('mass', 'lb', 0.45359237),
  'oz': ('mass', 'oz', 0.028349523125),
  'ounces': ('mass', 'oz', 0.028349523125),
  'c': ('temperature', '°C', 0),
  '°c': ('temperature', '°C', 0),
  'celsius': ('temperature', '°C', 0),
  'f': ('temperature', '°F', 0),
  '°f': ('temperature', '°F', 0),
  'fahrenheit': ('temperature', '°F', 0),
};

Computed? _convert(double amount, String from, String to) {
  final a = _units[from];
  final b = _units[to];
  if (a == null || b == null || a.$1 != b.$1) return null;
  if (a.$1 == 'temperature') {
    if (a.$2 == b.$2) return Computed(amount, unit: b.$2);
    final value = a.$2 == '°C' ? amount * 9 / 5 + 32 : (amount - 32) * 5 / 9;
    return Computed(value, unit: b.$2);
  }
  return Computed(amount * a.$3 / b.$3, unit: b.$2);
}

/// Recursive-descent arithmetic over `+ - * / ^`, `x`, `×`, `÷` and
/// parentheses. Anything else fails the parse.
class _Arithmetic {
  _Arithmetic(String source)
    : _s = source
          .replaceAll('×', '*')
          .replaceAll('÷', '/')
          .replaceAll(RegExp(r'(?<=[\d)])\s*x\s*(?=[\d(])'), '*')
          .replaceAll(' ', '');

  final String _s;
  int _i = 0;

  double? parse() {
    try {
      final value = _sum();
      return _i == _s.length ? value : null;
    } on FormatException {
      return null;
    }
  }

  double _sum() {
    var value = _product();
    while (_i < _s.length && (_s[_i] == '+' || _s[_i] == '-')) {
      final op = _s[_i++];
      final rhs = _product();
      value = op == '+' ? value + rhs : value - rhs;
    }
    return value;
  }

  double _product() {
    var value = _power();
    while (_i < _s.length && (_s[_i] == '*' || _s[_i] == '/')) {
      final op = _s[_i++];
      final rhs = _power();
      value = op == '*' ? value * rhs : value / rhs;
    }
    return value;
  }

  double _power() {
    final base = _unary();
    if (_i < _s.length && _s[_i] == '^') {
      _i++;
      return _pow(base, _power());
    }
    return base;
  }

  double _unary() {
    if (_i < _s.length && _s[_i] == '-') {
      _i++;
      return -_unary();
    }
    return _atom();
  }

  double _atom() {
    if (_i < _s.length && _s[_i] == '(') {
      _i++;
      final value = _sum();
      if (_i >= _s.length || _s[_i] != ')') throw const FormatException();
      _i++;
      return value;
    }
    final m = RegExp(r'\d+(?:\.\d+)?').matchAsPrefix(_s, _i);
    if (m == null) throw const FormatException();
    _i = m.end;
    return double.parse(m[0]!);
  }

  static double _pow(double base, double exponent) {
    if (exponent == exponent.roundToDouble() && exponent.abs() <= 64) {
      var result = 1.0;
      for (var n = 0; n < exponent.abs(); n++) {
        result *= base;
      }
      return exponent < 0 ? 1 / result : result;
    }
    throw const FormatException();
  }
}

/// App settings the command bar can change.
enum AppSetting {
  /// Dark theme.
  darkMode('Dark mode'),

  /// Larger text.
  largeText('Large text'),

  /// Sounds.
  sounds('Sounds'),

  /// Notifications.
  notifications('Notifications');

  const AppSetting(this.title);

  /// Display name.
  final String title;
}

/// A setting and the value the text asks for.
typedef SettingChange = ({AppSetting setting, bool on});

final _off = RegExp(
  r'\b(off|disable|disabled|stop|mute|silence|no|light mode|smaller|shrink|decrease|reduce)\b',
  caseSensitive: false,
);

/// The setting [text] changes, such as `turn on dark mode` or `make the font
/// bigger`, or null.
SettingChange? parseSetting(String text) {
  final lower = text.toLowerCase();
  final AppSetting? setting;
  if (RegExp(
    r'\b(dark|light)\s*(mode|theme)\b|\bnight mode\b',
  ).hasMatch(lower)) {
    setting = AppSetting.darkMode;
  } else if (RegExp(r'\b(font|text)\b').hasMatch(lower)) {
    setting = AppSetting.largeText;
  } else if (RegExp(r'\b(sounds?|mute|unmute)\b').hasMatch(lower)) {
    setting = AppSetting.sounds;
  } else if (RegExp(r'\bnotifications?\b').hasMatch(lower)) {
    setting = AppSetting.notifications;
  } else {
    setting = null;
  }
  if (setting == null) return null;
  final on = lower.contains('unmute') || !_off.hasMatch(lower);
  return (setting: setting, on: on);
}

/// [text] without the times and days that [parseTime] and [parseDay] read,
/// and without a dangling `at`, `on`, `in` or `for`.
String stripWhen(String text) {
  var s = text;
  for (final pattern in [
    _duration,
    _namedTime,
    _relativeDay,
    _monthDay,
    _ordinalDay,
    RegExp(r'\b(?:on\s+)?' + _weekday.pattern, caseSensitive: false),
  ]) {
    s = s.replaceAll(pattern, ' ');
  }
  s = s.replaceAllMapped(_clock, (m) {
    final isTime = m[1] != null || m[3] != null || m[4] != null;
    return isTime ? ' ' : m[0]!;
  });
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return s.replaceFirst(
    RegExp(r'\s+(?:at|on|in|for|by)$', caseSensitive: false),
    '',
  );
}

/// The text after the person that [parsePerson] reads from a messaging
/// verb, without a leading `that` or colon, or null.
String? messageBody(String text) {
  final m = _recipientVerb.firstMatch(text);
  if (m == null) return null;
  final body = text
      .substring(m.end)
      .replaceFirst(RegExp(r'^[\s:,-]*(?:that\s+)?', caseSensitive: false), '')
      .trim();
  return body.isEmpty ? null : body;
}

String _capitalize(String s) =>
    s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';
