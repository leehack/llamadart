import 'dart:math' as math;

import 'package:llamadart/llamadart.dart';

import 'tetris.dart';

/// Answers several Laya requests in one call, like
/// [DecisionEngine.systemOneBatch].
typedef LayaDecide =
    Future<List<DecisionResult>> Function(List<DecisionRequest> requests);

/// Who picks the placement.
enum PlayerKind {
  /// Best placement by [Placement.heuristic] over all legal moves.
  heuristic('Heuristic bot'),

  /// A random candidate.
  random('Random candidate'),

  /// Laya checklist: two yes/no facts per candidate.
  layaChecklist('Laya yes/no checklist', isLaya: true),

  /// Laya yes/no: is this a good move?
  layaJudge('Laya yes/no: good move?', isLaya: true),

  /// One Laya choice question over up to six candidates.
  layaChoice('Laya choice (A-F)', isLaya: true),

  /// Knockout of six-way choice questions with the Tetris-tuned head.
  layaTuned('Laya choice (Tetris-tuned)', isLaya: true);

  const PlayerKind(this.label, {this.isLaya = false});

  /// Display name.
  final String label;

  /// Whether this player asks Laya.
  final bool isLaya;
}

/// Which legal placements a candidate-based player considers.
enum ShortlistMode {
  /// The three best by heuristic plus three random others.
  mixed('3 best + 3 random'),

  /// The six best by heuristic.
  top('6 best by heuristic'),

  /// Six random placements.
  random('6 random'),

  /// Every legal placement.
  all('All legal moves');

  const ShortlistMode(this.label);

  /// Display name.
  final String label;
}

/// Candidates per shortlist and per choice question.
const int shortlistSize = 6;

/// Option labels of choice questions.
const List<String> optionLabels = ['A', 'B', 'C', 'D', 'E', 'F'];

/// Instructions of the base-head choice player.
const String layaInstructions =
    'Which placement of the falling Tetris piece is best? Prefer clearing '
    'lines, avoid new holes, and keep the stack low and flat.';

/// Instructions of the yes/no judge.
const String judgeInstructions =
    'Is this a good Tetris move? A good move clears lines, or adds no new '
    'holes and keeps the stack low and flat.';

/// Instructions the Tetris-tuned head was trained with.
///
/// `bin/make_dataset.dart` writes them into the training data; keep both in
/// sync.
const String tuneInstructions =
    'Which placement of the falling Tetris piece is best?';

/// Checklist question about line clears.
const String clearInstructions = 'Does this move clear at least one line?';

/// Checklist question about new holes.
const String holeInstructions = 'Does this move add any new holes?';

/// Laya heads a player can use; either may be missing.
class LayaHeads {
  /// Creates a set of heads.
  const LayaHeads({this.base, this.tuned});

  /// The published base head.
  final LayaDecide? base;

  /// The Tetris-tuned head.
  final LayaDecide? tuned;

  /// The head [kind] needs, or null when it needs none or it is missing.
  LayaDecide? of(PlayerKind kind) => !kind.isLaya
      ? null
      : kind == PlayerKind.layaTuned
      ? tuned
      : base;
}

/// Candidate placements in the order they are shown to the player.
List<Placement> buildShortlist(
  List<Placement> all,
  ShortlistMode mode,
  math.Random rng,
) {
  final ranked = [...all]..sort((a, b) => b.heuristic.compareTo(a.heuristic));
  final List<Placement> picked;
  switch (mode) {
    case ShortlistMode.all:
      picked = [...all];
    case ShortlistMode.top:
      picked = ranked.take(shortlistSize).toList();
    case ShortlistMode.random:
      picked = ([...all]..shuffle(rng)).take(shortlistSize).toList();
    case ShortlistMode.mixed:
      final best = ranked.take(3).toList();
      final rest = ranked.skip(3).toList()..shuffle(rng);
      picked = [...best, ...rest.take(shortlistSize - best.length)];
  }
  return picked..shuffle(rng);
}

/// Board state for the base-head choice player.
Map<String, Object> layaBoardState({
  required Piece piece,
  required Piece next,
  required int holes,
  required List<String> stack,
}) => {
  'game': 'tetris',
  'piece': piece.letter,
  'next': next.letter,
  'holes': holes,
  'stack': stack,
};

