import 'package:flutter_test/flutter_test.dart';
import 'package:laya_tetris_example/tetris.dart';

void fillRow(Board b, int y, {Set<int> except = const {}}) {
  for (var x = 0; x < boardWidth; x++) {
    if (!except.contains(x)) b.cells[y * boardWidth + x] = 1;
  }
}

Placement bestOf(List<Placement> ps) =>
    ps.reduce((a, b) => b.heuristic > a.heuristic ? b : a);

void main() {
  test('each piece has its distinct rotations', () {
    expect(
      {for (final p in Piece.values) p: rotations[p]!.length},
      {
        Piece.i: 2,
        Piece.o: 1,
        Piece.t: 4,
        Piece.s: 2,
        Piece.z: 2,
        Piece.j: 4,
        Piece.l: 4,
      },
    );
  });

  test('an empty board offers every rotation at every column', () {
    expect(enumeratePlacements(Board(), Piece.t), hasLength(8 + 9 + 8 + 9));
    expect(enumeratePlacements(Board(), Piece.i), hasLength(7 + 10));
    expect(enumeratePlacements(Board(), Piece.o), hasLength(9));
  });

  test('a vertical I clears four rows and scores a tetris', () {
    final g = Game(1);
    for (var y = boardHeight - 4; y < boardHeight; y++) {
      fillRow(g.board, y, except: {9});
    }
    g.current = Piece.i;
    final drop = g.placements().singleWhere((p) => p.rotation == 1 && p.x == 9);
    expect(drop.linesCleared, 4);
    expect(drop.aggregateHeight, 0);
    g.apply(drop);
    expect(g.lines, 4);
    expect(g.score, lineScores[4]);
    expect(g.clears[4], 1);
    expect(g.board.cells.every((c) => c == 0), isTrue);
  });

  test('clearing a row shifts the rows above it down', () {
    final b = Board();
    fillRow(b, boardHeight - 1, except: {0, 1});
    b.cells[(boardHeight - 2) * boardWidth + 5] = 3;
    final cleared = b.lock(Piece.o, rotations[Piece.o]!.single, 0, 18);
    expect(cleared, 1);
    expect(b.filled(0, boardHeight - 1), isTrue);
    expect(b.filled(5, boardHeight - 1), isTrue);
    expect(b.filled(2, boardHeight - 1), isFalse);
    expect(b.filled(0, boardHeight - 2), isFalse);
  });

  test('placements report holes they add and remove', () {
    final b = Board();
    fillRow(b, boardHeight - 1, except: {0});
    final flat = rotations[Piece.i]![0];
    final covering = enumeratePlacements(
      b,
      Piece.i,
    ).firstWhere((p) => p.shape == flat && p.x == 0);
    expect(covering.newHoles, 1);
    expect(covering.holesChange, 1);
    expect(covering.holes, 1);
    expect(covering.maxHeight, 2);

    for (var x = 0; x < 6; x++) {
      b.cells[(boardHeight - 2) * boardWidth + x] = 1;
    }
    expect(b.holes(), 1);
    final uncovering = enumeratePlacements(
      b,
      Piece.i,
    ).singleWhere((p) => p.shape == flat && p.x == 6);
    expect(uncovering.linesCleared, 1);
    expect(uncovering.holesChange, -1);
    expect(uncovering.newHoles, 0);
    expect(uncovering.describeCompact(), contains('removes one hole'));
  });

  test('the game ends when the next piece has no legal placement', () {
    final g = Game(4);
    for (var y = 1; y < boardHeight; y++) {
      fillRow(g.board, y, except: {y.isEven ? 0 : 9});
    }
    g.current = Piece.i;
    expect(g.next, isNot(Piece.i));
    g.apply(g.placements().singleWhere((p) => p.rotation == 0 && p.x == 0));
    expect(g.placements(), isEmpty);
    expect(g.over, isTrue);
  });

  test('the bag deals every piece once per seven', () {
    final bag = Bag(42);
    for (var round = 0; round < 3; round++) {
      final dealt = {for (var i = 0; i < 7; i++) bag.next()};
      expect(dealt, Piece.values.toSet());
    }
    final peeked = bag.peek();
    expect(bag.next(), peeked);
  });

  test('move descriptions keep the wording Laya was prompted with', () {
    final g = Game(7);
    for (var i = 0; i < 25; i++) {
      g.apply(bestOf(g.placements()));
    }
    expect(g.board.stackRows(), [
      '.#..#.....',
      '##..#.....',
      '#####...#.',
      '.#########',
    ]);
    expect((g.current.letter, g.next.letter, g.board.holes()), ('J', 'L', 1));
    final first = g.placements().first;
    expect(
      first.describe(),
      'cols 1-3 rot 0: clears 0, new holes 3, height 6, bumpiness 11',
    );
    expect(
      first.describeNatural(),
      'Dropping it in columns 1 to 3 clears no lines and adds three new '
      'holes. Afterwards the stack is low (6 rows) and a bit uneven.',
    );
    expect(
      first.describeCompact(),
      'columns 1 to 3: clears no lines, adds three holes, stack 6 rows, '
      'bumpiness 11',
    );
    final b = Board();
    fillRow(b, boardHeight - 1, except: {0, 1, 2, 3});
    final single = enumeratePlacements(
      b,
      Piece.i,
    ).singleWhere((p) => p.rotation == 0 && p.x == 0);
    expect(
      single.describeCompact(),
      'columns 1 to 4: clears one line, no new holes, stack 0 rows, '
      'bumpiness 0',
    );
    expect(
      single.describeNatural(),
      'Dropping it in columns 1 to 4 clears one line and adds no new holes. '
      'Afterwards the stack is low (0 rows) and flat.',
    );
  });
}
