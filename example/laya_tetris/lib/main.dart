import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart' hide Action;
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:llamadart/llamadart.dart'
    show GpuBackend, ModelDownloadCancelToken;

import 'laya/benchmark.dart';
import 'laya/models.dart';
import 'laya/store.dart';
import 'players.dart';
import 'realtime/bot.dart';
import 'realtime/engine.dart';
import 'realtime/planner.dart';
import 'tetris.dart' show Piece;

void main() => runApp(const LayaTetrisApp());

/// The Laya Tetris app.
class LayaTetrisApp extends StatelessWidget {
  /// Creates the app; [openStore] defaults to [ModelStore.open] and
  /// [loadModels] to [LayaModels.load].
  const LayaTetrisApp({
    super.key,
    this.openStore = ModelStore.open,
    this.loadModels = LayaModels.load,
  });

  /// Opens the model folder.
  final Future<ModelStore> Function() openStore;

  /// Loads the models for the game and the benchmark.
  final LayaLoader loadModels;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Laya Tetris',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorSchemeSeed: Colors.indigo,
      brightness: Brightness.dark,
      useMaterial3: true,
    ),
    home: GamePage(openStore: openStore, loadModels: loadModels),
  );
}

/// Colors of the pieces, in [Piece] order.
const List<Color> pieceColors = [
  Color(0xFF26C6DA),
  Color(0xFFFFCA28),
  Color(0xFFAB47BC),
  Color(0xFF66BB6A),
  Color(0xFFEF5350),
  Color(0xFF42A5F5),
  Color(0xFFFFA726),
];

/// The game screen.
class GamePage extends StatefulWidget {
  /// Creates the screen.
  const GamePage({
    super.key,
    required this.openStore,
    required this.loadModels,
  });

  /// Opens the model folder.
  final Future<ModelStore> Function() openStore;

  /// Loads the models for the game and the benchmark.
  final LayaLoader loadModels;

  @override
  State<GamePage> createState() => _GamePageState();
}

