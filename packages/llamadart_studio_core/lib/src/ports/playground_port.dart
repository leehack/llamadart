import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'model_storage_port.dart';

/// Pairwise cosine similarity matrix and raw embedding metadata.
@immutable
class EmbeddingComparisonResult {
  /// Creates an [EmbeddingComparisonResult].
  const EmbeddingComparisonResult({
    required this.texts,
    required this.dimensions,
    required this.similarityMatrix,
    required this.elapsedMs,
  });

  /// Input texts in order.
  final List<String> texts;

  /// Vector width produced by the encoder.
  final int dimensions;

  /// `N x N` cosine similarity matrix in `-1.0 .. 1.0`.
  final List<List<double>> similarityMatrix;

  /// Total embedding wall-clock duration in milliseconds.
  final int elapsedMs;
}

/// Ranked candidate document returned by a cross-encoder reranker.
@immutable
class RankedDocumentItem {
  /// Creates a [RankedDocumentItem].
  const RankedDocumentItem({
    required this.originalIndex,
    required this.document,
    required this.score,
  });

  /// Zero-based index in the input document list.
  final int originalIndex;

  /// Document text.
  final String document;

  /// Relevance score.
  final double score;
}

/// Decoded token piece for the Token Inspector.
@immutable
class InspectedToken {
  /// Creates an [InspectedToken].
  const InspectedToken({required this.id, required this.piece});

  /// Vocabulary token ID.
  final int id;

  /// Detokenized text piece.
  final String piece;
}

/// System-1 yes/no (`noul`) decision answer from `DecisionEngine`.
@immutable
class SystemOneEvaluation {
  /// Creates a [SystemOneEvaluation].
  const SystemOneEvaluation({
    required this.question,
    required this.probabilityTrue,
    required this.confidence,
    required this.elapsedMs,
    required this.deviceName,
  });

  /// Evaluated yes/no statement.
  final String question;

  /// Probability (`0.0 .. 1.0`) that the statement holds for `state`.
  final double probabilityTrue;

  /// Model confidence (`0.0 .. 1.0`).
  final double confidence;

  /// Single-pass evaluation latency in milliseconds.
  final int elapsedMs;

  /// Compute device reported by the decision head.
  final String deviceName;
}

/// Prefill & decode throughput benchmark result.
@immutable
class BenchmarkRunSummary {
  /// Creates a [BenchmarkRunSummary].
  const BenchmarkRunSummary({
    required this.modelName,
    required this.backendName,
    required this.promptTokens,
    required this.generatedTokens,
    required this.prefillLatencyMs,
    required this.decodeElapsedMs,
  });

  /// Benchmarked model name.
  final String modelName;

  /// Active backend label.
  final String backendName;

  /// Evaluated prompt token count.
  final int promptTokens;

  /// Generated completion token count.
  final int generatedTokens;

  /// Time to first token (prefill latency) in milliseconds.
  final int prefillLatencyMs;

  /// Decode phase duration in milliseconds.
  final int decodeElapsedMs;

  /// Prefill speed in tokens/sec.
  double get prefillTokensPerSecond =>
      prefillLatencyMs <= 0 ? 0 : (promptTokens * 1000.0) / prefillLatencyMs;

  /// Decode speed in tokens/sec.
  double get decodeTokensPerSecond =>
      decodeElapsedMs <= 0 ? 0 : (generatedTokens * 1000.0) / decodeElapsedMs;
}

/// Raw vector embeddings returned by `LlamaTextEmbedder`.
@immutable
class EmbeddedPassageResult {
  /// Creates an [EmbeddedPassageResult].
  const EmbeddedPassageResult({
    required this.texts,
    required this.dimensions,
    required this.vectors,
    required this.elapsedMs,
  });

  /// Embedded texts in input order.
  final List<String> texts;

  /// Vector width per passage.
  final int dimensions;

  /// L2-normalized embedding vectors.
  final List<List<double>> vectors;

  /// Total wall-clock embedding duration in milliseconds.
  final int elapsedMs;
}

/// Single query vector embedding returned by `LlamaTextEmbedder`.
@immutable
class EmbeddedQueryResult {
  /// Creates an [EmbeddedQueryResult].
  const EmbeddedQueryResult({
    required this.query,
    required this.dimensions,
    required this.vector,
    required this.elapsedMs,
  });

  /// Embedded search query string.
  final String query;

  /// Vector width.
  final int dimensions;

  /// L2-normalized query vector.
  final List<double> vector;

  /// Embedding wall-clock latency in milliseconds.
  final int elapsedMs;
}

