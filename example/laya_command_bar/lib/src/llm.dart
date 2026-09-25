import 'dart:math' as math;

import 'package:llamadart/llamadart.dart';

import 'example_bank.dart';
import 'intents.dart';
import 'sources.dart';

/// Qwen2.5 1.5B Instruct, Q4_K_M, 1.1 GB, under Apache 2.0. A transformer
/// without recurrent layers, so each read evaluates only the typed text after
/// the cached instructions.
final ModelSource defaultLlmModel = ModelSource.huggingFace(
  repoId: 'Qwen/Qwen2.5-1.5B-Instruct-GGUF',
  revision: '91cad51170dc346986eccefdc2dd33a9da36ead9',
  filePath: 'qwen2.5-1.5b-instruct-q4_k_m.gguf',
);

/// Default gate for [LlmIntentReader] readings, chosen on `evalCases` with
/// `bin/bench.dart`.
const double llmEnter = 0.5;

/// Log-probabilities of [candidates] as the token after [prompt], in order.
typedef CandidateScorer =
    Future<List<double>> Function(String prompt, List<int> candidates);

/// Reads intents with an instruction-tuned LLM without generating: the
/// prompt asks for an intent name, and each intent scores the probability of
/// its name's first token.
class LlmIntentReader {
  /// Creates a reader that puts each text into [promptFor] and scores
  /// [answerTokens], one per intent in [CommandIntent.values] order.
  LlmIntentReader(
    this._score, {
    required this.promptFor,
    required this.answerTokens,
  });

  final CandidateScorer _score;

  /// The prompt for a text.
  String Function(String text) promptFor;

  /// First token of each intent's name.
  final List<int> answerTokens;

  /// Reads [text]. [IntentReading.confidence] is the lead of the most
  /// probable intent over the second.
  Future<IntentReading> read(String text) async {
    final stopwatch = Stopwatch()..start();
    final logprobs = await _score(promptFor(text), answerTokens);
    final top = logprobs.reduce(math.max);
    final exps = [for (final l in logprobs) math.exp(l - top)];
    final sum = exps.reduce((a, b) => a + b);
    final probabilities = [for (final e in exps) e / sum];
    final sorted = [...probabilities]..sort();
    return IntentReading(
      text: text,
      probabilities: probabilities,
      confidence: sorted.last - sorted[sorted.length - 2],
      elapsed: stopwatch.elapsed,
    );
  }
}

/// The instructions, with each intent and labelled example.
String llmInstructions(Iterable<(CommandIntent, String)> examples) => [
  'Classify a command typed into a productivity app. Reply with the '
      'name of its intent only.',
  '',
  'Intents:',
  for (final e in intentDescriptions.entries) '- ${e.key.title}: ${e.value}',
  '',
  'Examples:',
  for (final (intent, text) in examples) '$text => ${intent.title}',
].join('\n');

/// Loads the instruction-tuned [model] (by default [defaultLlmModel])
/// through [downloads] and reads with the [seedExamples] and [corrections]
/// in its instructions.
Future<IntentSource> loadLlmSource({
  ModelSource? model,
  ModelDownloadManager? downloads,
  bool cpu = false,
  Iterable<(CommandIntent, String)> corrections = const [],
  LoadStatus? onStatus,
}) async {
  model ??= defaultLlmModel;
  final engine = LlamaEngine(LlamaBackend(), modelDownloadManager: downloads);
  try {
    onStatus?.call('Loading ${model.fileName}', null);
    await engine.loadModelSource(
      model,
      modelParams: ModelParams(
        contextSize: 4096,
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
        'The LLM reader needs next-token scoring, which this backend lacks.',
      );
    }
    final answerTokens = [
      for (final intent in CommandIntent.values)
        (await engine.tokenize(intent.title, addSpecial: false)).first,
    ];
    if (answerTokens.toSet().length != answerTokens.length) {
      throw StateError('Two intent names share a first token in this model.');
    }
    final examples = [...seedExamples, ...corrections];

    Future<String Function(String)> render() async {
      const marker = '<<command>>';
      final prompt = (await engine.chatTemplate([
        LlamaChatMessage.fromText(
          role: LlamaChatRole.system,
          text: llmInstructions(examples),
        ),
        const LlamaChatMessage.fromText(role: LlamaChatRole.user, text: marker),
      ], enableThinking: false)).prompt;
      final at = prompt.indexOf(marker);
      final head = prompt.substring(0, at);
      final tail = prompt.substring(at + marker.length);
      return (text) => '$head$text$tail';
    }

    final reader = LlmIntentReader(
      (prompt, candidates) async => [
        for (final t in (await engine.scoreNextToken(
          prompt,
          candidates: candidates,
        )).candidates)
          t.logprob,
      ],
      promptFor: await render(),
      answerTokens: answerTokens,
    );
    onStatus?.call('Warming up', null);
    await reader.read('remind me to call mom at 7');
    return IntentSource(
      reader: reader.read,
      enter: llmEnter,
      label: await engine.getBackendName(),
      minWords: 2,
      learn: (intent, text) async {
        examples.add((intent, text));
        reader.promptFor = await render();
      },
      dispose: engine.dispose,
    );
  } catch (_) {
    await engine.dispose();
    rethrow;
  }
}