class _GamePageState extends State<GamePage>
    with SingleTickerProviderStateMixin {
  final _focus = FocusNode();
  final _noFocus = FocusNode(canRequestFocus: false, skipTraversal: true);
  late final Ticker _ticker;
  late final AppLifecycleListener _lifecycle;
  Duration _lastTick = Duration.zero;
  double _clock = 0;

  ModelStore? _store;
  LayaModels? _models;
  LayaSetup? _setup;
  Future<void> _modelWork = Future.value();
  ModelDownloadCancelToken? _cancel;
  int _loadGeneration = 0;
  String _layaStatus = 'Opening the model folder…';
  double? _progress;
  bool _loadFailed = false;
  String _tunedStatus = '';

  RealtimePlayer _player = RealtimePlayer.layaChecklist;
  ShortlistMode _mode = Platform.isAndroid
      ? ShortlistMode.mixed
      : ShortlistMode.all;
  GpuBackend _backend = Platform.isAndroid ? GpuBackend.cpu : GpuBackend.auto;
  int _threads = Platform.isAndroid ? 6 : 4;
  LayaBackbone _backbone = LayaBackbone.q8;
  bool _natural = true;
  int _startLevel = 1;
  final int _seed = 1;
  double _keyMs = 60;

  late RealtimeTetris _g;
  late math.Random _rng;
  bool _started = false, _paused = false;
  final Map<RealtimePlayer, int> _best = {};

  int? _thinkingFor;
  Thought? _last;
  String? _thinkError;
  final _keys = <Action>[];
  int? _keysFor;
  double _nextKeyAt = 0;
  int _decisions = 0,
      _late = 0,
      _unreachable = 0,
      _thinkMsSum = 0,
      _pressed = 0;
  final Map<Action, double> _lit = {};
  int _gameNo = 0;
  int _seenEvent = 0;
  double _eventAt = -10;

  bool _benching = false;
  String _benchResult = '';

  @override
  void initState() {
    super.initState();
    _newGame();
    _ticker = createTicker(_onTick)..start();
    _lifecycle = AppLifecycleListener(onExitRequested: _onExit);
    widget.openStore().then(
      (store) {
        if (!mounted) return;
        _store = store;
        _reload();
      },
      onError: (Object e) {
        if (!mounted) return;
        setState(() {
          _layaStatus = 'Model folder unavailable: $e';
          _loadFailed = true;
        });
      },
    );
  }

  LayaHeads get _heads => _models?.heads ?? const LayaHeads();

  bool get _tunedMissing => _models != null && _models!.tuned == null;

  /// Replaces the loaded models with ones for the current settings; loads
  /// run one at a time and a newer request supersedes an older one.
  void _reload() {
    final store = _store;
    if (store == null) return;
    final generation = ++_loadGeneration;
    _cancel?.cancel();
    final old = _models;
    setState(() {
      _models = null;
      _setup = null;
      _layaStatus = 'Loading Laya…';
      _progress = null;
      _loadFailed = false;
      _tunedStatus = '';
      _thinkingFor = null;
      _keys.clear();
      _keysFor = null;
    });
    _modelWork = _modelWork.then((_) async {
      void update(void Function() change) {
        if (generation == _loadGeneration && mounted) setState(change);
      }

      try {
        await old?.dispose();
        if (generation != _loadGeneration || !mounted) return;
        final cancel = _cancel = ModelDownloadCancelToken();
        final setup = store.setup(
          _backbone,
          backend: _backend,
          threads: _threads,
        );
        final models = await widget.loadModels(
          setup,
          downloads: store.downloads,
          cancelToken: cancel,
          onStatus: (message, fraction) => update(() {
            _layaStatus = message;
            _progress = fraction;
          }),
        );
        if (generation != _loadGeneration || !mounted) {
          await models.dispose();
          return;
        }
        update(() {
          _models = models;
          _setup = setup;
          _progress = null;
          _layaStatus =
              '${_backbone.fileName} on ${models.backendName} '
              '(${models.deviceName}) · loaded in '
              '${models.loadMillis} ms';
          _tunedStatus = models.tuned != null
              ? 'Tetris-tuned head loaded'
              : 'Tetris-tuned head failed: ${models.tunedError}\n'
                    '${store.tunedHeadHelp(setup.tunedHead!)}';
        });
      } catch (e) {
        update(() {
          _progress = null;
          _layaStatus = 'Laya failed: $e';
          _loadFailed = true;
        });
      }
    });
  }

  /// Times one six-option choice with the loaded models' tuned head when it
  /// loaded, else their base head, on the best device and at several CPU
  /// thread counts, each in a fresh engine.
  Future<void> _benchmark() async {
    final store = _store, loaded = _setup;
    if (_benching || store == null || loaded == null) return;
    final backbone = _backbone;
    final tuned = _models?.tuned != null;
    final setup = tuned
        ? loaded
        : LayaSetup(backbone: loaded.backbone, head: loaded.head);
    final head = tuned ? 'tuned head' : 'base head';
    setState(() {
      _benching = true;
      _benchResult = 'Benchmarking ${backbone.fileName} with the $head…';
    });
    final lines = <String>[];
    await for (final r in benchmarkLaya(
      setup,
      downloads: store.downloads,
      load: widget.loadModels,
    )) {
      if (!mounted) return;
      lines.add('$r');
      setState(() {
        _benchResult =
            '${backbone.fileName}, $head, ${r.tokens} tokens\n'
            '${lines.join('\n')}';
      });
    }
    if (mounted) setState(() => _benching = false);
  }

  Future<AppExitResponse> _onExit() async {
    _ticker.stop();
    _loadGeneration++;
    _cancel?.cancel();
    await _modelWork;
    await _models?.dispose();
    _models = null;
    return AppExitResponse.exit;
  }

  @override
  void dispose() {
    _ticker.dispose();
    _lifecycle.dispose();
    _focus.dispose();
    _noFocus.dispose();
    _loadGeneration++;
    _cancel?.cancel();
    final models = _models;
    _modelWork.then((_) => models?.dispose());
    super.dispose();
  }

  void _newGame() {
    _gameNo++;
    _g = RealtimeTetris(seed: _seed + _gameNo, startLevel: _startLevel);
    _seenEvent = 0;
    _eventAt = -10;
    _rng = math.Random(_seed + _gameNo);
    _started = false;
    _paused = false;
    _thinkingFor = null;
    _last = null;
    _thinkError = null;
    _keys.clear();
    _keysFor = null;
    _decisions = _late = _unreachable = _thinkMsSum = _pressed = 0;
  }

  bool get _live => _started && !_paused && !_g.over;

  void _onTick(Duration elapsed) {
    final dt = math.min(0.1, (elapsed - _lastTick).inMicroseconds / 1e6);
    _lastTick = elapsed;
    _clock += dt;
    if (_g.eventId != _seenEvent) {
      _seenEvent = _g.eventId;
      _eventAt = _clock;
    }
    if (_live) {
      _g.tick(dt);
      if (_player.isBot) _driveBot();
      if (_g.over) _best[_player] = math.max(_best[_player] ?? 0, _g.score);
    }
    setState(() {});
  }

  bool get _botReady => !_player.isLaya || _heads.of(_player.bot!) != null;

  void _driveBot() {
    final a = _g.active;
    if (a == null) return;
    if (_thinkingFor != a.id && _botReady) {
      _thinkingFor = a.id;
      final game = _gameNo, generation = _loadGeneration;
      bool current() => game == _gameNo && generation == _loadGeneration;
      think(
        _g,
        _player.bot!,
        _mode,
        _rng,
        heads: _heads,
        natural: _natural,
      ).then(
        (t) {
          if (current()) _onThought(t);
        },
        onError: (Object e) {
          if (mounted && current()) _thinkError = '$e';
        },
      );
    }
    if (_keysFor == a.id) {
      while (_keys.isNotEmpty && _clock >= _nextKeyAt) {
        _press(_keys.removeAt(0));
        _nextKeyAt += _keyMs / 1000;
        if (_keyMs > 0) break;
      }
    }
  }

  void _onThought(Thought t) {
    if (!mounted) return;
    _decisions++;
    _thinkMsSum += t.thinkMillis;
    _last = t;
    _thinkError = null;
    if (_g.active?.id != t.pieceId || _g.over) {
      _late++;
      return;
    }
    final now = planMoves(
      _g,
    ).where((m) => m.landingKey == t.chosen.landingKey).toList();
    if (now.isEmpty) _unreachable++;
    _keys
      ..clear()
      ..addAll(now.isEmpty ? [Action.hardDrop] : now.first.keys);
    _keysFor = t.pieceId;
    _nextKeyAt = _clock;
  }

  void _press(Action a) {
    _g.input(a);
    _lit[a] = _clock;
    _pressed++;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.keyP || k == LogicalKeyboardKey.escape) {
      if (_started && !_g.over && !_benching) {
        setState(() => _paused = !_paused);
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.enter) {
      if (e is KeyDownEvent && _canStart) _startOrPause();
      return KeyEventResult.handled;
    }
    final action = switch (k) {
      LogicalKeyboardKey.keyA || LogicalKeyboardKey.arrowLeft => Action.left,
      LogicalKeyboardKey.keyD || LogicalKeyboardKey.arrowRight => Action.right,
      LogicalKeyboardKey.keyW ||
      LogicalKeyboardKey.arrowUp ||
      LogicalKeyboardKey.keyX => Action.rotateCw,
      LogicalKeyboardKey.keyQ || LogicalKeyboardKey.keyZ => Action.rotateCcw,
      LogicalKeyboardKey.keyS ||
      LogicalKeyboardKey.arrowDown => Action.softDrop,
      LogicalKeyboardKey.space => e is KeyDownEvent ? Action.hardDrop : null,
      LogicalKeyboardKey.keyC ||
      LogicalKeyboardKey.shiftLeft ||
      LogicalKeyboardKey.shiftRight => e is KeyDownEvent ? Action.hold : null,
      _ => null,
    };
    if (action == null) return KeyEventResult.ignored;
    if (_player == RealtimePlayer.human && _live) _press(action);
    return KeyEventResult.handled;
  }

  void _startOrPause() {
    setState(() {
      if (_g.over) _newGame();
      if (!_started) {
        _started = true;
      } else {
        _paused = !_paused;
      }
    });
    _focus.requestFocus();
  }

  void _restart() {
    setState(_newGame);
    _focus.requestFocus();
  }

  bool get _canStart => _botReady && !_benching;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Scaffold(
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, box) => box.maxWidth >= 700
                ? _wide(theme)
                : _narrow(theme, box.maxHeight),
          ),
        ),
      ),
    );
  }

  Widget _wide(ThemeData theme) => Padding(
    padding: const EdgeInsets.all(20),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          children: [
            Expanded(child: _board(theme)),
            const SizedBox(height: 12),
            _keyboard(theme),
          ],
        ),
        const SizedBox(width: 16),
        SizedBox(width: 92, child: _preview(theme)),
        const SizedBox(width: 16),
        Expanded(child: ListView(children: _info(theme))),
      ],
    ),
  );

  /// Phone portrait: board and preview on top, keys, then scrollable info.
  Widget _narrow(ThemeData theme, double height) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
    child: Column(
      children: [
        SizedBox(
          height: height * 0.52,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: _board(theme),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(width: 76, child: _preview(theme)),
            ],
          ),
        ),
        const SizedBox(height: 8),
        _keyboard(theme),
        const SizedBox(height: 8),
        Expanded(child: ListView(children: _info(theme))),
      ],
    ),
  );

  List<Widget> _info(ThemeData theme) => [
    Text('Laya Tetris', style: theme.textTheme.headlineSmall),
    const SizedBox(height: 4),
    _modelStatus(theme),
    const SizedBox(height: 16),
    _controls(),
    if (_player.isLaya) ...[
      const SizedBox(height: 12),
      Row(
        children: [
          OutlinedButton(
            onPressed: !_live && _models != null && !_benching
                ? _benchmark
                : null,
            child: const Text('Benchmark'),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(_benchResult, style: theme.textTheme.bodySmall)),
        ],
      ),
    ],
    const SizedBox(height: 16),
    _scoreCard(theme),
    if (_player.isBot) ...[const SizedBox(height: 16), _botCard(theme)],
    const SizedBox(height: 16),
  ];

  Widget _modelStatus(ThemeData theme) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(_layaStatus, style: theme.textTheme.bodySmall),
      if (_models == null && !_loadFailed) ...[
        const SizedBox(height: 6),
        LinearProgressIndicator(value: _progress),
      ],
      if ((_loadFailed || _tunedMissing) && _store != null)
        TextButton.icon(
          onPressed: _benching ? null : _reload,
          icon: const Icon(Icons.refresh),
          label: Text(_loadFailed ? 'Retry' : 'Reload models'),
        ),
      if (_tunedStatus.isNotEmpty) ...[
        const SizedBox(height: 4),
        Text(
          _tunedStatus,
          style: theme.textTheme.bodySmall?.copyWith(
            color: _tunedMissing ? theme.colorScheme.tertiary : null,
          ),
        ),
      ],
    ],
  );

  Widget _board(ThemeData theme) => AspectRatio(
    aspectRatio: fieldWidth / (fieldHeight - hiddenRows),
    child: Stack(
      children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xFF12131A),
              border: Border.all(color: Colors.white24),
            ),
            child: CustomPaint(painter: FieldPainter(_g)),
          ),
        ),
        if (_clock - _eventAt < 1.6 && _g.lastEvent.isNotEmpty)
          Positioned(
            left: 0,
            right: 0,
            top: 60,
            child: IgnorePointer(
              child: Opacity(
                opacity: (1.6 - (_clock - _eventAt)).clamp(0.0, 1.0),
                child: Text(
                  _g.lastEvent,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge?.copyWith(
                    color: Colors.amberAccent,
                    fontWeight: FontWeight.w800,
                    shadows: const [Shadow(blurRadius: 6)],
                  ),
                ),
              ),
            ),
          ),
        if (!_started || _paused || _g.over)
          Positioned.fill(child: _overlay(theme)),
      ],
    ),
  );

  Widget _overlay(ThemeData theme) {
    final title = _g.over ? 'Game over' : (_paused ? 'Paused' : 'Ready');
    final sub = _g.over
        ? 'Score ${_g.score} · level ${_g.level} · ${_g.lines} lines'
        : (_player == RealtimePlayer.human
              ? 'Press Enter to ${_paused ? 'resume' : 'start'}'
              : _canStart
              ? '${_player.label} will play'
              : _benching
              ? 'Waiting for the benchmark'
              : _player == RealtimePlayer.layaTuned && _tunedMissing
              ? '${_player.label} needs the Tetris-tuned head'
              : '${_player.label} is waiting for Laya');
    return ColoredBox(
      color: Colors.black54,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: theme.textTheme.headlineMedium),
            const SizedBox(height: 8),
            Text(sub, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _canStart ? _startOrPause : null,
              child: Text(
                _g.over ? 'New game' : (_paused ? 'Resume' : 'Start'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _picker<T>(
    String label,
    double width,
    T value,
    List<(T, String)> items,
    void Function(T) onChanged, {
    bool Function(T)? enabled,
    bool active = true,
  }) => SizedBox(
    width: width,
    child: InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          focusNode: _noFocus,
          items: [
            for (final (v, text) in items)
              DropdownMenuItem(
                value: v,
                enabled: enabled?.call(v) ?? true,
                child: Text(text),
              ),
          ],
          onChanged: active
              ? (v) {
                  if (v != null && v != value) onChanged(v);
                  _focus.requestFocus();
                }
              : null,
        ),
      ),
    ),
  );

  /// Switches who plays; a running game continues from the current piece.
  void _setPlayer(RealtimePlayer p) => setState(() {
    _player = p;
    _keys.clear();
    _keysFor = null;
    _thinkingFor = null;
    _thinkError = null;
  });

  Widget _controls() {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _picker(
          'Player',
          280,
          _player,
          [for (final p in RealtimePlayer.values) (p, p.label)],
          _setPlayer,
          enabled: (p) =>
              p != RealtimePlayer.layaTuned || _models?.tuned != null,
        ),
        _picker(
          'Start level',
          130,
          _startLevel,
          [for (var l = 1; l <= 15; l++) (l, '$l')],
          (l) {
            setState(() {
              _startLevel = l;
              _newGame();
            });
          },
        ),
        if (_player.isLaya) ...[
          _picker(
            'Compute',
            130,
            _backend,
            [(GpuBackend.auto, 'GPU (auto)'), (GpuBackend.cpu, 'CPU')],
            (b) {
              _backend = b;
              _reload();
            },
            active: !_benching,
          ),
          _picker(
            'Backbone',
            200,
            _backbone,
            [for (final b in LayaBackbone.values) (b, b.label)],
            (b) {
              _backbone = b;
              _reload();
            },
            active: !_benching,
          ),
          _picker(
            'CPU threads',
            130,
            _threads,
            [
              for (final n in [1, 2, 3, 4, 6, 8]) (n, '$n'),
            ],
            (n) {
              _threads = n;
              _reload();
            },
            active: !_benching,
          ),
          _picker(
            'Laya considers',
            220,
            _mode,
            [for (final m in ShortlistMode.values) (m, m.label)],
            (m) {
              setState(() => _mode = m);
            },
          ),
        ],
        FilledButton.tonalIcon(
          onPressed: _started && !_g.over && !_benching ? _startOrPause : null,
          icon: Icon(_paused ? Icons.play_arrow : Icons.pause),
          label: Text(_paused ? 'Resume' : 'Pause'),
        ),
        OutlinedButton.icon(
          onPressed: _restart,
          icon: const Icon(Icons.restart_alt),
          label: const Text('Restart'),
        ),
        if (_player.isBot)
          SizedBox(
            width: 300,
            child: Row(
              children: [
                Text('Key speed ${_keyMs.round()} ms'),
                Expanded(
                  child: Slider(
                    value: _keyMs,
                    max: 200,
                    divisions: 20,
                    onChanged: (v) => setState(() => _keyMs = v),
                    onChangeEnd: (_) => _focus.requestFocus(),
                  ),
                ),
              ],
            ),
          ),
        if (_player == RealtimePlayer.layaChecklist ||
            _player == RealtimePlayer.layaJudge)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Switch(
                value: _natural,
                onChanged: (v) {
                  setState(() => _natural = v);
                  _focus.requestFocus();
                },
              ),
              const Text('Plain-English moves'),
            ],
          ),
      ],
    );
  }

  Widget _scoreCard(ThemeData theme) {
    final rowsPerSec = 1 / math.max(1e-3, _g.secondsPerRow);
    final tiles = <(String, String)>[
      ('Score', '${_g.score}'),
      ('Level', '${_g.level}'),
      ('Lines', '${_g.lines}'),
      ('Pieces', '${_g.pieces}'),
      (
        'Gravity',
        rowsPerSec >= 60 ? '20G' : '${rowsPerSec.toStringAsFixed(1)} rows/s',
      ),
      ('Best this session', '${_best[_player] ?? 0}'),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 28,
              runSpacing: 12,
              children: [
                for (final (k, v) in tiles)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(k, style: theme.textTheme.labelSmall),
                      Text(v, style: theme.textTheme.titleLarge),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              'Singles ${_g.clears[1]} · doubles ${_g.clears[2]} · triples ${_g.clears[3]} · tetrises ${_g.clears[4]} · '
              'T-spins ${_g.tSpins} · back-to-backs ${_g.backToBacks}${_g.combo > 0 ? ' · combo ${_g.combo}' : ''}',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _botCard(ThemeData theme) {
    final t = _last;
    final meanThink = _decisions == 0 ? 0 : _thinkMsSum / _decisions;
    final thinking =
        _thinkingFor != null &&
        _g.active?.id == _thinkingFor &&
        _keysFor != _thinkingFor;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _live ? (thinking ? 'Thinking…' : 'Pressing keys') : 'Idle',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 6),
            Text(
              'Decisions $_decisions · mean think ${meanThink.toStringAsFixed(0)} ms · '
              'too slow (piece locked first) $_late · target blocked $_unreachable · keys pressed $_pressed',
              style: theme.textTheme.bodySmall,
            ),
            Text(
              'A row falls every ${(_g.secondsPerRow * 1000).toStringAsFixed(0)} ms now; '
              'lock delay ${(lockDelaySeconds * 1000).round()} ms',
              style: theme.textTheme.bodySmall,
            ),
            if (_thinkError != null)
              Text(
                'Last decision failed: $_thinkError',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            if (t != null && t.options.length > 1) ...[
              const SizedBox(height: 12),
              Text(
                'Last decision: ${t.options.length} of ${t.candidates} landings in ${t.thinkMillis} ms'
                '${t.verdict == null ? '' : ' (${t.verdict!.questions} Laya questions)'}',
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 6),
              for (final i in _topRows(t)) _optionRow(t, i),
            ],
          ],
        ),
      ),
    );
  }

  List<int> _topRows(Thought t) {
    final idx = List<int>.generate(t.options.length, (i) => i);
    final s = t.verdict?.scores;
    if (s != null) idx.sort((a, b) => s[b].compareTo(s[a]));
    return idx.take(6).toList();
  }

  Widget _optionRow(Thought t, int i) {
    final o = t.options[i];
    final chosen = identical(o, t.chosen);
    final style = TextStyle(
      fontFeatures: const [FontFeature.tabularFigures()],
      fontWeight: chosen ? FontWeight.bold : FontWeight.normal,
      color: chosen ? Theme.of(context).colorScheme.primary : null,
    );
    final f = t.verdict?.facts?[i];
    final s = t.verdict?.scores[i];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(width: 20, child: Text(chosen ? '●' : '', style: style)),
          Expanded(child: Text(o.placement.describe(), style: style)),
          if (f != null)
            SizedBox(
              width: 170,
              child: Text(
                'clear ${(f.$1 * 100).toStringAsFixed(0)}% · hole ${(f.$2 * 100).toStringAsFixed(0)}%',
                style: style,
              ),
            )
          else if (s != null)
            SizedBox(
              width: 90,
              child: Text(
                '${_player == RealtimePlayer.layaJudge ? 'good' : 'p'} '
                '${(s * 100).toStringAsFixed(0)}%',
                style: style,
              ),
            ),
        ],
      ),
    );
  }

  Widget _preview(ThemeData theme) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('Hold', style: theme.textTheme.labelSmall),
      const SizedBox(height: 6),
      Opacity(
        opacity: _g.canHold ? 1 : 0.35,
        child: SizedBox(
          width: 80,
          height: 50,
          child: _g.held == null
              ? null
              : CustomPaint(painter: PiecePainter(_g.held!)),
        ),
      ),
      const SizedBox(height: 16),
      Text('Next', style: theme.textTheme.labelSmall),
      const SizedBox(height: 6),
      for (final p in _g.preview(3))
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: SizedBox(
            width: 80,
            height: 50,
            child: CustomPaint(painter: PiecePainter(p)),
          ),
        ),
    ],
  );

  Widget _keyboard(ThemeData theme) {
    bool on(Action a) => _clock - (_lit[a] ?? -10) < 0.12;
    Widget cap(String label, Action a, {double width = 40}) => GestureDetector(
      onTapDown: (_) {
        if (_player == RealtimePlayer.human && _live) _press(a);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 60),
        width: width,
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: on(a)
              ? theme.colorScheme.primary
              : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: on(a) ? theme.colorScheme.onPrimary : null,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
    final who = _player == RealtimePlayer.human ? 'you' : _player.label;
    return Column(
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            cap('Q', Action.rotateCcw),
            const SizedBox(width: 4),
            cap('W ↑', Action.rotateCw, width: 52),
            const SizedBox(width: 4),
            cap('C ⇧ Hold', Action.hold, width: 76),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            cap('A ←', Action.left, width: 52),
            const SizedBox(width: 4),
            cap('S ↓', Action.softDrop, width: 52),
            const SizedBox(width: 4),
            cap('D →', Action.right, width: 52),
          ],
        ),
        const SizedBox(height: 4),
        cap('Space', Action.hardDrop, width: 164),
        const SizedBox(height: 6),
        Text('Keys pressed by $who', style: theme.textTheme.bodySmall),
      ],
    );
  }
}

