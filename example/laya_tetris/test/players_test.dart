import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:laya_tetris_example/players.dart';
import 'package:laya_tetris_example/tetris.dart';
import 'package:llamadart/llamadart.dart';

/// Distinct synthetic placements; a lower bumpiness has a better heuristic.
List<Placement> synthetic(int n) => [
  for (var i = 0; i < n; i++)
    Placement(
      piece: Piece.t,
      rotation: 0,
      shape: const [(1, 0), (0, 1), (1, 1), (2, 1)],
      x: i % 8,
      y: 18,
      linesCleared: 0,
      holes: 0,
      newHoles: 0,
      holesChange: 0,
      aggregateHeight: 10,
      maxHeight: 2,
      bumpiness: i,
    ),
];

int bumpinessOf(Object? description) =>
    int.parse(RegExp(r'bumpiness (\d+)').firstMatch('$description')!.group(1)!);

DecisionResult result(
  Map<String, DecisionAnswer> answers, {
  Map<String, DecisionQuestion>? questions,
}) => DecisionResult(
  model: 'fake',
  answers: answers,
  questions: questions,
  usage: DecisionUsage(inputTokens: 10 * answers.length, outputTokens: 0),
);

ChoiceAnswer choiceAnswer(List<double> p) {
  var best = 0;
  for (var i = 1; i < p.length; i++) {
    if (p[i] > p[best]) best = i;
  }
  return ChoiceAnswer(
    choice: optionLabels[best],
    probabilities: {for (var i = 0; i < p.length; i++) optionLabels[i]: p[i]},
    confidence: 1,
    actProbability: 0,
  );
}

NoulAnswer noulAnswer(double p) =>
    NoulAnswer(noul: p, confidence: math.max(p, 1 - p), actProbability: 0);

/// Records every batch and answers choice questions in favour of the lowest
/// bumpiness, keeping each request's questions as `DecisionEngine` does.
class FakeLaya {
  final batches = <List<DecisionRequest>>[];

  Future<List<DecisionResult>> decide(List<DecisionRequest> requests) async {
    batches.add(requests);
    return [
      for (final r in requests)
        result({
          for (final MapEntry(key: id, value: q) in r.questions.entries)
            id: switch (q) {
              ChoiceQuestion(:final criteria) => () {
                final w = [
                  for (final d in criteria.values)
                    math.exp(-bumpinessOf(d).toDouble()),
                ];
                final sum = w.reduce((a, b) => a + b);
                return choiceAnswer([for (final v in w) v / sum]);
              }(),
              _ => noulAnswer(0.5),
            },
        }, questions: r.questions),
    ];
  }
}

