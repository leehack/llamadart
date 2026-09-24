import 'dart:math' as math;
import 'dart:typed_data';

/// Board width in cells.
const int boardWidth = 10;

/// Board height in cells, without spawn rows.
const int boardHeight = 20;

/// The seven tetrominoes.
enum Piece {
  i('I'),
  o('O'),
  t('T'),
  s('S'),
  z('Z'),
  j('J'),
  l('L');

  const Piece(this.letter);

  /// Upper-case letter used in Laya prompts and the UI.
  final String letter;
}

/// A cell as (column, row), row 0 at the top.
typedef Cell = (int x, int y);

const Map<Piece, List<String>> _shapes = {
  Piece.i: ['....', 'XXXX', '....', '....'],
  Piece.o: ['.XX.', '.XX.', '....', '....'],
  Piece.t: ['.X..', 'XXX.', '....', '....'],
  Piece.s: ['.XX.', 'XX..', '....', '....'],
  Piece.z: ['XX..', '.XX.', '....', '....'],
  Piece.j: ['X...', 'XXX.', '....', '....'],
  Piece.l: ['..X.', 'XXX.', '....', '....'],
};

List<Cell> _normalize(Iterable<Cell> cells) {
  final minX = cells.map((c) => c.$1).reduce(math.min);
  final minY = cells.map((c) => c.$2).reduce(math.min);
  return [for (final c in cells) (c.$1 - minX, c.$2 - minY)]
    ..sort((a, b) => a.$2 != b.$2 ? a.$2 - b.$2 : a.$1 - b.$1);
}

/// Distinct rotations of each piece, cells normalized to a top-left origin.
final Map<Piece, List<List<Cell>>> rotations = {
  for (final p in Piece.values) p: _rotationsOf(p),
};

List<List<Cell>> _rotationsOf(Piece p) {
  var cells = <Cell>[
    for (var y = 0; y < 4; y++)
      for (var x = 0; x < 4; x++)
        if (_shapes[p]![y][x] == 'X') (x, y),
  ];
  final out = <List<Cell>>[];
  final seen = <String>{};
  for (var r = 0; r < 4; r++) {
    final n = _normalize(cells);
    if (seen.add(n.toString())) out.add(n);
    cells = [for (final c in cells) (3 - c.$2, c.$1)];
  }
  return out;
}

/// Row-major cells, row 0 at the top; 0 is empty, otherwise piece index + 1.
class Board {
  /// Creates an empty board.
  Board() : cells = Uint8List(boardWidth * boardHeight);
  Board._(this.cells);

  /// Cell contents, row-major.
  final Uint8List cells;

  /// Returns an independent copy.
  Board copy() => Board._(Uint8List.fromList(cells));

  /// Whether the cell at ([x], [y]) is filled.
  bool filled(int x, int y) => cells[y * boardWidth + x] != 0;

  /// Whether [shape] fits with its origin at ([x], [y]); rows above 0 are free.
  bool fits(List<Cell> shape, int x, int y) {
    for (final c in shape) {
      final cx = x + c.$1, cy = y + c.$2;
      if (cx < 0 || cx >= boardWidth || cy >= boardHeight) return false;
      if (cy >= 0 && filled(cx, cy)) return false;
    }
    return true;
  }

  /// Lowest resting y for a hard drop from above the board, or null if the
  /// piece would lock partly above the top.
  int? dropY(List<Cell> shape, int x) {
    final h = shape.map((c) => c.$2).reduce(math.max) + 1;
    var y = -h;
    if (!fits(shape, x, y)) return null;
    while (fits(shape, x, y + 1)) {
      y++;
    }
    return y < 0 ? null : y;
  }

  /// Locks [shape] and clears full rows; returns the number of cleared rows.
  int lock(Piece p, List<Cell> shape, int x, int y) {
    for (final c in shape) {
      cells[(y + c.$2) * boardWidth + x + c.$1] = p.index + 1;
    }
    var cleared = 0;
    for (var row = boardHeight - 1; row >= 0;) {
      var full = true;
      for (var cx = 0; cx < boardWidth; cx++) {
        if (!filled(cx, row)) {
          full = false;
          break;
        }
      }
      if (!full) {
        row--;
        continue;
      }
      cells.setRange(boardWidth, (row + 1) * boardWidth, cells);
      cells.fillRange(0, boardWidth, 0);
      cleared++;
    }
    return cleared;
  }

