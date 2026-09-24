import 'package:flutter_test/flutter_test.dart';
import 'package:laya_tetris_example/realtime/engine.dart';
import 'package:laya_tetris_example/realtime/planner.dart';
import 'package:laya_tetris_example/tetris.dart' show Piece;

void fillRow(Field f, int y, {Set<int> except = const {}}) {
  for (var x = 0; x < fieldWidth; x++) {
    if (!except.contains(x)) f.cells[y * fieldWidth + x] = 1;
  }
}

RealtimeTetris tsdSetup({required bool rotated}) {
  final g = RealtimeTetris(seed: 1);
  fillRow(g.field, 21, except: {4});
  fillRow(g.field, 20, except: {3, 4, 5});
  g.field.cells[19 * fieldWidth + 5] = 1;
  g.active = Active(Piece.t, 2, 3, 19, 99)..lastWasRotation = rotated;
  return g;
}

List<int> occupied(Field f) => [
  for (var i = 0; i < f.cells.length; i++)
    if (f.cells[i] != 0) i,
];

void main() {
  test('T-spin double scores 1200 x level and clears two lines', () {
    final g = tsdSetup(rotated: true);
    g.input(Action.hardDrop);
    expect(g.lines, 2);
    expect(g.tSpins, 1);
    expect(g.lastEvent, 'T-Spin Double +1200');
    expect(g.score, 1200);
  });

  test('the same drop without a final rotation is a plain double', () {
    final g = tsdSetup(rotated: false);
    g.input(Action.hardDrop);
    expect(g.lines, 2);
    expect(g.tSpins, 0);
    expect(g.lastEvent, 'Double +300');
  });

  test('rotating into the T slot through input makes the drop a T-spin', () {
    final g = tsdSetup(rotated: false);
    g.active = Active(Piece.t, 1, 3, 19, 99);
    expect(g.input(Action.rotateCw), isTrue);
    expect(g.active!.pose, (2, 3, 19));
    expect(g.active!.lastWasRotation, isTrue);
    g.input(Action.hardDrop);
    expect(g.tSpins, 1);
    expect(g.lastEvent, 'T-Spin Double +1200');
  });

  test('back-to-back tetrises earn 1.5x', () {
    final g = RealtimeTetris(seed: 1);
    for (var round = 0; round < 2; round++) {
      for (var y = 18; y < 22; y++) {
        fillRow(g.field, y, except: {9});
      }
      g.active = Active(Piece.i, 1, 7, 0, 100 + round);
      g.input(Action.hardDrop);
    }
    expect(g.clears[4], 2);
    expect(g.backToBacks, 1);
    expect(g.lastEvent, startsWith('Back-to-Back Combo 1 Tetris'));
  });

  test('hold swaps once per piece', () {
    final g = RealtimeTetris(seed: 3);
    final first = g.active!.piece;
    final next = g.preview(1).first;
    expect(g.input(Action.hold), isTrue);
    expect(g.held, first);
    expect(g.active!.piece, next);
    expect(g.input(Action.hold), isFalse);
    g.input(Action.hardDrop);
    expect(g.canHold, isTrue);
    final third = g.active!.piece;
    expect(g.input(Action.hold), isTrue);
    expect(g.active!.piece, first);
    expect(g.held, third);
  });

  test('gravity drops the piece and the lock delay locks it', () {
    final g = RealtimeTetris(seed: 5);
    final id = g.active!.id;
    final y = g.active!.y;
    g.tick(g.secondsPerRow + 0.001);
    expect(g.active!.y, y + 1);
    for (var i = 0; i < 1000 && !g.grounded; i++) {
      g.tick(0.05);
    }
    expect(g.grounded, isTrue);
    expect(g.active!.id, id);
    expect(g.pieces, 0);
    g.tick(lockDelaySeconds);
    expect(g.pieces, 1);
    expect(g.active!.id, isNot(id));
  });

  test('levels rise every ten lines and speed up gravity', () {
    final g = RealtimeTetris(seed: 1, startLevel: 3);
    final slow = g.secondsPerRow;
    g.lines = 10;
    expect(g.level, 4);
    expect(g.secondsPerRow, lessThan(slow));
  });

  test('a piece locked entirely in the hidden rows ends the game', () {
    final g = RealtimeTetris(seed: 2);
    for (var y = hiddenRows; y < fieldHeight; y++) {
      fillRow(g.field, y, except: {y.isEven ? 0 : 9});
    }
    g.active = Active(Piece.o, 0, 4, 0, 50);
    g.input(Action.hardDrop);
    expect(g.over, isTrue);
    expect(g.active, isNull);
  });

  test('every planned move lands exactly where the planner says', () {
    for (final seed in [1, 2, 3]) {
      final g = RealtimeTetris(seed: seed);
      fillRow(g.field, 21, except: {2, 7});
      fillRow(g.field, 20, except: {2, 3, 6, 7, 8});
      final moves = planMoves(g);
      expect(moves, isNotEmpty);
      expect(
        {for (final m in moves) m.landingKey},
        hasLength(moves.length),
        reason: 'one move per distinct landing',
      );
      for (final m in moves) {
        final replay = RealtimeTetris(seed: seed);
        replay.field.cells.setAll(0, g.field.cells);
        replay.active = Active(g.active!.piece, 0, g.active!.x, g.active!.y, 1);
        final before = occupied(replay.field).toSet();
        final piece = replay.active!.piece;
        for (final k in m.keys) {
          replay.input(k);
        }
        expect(replay.pieces, 1);
        if (m.placement.linesCleared == 0) {
          final placed = occupied(replay.field).toSet().difference(before);
          expect(placed, {
            for (final (x, y) in m.cells) y * fieldWidth + x,
          }, reason: '$piece ${m.keys}');
        } else {
          expect(replay.lines, m.placement.linesCleared);
        }
      }
    }
  });

  test('the planner finds every landing of a T on an empty field', () {
    final g = RealtimeTetris(seed: 1);
    g.active = Active(Piece.t, 0, 3, 1, 1);
    expect(planMoves(g), hasLength(8 + 9 + 8 + 9));
  });
}