void main() {
  group('buildShortlist', () {
    final all = synthetic(12);

    test('mixed keeps the three best and fills up to six', () {
      final s = buildShortlist(all, ShortlistMode.mixed, math.Random(1));
      expect(s, hasLength(shortlistSize));
      expect(s.toSet(), containsAll(all.take(3)));
    });

    test('top keeps the six best', () {
      final s = buildShortlist(all, ShortlistMode.top, math.Random(1));
      expect(s.toSet(), all.take(6).toSet());
    });

    test('all keeps every placement and random keeps six of them', () {
      final rng = math.Random(1);
      expect(buildShortlist(all, ShortlistMode.all, rng).toSet(), all.toSet());
      final r = buildShortlist(all, ShortlistMode.random, rng);
      expect(r, hasLength(6));
      expect(all.toSet(), containsAll(r));
    });
  });

  group('knockoutWithLaya', () {
    test('plays rounds of up to six as one batch each', () async {
      final fake = FakeLaya();
      final options = synthetic(13);
      final v = await knockoutWithLaya(
        fake.decide,
        Piece.t,
        options,
        math.Random(3),
      );
      expect(
        [for (final b in fake.batches) b.length],
        [3, 1],
        reason: '13 options: groups of 4, 4 and 5, then one final of 3',
      );
      expect(
        [
          for (final r in fake.batches.first)
            (r.questions['move'] as ChoiceQuestion).criteria.length,
        ],
        [4, 4, 5],
      );
      expect(options[v.chosen].bumpiness, 0);
      expect(v.questions, 4);
      expect(v.tokens, 40);
      expect(v.scores[v.chosen], greaterThan(0.5));
      expect(v.scores, hasLength(13));
    });

    test('asks in the format the tuned head was trained on', () async {
      final fake = FakeLaya();
      final options = synthetic(4);
      await knockoutWithLaya(fake.decide, Piece.t, options, math.Random(0));
      final request = fake.batches.single.single;
      expect(request.state, {'game': 'tetris', 'piece': 'T'});
      final q = request.questions['move'] as ChoiceQuestion;
      expect(q.instructions, tuneInstructions);
      expect(q.criteria.keys, ['A', 'B', 'C', 'D']);
      expect(q.criteria.values.toSet(), {
        for (final o in options) o.describeCompact(),
      });
    });

    test('a single candidate needs no question', () async {
      final fake = FakeLaya();
      final v = await knockoutWithLaya(
        fake.decide,
        Piece.t,
        synthetic(1),
        math.Random(0),
      );
      expect(v.chosen, 0);
      expect(fake.batches, isEmpty);
      expect(v.questions, 0);
    });
  });

  test(
    'the checklist asks two facts per move and scores clear - hole',
    () async {
      final options = synthetic(3);
      const clears = [0.2, 0.9, 0.9], holes = [0.1, 0.7, 0.2];
      final batches = <List<DecisionRequest>>[];
      Future<List<DecisionResult>> decide(List<DecisionRequest> rs) async {
        batches.add(rs);
        return [
          for (var i = 0; i < rs.length; i++)
            result({
              'clears': noulAnswer(clears[i]),
              'holes': noulAnswer(holes[i]),
            }),
        ];
      }

      final v = await checklistWithLaya(
        decide,
        Piece.t,
        options,
        math.Random(0),
      );
      expect(batches, hasLength(1));
      final request = batches.single.first;
      expect(
        (request.questions['clears']! as NoulQuestion).instructions,
        clearInstructions,
      );
      expect(
        (request.questions['holes']! as NoulQuestion).instructions,
        holeInstructions,
      );
      expect(request.state, {
        'game': 'tetris',
        'piece': 'T',
        'move': options.first.describeNatural(),
      });
      expect(v.chosen, 2);
      expect(v.facts, [(0.2, 0.1), (0.9, 0.7), (0.9, 0.2)]);
      expect(v.scores[2], closeTo(0.7, 1e-9));
      expect(v.questions, 6);
    },
  );

  test('the judge picks the most likely good move, terse on request', () async {
    final options = synthetic(3);
    final batches = <List<DecisionRequest>>[];
    Future<List<DecisionResult>> decide(List<DecisionRequest> rs) async {
      batches.add(rs);
      return [
        for (final p in [0.3, 0.8, 0.6]) result({'good': noulAnswer(p)}),
      ];
    }

    final v = await judgeWithLaya(
      decide,
      Piece.t,
      options,
      math.Random(0),
      natural: false,
    );
    expect(v.chosen, 1);
    expect(
      (batches.single.first.state as Map)['move'],
      options.first.describe(),
    );
    expect(
      (batches.single.first.questions['good']! as NoulQuestion).instructions,
      judgeInstructions,
    );
  });

  group('pickPlacement', () {
    final game = Game(4);

    test('the base-head choice caps "all moves" at six options', () async {
      final fake = FakeLaya();
      final pick = await pickPlacement(
        PlayerKind.layaChoice,
        game.placements(),
        piece: game.current,
        mode: ShortlistMode.all,
        rng: math.Random(0),
        heads: LayaHeads(base: fake.decide),
        boardState: () => layaBoardState(
          piece: game.current,
          next: game.next,
          holes: 0,
          stack: const [],
        ),
      );
      expect(pick.options, hasLength(shortlistSize));
      final request = fake.batches.single.single;
      expect(request.state, {
        'game': 'tetris',
        'piece': 'T',
        'next': 'Z',
        'holes': 0,
        'stack': <String>[],
      });
      final q = request.questions['move']! as ChoiceQuestion;
      expect(q.instructions, layaInstructions);
      expect(q.criteria['A'], pick.options.first.describe());
      expect(pick.verdict!.questions, 1);
      expect(
        pick.placement.bumpiness,
        pick.options.map((o) => o.bumpiness).reduce(math.min),
      );
      final weights = [
        for (final o in pick.options) math.exp(-o.bumpiness.toDouble()),
      ];
      final sum = weights.reduce((a, b) => a + b);
      expect(pick.verdict!.scores, [
        for (final w in weights) closeTo(w / sum, 1e-12),
      ]);
    });

    test('the tuned player uses only the tuned head', () async {
      final base = FakeLaya(), tuned = FakeLaya();
      await pickPlacement(
        PlayerKind.layaTuned,
        game.placements(),
        piece: game.current,
        mode: ShortlistMode.all,
        rng: math.Random(0),
        heads: LayaHeads(base: base.decide, tuned: tuned.decide),
      );
      expect(base.batches, isEmpty);
      expect(tuned.batches, isNotEmpty);
    });

    test('a Laya player without its head fails loudly', () async {
      await expectLater(
        pickPlacement(
          PlayerKind.layaTuned,
          game.placements(),
          piece: game.current,
          mode: ShortlistMode.mixed,
          rng: math.Random(0),
          heads: LayaHeads(base: FakeLaya().decide),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Tetris-tuned head'),
          ),
        ),
      );
    });

    test('the heuristic picks the best of all moves without Laya', () async {
      final all = game.placements();
      final pick = await pickPlacement(
        PlayerKind.heuristic,
        all,
        piece: game.current,
        mode: ShortlistMode.mixed,
        rng: math.Random(0),
      );
      expect(
        pick.placement.heuristic,
        all.map((p) => p.heuristic).reduce(math.max),
      );
      expect(pick.verdict, isNull);
    });
  });

  test('decide ranks the pick among all moves and Stats sums it', () async {
    final game = Game(4);
    final stats = Stats();
    final heuristic = await decide(
      game,
      PlayerKind.heuristic,
      ShortlistMode.all,
      math.Random(0),
    );
    expect(heuristic.rankOverall, 1);
    expect(heuristic.pickedShortlistBest, isTrue);
    stats.add(heuristic);
    final random = await decide(
      game,
      PlayerKind.random,
      ShortlistMode.random,
      math.Random(0),
    );
    expect(random.candidates, game.placements().length);
    expect(random.rankOverall, inInclusiveRange(1, random.candidates));
    stats.add(random);
    expect(stats.meanRank, (1 + random.rankOverall) / 2);
    expect(stats.factSummary(), isEmpty);
  });
}