  /// Height of each column, 0 for an empty column.
  List<int> columnHeights() => [
    for (var x = 0; x < boardWidth; x++)
      () {
        for (var y = 0; y < boardHeight; y++) {
          if (filled(x, y)) return boardHeight - y;
        }
        return 0;
      }(),
  ];

  /// Empty cells with a filled cell somewhere above them.
  int holes() {
    var n = 0;
    for (var x = 0; x < boardWidth; x++) {
      var roof = false;
      for (var y = 0; y < boardHeight; y++) {
        if (filled(x, y)) {
          roof = true;
        } else if (roof) {
          n++;
        }
      }
    }
    return n;
  }

  /// Rows from the top of the stack down, '#' filled and '.' empty.
  List<String> stackRows() {
    final rows = <String>[];
    for (var y = 0; y < boardHeight; y++) {
      final s = String.fromCharCodes([
        for (var x = 0; x < boardWidth; x++) filled(x, y) ? 35 : 46,
      ]);
      if (rows.isNotEmpty || s.contains('#')) rows.add(s);
    }
    return rows;
  }
}

const List<String> _numberWords = [
  'no',
  'one',
  'two',
  'three',
  'four',
  'five',
  'six',
  'seven',
  'eight',
];

String _words(int v) => v < _numberWords.length ? _numberWords[v] : '$v';

/// One way to drop the current piece, with the board it leaves behind.
class Placement {
  /// Creates a placement and its resulting board statistics.
  Placement({
    required this.piece,
    required this.rotation,
    required this.shape,
    required this.x,
    required this.y,
    required this.linesCleared,
    required this.holes,
    required this.newHoles,
    required this.holesChange,
    required this.aggregateHeight,
    required this.maxHeight,
    required this.bumpiness,
  });

  /// The piece being placed.
  final Piece piece;

  /// Rotation index.
  final int rotation;

  /// Cells relative to ([x], [y]).
  final List<Cell> shape;

  /// Leftmost column and top row of the landed piece.
  final int x, y;

  /// Rows cleared by this placement.
  final int linesCleared;

  /// Holes on the resulting board.
  final int holes;

  /// Holes added, never negative.
  final int newHoles;

  /// Holes after minus holes before; negative when a clear uncovers holes.
  final int holesChange;

  /// Sum of the resulting column heights.
  final int aggregateHeight;

  /// Tallest resulting column.
  final int maxHeight;

  /// Sum of height differences between neighbouring columns.
  final int bumpiness;

  /// Width of the piece in this rotation.
  int get width => shape.map((c) => c.$1).reduce(math.max) + 1;

  /// Yiyuan Lee's tuned linear evaluation, the classic single-piece baseline.
  double get heuristic =>
      -0.510066 * aggregateHeight +
      0.760666 * linesCleared -
      0.35663 * holes -
      0.184483 * bumpiness;

  String get _columns =>
      width == 1 ? 'col ${x + 1}' : 'cols ${x + 1}-${x + width}';

  /// Terse form with digits.
  String describe() =>
      '$_columns rot $rotation: clears $linesCleared, new holes $newHoles, '
      'height $maxHeight, bumpiness $bumpiness';

  /// Short plain form that fits six options in Laya's 192-token head budget.
  ///
  /// The Tetris-tuned head was trained on this wording.
  String describeCompact() {
    final lines = linesCleared == 1
        ? 'one line'
        : '${_words(linesCleared)} lines';
    final holes = holesChange > 0
        ? (holesChange == 1
              ? 'adds one hole'
              : 'adds ${_words(holesChange)} holes')
        : holesChange < 0
        ? (holesChange == -1
              ? 'removes one hole'
              : 'removes ${_words(-holesChange)} holes')
        : 'no new holes';
    final cols = width == 1
        ? 'column ${x + 1}'
        : 'columns ${x + 1} to ${x + width}';
    return '$cols: clears $lines, $holes, stack $maxHeight rows, bumpiness $bumpiness';
  }