/// Typed question specification evaluated in a single `DecisionEngine.systemOne`
/// pass (`ChoiceKey`, `ScoreKey`, or `NoulKey`).
@immutable
sealed class SystemOneQuestionSpec {
  /// Creates a [SystemOneQuestionSpec].
  const SystemOneQuestionSpec({required this.id, required this.prompt});

  /// Stable question identifier.
  final String id;

  /// Question text evaluated by `DecisionEngine`.
  final String prompt;
}

/// Categorical choice specification backed by `ChoiceKey.labels`.
final class SystemOneChoiceQuestionSpec extends SystemOneQuestionSpec {
  /// Creates a [SystemOneChoiceQuestionSpec].
  const SystemOneChoiceQuestionSpec({
    required super.id,
    required super.prompt,
    required this.labels,
    this.includeUncertain = false,
  });

  /// Candidate choice labels.
  final List<String> labels;

  /// Whether `DecisionEngine` includes an extra uncertain bucket.
  final bool includeUncertain;
}

/// Ordinal score specification backed by `ScoreKey.of`.
final class SystemOneScoreQuestionSpec extends SystemOneQuestionSpec {
  /// Creates a [SystemOneScoreQuestionSpec].
  const SystemOneScoreQuestionSpec({
    required super.id,
    required super.prompt,
    required this.levels,
  });

  /// Ordered score level descriptions (low to high).
  final List<String> levels;
}

/// Binary yes/no (`noul`) specification backed by `NoulKey.of`.
final class SystemOneNoulQuestionSpec extends SystemOneQuestionSpec {
  /// Creates a [SystemOneNoulQuestionSpec].
  const SystemOneNoulQuestionSpec({required super.id, required super.prompt});
}

/// Typed answer produced by `DecisionEngine.systemOne`.
@immutable
sealed class SystemOneQuestionAnswer {
  /// Creates a [SystemOneQuestionAnswer].
  const SystemOneQuestionAnswer({
    required this.id,
    required this.prompt,
    required this.confidence,
  });

  /// Question identifier matching the input [SystemOneQuestionSpec].
  final String id;

  /// Prompt evaluated by the head.
  final String prompt;

  /// Model confidence (`0.0 .. 1.0`).
  final double confidence;
}

/// Typed answer for a [SystemOneChoiceQuestionSpec].
final class SystemOneChoiceAnswer extends SystemOneQuestionAnswer {
  /// Creates a [SystemOneChoiceAnswer].
  const SystemOneChoiceAnswer({
    required super.id,
    required super.prompt,
    required super.confidence,
    required this.choice,
    required this.probabilities,
  });

  /// Top-probability label (or `uncertain` if selected).
  final String choice;

  /// Per-label probabilities normalized across options.
  final Map<String, double> probabilities;
}

/// Typed answer for a [SystemOneScoreQuestionSpec].
final class SystemOneScoreAnswer extends SystemOneQuestionAnswer {
  /// Creates a [SystemOneScoreAnswer].
  const SystemOneScoreAnswer({
    required super.id,
    required super.prompt,
    required super.confidence,
    required this.score,
    required this.levels,
    required this.levelProbabilities,
  });

  /// Expected continuous score weighted across levels (`1.0 .. N`).
  final double score;

  /// Ordered level labels.
  final List<String> levels;

  /// Probability distribution across [levels].
  final Map<String, double> levelProbabilities;
}

/// Typed answer for a [SystemOneNoulQuestionSpec].
final class SystemOneNoulAnswer extends SystemOneQuestionAnswer {
  /// Creates a [SystemOneNoulAnswer].
  const SystemOneNoulAnswer({
    required super.id,
    required super.prompt,
    required super.confidence,
    required this.probabilityTrue,
  });

  /// Probability (`0.0 .. 1.0`) that the statement holds.
  final double probabilityTrue;
}

/// Combined single-pass `DecisionEngine.systemOne` batch result.
@immutable
class SystemOneBatchEvaluation {
  /// Creates a [SystemOneBatchEvaluation].
  const SystemOneBatchEvaluation({
    required this.answers,
    required this.elapsedMs,
    required this.deviceName,
  });

  /// Typed answers in request order.
  final List<SystemOneQuestionAnswer> answers;

  /// Wall-clock single-pass evaluation latency in milliseconds.
  final int elapsedMs;

  /// Compute device reported by the decision head.
  final String deviceName;

  /// Average latency per answered question in milliseconds.
  double get avgMsPerQuestion =>
      answers.isEmpty ? elapsedMs.toDouble() : elapsedMs / answers.length;

