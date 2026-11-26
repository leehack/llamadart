import 'dart:convert';
import 'dart:math' as math;

/// One token and its log-probability.
class LlamaTokenLogprob {
  /// Creates a token log-probability.
  LlamaTokenLogprob({
    required this.token,
    required List<int> bytes,
    required this.logprob,
  }) : bytes = List.unmodifiable(bytes);

  /// Token id in the model's vocabulary.
  final int token;

  /// UTF-8 bytes of the token's text, special tokens included. A token can
  /// hold part of a multi-byte character.
  final List<int> bytes;

  /// Natural-log probability of the token.
  final double logprob;

  /// The token's text, with malformed UTF-8 replaced by U+FFFD.
  String get text => utf8.decode(bytes, allowMalformed: true);

  /// The probability, `exp(logprob)`.
  double get probability => math.exp(logprob);

  /// Converts this object to a JSON map in the shape of an OpenAI
  /// `top_logprobs` entry, plus the token id as `id`.
  ///
  /// A token the model rules out has `-infinity` as its [logprob], which JSON
  /// cannot hold, so it is written as `-9999`, as OpenAI does.
  Map<String, dynamic> toJson() => {
    'token': text,
    'id': token,
    'logprob': logprob.isFinite ? logprob : -9999.0,
    'bytes': bytes,
  };

  /// Creates a [LlamaTokenLogprob] from [toJson] output.
  factory LlamaTokenLogprob.fromJson(Map<String, dynamic> json) {
    return LlamaTokenLogprob(
      token: json['id'] as int,
      bytes: (json['bytes'] as List<dynamic>).cast<int>(),
      logprob: (json['logprob'] as num).toDouble(),
    );
  }
}

/// The log-probabilities of one generated token: the sampled token and the
/// most probable alternatives at that position.
///
/// They come from a softmax over the model's raw logits for the position,
/// before logit bias, repetition and other penalties, grammar and
/// temperature, so the sampled token can be absent from [top] and can have a
/// low probability when sampling settings steer it.
class LlamaGeneratedTokenLogprobs {
  /// Creates the log-probabilities of one generated token.
  LlamaGeneratedTokenLogprobs({
    required this.sampled,
    required List<LlamaTokenLogprob> top,
  }) : top = List.unmodifiable(top);

  /// The token the sampler chose, with the bytes it added to the stream.
  final LlamaTokenLogprob sampled;

  /// The most probable tokens at this position, most probable first.
  ///
  /// Empty when `GenerationParams.topLogprobs` is 0.
  final List<LlamaTokenLogprob> top;

  /// Converts this object to a JSON map in the shape of an OpenAI chat
  /// completion `logprobs.content` entry.
  Map<String, dynamic> toJson() => {
    ...sampled.toJson(),
    'top_logprobs': [for (final alternative in top) alternative.toJson()],
  };

  /// Creates [LlamaGeneratedTokenLogprobs] from [toJson] output.
  factory LlamaGeneratedTokenLogprobs.fromJson(Map<String, dynamic> json) {
    return LlamaGeneratedTokenLogprobs(
      sampled: LlamaTokenLogprob.fromJson(json),
      top: [
        for (final alternative in json['top_logprobs'] as List<dynamic>)
          LlamaTokenLogprob.fromJson(alternative as Map<String, dynamic>),
      ],
    );
  }
}

/// Log-probabilities of the token that would follow a prompt, from
/// `LlamaEngine.scoreNextToken`.
///
/// They come from a softmax over the model's raw logits at the last prompt
/// position. Sampling settings such as temperature, top-k, penalties and
/// grammar do not apply.
class LlamaNextTokenScores {
  /// Creates next-token scores.
  LlamaNextTokenScores({
    required List<LlamaTokenLogprob> candidates,
    required List<LlamaTokenLogprob> top,
    required this.promptTokens,
  }) : candidates = List.unmodifiable(candidates),
       top = List.unmodifiable(top);

  /// The requested candidate tokens, in request order.
  final List<LlamaTokenLogprob> candidates;

  /// The most probable tokens, most probable first.
  final List<LlamaTokenLogprob> top;

  /// Number of tokens the prompt tokenized to.
  final int promptTokens;
}
