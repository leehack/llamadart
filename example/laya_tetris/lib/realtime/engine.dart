import 'dart:math' as math;
import 'dart:typed_data';

import '../tetris.dart' show Cell, Piece;

/// Playfield width in cells.
const int fieldWidth = 10;

/// Playfield height including [hiddenRows].
const int fieldHeight = 22;

/// Spawn rows above the visible field.
const int hiddenRows = 2;

/// Time a grounded piece waits before it locks.
const double lockDelaySeconds = 0.5;

/// Moves or rotations that may restart the lock delay at one height.
const int maxLockResets = 15;

/// Player inputs.
enum Action { left, right, rotateCw, rotateCcw, softDrop, hardDrop, hold }

/// Playfield including [hiddenRows] spawn rows at the top; row 0 is the top.
class Field {
  /// Creates an empty field.
  Field() : cells = Uint8List(fieldWidth * fieldHeight);
  Field._(this.cells);

  /// Cell contents, row-major; 0 is empty, otherwise piece index + 1.
  final Uint8List cells;

  /// Returns an independent copy.
  Field copy() => Field._(Uint8List.fromList(cells));

  /// Whether the cell at ([x], [y]) is filled.
  bool filled(int x, int y) => cells[y * fieldWidth + x] != 0;

  /// Whether [shape] fits inside the field at ([x], [y]).
  bool fits(List<Cell> shape, int x, int y) {
    for (final c in shape) {
      final cx = x + c.$1, cy = y + c.$2;
      if (cx < 0 || cx >= fieldWidth || cy < 0 || cy >= fieldHeight) {
        return false;
      }
      if (filled(cx, cy)) return false;
    }
    return true;
  }

  /// Writes [shape] of [p] at ([x], [y]).
  void place(Piece p, List<Cell> shape, int x, int y) {
    for (final c in shape) {
      cells[(y + c.$2) * fieldWidth + x + c.$1] = p.index + 1;
    }
  }

  /// Removes full rows; returns how many were cleared.
  int clearLines() {
    var cleared = 0;
    for (var row = fieldHeight - 1; row >= 0;) {
      var full = true;
      for (var x = 0; x < fieldWidth; x++) {
        if (!filled(x, row)) {
          full = false;
          break;
        }
      }
      if (!full) {
        row--;
        continue;
      }
      cells.setRange(fieldWidth, (row + 1) * fieldWidth, cells);
      cells.fillRange(0, fieldWidth, 0);
      cleared++;
    }
    return cleared;
  }

  /// Height of each column, 0 for an empty column.
  List<int> heights() => [
    for (var x = 0; x < fieldWidth; x++)
      () {
        for (var y = 0; y < fieldHeight; y++) {
          if (filled(x, y)) return fieldHeight - y;
        }
        return 0;
      }(),
  ];