/// State describing one move, for the yes/no players.
Map<String, Object> moveState(
  Piece piece,
  Placement p, {
  bool natural = true,
}) => {
  'game': 'tetris',
  'piece': piece.letter,
  'move': natural ? p.describeNatural() : p.describe(),
};

/// Laya's verdict on a list of candidates.
class LayaVerdict {
  /// Creates a verdict.
  LayaVerdict({
    required this.chosen,
    required this.scores,
    required this.tokens,
    required this.questions,
    this.facts,
  });

  /// Index of the chosen candidate.
  final int chosen;

  /// Per candidate: choice probability, judge p(yes), or checklist score.
  ///
  /// In a knockout, each candidate's probability in the last group it played.
  final List<double> scores;

  /// Checklist only: per candidate (p clears a line, p adds a hole).
  final List<(double, double)>? facts;

  /// Encoded tokens over all questions.
  final int tokens;

  /// Questions asked, one encoder pass each.
  final int questions;
}

/// Index of the maximum of [v], breaking exact ties at random.
int argmaxRandomTies(List<double> v, math.Random rng) {
  final m = v.reduce(math.max);
  final best = [
    for (var i = 0; i < v.length; i++)
      if (v[i] >= m - 1e-9) i,
  ];
  return best[rng.nextInt(best.length)];
}

int _tokens(List<DecisionResult> rs) =>
    rs.fold(0, (a, r) => a + r.usage.inputTokens);

int _questions(List<DecisionResult> rs) =>
    rs.fold(0, (a, r) => a + r.answers.length);

/// Asks, for every candidate, whether it is a good move.
Future<LayaVerdict> judgeWithLaya(
  LayaDecide decide,
  Piece piece,
  List<Placement> options,
  math.Random rng, {
  bool natural = true,
}) async {
  final rs = await decide([
    for (final o in options)
      DecisionRequest(
        state: moveState(piece, o, natural: natural),
        questions: {'good': DecisionQuestion.noul(judgeInstructions)},
      ),
  ]);
  final scores = [for (final r in rs) r.nouls['good']!.noul];
  return LayaVerdict(
    chosen: argmaxRandomTies(scores, rng),
    scores: scores,
    tokens: _tokens(rs),
    questions: _questions(rs),
  );
}

/// Asks, for every candidate, whether it clears a line and whether it adds a
/// hole; scores p(clear) - p(hole).
Future<LayaVerdict> checklistWithLaya(
  LayaDecide decide,
  Piece piece,
  List<Placement> options,
  math.Random rng, {
  bool natural = true,
}) async {
  final rs = await decide([
    for (final o in options)
      DecisionRequest(
        state: moveState(piece, o, natural: natural),
        questions: {
          'clears': DecisionQuestion.noul(clearInstructions),
          'holes': DecisionQuestion.noul(holeInstructions),
        },
      ),
  ]);
  final facts = [
    for (final r in rs) (r.nouls['clears']!.noul, r.nouls['holes']!.noul),
  ];
  final scores = [for (final (c, h) in facts) c - h];
  return LayaVerdict(
    chosen: argmaxRandomTies(scores, rng),
    scores: scores,
    facts: facts,
    tokens: _tokens(rs),
    questions: _questions(rs),
  );
}

/// Asks one choice question over at most [shortlistSize] candidates.
Future<LayaVerdict> chooseWithLaya(
  LayaDecide decide,
  Map<String, Object> boardState,
  List<Placement> options,
) async {
  if (options.length > shortlistSize) {
    throw ArgumentError.value(
      options.length,
      'options',
      'A choice question takes at most $shortlistSize candidates',
    );
  }
  final move = ChoiceKey.of(
    'move',
    layaInstructions,
    options: options,
    label: (_, i) => optionLabels[i],
    describe: (p) => p.describe(),
  );
  final rs = await decide([
    DecisionRequest(
      state: boardState,
      questions: DecisionKey.questionsOf([move]),
    ),
  ]);
  final answer = rs.single.answerOf(move);
  return LayaVerdict(
    chosen: answer.index,
    scores: answer.optionProbabilities,
    tokens: _tokens(rs),
    questions: _questions(rs),
  );
}