  /// Plain-English form with the counts as words.
  String describeNatural() {
    final lines = linesCleared == 1
        ? 'one line'
        : '${_words(linesCleared)} lines';
    final holes = newHoles == 1
        ? 'one new hole'
        : '${_words(newHoles)} new holes';
    final height = maxHeight <= 6
        ? 'low'
        : maxHeight <= 12
        ? 'medium'
        : 'dangerously high';
    final surface = bumpiness <= 6
        ? 'flat'
        : bumpiness <= 12
        ? 'a bit uneven'
        : 'very uneven';
    final cols = width == 1
        ? 'column ${x + 1}'
        : 'columns ${x + 1} to ${x + width}';
    return 'Dropping it in $cols clears $lines '
        'and adds $holes. Afterwards the stack is $height ($maxHeight rows) and $surface.';
  }
}

/// Every hard-drop landing of [piece] on [board].
List<Placement> enumeratePlacements(Board board, Piece piece) {
  final holesBefore = board.holes();
  final out = <Placement>[];
  final rots = rotations[piece]!;
  for (var r = 0; r < rots.length; r++) {
    final shape = rots[r];
    final w = shape.map((c) => c.$1).reduce(math.max) + 1;
    for (var x = 0; x <= boardWidth - w; x++) {
      final y = board.dropY(shape, x);
      if (y == null) continue;
      final after = board.copy();
      final cleared = after.lock(piece, shape, x, y);
      final hs = after.columnHeights();
      var bump = 0;
      for (var i = 0; i < boardWidth - 1; i++) {
        bump += (hs[i] - hs[i + 1]).abs();
      }
      final holes = after.holes();
      out.add(
        Placement(
          piece: piece,
          rotation: r,
          shape: shape,
          x: x,
          y: y,
          linesCleared: cleared,
          holes: holes,
          newHoles: math.max(0, holes - holesBefore),
          holesChange: holes - holesBefore,
          aggregateHeight: hs.reduce((a, b) => a + b),
          maxHeight: hs.reduce(math.max),
          bumpiness: bump,
        ),
      );
    }
  }
  return out;
}

/// Seeded 7-bag randomizer.
class Bag {
  /// Creates a bag with a fixed [seed].
  Bag(int seed) : _rng = math.Random(seed);
  final math.Random _rng;
  final _queue = <Piece>[];

  /// Removes and returns the next piece.
  Piece next() {
    if (_queue.length < 2) _queue.addAll([...Piece.values]..shuffle(_rng));
    return _queue.removeAt(0);
  }

  /// The piece [next] will return.
  Piece peek() {
    if (_queue.isEmpty) _queue.addAll([...Piece.values]..shuffle(_rng));
    return _queue.first;
  }
}

/// Points for 0 to 4 cleared lines in the turn-based game.
const List<int> lineScores = [0, 100, 300, 500, 800];

/// Turn-based Tetris without gravity: each turn places the current piece.
class Game {
  /// Starts a game whose pieces come from a bag seeded with [seed].
  Game(this.seed) : bag = Bag(seed) {
    current = bag.next();
  }

  /// Bag seed.
  final int seed;

  /// Piece source.
  final Bag bag;

  /// The playfield.
  final board = Board();

  /// The piece to place.
  late Piece current;

  /// Pieces placed, lines cleared and score so far.
  int pieces = 0, lines = 0, score = 0;

  /// Placements that cleared 0, 1, 2, 3 and 4 lines.
  final clears = List<int>.filled(5, 0);

  /// Whether the current piece has no legal placement.
  bool over = false;

  /// The piece after [current].
  Piece get next => bag.peek();

  /// Legal placements of [current].
  List<Placement> placements() => enumeratePlacements(board, current);

  /// Places [current] as [p] and draws the next piece.
  void apply(Placement p) {
    final cleared = board.lock(p.piece, p.shape, p.x, p.y);
    pieces++;
    lines += cleared;
    clears[cleared]++;
    score += lineScores[cleared];
    current = bag.next();
    if (placements().isEmpty) over = true;
  }
}