  /// Empty cells with a filled cell somewhere above them.
  int holes() {
    var n = 0;
    for (var x = 0; x < fieldWidth; x++) {
      var roof = false;
      for (var y = 0; y < fieldHeight; y++) {
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
    for (var y = 0; y < fieldHeight; y++) {
      final s = String.fromCharCodes([
        for (var x = 0; x < fieldWidth; x++) filled(x, y) ? 35 : 46,
      ]);
      if (rows.isNotEmpty || s.contains('#')) rows.add(s);
    }
    return rows;
  }
}

const Map<Piece, (int, List<Cell>)> _spawnShapes = {
  Piece.i: (4, [(0, 1), (1, 1), (2, 1), (3, 1)]),
  Piece.o: (2, [(0, 0), (1, 0), (0, 1), (1, 1)]),
  Piece.t: (3, [(1, 0), (0, 1), (1, 1), (2, 1)]),
  Piece.s: (3, [(1, 0), (2, 0), (0, 1), (1, 1)]),
  Piece.z: (3, [(0, 0), (1, 0), (1, 1), (2, 1)]),
  Piece.j: (3, [(0, 0), (0, 1), (1, 1), (2, 1)]),
  Piece.l: (3, [(2, 0), (0, 1), (1, 1), (2, 1)]),
};

/// The four SRS rotation states of each piece inside its bounding box.
final Map<Piece, List<List<Cell>>> srsStates = {
  for (final p in Piece.values)
    p: () {
      final (n, cells) = _spawnShapes[p]!;
      final states = <List<Cell>>[cells];
      for (var r = 1; r < 4; r++) {
        states.add([for (final c in states.last) (n - 1 - c.$2, c.$1)]);
      }
      return states;
    }(),
};

/// Bounding-box size of [p].
int boxSize(Piece p) => _spawnShapes[p]!.$1;

// SRS kick offsets with y pointing down (the guideline tables use y up).
const Map<(int, int), List<Cell>> _kicksJlstz = {
  (0, 1): [(0, 0), (-1, 0), (-1, -1), (0, 2), (-1, 2)],
  (1, 0): [(0, 0), (1, 0), (1, 1), (0, -2), (1, -2)],
  (1, 2): [(0, 0), (1, 0), (1, 1), (0, -2), (1, -2)],
  (2, 1): [(0, 0), (-1, 0), (-1, -1), (0, 2), (-1, 2)],
  (2, 3): [(0, 0), (1, 0), (1, -1), (0, 2), (1, 2)],
  (3, 2): [(0, 0), (-1, 0), (-1, 1), (0, -2), (-1, -2)],
  (3, 0): [(0, 0), (-1, 0), (-1, 1), (0, -2), (-1, -2)],
  (0, 3): [(0, 0), (1, 0), (1, -1), (0, 2), (1, 2)],
};

const Map<(int, int), List<Cell>> _kicksI = {
  (0, 1): [(0, 0), (-2, 0), (1, 0), (-2, 1), (1, -2)],
  (1, 0): [(0, 0), (2, 0), (-1, 0), (2, -1), (-1, 2)],
  (1, 2): [(0, 0), (-1, 0), (2, 0), (-1, -2), (2, 1)],
  (2, 1): [(0, 0), (1, 0), (-2, 0), (1, 2), (-2, -1)],
  (2, 3): [(0, 0), (2, 0), (-1, 0), (2, -1), (-1, 2)],
  (3, 2): [(0, 0), (-2, 0), (1, 0), (-2, 1), (1, -2)],
  (3, 0): [(0, 0), (1, 0), (-2, 0), (1, 2), (-2, -1)],
  (0, 3): [(0, 0), (-1, 0), (2, 0), (-1, -2), (2, 1)],
};

/// Position of a piece: rotation state and bounding-box origin.
typedef Pose = (int rot, int x, int y);

/// Rotates with SRS wall kicks; [dir] is +1 clockwise or -1 counter-clockwise.
Pose? tryRotate(Field f, Piece p, Pose pose, int dir) =>
    tryRotateKick(f, p, pose, dir)?.$1;

/// Like [tryRotate], also returning which kick test (0-4) succeeded.
(Pose, int)? tryRotateKick(Field f, Piece p, Pose pose, int dir) {
  if (p == Piece.o) return (pose, 0);
  final (rot, x, y) = pose;
  final to = (rot + dir) & 3;
  final shape = srsStates[p]![to];
  final kicks = (p == Piece.i ? _kicksI : _kicksJlstz)[(rot, to)]!;
  for (var i = 0; i < kicks.length; i++) {
    final (dx, dy) = kicks[i];
    if (f.fits(shape, x + dx, y + dy)) return ((to, x + dx, y + dy), i);
  }
  return null;
}

/// T-spin kind of a lock.
enum Spin { none, mini, full }

/// The falling piece.
class Active {
  /// Creates a piece at rotation [rot] and origin ([x], [y]).
  Active(this.piece, this.rot, this.x, this.y, this.id);

  /// Piece type.
  final Piece piece;

  /// Rotation state and bounding-box origin.
  int rot, x, y;

  /// Unique per spawned piece within a game.
  final int id;

  /// Whether the last successful maneuver was a rotation.
  bool lastWasRotation = false;

  /// Kick test (0-4) of the last rotation.
  int lastKick = 0;

  /// Cells of the current rotation.
  List<Cell> get shape => srsStates[piece]![rot];

  /// Current pose.
  Pose get pose => (rot, x, y);
  set pose(Pose p) {
    rot = p.$1;
    x = p.$2;
    y = p.$3;
  }
}

/// Real-time Tetris with gravity, lock delay, hold, levels and guideline
/// scoring including T-spins, back-to-backs and combos.
class RealtimeTetris {
  /// Starts a game with a 7-bag seeded by [seed].
  RealtimeTetris({required int seed, this.startLevel = 1})
    : _rng = math.Random(seed) {
    _spawn();
  }

  /// Level at zero lines.
  final int startLevel;
  final math.Random _rng;

  /// The playfield.
  final field = Field();
  final _queue = <Piece>[];

  /// The falling piece, or null after game over.
  Active? active;

  /// Score, cleared lines and locked pieces.
  int score = 0, lines = 0, pieces = 0;

  /// Locks that cleared 0, 1, 2, 3 and 4 lines.
  final clears = List<int>.filled(5, 0);

  /// Whether the game has ended.
  bool over = false;

  /// The held piece.
  Piece? held;

  /// Whether hold is allowed for the current piece.
  bool canHold = true;

  /// T-spins and back-to-back bonuses so far.
  int tSpins = 0, backToBacks = 0;

  /// Consecutive clearing locks minus one; -1 without a running combo.
  int combo = -1;
  bool _b2bReady = false;

  /// Name of the latest scoring event, such as "T-Spin Double +1200".
  String lastEvent = '';

  /// Changes whenever [lastEvent] does.
  int eventId = 0;
  double _gravity = 0, _lock = 0;
  int _resets = 0, _lowest = 0, _nextId = 0;

  /// Current level: one more every ten lines.
  int get level => startLevel + lines ~/ 10;

  /// Guideline gravity: seconds for the piece to fall one row.
  double get secondsPerRow =>
      math.pow(math.max(0.0, 0.8 - (level - 1) * 0.007), level - 1).toDouble();

  /// The next [n] pieces.
  List<Piece> preview(int n) {
    while (_queue.length < n) {
      _queue.addAll([...Piece.values]..shuffle(_rng));
    }
    return _queue.take(n).toList();
  }

  void _spawn([Piece? forced]) {
    final Piece p;
    if (forced != null) {
      p = forced;
    } else {
      p = preview(1).first;
      _queue.removeAt(0);
    }
    final n = boxSize(p);
    final a = Active(
      p,
      0,
      (fieldWidth - n) ~/ 2,
      p == Piece.i ? -1 : 0,
      _nextId++,
    );
    if (!field.fits(a.shape, a.x, a.y)) {
      over = true;
      active = null;
      return;
    }
    if (field.fits(a.shape, a.x, a.y + 1)) a.y++;
    active = a;
    _gravity = 0;
    _lock = 0;
    _resets = 0;
    _lowest = a.y;
  }

  bool _fits(Pose p) => field.fits(srsStates[active!.piece]![p.$1], p.$2, p.$3);

  /// Whether the active piece rests on something.
  bool get grounded {
    final a = active;
    return a != null && !field.fits(a.shape, a.x, a.y + 1);
  }

  /// Rows the active piece would fall on a hard drop.
  int dropDistance() {
    final a = active;
    if (a == null) return 0;
    var d = 0;
    while (field.fits(a.shape, a.x, a.y + d + 1)) {
      d++;
    }
    return d;
  }

  /// Advances gravity and the lock delay by [dt] seconds.
  void tick(double dt) {
    final a = active;
    if (over || a == null) return;
    _gravity += dt;
    final spr = secondsPerRow;
    while (_gravity >= spr && field.fits(a.shape, a.x, a.y + 1)) {
      _gravity -= spr;
      a.y++;
      a.lastWasRotation = false;
      _touchedDown(a);
    }
    if (grounded) {
      _gravity = 0;
      _lock += dt;
      if (_lock >= lockDelaySeconds) _lockPiece();
    } else {
      _lock = 0;
    }
  }

  void _touchedDown(Active a) {
    if (a.y > _lowest) {
      _lowest = a.y;
      _resets = 0;
    }
  }

  void _moved() {
    if (grounded && _resets < maxLockResets) {
      _lock = 0;
      _resets++;
    }
  }

  /// Applies one key action; returns whether it had an effect.
  bool input(Action action) {
    final a = active;
    if (over || a == null) return false;
    switch (action) {
      case Action.left || Action.right:
        final dx = action == Action.left ? -1 : 1;
        if (!_fits((a.rot, a.x + dx, a.y))) return false;
        a.x += dx;
        a.lastWasRotation = false;
        _moved();
        return true;
      case Action.rotateCw || Action.rotateCcw:
        final r = tryRotateKick(
          field,
          a.piece,
          a.pose,
          action == Action.rotateCw ? 1 : -1,
        );
        if (r == null) return false;
        a.pose = r.$1;
        a.lastWasRotation = true;
        a.lastKick = r.$2;
        _touchedDown(a);
        _moved();
        return true;
      case Action.softDrop:
        if (!field.fits(a.shape, a.x, a.y + 1)) return false;
        a.y++;
        a.lastWasRotation = false;
        score += 1;
        _gravity = 0;
        _touchedDown(a);
        return true;
      case Action.hardDrop:
        final d = dropDistance();
        a.y += d;
        if (d > 0) a.lastWasRotation = false;
        score += 2 * d;
        _lockPiece();
        return true;
      case Action.hold:
        if (!canHold) return false;
        final swap = held;
        held = a.piece;
        canHold = false;
        _spawn(swap);
        return true;
    }
  }

  /// Guideline 3-corner T-spin check, before the piece is placed.
  Spin _spin(Active a) {
    if (a.piece != Piece.t || !a.lastWasRotation) return Spin.none;
    bool occ(int dx, int dy) {
      final x = a.x + dx, y = a.y + dy;
      return x < 0 ||
          x >= fieldWidth ||
          y < 0 ||
          y >= fieldHeight ||
          field.filled(x, y);
    }

    final corners = [occ(0, 0), occ(2, 0), occ(2, 2), occ(0, 2)];
    if (corners.where((c) => c).length < 3) return Spin.none;
    final front = [(0, 1), (1, 2), (2, 3), (3, 0)][a.rot];
    final frontCount =
        (corners[front.$1] ? 1 : 0) + (corners[front.$2] ? 1 : 0);
    return frontCount == 2 || a.lastKick == 4 ? Spin.full : Spin.mini;
  }

  void _lockPiece() {
    final a = active!;
    final spin = _spin(a);
    field.place(a.piece, a.shape, a.x, a.y);
    pieces++;
    final aboveVisible = a.shape.every((c) => a.y + c.$2 < hiddenRows);
    final cleared = field.clearLines();
    clears[cleared]++;
    final base = switch (spin) {
      Spin.full => const [400, 800, 1200, 1600][cleared],
      Spin.mini => const [100, 200, 400, 400][cleared],
      Spin.none => const [0, 100, 300, 500, 800][cleared],
    };
    var points = base * level;
    final names = <String>[];
    if (spin != Spin.none) {
      tSpins++;
      names.add('${spin == Spin.mini ? 'Mini ' : ''}T-Spin');
    }
    if (cleared > 0) {
      final difficult = cleared == 4 || spin != Spin.none;
      if (difficult && _b2bReady) {
        points = points * 3 ~/ 2;
        backToBacks++;
        names.insert(0, 'Back-to-Back');
      }
      _b2bReady = difficult;
      combo++;
      if (combo > 0) {
        points += 50 * combo * level;
        names.add('Combo $combo');
      }
      names.add(const ['', 'Single', 'Double', 'Triple', 'Tetris'][cleared]);
    } else {
      combo = -1;
    }
    score += points;
    lines += cleared;
    if (names.isNotEmpty) {
      lastEvent = '${names.join(' ')}${points > 0 ? ' +$points' : ''}';
      eventId++;
    }
    canHold = true;
    if (aboveVisible) {
      over = true;
      active = null;
      return;
    }
    _spawn();
  }
}
