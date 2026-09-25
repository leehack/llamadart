import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../commands.dart';
import '../intent_gate.dart';
import '../intent_runner.dart';
import '../intents.dart';
import '../slots.dart';
import '../sources.dart';
import '../store.dart';
import 'panels.dart';

/// Commands the "Type it" chips type, one character at a time.
const List<String> sampleCommands = [
  'remind me to call mom at 7',
  'text sam I am here',
  'meeting with Bo friday',
  'what is 12 * 9',
  'find my notes about the Q3 budget',
  'turn on dark mode',
];

/// The command bar: the selected source reads the text on every change, and
/// the bar takes the shape of the intent once the [IntentGate] lets it.
class CommandBarPage extends StatefulWidget {
  /// Creates the page.
  const CommandBarPage({
    super.key,
    required this.sources,
    required this.settings,
    required this.onSetting,
    this.labels,
    this.typingInterval = const Duration(milliseconds: 55),
  });

  /// The sources the header switches between; the first loads at start.
  final List<SourceOption> sources;

  /// Current app settings.
  final Map<AppSetting, bool> settings;

  /// Changes one setting.
  final void Function(AppSetting setting, bool on) onSetting;

  /// Where run commands are logged, if anywhere.
  final LabelLog? labels;

  /// Delay between the characters that a sample chip types.
  final Duration typingInterval;

  @override
  State<CommandBarPage> createState() => _CommandBarPageState();
}

