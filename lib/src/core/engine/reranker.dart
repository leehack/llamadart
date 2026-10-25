import '../exceptions.dart';
import '../models/inference/reranking.dart';
import 'engine.dart';

/// Ranks documents against a query with a loaded cross-encoder reranker.
///
/// Native llama.cpp rank-pooled GGUF models are supported. WebGPU, LiteRT-LM
/// and ordinary embedding/chat models report unsupported. This wrapper borrows
/// [engine]; await calls before switching models or disposing it. It neither
/// owns a model nor changes the engine's embedding API.
final class LlamaReranker {
  /// Borrows an existing engine, including its context and cancellation policy.
  const LlamaReranker(this.engine);

  /// Existing engine; a separate reranker model normally uses its own engine.
  final LlamaEngine engine;

  /// Explicit model/runtime probe; unloaded or disposed engines are unsupported.
  Future<LlamaRerankingCapabilities> get capabilities =>
      engine.backendRerankingCapabilities;

  /// Returns documents sorted by native output [scoreIndex], descending.
  ///
  /// Output zero matches upstream llama-server. Inspect [capabilities] to choose
  /// another classifier label; this API does not infer a positive class. Ties
  /// preserve input order. [topN] limits returned results after all documents
  /// are scored; null returns all. Empty documents lists return no results on
  /// a supported, loaded engine. Query and document text is preserved verbatim.
  ///
  /// Uses the model's named `rerank` placeholder template when present, or its
  /// vocabulary's BOS/SEP/EOS query/document token framing otherwise.
  /// Complete inputs are preflighted before inference; no truncation or partial
  /// result is returned. Oversized pairs throw [LlamaInferenceException].
  /// Unsupported models/runtimes throw [LlamaUnsupportedException], invalid
  /// score indices or negative [topN] throw [LlamaArgumentException]. An
  /// unloaded engine throws [LlamaContextException]; disposal throws
  /// [LlamaStateException]. Cancellation via [cancel] or the engine fails the call with [LlamaInferenceException] after
  /// its current native pass settles, retaining buffers until then.
  Future<List<LlamaRerankResult>> rerank(
    String query,
    List<String> documents, {
    int scoreIndex = 0,
    int? topN,
  }) async {
    if (topN != null && topN < 0) {
      throw LlamaArgumentException('Reranking topN must not be negative.');
    }
    final inputs = List<String>.of(documents);
    final output = await engine.rerankBackend(query, inputs, scoreIndex);
    final labels = output.classifierLabels;
    if (labels.isEmpty || output.scores.length != inputs.length) {
      throw LlamaInferenceException(
        'Reranking returned an invalid output shape.',
      );
    }
    final results = <LlamaRerankResult>[];
    for (var i = 0; i < output.scores.length; i++) {
      final scores = output.scores[i];
      if (scores.length != labels.length ||
          scoreIndex >= scores.length ||
          scores.any((score) => !score.isFinite)) {
        throw LlamaInferenceException(
          'Reranking returned invalid classifier scores.',
        );
      }
      results.add(
        LlamaRerankResult(
          index: i,
          score: scores[scoreIndex],
          classifierScores: scores,
          classifierLabels: labels,
        ),
      );
    }
    results.sort((a, b) {
      final order = b.score.compareTo(a.score);
      return order == 0 ? a.index.compareTo(b.index) : order;
    });
    return List<LlamaRerankResult>.unmodifiable(
      topN == null ? results : results.take(topN),
    );
  }

  /// Cancels this engine's pending inference, including a reranking call.
  ///
  /// The current native pass must settle before its output buffers are freed.
  void cancel() => engine.cancelGeneration();
}
