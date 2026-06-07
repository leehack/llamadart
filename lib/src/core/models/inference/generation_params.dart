/// Parameters controlling the token sampling and generation process.
///
/// Use [GenerationParams] to fine-tune how the model generates text, including
/// randomness (temperature), sampling constraints (Top-K/Top-P), and
/// architectural limits (max tokens).
///
/// Example:
/// ```dart
/// final params = GenerationParams(
///   temp: 0.7,
///   maxTokens: 1024,
///   stopSequences: ['User:', '\n\n'],
///   grammar: 'root ::= "yes" | "no"', // Force binary response
/// );
/// ```
/// Lazy grammar activation trigger.
class GenerationGrammarTrigger {
  /// Trigger type (0=word, 1=token, 2=pattern, 3=pattern_full).
  final int type;

  /// Trigger text value.
  final String value;

  /// Trigger token id for token-based triggers.
  final int? token;

  /// Creates a new grammar trigger.
  const GenerationGrammarTrigger({
    required this.type,
    required this.value,
    this.token,
  });
}

/// Backend-neutral speculative decoding strategy.
enum SpeculativeDecodingStrategy {
  /// Let the selected backend choose its native speculative decoding mode.
  backendDefault,

  /// Multi-token prediction.
  ///
  /// llama.cpp maps this to its `draft-mtp` speculative path. LiteRT-LM native
  /// currently maps this to its runtime speculative decoding switch.
  mtp,
}

/// Backend-neutral speculative decoding configuration.
///
/// Backends map the strategy and knobs they support to their native runtime.
/// Unsupported strategy/option combinations must fail explicitly instead of
/// silently falling back.
class SpeculativeDecodingConfig {
  /// Strategy to use when speculative decoding is enabled.
  final SpeculativeDecodingStrategy strategy;

  /// Maximum number of draft tokens to propose per speculative step.
  ///
  /// `null` lets the backend choose its default.
  final int? draftTokenMax;

  /// Minimum number of draft tokens required for speculative verification.
  ///
  /// `null` lets the backend choose its default.
  final int? draftTokenMin;

  /// Minimum draft-token probability accepted by the backend.
  ///
  /// `null` lets the backend choose its default.
  final double? minProbability;

  /// Creates a backend-neutral speculative decoding configuration.
  const SpeculativeDecodingConfig({
    this.strategy = SpeculativeDecodingStrategy.backendDefault,
    this.draftTokenMax,
    this.draftTokenMin,
    this.minProbability,
  }) : assert(draftTokenMax == null || draftTokenMax >= 0),
       assert(draftTokenMin == null || draftTokenMin >= 0),
       assert(
         minProbability == null ||
             (minProbability >= 0.0 && minProbability <= 1.0),
       );

  /// Enables the backend's default speculative decoding behavior.
  const SpeculativeDecodingConfig.backendDefault()
    : strategy = SpeculativeDecodingStrategy.backendDefault,
      draftTokenMax = null,
      draftTokenMin = null,
      minProbability = null;

  /// Enables multi-token prediction speculative decoding.
  const SpeculativeDecodingConfig.mtp({
    this.draftTokenMax,
    this.draftTokenMin,
    this.minProbability,
  }) : strategy = SpeculativeDecodingStrategy.mtp,
       assert(draftTokenMax == null || draftTokenMax >= 0),
       assert(draftTokenMin == null || draftTokenMin >= 0),
       assert(
         minProbability == null ||
             (minProbability >= 0.0 && minProbability <= 1.0),
       );
}

/// Parameters controlling the token sampling and generation process.
class GenerationParams {
  /// Default prompt prefix reuse behavior for native generation.
  static const bool defaultReusePromptPrefix = true;

  /// Default native stream batching threshold by token pieces.
  static const int defaultStreamBatchTokenThreshold = 8;

  /// Default native stream batching threshold by byte size.
  static const int defaultStreamBatchByteThreshold = 512;

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

  /// Min-P sampling threshold.
  ///
  /// Set to 0.0 to disable Min-P filtering.
  final double minP;

  /// Penalty applied to tokens that have already appeared in the sequence.
  /// 1.0 means no penalty.
  final double penalty;

  /// Random seed for the sampler.
  ///
  /// If null, a seed based on the current time will be used.
  final int? seed;

  /// List of strings that, if generated, will immediately stop the generation process.
  final List<String> stopSequences;

  /// GBNF grammar string for structured output (e.g., "root ::= \"hello\" | \"world\"").
  final String? grammar;

  /// Whether grammar should be lazily activated by triggers.
  final bool grammarLazy;

  /// Lazy grammar activation triggers.
  final List<GenerationGrammarTrigger> grammarTriggers;

  /// Tokens to preserve during constrained decoding.
  final List<String> preservedTokens;

  /// Grammar start symbol. Defaults to "root".
  final String grammarRoot;