/// Paints the visible field, the ghost and the active piece.
class FieldPainter extends CustomPainter {
  /// Creates a painter for [g].
  FieldPainter(this.g);

  /// The game to paint.
  final RealtimeTetris g;

  @override
  void paint(Canvas canvas, Size size) {
    const rows = fieldHeight - hiddenRows;
    final cw = size.width / fieldWidth, ch = size.height / rows;
    final grid = Paint()..color = Colors.white10;
    for (var x = 1; x < fieldWidth; x++) {
      canvas.drawLine(Offset(x * cw, 0), Offset(x * cw, size.height), grid);
    }
    for (var y = 1; y < rows; y++) {
      canvas.drawLine(Offset(0, y * ch), Offset(size.width, y * ch), grid);
    }
    void cell(int x, int y, Paint p) {
      final vy = y - hiddenRows;
      if (vy < 0) return;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x * cw + 1, vy * ch + 1, cw - 2, ch - 2),
          const Radius.circular(3),
        ),
        p,
      );
    }

    for (var y = 0; y < fieldHeight; y++) {
      for (var x = 0; x < fieldWidth; x++) {
        final v = g.field.cells[y * fieldWidth + x];
        if (v != 0) cell(x, y, Paint()..color = pieceColors[v - 1]);
      }
    }
    final a = g.active;
    if (a == null) return;
    final color = pieceColors[a.piece.index];
    final ghost = Paint()
      ..color = color.withValues(alpha: 0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final d = g.dropDistance();
    for (final c in a.shape) {
      cell(a.x + c.$1, a.y + c.$2 + d, ghost);
    }
    for (final c in a.shape) {
      cell(a.x + c.$1, a.y + c.$2, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(FieldPainter old) => true;
}

/// Paints one piece centred, for the hold and next boxes.
class PiecePainter extends CustomPainter {
  /// Creates a painter for [piece].
  PiecePainter(this.piece);

  /// The piece to paint.
  final Piece piece;

  @override
  void paint(Canvas canvas, Size size) {
    final cells = srsStates[piece]![0];
    final minX = cells.map((c) => c.$1).reduce(math.min),
        maxX = cells.map((c) => c.$1).reduce(math.max);
    final minY = cells.map((c) => c.$2).reduce(math.min),
        maxY = cells.map((c) => c.$2).reduce(math.max);
    const s = 18.0;
    final ox = (size.width - (maxX - minX + 1) * s) / 2,
        oy = (size.height - (maxY - minY + 1) * s) / 2;
    final paint = Paint()..color = pieceColors[piece.index];
    for (final c in cells) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            ox + (c.$1 - minX) * s + 1,
            oy + (c.$2 - minY) * s + 1,
            s - 2,
            s - 2,
          ),
          const Radius.circular(3),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(PiecePainter old) => old.piece != piece;
}