/// Tuned-head knockout: groups of up to six, winners advance until one
/// remains. Each round's groups go to [decide] as one batch.
Future<LayaVerdict> knockoutWithLaya(
  LayaDecide decide,
  Piece piece,
  List<Placement> options,
  math.Random rng,
) async {
  final scores = List<double>.filled(options.length, 1);
  var alive = [for (var i = 0; i < options.length; i++) i]..shuffle(rng);
  var tokens = 0, questions = 0;
  while (alive.length > 1) {
    final n = (alive.length / shortlistSize).ceil();
    final groups = [
      for (var g = 0; g < n; g++)
        alive.sublist(g * alive.length ~/ n, (g + 1) * alive.length ~/ n),
    ];
    final rs = await decide([
      for (final g in groups)
        DecisionRequest(
          state: {'game': 'tetris', 'piece': piece.letter},
          questions: {
            'move': DecisionQuestion.choice(
              tuneInstructions,
              criteria: {
                for (var j = 0; j < g.length; j++)
                  optionLabels[j]: options[g[j]].describeCompact(),
              },
            ),
          },
        ),
    ]);
    alive = [
      for (var g = 0; g < n; g++)
        () {
          final p = rs[g].choices['move']!.probabilities.values.toList();
          for (var j = 0; j < groups[g].length; j++) {
            scores[groups[g][j]] = p[j];
          }
          return groups[g][argmaxRandomTies(p, rng)];
        }(),
    ];
    tokens += _tokens(rs);
    questions += _questions(rs);
  }
  return LayaVerdict(
    chosen: alive.single,
    scores: scores,
    tokens: tokens,
    questions: questions,
  );
}

/// A player's choice among candidate placements.
class Pick {
  /// Creates a pick.
  Pick(this.options, this.chosen, {this.verdict, this.micros = 0});

  /// Candidates the player considered.
  final List<Placement> options;

  /// Index of the chosen candidate in [options].
  final int chosen;

  /// Laya's verdict, for Laya players.
  final LayaVerdict? verdict;

  /// Wall time of the Laya calls in microseconds.
  final int micros;

  /// The chosen placement.
  Placement get placement => options[chosen];
}

/// Picks one of [all] for [piece] as [kind].
///
/// [boardState] is only read by [PlayerKind.layaChoice], which considers at
/// most six candidates and so uses [ShortlistMode.mixed] instead of
/// [ShortlistMode.all]. Throws [StateError] when [kind] needs a head that
/// [heads] lacks.
Future<Pick> pickPlacement(
  PlayerKind kind,
  List<Placement> all, {
  required Piece piece,
  required ShortlistMode mode,
  required math.Random rng,
  LayaHeads heads = const LayaHeads(),
  Map<String, Object> Function()? boardState,
  bool natural = true,
}) async {
  if (kind == PlayerKind.heuristic) {
    final best = all.reduce((a, b) => b.heuristic > a.heuristic ? b : a);
    return Pick([best], 0);
  }
  final options = buildShortlist(
    all,
    kind == PlayerKind.layaChoice && mode == ShortlistMode.all
        ? ShortlistMode.mixed
        : mode,
    rng,
  );
  if (kind == PlayerKind.random) {
    return Pick(options, rng.nextInt(options.length));
  }
  final decide = heads.of(kind);
  if (decide == null) {
    throw StateError(
      '${kind.label} needs the '
      '${kind == PlayerKind.layaTuned ? 'Tetris-tuned' : 'base'} head, '
      'which is not loaded.',
    );
  }
  final sw = Stopwatch()..start();
  final verdict = switch (kind) {
    PlayerKind.layaJudge => await judgeWithLaya(
      decide,
      piece,
      options,
      rng,
      natural: natural,
    ),
    PlayerKind.layaChecklist => await checklistWithLaya(
      decide,
      piece,
      options,
      rng,
      natural: natural,
    ),
    PlayerKind.layaChoice => await chooseWithLaya(
      decide,
      boardState!(),
      options,
    ),
    _ => await knockoutWithLaya(decide, piece, options, rng),
  };
  return Pick(
    options,
    verdict.chosen,
    verdict: verdict,
    micros: sw.elapsedMicroseconds,
  );
}

