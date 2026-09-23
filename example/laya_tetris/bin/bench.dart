// Headless Laya Tetris runs through DecisionEngine with local model files.
//
// dart run bin/bench.dart --model laya-Q8_0.gguf --head laya-head.safetensors \
//   [--tuned-head laya-head-tetris.safetensors] [options]
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:args/args.dart';
import 'package:laya_tetris_example/laya/benchmark.dart';
import 'package:laya_tetris_example/laya/models.dart';
import 'package:laya_tetris_example/players.dart';
import 'package:laya_tetris_example/realtime/bot.dart';
import 'package:laya_tetris_example/realtime/engine.dart';
import 'package:laya_tetris_example/realtime/planner.dart';
import 'package:laya_tetris_example/tetris.dart';
import 'package:llamadart/llamadart.dart';

const _players = {
  'heuristic': PlayerKind.heuristic,
  'random': PlayerKind.random,
  'judge': PlayerKind.layaJudge,
  'checklist': PlayerKind.layaChecklist,
  'choice': PlayerKind.layaChoice,
  'tuned': PlayerKind.layaTuned,
};

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('model', help: 'Backbone GGUF, such as laya-Q8_0.gguf.')
    ..addOption('head', help: 'Base head, laya-head.safetensors.')
    ..addOption('tuned-head', help: 'Tetris-tuned head.')
    ..addFlag('cpu', help: 'Run on the CPU instead of the best device.')
    ..addOption('threads', defaultsTo: '4', help: 'CPU threads.')
    ..addMultiOption(
      'players',
      allowed: _players.keys,
      help: 'Players to run; default: all that have their head.',
    )
    ..addMultiOption(
      'modes',
      allowed: ShortlistMode.values.map((m) => m.name),
      defaultsTo: ['mixed', 'all'],
      help: 'Candidate shortlists for the Laya and random players.',
    )
    ..addOption('pieces', defaultsTo: '150', help: 'Piece cap per game.')
    ..addOption('seeds', defaultsTo: '5', help: 'Games per player.')
    ..addFlag('terse', help: 'Describe yes/no moves with digits.')
    ..addFlag(
      'realtime',
      help: 'Play real-time games on the wall clock instead.',
    )
    ..addOption('level', defaultsTo: '1', help: 'Real-time start level.')
    ..addOption('key-ms', defaultsTo: '60', help: 'Real-time key interval.')
    ..addOption(
      'minutes',
      defaultsTo: '10',
      help: 'Real-time cap per game in minutes.',
    )
    ..addFlag(
      'speed',
      help: 'Time one question on the best device and at 2-8 CPU threads.',
    )
    ..addFlag('help', abbr: 'h', negatable: false);
  final args = parser.parse(arguments);
  final model = args.option('model'), head = args.option('head');
  if (args.flag('help') || model == null || head == null) {
    stdout.writeln(parser.usage);
    exitCode = args.flag('help') ? 0 : 64;
    return;
  }
  final tunedHead = args.option('tuned-head');
  final setup = LayaSetup(
    backbone: ModelSource.path(model),
    head: ModelSource.path(head),
    tunedHead: tunedHead == null ? null : ModelSource.path(tunedHead),
    backend: args.flag('cpu') ? GpuBackend.cpu : GpuBackend.auto,
    threads: int.parse(args.option('threads')!),
  );

  if (args.flag('speed')) {
    stdout.writeln(
      'One six-option choice with the ${tunedHead == null ? 'base' : 'tuned'} head',
    );
    await for (final r in benchmarkLaya(setup)) {
      stdout.writeln('${r.tokens} tokens, $r');
    }
    return;
  }

  final laya = await LayaModels.load(setup);
  if (laya.tunedError != null) {
    stderr.writeln('Tuned head failed: ${laya.tunedError}');
  }
  final heads = laya.heads;
  final kinds = args.multiOption('players').isEmpty
      ? [
          for (final k in PlayerKind.values)
            if (k != PlayerKind.layaTuned || laya.tuned != null) k,
        ]
      : [for (final p in args.multiOption('players')) _players[p]!];
  final modes = [
    for (final m in args.multiOption('modes')) ShortlistMode.values.byName(m),
  ];
  stdout.writeln(
    'Laya on ${laya.backendName} (${laya.deviceName}), '
    'loaded in ${laya.loadMillis} ms',
  );
  try {
    if (args.flag('realtime')) {
      await _realtime(
        kinds,
        modes,
        heads,
        startLevel: int.parse(args.option('level')!),
        keyMs: int.parse(args.option('key-ms')!),
        games: int.parse(args.option('seeds')!),
        minutes: int.parse(args.option('minutes')!),
        natural: !args.flag('terse'),
      );
    } else {
      await _turnBased(
        kinds,
        modes,
        heads,
        maxPieces: int.parse(args.option('pieces')!),
        seeds: int.parse(args.option('seeds')!),
        natural: !args.flag('terse'),
      );
    }
  } finally {
    await laya.dispose();
  }
}

/// Runs for each player: the heuristic once, others once per mode; the
/// choice player caps "all" at six candidates, so it skips that mode.
Iterable<(PlayerKind, ShortlistMode)> _runs(
  List<PlayerKind> kinds,
  List<ShortlistMode> modes,
) sync* {
  for (final k in kinds) {
    if (k == PlayerKind.heuristic) {
      yield (k, ShortlistMode.all);
      continue;
    }
    for (final m in modes) {
      if (k == PlayerKind.layaChoice && m == ShortlistMode.all) continue;
      yield (k, m);
    }
  }
}

