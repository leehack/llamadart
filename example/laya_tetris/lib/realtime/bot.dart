import 'dart:math' as math;

import '../players.dart';
import '../tetris.dart' show Placement;
import 'engine.dart';
import 'planner.dart';

/// Who plays the real-time game.
enum RealtimePlayer {
  /// Keyboard or on-screen keys.
  human('You (WASD / arrows + Space)'),

  /// Laya with the base head: clears a line? adds a hole?
  layaChecklist('Laya yes/no checklist', bot: PlayerKind.layaChecklist),

  /// Laya with the base head: good move?
  layaJudge('Laya yes/no: good move?', bot: PlayerKind.layaJudge),

  /// Laya with the base head: one A-F choice.
  layaChoice('Laya choice (A-F)', bot: PlayerKind.layaChoice),

  /// Laya with the Tetris-tuned head: A-F knockout.
  layaTuned('Laya choice (Tetris-tuned)', bot: PlayerKind.layaTuned),

  /// Best move by heuristic.
  heuristic('Heuristic bot', bot: PlayerKind.heuristic),

  /// Random candidate.
  random('Random candidate', bot: PlayerKind.random);

  const RealtimePlayer(this.label, {this.bot});

  /// Display name.
  final String label;

  /// Decision logic, or null for the human player.
  final PlayerKind? bot;

  /// Whether a bot presses the keys.
  bool get isBot => bot != null;

  /// Whether this player asks Laya.
  bool get isLaya => bot?.isLaya ?? false;
}

/// One bot decision for the piece with [pieceId].
class Thought {
  /// Creates a thought.
  Thought({
    required this.pieceId,
    required this.options,
    required this.chosen,
    required this.candidates,
    required this.thinkMillis,
    this.verdict,
  });

  /// Piece the decision is for.
  final int pieceId;

  /// Candidates the bot considered.
  final List<Move> options;

  /// The chosen landing.
  final Move chosen;

  /// Reachable landings.
  final int candidates;

  /// Time from planning to decision.
  final int thinkMillis;

  /// Laya's verdict, for Laya players.
  final LayaVerdict? verdict;
}

/// Picks a landing for the active piece; gravity keeps running meanwhile.
Future<Thought> think(
  RealtimeTetris g,
  PlayerKind kind,
  ShortlistMode mode,
  math.Random rng, {
  LayaHeads heads = const LayaHeads(),
  bool natural = true,
}) async {
  final sw = Stopwatch()..start();
  final a = g.active!;
  final moves = planMoves(g);
  final byPlacement = Map<Placement, Move>.identity();
  for (final m in moves) {
    byPlacement[m.placement] = m;
  }
  final next = g.preview(1).first;
  final holes = g.field.holes();
  final stack = g.field.stackRows();
  final pick = await pickPlacement(
    kind,
    [for (final m in moves) m.placement],
    piece: a.piece,
    mode: mode,
    rng: rng,
    heads: heads,
    natural: natural,
    boardState: () =>
        layaBoardState(piece: a.piece, next: next, holes: holes, stack: stack),
  );
  final options = [for (final p in pick.options) byPlacement[p]!];
  return Thought(
    pieceId: a.id,
    options: options,
    chosen: options[pick.chosen],
    candidates: moves.length,
    thinkMillis: sw.elapsedMilliseconds,
    verdict: pick.verdict,
  );
}