class _CommandBarPageState extends State<CommandBarPage> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  final _gate = IntentGate();

  int _selected = 0;
  IntentSource? _source;
  IntentRunner? _runner;
  String? _loadStatus;
  double? _loadFraction;
  String? _loadError;

  IntentReading? _reading;
  CommandSlots _slots = CommandSlots.parse('');
  String? _error;
  bool _needsPick = false;
  Timer? _typing;
  final List<Activity> _activity = [];

  @override
  void initState() {
    super.initState();
    _select(0);
  }

  @override
  void dispose() {
    _typing?.cancel();
    unawaited(_runner?.dispose());
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Switches to source [index], loading it on first use. The text stays,
  /// and the new source reads it.
  void _select(int index) {
    final old = _runner;
    setState(() {
      _selected = index;
      _source = null;
      _runner = null;
      _reading = null;
      _error = null;
      _loadError = null;
      _loadStatus = 'Loading ${widget.sources[index].name}';
      _loadFraction = null;
      _gate.forgetReadings();
    });
    unawaited(old?.dispose());
    unawaited(_load(index));
  }

  Future<void> _load(int index) async {
    final option = widget.sources[index];
    try {
      final source = await option.load((message, fraction) {
        if (mounted && _selected == index) {
          setState(() {
            _loadStatus = message;
            _loadFraction = fraction;
          });
        }
      });
      if (!mounted || _selected != index) return;
      final runner = IntentRunner(
        source.reader,
        onReading: _onReading,
        onError: _onError,
      );
      setState(() {
        _source = source;
        _runner = runner;
        _loadStatus = null;
        _gate
          ..enter = source.enter
          ..minWords = source.minWords;
      });
      runner.submit(_controller.text);
    } catch (e) {
      if (mounted && _selected == index) {
        setState(() {
          _loadStatus = null;
          _loadError = '$e';
        });
      }
    }
  }

  void _onChanged(String text) {
    setState(() {
      _slots = CommandSlots.parse(text);
      _needsPick = false;
      if (text.trim().isEmpty) {
        _gate.clear();
        _reading = null;
      }
    });
    _runner?.submit(text);
  }

  void _onUserChanged(String text) {
    _typing?.cancel();
    _onChanged(text);
  }

  void _onReading(IntentReading reading) {
    if (!mounted) return;
    setState(() {
      _error = null;
      _reading = reading;
      _gate.update(reading);
    });
  }

  void _onError(Object error) {
    if (mounted) setState(() => _error = '$error');
  }

  void _typeSample(String sample) {
    _typing?.cancel();
    _setText('');
    var n = 0;
    _typing = Timer.periodic(widget.typingInterval, (timer) {
      n++;
      _setText(sample.substring(0, n));
      if (n == sample.length) timer.cancel();
    });
    _refocus();
  }

  void _setText(String text) {
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _onChanged(text);
  }

  void _pin(CommandIntent intent) {
    setState(() {
      _gate.pin(_gate.pinned == intent ? null : intent);
      _needsPick = false;
    });
    _refocus();
  }

  void _run() {
    final text = _controller.text.trim();
    final intent = _gate.shown;
    if (text.isEmpty) return;
    if (intent == null) {
      setState(() => _needsPick = true);
      return;
    }
    final activity = activityFor(intent, text, _slots);
    if (activity == null) return;
    final change = _slots.setting;
    if (intent == CommandIntent.settings && change != null) {
      widget.onSetting(change.setting, change.on);
    }
    final reading = _reading;
    final picked = _gate.pinned != null;
    unawaited(
      widget.labels?.add({
        'text': text,
        'intent': intent.name,
        'source': picked ? 'picked' : 'reader',
        'reader': widget.sources[_selected].name,
        if (reading != null && reading.text == text) ...{
          'reader_top': reading.top.name,
          'reader_confidence': double.parse(
            reading.confidence.toStringAsFixed(4),
          ),
        },
      }),
    );
    if (picked) {
      for (final option in widget.sources) {
        final learn = option.loaded?.learn;
        if (learn != null) unawaited(learn(intent, text));
      }
    }
    _typing?.cancel();
    setState(() => _activity.insert(0, activity));
    _setText('');
    _refocus();
  }

  /// Focuses the bar with the caret at the end: focusing it again on desktop
  /// selects all of the text, which the next keystroke would replace.
  void _refocus() {
    _focus.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _controller.selection = TextSelection.collapsed(
        offset: _controller.text.length,
      );
    });
  }

  void _clear() {
    _typing?.cancel();
    _setText('');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shown = _gate.shown;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.escape): _clear,
              },
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
                children: [
                  _header(theme),
                  const SizedBox(height: 16),
                  _bar(theme, shown),
                  const SizedBox(height: 12),
                  _intentStrip(theme, shown),
                  const SizedBox(height: 12),
                  _samples(),
                  const SizedBox(height: 24),
                  ..._activityList(theme),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(ThemeData theme) {
    final reading = _reading;
    final runner = _runner;
    final source = _source;
    final stats = [
      widget.sources[_selected].detail,
      if (source != null) source.label,
      if (reading != null) '${reading.elapsed.inMilliseconds} ms per read',
      if (runner != null) '${runner.reads} reads',
      if (runner != null && runner.skipped > 0) '${runner.skipped} skipped',
    ].join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Laya command bar',
                style: theme.textTheme.titleLarge,
              ),
            ),
            IconButton(
              tooltip: 'Gate',
              icon: const Icon(Icons.speed),
              onPressed: _showGate,
            ),
          ],
        ),
        const SizedBox(height: 8),
        SegmentedButton<int>(
          showSelectedIcon: false,
          segments: [
            for (var i = 0; i < widget.sources.length; i++)
              ButtonSegment(value: i, label: Text(widget.sources[i].name)),
          ],
          selected: {_selected},
          onSelectionChanged: (s) {
            if (s.single != _selected) _select(s.single);
            _refocus();
          },
        ),
        const SizedBox(height: 6),
        Text(
          stats,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }

  Widget _bar(ThemeData theme, CommandIntent? shown) {
    final scheme = theme.colorScheme;
    final slots = _slots;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: shown == null ? scheme.outlineVariant : scheme.primary,
          width: shown == null ? 1 : 2,
        ),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
            child: Row(
              children: [
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 160),
                  transitionBuilder: (child, animation) =>
                      ScaleTransition(scale: animation, child: child),
                  child: Icon(
                    shown == null
                        ? Icons.keyboard_command_key
                        : intentIcon(shown),
                    key: ValueKey(shown),
                    color: shown == null
                        ? scheme.onSurfaceVariant
                        : scheme.primary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _controller,
                    focusNode: _focus,
                    autofocus: true,
                    onChanged: _onUserChanged,
                    onSubmitted: (_) {
                      _run();
                      _refocus();
                    },
                    style: theme.textTheme.titleMedium,
                    decoration: const InputDecoration(
                      hintText: 'Type a command',
                      border: InputBorder.none,
                    ),
                  ),
                ),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 160),
                  child: shown == null
                      ? const SizedBox.shrink()
                      : Padding(
                          key: ValueKey(shown),
                          padding: const EdgeInsets.only(left: 8),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (_gate.pinned != null)
                                Icon(
                                  Icons.push_pin,
                                  size: 14,
                                  color: scheme.primary,
                                ),
                              const SizedBox(width: 4),
                              Text(
                                shown.title,
                                style: theme.textTheme.labelLarge?.copyWith(
                                  color: scheme.primary,
                                ),
                              ),
                            ],
                          ),
                        ),
                ),
              ],
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              layoutBuilder: (current, previous) => Stack(
                alignment: Alignment.topCenter,
                children: [...previous, ?current],
              ),
              child: shown == null
                  ? const SizedBox(
                      key: ValueKey('plain'),
                      width: double.infinity,
                    )
                  : KeyedSubtree(
                      key: ValueKey(shown),
                      child: IntentPanel(
                        intent: shown,
                        text: _controller.text,
                        slots: slots,
                        searchable: [
                          ...sampleLibrary,
                          for (final a in _activity) a.title,
                        ],
                        settings: widget.settings,
                        onRun: _run,
                        onSetting: widget.onSetting,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _intentStrip(ThemeData theme, CommandIntent? shown) {
    final reading = _reading;
    final scheme = theme.colorScheme;
    final name = widget.sources[_selected].name;
    final String hint;
    if (_loadError != null) {
      hint = 'Could not load $name: $_loadError';
    } else if (_loadStatus != null) {
      hint = _loadStatus!;
    } else if (_error != null) {
      hint = '$name failed: $_error';
    } else if (_needsPick) {
      hint = 'Not sure what this is. Pick one, then press Enter.';
    } else if (reading == null) {
      hint = '$name reads every change and reshapes the bar when it is sure.';
    } else if (shown == null) {
      hint =
          'Not sure yet (confidence ${reading.confidence.toStringAsFixed(2)}). '
          'Keep typing or pick one.';
    } else if (_gate.pinned != null) {
      hint = 'You picked ${shown.title}. Tap it again to let $name decide.';
    } else {
      hint =
          'Confidence ${reading.confidence.toStringAsFixed(2)}. '
          'Enter runs it; Esc clears.';
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final intent in CommandIntent.values)
              _IntentChip(
                intent: intent,
                probability: reading?.probabilityOf(intent) ?? 0,
                selected: intent == shown,
                pinned: intent == _gate.pinned,
                highlight: _needsPick,
                onTap: () => _pin(intent),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (_loadStatus != null) ...[
          LinearProgressIndicator(value: _loadFraction),
          const SizedBox(height: 6),
        ],
        Row(
          children: [
            Expanded(
              child: Text(
                hint,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: _error != null || _needsPick || _loadError != null
                      ? scheme.error
                      : scheme.onSurfaceVariant,
                ),
              ),
            ),
            if (_loadError != null)
              TextButton(
                onPressed: () => _select(_selected),
                child: const Text('Retry'),
              ),
          ],
        ),
      ],
    );
  }

  Widget _samples() {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        const Text('Type it:'),
        for (final sample in sampleCommands)
          ActionChip(
            label: Text(sample),
            visualDensity: VisualDensity.compact,
            onPressed: () => _typeSample(sample),
          ),
      ],
    );
  }

  List<Widget> _activityList(ThemeData theme) {
    if (_activity.isEmpty) {
      return [
        Text(
          'Commands you run appear here.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ];
    }
    return [
      Text('Activity', style: theme.textTheme.titleSmall),
      for (final a in _activity)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(intentIcon(a.intent)),
          title: Text(a.title),
          subtitle: Text(a.detail),
        ),
    ];
  }

  Future<void> _showGate() async {
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Gate'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'The bar changes shape when '
                '${widget.sources[_selected].name}\'s confidence reaches '
                '${_gate.enter.toStringAsFixed(2)}.',
              ),
              Slider(
                value: _gate.enter,
                min: 0.2,
                max: 0.95,
                divisions: 15,
                label: _gate.enter.toStringAsFixed(2),
                onChanged: (v) {
                  setDialogState(() => _gate.enter = v);
                  setState(() {
                    final reading = _reading;
                    if (reading != null) _gate.update(reading);
                  });
                },
              ),
              if (widget.labels case final labels?)
                Text(
                  'Run commands are logged to ${labels.path}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }
}

class _IntentChip extends StatelessWidget {
  const _IntentChip({
    required this.intent,
    required this.probability,
    required this.selected,
    required this.pinned,
    required this.highlight,
    required this.onTap,
  });

  final CommandIntent intent;
  final double probability;
  final bool selected;
  final bool pinned;
  final bool highlight;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = selected ? scheme.onPrimaryContainer : scheme.onSurface;
    return Semantics(
      button: true,
      selected: selected,
      label: '${intent.title}, ${(probability * 100).round()} percent',
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: selected ? scheme.primaryContainer : scheme.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: highlight
                  ? scheme.error
                  : selected
                  ? scheme.primary
                  : scheme.outlineVariant,
            ),
          ),
          child: Stack(
            children: [
              Positioned.fill(
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(end: probability.clamp(0, 1)),
                    duration: const Duration(milliseconds: 150),
                    curve: Curves.easeOut,
                    builder: (context, value, _) => FractionallySizedBox(
                      widthFactor: value,
                      heightFactor: 1,
                      child: ColoredBox(
                        color: scheme.primary.withValues(alpha: 0.14),
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      pinned ? Icons.push_pin : intentIcon(intent),
                      size: 16,
                      color: fg,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      intent.title,
                      style: TextStyle(color: fg, fontSize: 13),
                    ),
                    const SizedBox(width: 6),
                    SizedBox(
                      width: 28,
                      child: Text(
                        (probability * 100).round().toString(),
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          color: fg.withValues(alpha: 0.7),
                          fontSize: 12,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
