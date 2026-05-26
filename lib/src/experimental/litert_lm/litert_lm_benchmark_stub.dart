// coverage:ignore-file

/// Benchmark metrics shape shared with the native LiteRT-LM implementation.
class LiteRtLmBenchmarkMetrics {
  /// Number of prompt/input tokens.
  final int inputTokens;

  /// Number of generated/output tokens.
  final int outputTokens;

  /// Time to first token in seconds, when reported by LiteRT-LM.
  final double? timeToFirstTokenSeconds;

  /// Engine initialization time in seconds, when reported by LiteRT-LM.
  final double? initSeconds;

  /// Prompt prefill throughput in tokens per second.
  final double? prefillTokensPerSecond;

  /// Decode throughput in tokens per second.
  final double? decodeTokensPerSecond;

  /// Wall-clock runtime measured by Dart.
  final int wallMilliseconds;

  /// Creates benchmark metrics.
  const LiteRtLmBenchmarkMetrics({
    required this.inputTokens,
    required this.outputTokens,
    required this.timeToFirstTokenSeconds,
    required this.initSeconds,
    required this.prefillTokensPerSecond,
    required this.decodeTokensPerSecond,
    required this.wallMilliseconds,
  });

  /// Converts metrics to JSON-compatible values.
  Map<String, Object?> toJson() => {
    'inputTokens': inputTokens,
    'outputTokens': outputTokens,
    'timeToFirstTokenSeconds': timeToFirstTokenSeconds,
    'initSeconds': initSeconds,
    'prefillTokensPerSecond': prefillTokensPerSecond,
    'decodeTokensPerSecond': decodeTokensPerSecond,
    'wallMilliseconds': wallMilliseconds,
  };
}

/// Generated text and benchmark metrics from a LiteRT-LM run.
class LiteRtLmBenchmarkResult {
  /// Generated text.
  final String text;

  /// Benchmark metrics.
  final LiteRtLmBenchmarkMetrics metrics;

  /// Creates a benchmark result.
  const LiteRtLmBenchmarkResult({required this.text, required this.metrics});
}

/// Web-safe placeholder for the native-only benchmark client.
class LiteRtLmBenchmarkClient {
  /// Creates a placeholder client on platforms without `dart:ffi`.
  LiteRtLmBenchmarkClient() {
    throw UnsupportedError('LiteRT-LM benchmark requires a native platform.');
  }

  /// Initializes the native LiteRT-LM engine.
  Future<void> initialize({
    required String modelPath,
    String backend = 'gpu',
    int maxTokens = 4096,
    int outputTokens = 256,
    int? prefillTokens,
    String? cacheDir,
    bool speculativeDecoding = true,
  }) {
    throw UnsupportedError('LiteRT-LM benchmark requires a native platform.');
  }

  /// Runs the benchmark.
  Future<LiteRtLmBenchmarkResult> run({
    required String prompt,
    int warmupRuns = 1,
    int measuredRuns = 3,
  }) {
    throw UnsupportedError('LiteRT-LM benchmark requires a native platform.');
  }

  /// Releases native LiteRT-LM resources.
  void dispose() {}
}