  /// Enables backend-native speculative decoding when supported.
  ///
  /// Native LiteRT-LM forwards this flag to the runtime's speculative decoding
  /// setting. llama.cpp maps it to the backend-default speculative strategy
  /// when the active model/context supports that path. WebGPU and LiteRT-LM web
  /// reject this option until their runtimes expose equivalent controls.
  ///
  /// Prefer [speculativeDecodingConfig] for new code that needs a specific
  /// strategy or runtime-neutral options.
  final bool speculativeDecoding;

  /// Strategy and knobs for backend-native speculative decoding.
  ///
  /// `null` disables speculative decoding unless [speculativeDecoding] is true.
  /// When [speculativeDecoding] is true and this is null, backends should treat
  /// the request as [SpeculativeDecodingStrategy.backendDefault].
  final SpeculativeDecodingConfig? speculativeDecodingConfig;

  /// Reuses matching prompt prefixes from previous requests in the same native
  /// context to reduce prompt ingestion latency.
  ///
  /// This optimization applies to native text-only generation.
  /// Exact full-prompt replays are conservatively re-ingested to preserve
  /// deterministic parity.
  final bool reusePromptPrefix;

  /// Native worker chunk flush threshold by token pieces.
  ///
  /// Lower values improve stream granularity but increase isolate message
  /// overhead. Higher values reduce overhead but emit larger chunks.
  final int streamBatchTokenThreshold;

  /// Native worker chunk flush threshold by byte size.
  ///
  /// Lower values improve stream granularity but increase isolate message
  /// overhead. Higher values reduce overhead but emit larger chunks.
  final int streamBatchByteThreshold;

  /// Creates generation parameters with default values.
  const GenerationParams({
    this.maxTokens = 4096,
    this.temp = 0.8,
    this.topK = 40,
    this.topP = 0.9,
    this.minP = 0.0,
    this.penalty = 1.1,
    this.seed,
    this.stopSequences = const [],
    this.grammar,
    this.grammarLazy = false,
    this.grammarTriggers = const [],
    this.preservedTokens = const [],
    this.grammarRoot = 'root',
    this.speculativeDecoding = false,
    this.speculativeDecodingConfig,
    this.reusePromptPrefix = defaultReusePromptPrefix,
    this.streamBatchTokenThreshold = defaultStreamBatchTokenThreshold,
    this.streamBatchByteThreshold = defaultStreamBatchByteThreshold,
  });

  /// Whether speculative decoding is requested by either public API shape.
  bool get isSpeculativeDecodingEnabled =>
      speculativeDecoding || speculativeDecodingConfig != null;

  /// Resolved speculative decoding configuration, if enabled.
  ///
  /// Legacy [speculativeDecoding] requests resolve to backend-default
  /// speculative decoding.
  SpeculativeDecodingConfig? get resolvedSpeculativeDecodingConfig =>
      speculativeDecodingConfig ??
      (speculativeDecoding
          ? const SpeculativeDecodingConfig.backendDefault()
          : null);

  /// Creates a copy of this [GenerationParams] with updated fields.
  GenerationParams copyWith({
    int? maxTokens,
    double? temp,
    int? topK,
    double? topP,
    double? minP,
    double? penalty,
    int? seed,
    List<String>? stopSequences,
    String? grammar,
    bool? grammarLazy,
    List<GenerationGrammarTrigger>? grammarTriggers,
    List<String>? preservedTokens,
    String? grammarRoot,
    bool? speculativeDecoding,
    SpeculativeDecodingConfig? speculativeDecodingConfig,
    bool clearSpeculativeDecodingConfig = false,
    bool? reusePromptPrefix,
    int? streamBatchTokenThreshold,
    int? streamBatchByteThreshold,
  }) {
    return GenerationParams(
      maxTokens: maxTokens ?? this.maxTokens,
      temp: temp ?? this.temp,
      topK: topK ?? this.topK,
      topP: topP ?? this.topP,
      minP: minP ?? this.minP,
      penalty: penalty ?? this.penalty,
      seed: seed ?? this.seed,
      stopSequences: stopSequences ?? this.stopSequences,
      grammar: grammar ?? this.grammar,
      grammarLazy: grammarLazy ?? this.grammarLazy,
      grammarTriggers: grammarTriggers ?? this.grammarTriggers,
      preservedTokens: preservedTokens ?? this.preservedTokens,
      grammarRoot: grammarRoot ?? this.grammarRoot,
      speculativeDecoding: speculativeDecoding ?? this.speculativeDecoding,
      speculativeDecodingConfig: clearSpeculativeDecodingConfig
          ? null
          : (speculativeDecodingConfig ?? this.speculativeDecodingConfig),
      reusePromptPrefix: reusePromptPrefix ?? this.reusePromptPrefix,
      streamBatchTokenThreshold:
          streamBatchTokenThreshold ?? this.streamBatchTokenThreshold,
      streamBatchByteThreshold:
          streamBatchByteThreshold ?? this.streamBatchByteThreshold,
    );
  }
}