  /// Question evaluation throughput (`questions / sec`).
  double get questionsPerSecond =>
      elapsedMs <= 0 ? 0 : (answers.length * 1000.0) / elapsedMs;

  /// Looks up a typed answer by [id], or `null` if absent.
  SystemOneQuestionAnswer? byId(String id) {
    for (final answer in answers) {
      if (answer.id == id) {
        return answer;
      }
    }
    return null;
  }
}

/// Capabilities supported by the currently active embedding engine.
@immutable
class EmbeddingCapabilityInfo {
  /// Creates an [EmbeddingCapabilityInfo].
  const EmbeddingCapabilityInfo({
    this.supportsText = true,
    this.supportsImage = false,
    this.supportsAudio = false,
    this.isReady = false,
  });

  /// Whether plain text embeddings are supported.
  final bool supportsText;

  /// Whether image content embeddings (`EmbeddingGemma 2` multimodal) work.
  final bool supportsImage;

  /// Whether raw WAV audio embeddings (`EmbeddingGemma 2` multimodal) work.
  final bool supportsAudio;

  /// Whether an embedding engine is currently loaded and ready.
  final bool isReady;

  /// Whether any non-text modality is active.
  bool get isMultimodal => supportsImage || supportsAudio;
}

/// Multimodal payload for indexing a notebook item via `EmbeddingGemma 2` or
/// text-embedding fallback.
@immutable
class NoteEmbeddingInput {
  /// Creates a [NoteEmbeddingInput].
  const NoteEmbeddingInput({
    required this.text,
    this.title,
    this.imageBytes,
    this.imageMimeType,
    this.audioWavBytes,
  });

  /// Primary text/transcript body to embed.
  final String text;

  /// Optional note heading used by asymmetric document profiles.
  final String? title;

  /// Optional image bytes (PNG/JPEG/WebP).
  final Uint8List? imageBytes;

  /// Optional MIME type for [imageBytes].
  final String? imageMimeType;

  /// Optional 16 kHz mono WAV audio clip bytes.
  final Uint8List? audioWavBytes;
}

/// Vector result produced for a [NoteEmbeddingInput].
@immutable
class NoteEmbeddingVectorResult {
  /// Creates a [NoteEmbeddingVectorResult].
  const NoteEmbeddingVectorResult({
    required this.vector,
    required this.dimensions,
    required this.elapsedMs,
    required this.usedMultimodal,
  });

  /// L2-normalized embedding vector.
  final List<double> vector;

  /// Vector width.
  final int dimensions;

  /// Wall-clock embedding duration in milliseconds.
  final int elapsedMs;

  /// True when raw image or audio parts were encoded via `embedContent`.
  final bool usedMultimodal;
}

/// Speed burst benchmark & optional LLM comparison summary for `DecisionEngine`.
@immutable
class DecisionBenchmarkSummary {
  /// Creates a [DecisionBenchmarkSummary].
  const DecisionBenchmarkSummary({
    required this.iterations,
    required this.questionsPerPass,
    required this.totalElapsedMs,
    required this.minMs,
    required this.medianMs,
    required this.p95Ms,
    required this.deviceName,
    this.llmCompareElapsedMs,
    this.llmCompareModelName,
    this.llmCompareSummary,
  });

  /// Number of single-pass `systemOne` invocations measured.
  final int iterations;

  /// Number of typed questions evaluated together per pass.
  final int questionsPerPass;

  /// Total wall-clock time across all [iterations].
  final int totalElapsedMs;

  /// Fastest pass latency in milliseconds.
  final int minMs;

  /// Median pass latency in milliseconds.
  final int medianMs;

  /// 95th-percentile pass latency in milliseconds.
  final int p95Ms;

  /// Compute device reported by `DecisionEngine`.
  final String deviceName;

  /// Optional wall-clock latency of the active Chat LLM performing the exact
  /// same multi-key classification prompt.
  final int? llmCompareElapsedMs;

  /// Name of the active Chat LLM compared against, when measured.
  final String? llmCompareModelName;

  /// Compact output preview from the Chat LLM comparison run.
  final String? llmCompareSummary;

  /// System-1 batch passes per second.
  double get passesPerSecond =>
      totalElapsedMs <= 0 ? 0 : (iterations * 1000.0) / totalElapsedMs;

  /// Individual question decisions answered per second.
  double get decisionsPerSecond => totalElapsedMs <= 0
      ? 0
      : (iterations * questionsPerPass * 1000.0) / totalElapsedMs;

