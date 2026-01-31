/// Parameters controlling the token sampling and generation process.
class GenerationParams {
  /// Maximum number of new tokens to generate.
  final int maxTokens;

  /// Temperature for sampling (higher = more creative/random, lower = more deterministic).
  /// Range is typically 0.0 to 2.0.
  final double temp;

  /// Top-K sampling: only sample from the top K most likely tokens.
  /// Set to 0 to disable.
  final int topK;

  /// Top-P sampling (nucleus sampling): only sample from tokens whose
  /// cumulative probability exceeds P.
  final double topP;

  /// Penalty applied to tokens that have already appeared in the sequence.
  /// 1.0 means no penalty.
  final double penalty;

  /// Random seed for the sampler.
  ///
  /// If null, a seed based on the current time will be used.
  final int? seed;

  /// List of strings that, if generated, will immediately stop the generation process.
  final List<String> stopSequences;

  /// Creates generation parameters with default values.
  const GenerationParams({
    this.maxTokens = 512,
    this.temp = 0.8,
    this.topK = 40,
    this.topP = 0.9,
    this.penalty = 1.1,
    this.seed,
    this.stopSequences = const [],
  });

  /// Creates a copy of this [GenerationParams] with updated fields.
  GenerationParams copyWith({
    int? maxTokens,
    double? temp,
    int? topK,
    double? topP,
    double? penalty,
    int? seed,
    List<String>? stopSequences,
  }) {
    return GenerationParams(
      maxTokens: maxTokens ?? this.maxTokens,
      temp: temp ?? this.temp,
      topK: topK ?? this.topK,
      topP: topP ?? this.topP,
      penalty: penalty ?? this.penalty,
      seed: seed ?? this.seed,
      stopSequences: stopSequences ?? this.stopSequences,
    );
  }
}
