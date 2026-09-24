// Heuristic-labelled Laya `choice` examples from Tetris positions, the data
// for fine-tuning the Tetris head.
//
// dart run bin/make_dataset.dart <out_dir> [train_groups] [val_groups]
//
// Writes train.jsonl and val.jsonl. Each line holds `state` and `q` in the
// Laya request format, `target` (the heuristic-best options share
// probability 1) and `h` (each option's heuristic value).
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:laya_tetris_example/players.dart';
import 'package:laya_tetris_example/tetris.dart';

void main(List<String> args) {
  final out = Directory(args.isEmpty ? 'dataset' : args[0])
    ..createSync(recursive: true);
  final trainGroups = args.length > 1 ? int.parse(args[1]) : 16000;
  final valGroups = args.length > 2 ? int.parse(args[2]) : 2000;
  _write(File('${out.path}/train.jsonl'), trainGroups, 1000);
  _write(File('${out.path}/val.jsonl'), valGroups, 900000);
}

void _write(File f, int groups, int seedBase) {
  final sink = f.openWrite();
  final rng = math.Random(seedBase);
  var written = 0, game = 0, positions = 0;
  final sizes = List<int>.filled(7, 0);
  while (written < groups) {
    final g = Game(seedBase + game++);
    while (!g.over && g.pieces < 400 && written < groups) {
      final all = g.placements();
      final ranked = [...all]
        ..sort((a, b) => b.heuristic.compareTo(a.heuristic));
      if (rng.nextDouble() < 0.5 && all.length >= 2) {
        positions++;
        for (var i = 0; i < 2 && written < groups; i++) {
          final k = math.min(
            all.length,
            rng.nextDouble() < 0.5 ? 6 : 2 + rng.nextInt(4),
          );
          final pool = rng.nextBool() ? ranked.take(8).toList() : [...all];
          if (pool.length < k) continue;
          pool.shuffle(rng);
          final opts = pool.take(k).toList();
          final hs = [for (final o in opts) o.heuristic];
          final best = hs.reduce(math.max);
          final isBest = [for (final h in hs) h >= best - 1e-9];
          final nBest = isBest.where((b) => b).length;
          if (nBest == k) continue;
          sink.writeln(
            jsonEncode({
              'state': {'game': 'tetris', 'piece': g.current.letter},
              'q': {
                'type': 'choice',
                'instructions': tuneInstructions,
                'criteria': {
                  for (var j = 0; j < k; j++)
                    optionLabels[j]: opts[j].describeCompact(),
                },
              },
              'target': [for (final b in isBest) b ? 1 / nBest : 0.0],
              'h': hs,
            }),
          );
          sizes[k]++;
          written++;
        }
      }
      final r = rng.nextDouble();
      final Placement move;
      if (r < 0.75) {
        move = ranked.first;
      } else if (r < 0.9) {
        move = ranked[rng.nextInt(math.min(5, ranked.length))];
      } else {
        move = all[rng.nextInt(all.length)];
      }
      g.apply(move);
    }
  }
  sink.close();
  stdout.writeln(
    '${f.path}: $written groups from $positions positions in $game games; '
    'sizes ${sizes.sublist(2)}',
  );
}