  /// Mean latency per System-1 pass in milliseconds.
  double get meanMs => iterations <= 0 ? 0 : totalElapsedMs / iterations;

  /// Speedup ratio (`llmCompareElapsedMs / medianMs`) when compared against LLM.
  double? get speedupVsLlm {
    final llm = llmCompareElapsedMs;
    if (llm == null || llm <= 0) {
      return null;
    }
    final baseline = medianMs > 0 ? medianMs.toDouble() : meanMs;
    if (baseline <= 0) {
      return null;
    }
    return llm / baseline;
  }
}

/// Lifecycle port for adapters hosting dedicated Playground/Notebook models.
abstract interface class StudioDedicatedModelLoader {
  /// Loads a dedicated embedding, reranker, or decision model from [assets].
  Future<void> loadDedicatedModel({
    required ResolvedModelAssets assets,
    required bool isWeb,
  });

  /// Releases any dedicated playground engines.
  Future<void> dispose();
}

/// Segregated embedding capability port for Playground and Multimodal Notebook.
abstract interface class StudioEmbeddingPort
    implements StudioDedicatedModelLoader {
  /// Reports modalities supported by the currently loaded embedding engine.
  Future<EmbeddingCapabilityInfo> probeEmbeddingCapabilities();

  /// Computes embeddings and pairwise cosine similarity across [texts].
  Future<EmbeddingComparisonResult> computeEmbeddings(List<String> texts);

  /// Computes document vectors for semantic indexing (using asymmetric document
  /// prefixes when supported by the loaded embedder).
  Future<EmbeddedPassageResult> embedDocuments(
    List<String> documents, {
    List<String?>? titles,
  });

  /// Computes a vector for a single note, using multimodal `embedContent`
  /// when image/audio bytes are attached and supported by `EmbeddingGemma 2`.
  Future<NoteEmbeddingVectorResult> embedNoteContent(NoteEmbeddingInput input);

  /// Computes a search query vector matching [embedDocuments].
  Future<EmbeddedQueryResult> embedQuery(String query);
}

/// Segregated cross-encoder reranking port.
abstract interface class StudioRerankerPort
    implements StudioDedicatedModelLoader {
  /// Scores and sorts [documents] against [query] using `LlamaReranker`.
  Future<List<RankedDocumentItem>> rerank({
    required String query,
    required List<String> documents,
  });
}

/// Segregated Laya System-1 decision evaluation & benchmarking port.
abstract interface class StudioDecisionPort
    implements StudioDedicatedModelLoader {
  /// Evaluates a System-1 yes/no (`noul`) question on [stateText].
  Future<SystemOneEvaluation> evaluateSystemOne({
    required String stateText,
    required String yesNoQuestion,
  });

  /// Evaluates multiple typed `ChoiceKey`, `ScoreKey`, and `NoulKey` questions
  /// in a single `DecisionEngine.systemOne` forward pass.
  Future<SystemOneBatchEvaluation> evaluateSystemOneBatch({
    required Object state,
    required List<SystemOneQuestionSpec> questions,
  });

  /// Runs [iterations] repeated `DecisionEngine.systemOne` passes to measure
  /// real throughput (`decisions/sec`, median/p95 ms) and optionally compares
  /// wall-clock latency against the active Chat LLM on the exact same task.
  Future<DecisionBenchmarkSummary> runDecisionSpeedBenchmark({
    required Object state,
    required List<SystemOneQuestionSpec> questions,
    int iterations = 15,
    bool compareWithActiveChatLlm = false,
  });
}

/// Segregated tokenizer inspection port.
abstract interface class StudioTokenInspectorPort {
  /// Tokenizes [text] into individual token IDs and decoded pieces using the
  /// active chat or playground engine.
  Future<List<InspectedToken>> inspectTokens(String text);
}

/// Segregated LLM prefill/decode throughput benchmark port.
abstract interface class StudioBenchmarkPort {
  /// Runs a short deterministic prefill + decode throughput benchmark on the
  /// active chat engine.
  Future<BenchmarkRunSummary> runBenchmark({int targetDecodeTokens = 64});
}

/// Composite port bundling all Playground developer lab capabilities
/// (Embeddings, Multimodal Notes, Reranking, System-1 Decision Heads,
/// Tokenization, and Benchmarks).
abstract interface class StudioPlaygroundPort
    implements
        StudioEmbeddingPort,
        StudioRerankerPort,
        StudioDecisionPort,
        StudioTokenInspectorPort,
        StudioBenchmarkPort {}
