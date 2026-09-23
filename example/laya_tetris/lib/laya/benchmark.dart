import 'package:llamadart/llamadart.dart';

import '../players.dart';
import '../tetris.dart';
import 'models.dart';

/// Default benchmark configurations: the best device, then CPU thread counts.
const List<(GpuBackend, int)> speedConfigs = [
  (GpuBackend.auto, 4),
  (GpuBackend.cpu, 2),
  (GpuBackend.cpu, 4),
  (GpuBackend.cpu, 6),
  (GpuBackend.cpu, 8),
];

/// Mean time of one question in one configuration.
class SpeedResult {
  /// Creates a result.
  SpeedResult(this.label, {this.millis, this.tokens = 0, this.error});

  /// Configuration, such as `CPU x4` or `Metal (MTL0)`.
  final String label;

  /// Mean `systemOneBatch` wall time per question.
  final double? millis;

  /// Tokens in the question's sequence.
  final int tokens;

  /// Why the configuration failed.
  final String? error;

  @override
  String toString() => error != null
      ? '$label failed: $error'
      : '$label: ${millis!.toStringAsFixed(1)} ms per question';
}

/// The fixed six-option question the benchmark times.
DecisionRequest speedRequest() {
  final moves = enumeratePlacements(Board(), Piece.t).take(6).toList();
  return DecisionRequest(
    state: {'game': 'tetris', 'piece': Piece.t.letter},
    questions: {
      'move': DecisionQuestion.choice(
        tuneInstructions,
        criteria: {
          for (var j = 0; j < moves.length; j++)
            optionLabels[j]: moves[j].describeCompact(),
        },
      ),
    },
  );
}

/// Times [speedRequest] in each of [configs], each in fresh models from
/// [load] with [setup]'s backbone and its tuned head, or its base head without
/// one.
///
/// Discards [warmup] runs, then averages [runs].
Stream<SpeedResult> benchmarkLaya(
  LayaSetup setup, {
  List<(GpuBackend, int)> configs = speedConfigs,
  int runs = 4,
  int warmup = 2,
  ModelDownloadManager? downloads,
  LayaLoader load = LayaModels.load,
}) async* {
  final request = speedRequest();
  for (final (backend, threads) in configs) {
    final cpuLabel = 'CPU x$threads';
    LayaModels? models;
    try {
      models = await load(
        LayaSetup(
          backbone: setup.backbone,
          head: setup.tunedHead ?? setup.head,
          backend: backend,
          threads: threads,
        ),
        downloads: downloads,
      );
      var micros = 0, tokens = 0;
      for (var i = 0; i < warmup + runs; i++) {
        final sw = Stopwatch()..start();
        final r = await models.base([request]);
        if (i >= warmup) micros += sw.elapsedMicroseconds;
        tokens = r.single.usage.inputTokens;
      }
      yield SpeedResult(
        backend == GpuBackend.cpu
            ? cpuLabel
            : '${models.backendName} (${models.deviceName})',
        millis: micros / runs / 1000,
        tokens: tokens,
      );
    } catch (e) {
      yield SpeedResult(
        backend == GpuBackend.cpu ? cpuLabel : backend.name,
        error: '$e',
      );
    } finally {
      await models?.dispose();
    }
  }
}
