import 'dart:math' as math;

import 'package:llamadart/llamadart.dart';

import 'intents.dart';
import 'llm.dart';
import 'sources.dart';

/// [decider-2b](https://huggingface.co/Mapika/decider-2b) v10 as a Q8_0 GGUF,
/// 2.0 GB, under Apache 2.0: Qwen3.5-2B-Base trained to answer typed
/// decision questions from the probabilities of the option letters.
final ModelSource defaultDeciderModel = ModelSource.huggingFace(
  repoId: 'cosetoenor/decider-2b-GGUF',
  revision: 'dcc6e5537f922266d1126c15682ac0929517ee33',
  filePath: 'decider-2b-q8_0.gguf',
);

/// decider-2b v10's fitted temperature, from its `decider_config.json`.
const double deciderTemperature = 1.3;

/// Default gate for [DeciderIntentReader] readings, chosen on `evalCases`
/// with `bin/bench.dart`.
const double deciderEnter = 0.6;

const String _letters = 'ABCDEFGH';

/// decider's plain prompt for [text]: the text as the context, then
/// [intentKey]'s question with one lettered option per intent, then the
/// answer slot whose next token is the chosen letter.
String deciderPrompt(String text) {
  final question = intentKey.question;
  return [
    'Context:\n$text\n\nQuestion: ${question.instructions}\nOptions:',
    for (final (i, intent) in CommandIntent.values.indexed)
      '\n(${_letters[i]}) ${intent.name}: ${question.criteria[intent.name]}',
    '\nAnswer: (',
  ].join();
}

/// Reads intents with decider: one pass over [deciderPrompt], and a softmax
/// over the option letters' log-probabilities divided by [temperature].
class DeciderIntentReader {
  /// Creates a reader that scores [letterTokens], one per intent in
  /// [CommandIntent.values] order.
  DeciderIntentReader(
    this._score, {
    required this.letterTokens,
    this.temperature = deciderTemperature,
  });

  final CandidateScorer _score;

  /// Token of each option letter.
  final List<int> letterTokens;

  /// Softmax temperature.
  final double temperature;

  /// Reads [text]. [IntentReading.confidence] is the probability of the most
  /// probable intent, as decider reports it.
  Future<IntentReading> read(String text) async {
    final stopwatch = Stopwatch()..start();
    final logprobs = await _score(deciderPrompt(text), letterTokens);
    final scaled = [for (final l in logprobs) l / temperature];
    final top = scaled.reduce(math.max);
    final exps = [for (final l in scaled) math.exp(l - top)];
    final sum = exps.reduce((a, b) => a + b);
    final probabilities = [for (final e in exps) e / sum];
    return IntentReading(
      text: text,
      probabilities: probabilities,
      confidence: probabilities.reduce(math.max),
      elapsed: stopwatch.elapsed,
    );
  }
}

/// Loads [model] (by default [defaultDeciderModel]) through [downloads].
Future<IntentSource> loadDeciderSource({
  ModelSource? model,
  ModelDownloadManager? downloads,
  bool cpu = false,
  LoadStatus? onStatus,
}) async {
  model ??= defaultDeciderModel;
  final engine = LlamaEngine(LlamaBackend(), modelDownloadManager: downloads);
  try {
    onStatus?.call('Loading ${model.fileName}', null);
    await engine.loadModelSource(
      model,
      modelParams: ModelParams(
        contextSize: 512,
        preferredBackend: cpu ? GpuBackend.cpu : GpuBackend.auto,
        gpuLayers: cpu ? 0 : ModelParams.maxGpuLayers,
      ),
      onProgress: (p) => onStatus?.call(
        'Downloading ${model!.fileName}: ${(p.receivedBytes / 1e6).round()}'
        '${p.totalBytes == null ? '' : ' of ${(p.totalBytes! / 1e6).round()}'}'
        ' MB',
        p.fraction,
      ),
    );
    if (!engine.supportsNextTokenScoring) {
      throw LlamaUnsupportedException(
        'The decider reader needs next-token scoring, which this backend '
        'lacks.',
      );
    }
    final letterTokens = <int>[];
    for (final letter in _letters.split('')) {
      final ids = await engine.tokenize(letter, addSpecial: false);
      if (ids.length != 1) {
        throw StateError('The letter $letter is not one token in this model.');
      }
      letterTokens.add(ids.single);
    }
    final reader = DeciderIntentReader(
      (prompt, candidates) async => [
        for (final t in (await engine.scoreNextToken(
          prompt,
          candidates: candidates,
        )).candidates)
          t.logprob,
      ],
      letterTokens: letterTokens,
    );
    onStatus?.call('Warming up', null);
    await reader.read('remind me to call mom at 7');
    return IntentSource(
      reader: reader.read,
      enter: deciderEnter,
      label: await engine.getBackendName(),
      minWords: 2,
      dispose: engine.dispose,
    );
  } catch (_) {
    await engine.dispose();
    rethrow;
  }
}
