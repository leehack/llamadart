import 'dart:math' as math;

import '../tetris.dart' show Cell, Placement;
import 'engine.dart';

/// A reachable landing spot for the active piece and the keys that get there.
class Move {
  /// Creates a move.
  Move(this.keys, this.pose, this.cells, this.placement);

  /// Key presses, ending with a hard drop.
  final List<Action> keys;

  /// Pose after the hard drop.
  final Pose pose;

  /// Field cells the piece occupies after the hard drop.
  final List<Cell> cells;

  /// The landing and the board it leaves behind.
  final Placement placement;

  /// Identity of the landing, independent of the keys used.
  String get landingKey => ([
    ...cells,
  ]..sort((a, b) => a.$2 != b.$2 ? a.$2 - b.$2 : a.$1 - b.$1)).toString();
}

const List<List<Action>> _rotations = [
  [],
  [Action.rotateCw],
  [Action.rotateCw, Action.rotateCw],
  [Action.rotateCcw],
];

/// Every distinct landing reachable by rotating in place, shifting, then a
/// hard drop from the active piece's current pose.
List<Move> planMoves(RealtimeTetris g) {
  final a = g.active;
  if (a == null) return const [];
  final f = g.field;
  final holesBefore = f.holes();
  final byLanding = <String, Move>{};
  for (final rotKeys in _rotations) {
    Pose? pose = a.pose;
    for (final k in rotKeys) {
      pose = tryRotate(f, a.piece, pose!, k == Action.rotateCw ? 1 : -1);
      if (pose == null) break;
    }
    if (pose == null) continue;
    final shape = srsStates[a.piece]![pose.$1];
    for (final dir in const [0, -1, 1]) {
      var (rot, x, y) = pose;
      final keys = [...rotKeys];
      for (var step = 0; step < fieldWidth; step++) {
        if (step > 0 || dir != 0) {
          if (dir == 0) break;
          if (!f.fits(shape, x + dir, y)) break;
          x += dir;
          keys.add(dir < 0 ? Action.left : Action.right);
        }
        var dy = y;
        while (f.fits(shape, x, dy + 1)) {
          dy++;
        }
        final cells = [for (final c in shape) (x + c.$1, dy + c.$2)];
        final m = Move(
          [...keys, Action.hardDrop],
          (rot, x, dy),
          cells,
          _evaluate(g, shape, x, dy, rot, holesBefore),
        );
        final existing = byLanding[m.landingKey];
        if (existing == null || existing.keys.length > m.keys.length) {
          byLanding[m.landingKey] = m;
        }
        if (dir == 0) break;
      }
    }
  }
  return byLanding.values.toList();
}

Placement _evaluate(
  RealtimeTetris g,
  List<Cell> shape,
  int x,
  int y,
  int rot,
  int holesBefore,
) {
  final after = g.field.copy()..place(g.active!.piece, shape, x, y);
  final cleared = after.clearLines();
  final hs = after.heights();
  var bump = 0;
  for (var i = 0; i < fieldWidth - 1; i++) {
    bump += (hs[i] - hs[i + 1]).abs();
  }
  final holes = after.holes();
  final minX = shape.map((c) => x + c.$1).reduce(math.min);
  final minY = shape.map((c) => y + c.$2).reduce(math.min);
  return Placement(
    piece: g.active!.piece,
    rotation: rot,
    shape: [for (final c in shape) (x + c.$1 - minX, y + c.$2 - minY)],
    x: minX,
    y: minY,
    linesCleared: cleared,
    holes: holes,
    newHoles: math.max(0, holes - holesBefore),
    holesChange: holes - holesBefore,
    aggregateHeight: hs.reduce((a, b) => a + b),
    maxHeight: hs.reduce(math.max),
    bumpiness: bump,
  );
}