/// One turn-based decision and how it compares with the heuristic.
class Decision {
  /// Creates a decision record.
  Decision(this.pick, {required this.rankOverall, required this.candidates});

  /// The player's pick.
  final Pick pick;

  /// 1-based rank of the chosen placement among all legal ones by heuristic.
  final int rankOverall;

  /// Number of legal placements.
  final int candidates;

  /// Whether the pick is the best candidate by heuristic.
  bool get pickedShortlistBest {
    final best = pick.options
        .map((o) => o.heuristic)
        .reduce((a, b) => math.max(a, b));
    return pick.placement.heuristic >= best - 1e-9;
  }
}

/// Picks one placement for the current piece of [game].
Future<Decision> decide(
  Game game,
  PlayerKind kind,
  ShortlistMode mode,
  math.Random rng, {
  LayaHeads heads = const LayaHeads(),
  bool natural = true,
}) async {
  final all = game.placements();
  final pick = await pickPlacement(
    kind,
    all,
    piece: game.current,
    mode: mode,
    rng: rng,
    heads: heads,
    natural: natural,
    boardState: () => layaBoardState(
      piece: game.current,
      next: game.next,
      holes: game.board.holes(),
      stack: game.board.stackRows(),
    ),
  );
  final chosen = pick.placement.heuristic;
  final ranked = [for (final p in all) p.heuristic]
    ..sort((a, b) => b.compareTo(a));
  return Decision(
    pick,
    rankOverall: ranked.indexWhere((h) => h <= chosen + 1e-9) + 1,
    candidates: all.length,
  );
}

/// Running per-player statistics over turn-based decisions.
class Stats {
  int _decisions = 0, _agree = 0, _rankSum = 0, _micros = 0, _questions = 0;
  int _clearRight = 0, _clearTotal = 0, _clearPositives = 0, _clearHits = 0;
  int _holeRight = 0, _holeTotal = 0, _holePositives = 0, _holeHits = 0;

  /// Adds one decision.
  void add(Decision d) {
    _decisions++;
    if (d.pickedShortlistBest) _agree++;
    _rankSum += d.rankOverall;
    _micros += d.pick.micros;
    final v = d.pick.verdict;
    if (v == null) return;
    _questions += v.questions;
    final f = v.facts;
    if (f == null) return;
    for (var i = 0; i < f.length; i++) {
      final o = d.pick.options[i];
      final clears = o.linesCleared > 0, holes = o.newHoles > 0;
      _clearTotal++;
      _holeTotal++;
      if ((f[i].$1 > 0.5) == clears) _clearRight++;
      if ((f[i].$2 > 0.5) == holes) _holeRight++;
      if (clears) {
        _clearPositives++;
        if (f[i].$1 > 0.5) _clearHits++;
      }
      if (holes) {
        _holePositives++;
        if (f[i].$2 > 0.5) _holeHits++;
      }
    }
  }

  /// Share of decisions that picked the best candidate by heuristic.
  double get agreeRate => _decisions == 0 ? 0 : _agree / _decisions;

  /// Mean rank of the chosen placement among all legal ones.
  double get meanRank => _decisions == 0 ? 0 : _rankSum / _decisions;

  /// Mean Laya wall time per decision in milliseconds.
  double get meanMillis => _decisions == 0 ? 0 : _micros / _decisions / 1000;

  /// Mean Laya questions per decision.
  double get meanQuestions => _decisions == 0 ? 0 : _questions / _decisions;

  /// Checklist accuracy against the true facts, or empty for other players.
  String factSummary() => _clearTotal == 0
      ? ''
      : 'clear ${_pct(_clearRight, _clearTotal)} (recall ${_pct(_clearHits, _clearPositives)}), '
            'hole ${_pct(_holeRight, _holeTotal)} (recall ${_pct(_holeHits, _holePositives)})';

  static String _pct(int a, int b) =>
      b == 0 ? 'n/a' : '${(100 * a / b).toStringAsFixed(0)}%';
}