Future<void> _turnBased(
  List<PlayerKind> kinds,
  List<ShortlistMode> modes,
  LayaHeads heads, {
  required int maxPieces,
  required int seeds,
  required bool natural,
}) async {
  stdout.writeln(
    'Turn-based, up to $maxPieces pieces, $seeds seeds, '
    '${natural ? 'natural' : 'terse'} yes/no phrasing\n',
  );
  stdout.writeln(
    '${'player'.padRight(27)}${'candidates'.padRight(19)}'
    'pieces  lines  score  best%   rank  questions  ms/move  facts',
  );
  for (final (kind, mode) in _runs(kinds, modes)) {
    var pieces = 0, lines = 0, score = 0;
    final st = Stats();
    final sw = Stopwatch()..start();
    for (var s = 0; s < seeds; s++) {
      final g = Game(500000 + s);
      final rng = math.Random(s);
      while (!g.over && g.pieces < maxPieces) {
        final d = await decide(
          g,
          kind,
          mode,
          rng,
          heads: heads,
          natural: natural,
        );
        st.add(d);
        g.apply(d.pick.placement);
      }
      pieces += g.pieces;
      lines += g.lines;
      score += g.score;
    }
    String avg(int v) => (v / seeds).toStringAsFixed(0).padLeft(6);
    stdout.writeln(
      '${kind.label.padRight(27)}'
      '${(kind == PlayerKind.heuristic ? '-' : mode.label).padRight(18)} '
      '${avg(pieces)} ${avg(lines)} ${avg(score)}  '
      '${(st.agreeRate * 100).toStringAsFixed(0).padLeft(4)}%  '
      '${st.meanRank.toStringAsFixed(1).padLeft(5)}  '
      '${st.meanQuestions.toStringAsFixed(1).padLeft(9)}  '
      '${st.meanMillis.toStringAsFixed(0).padLeft(7)}  ${st.factSummary()}'
      '   [${(sw.elapsedMilliseconds / 1000).toStringAsFixed(0)} s]',
    );
  }
}

/// Plays real-time games on the wall clock: gravity runs while Laya thinks.
Future<void> _realtime(
  List<PlayerKind> kinds,
  List<ShortlistMode> modes,
  LayaHeads heads, {
  required int startLevel,
  required int keyMs,
  required int games,
  required int minutes,
  required bool natural,
}) async {
  stdout.writeln(
    'Real-time, start level $startLevel, $keyMs ms per key, $games games\n',
  );
  for (final (kind, mode) in _runs(kinds, modes)) {
    for (var gi = 0; gi < games; gi++) {
      final g = RealtimeTetris(seed: 100 + gi, startLevel: startLevel);
      final rng = math.Random(gi);
      final sw = Stopwatch()..start();
      var last = 0.0, nextKey = 0.0;
      int? thinkingFor, keysFor;
      final keys = <Action>[];
      var decisions = 0, late = 0, blocked = 0, thinkMs = 0;
      Object? failure;
      while (!g.over && failure == null && sw.elapsed.inMinutes < minutes) {
        await Future<void>.delayed(const Duration(milliseconds: 16));
        final now = sw.elapsedMicroseconds / 1e6;
        g.tick(math.min(0.1, now - last));
        last = now;
        final a = g.active;
        if (a == null) continue;
        if (thinkingFor != a.id) {
          thinkingFor = a.id;
          unawaited(
            think(g, kind, mode, rng, heads: heads, natural: natural).then((t) {
              decisions++;
              thinkMs += t.thinkMillis;
              if (g.active?.id != t.pieceId || g.over) {
                late++;
                return;
              }
              final m = planMoves(
                g,
              ).where((m) => m.landingKey == t.chosen.landingKey).toList();
              if (m.isEmpty) blocked++;
              keys
                ..clear()
                ..addAll(m.isEmpty ? [Action.hardDrop] : m.first.keys);
              keysFor = t.pieceId;
              nextKey = sw.elapsedMicroseconds / 1e6;
            }, onError: (Object e) => failure = e),
          );
        }
        if (keysFor == a.id) {
          while (keys.isNotEmpty && sw.elapsedMicroseconds / 1e6 >= nextKey) {
            g.input(keys.removeAt(0));
            nextKey += keyMs / 1000;
            if (keyMs > 0) break;
          }
        }
      }
      stdout.writeln(
        '${kind.label}, ${kind == PlayerKind.heuristic ? '-' : mode.label}, '
        'game ${gi + 1}: score ${g.score}, level ${g.level}, lines ${g.lines}, '
        'pieces ${g.pieces}, clears ${g.clears}, T-spins ${g.tSpins}, '
        '${sw.elapsed.inSeconds} s; decisions $decisions, mean think '
        '${decisions == 0 ? 0 : thinkMs ~/ decisions} ms, too slow $late, '
        'target blocked $blocked'
        '${failure != null
            ? ', failed: $failure'
            : g.over
            ? ''
            : ' (stopped at $minutes min)'}',
      );
    }
  }
}
