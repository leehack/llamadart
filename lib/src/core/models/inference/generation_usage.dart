/// Token counts and timings of one generation request.
class LlamaGenerationUsage {
  /// Prompt tokens in the context when generation started, including
  /// [cachedPromptTokens] and any media tokens.
  final int promptTokens;

  /// Leading prompt tokens reused from the context's previous request instead
  /// of being evaluated again, or null when the backend cannot tell.
  final int? cachedPromptTokens;

  /// Generated tokens with a non-empty text piece, including tokens that
  /// formed a stop sequence. The end-of-generation token is not counted.
  final int completionTokens;

  /// Time from the backend starting the request to its first streamed text,
  /// or null when it streamed none.
  ///
  /// Measured where the backend generates, before any batching of streamed
  /// tokens, so it excludes time spent queued behind another request.
  final Duration? timeToFirstToken;

  /// Time from the backend starting the request to the end of generation.
  final Duration duration;

  /// Creates a new [LlamaGenerationUsage].
  const LlamaGenerationUsage({
    required this.promptTokens,
    this.cachedPromptTokens,
    required this.completionTokens,
    this.timeToFirstToken,
    required this.duration,
  });

  /// [promptTokens] plus [completionTokens].
  int get totalTokens => promptTokens + completionTokens;

  /// Creates a [LlamaGenerationUsage] from a map produced by [toJson].
  factory LlamaGenerationUsage.fromJson(Map<String, dynamic> json) {
    final details = json['prompt_tokens_details'] as Map<String, dynamic>?;
    final timeToFirstTokenMs = json['time_to_first_token_ms'] as num?;
    return LlamaGenerationUsage(
      promptTokens: json['prompt_tokens'] as int,
      cachedPromptTokens: details?['cached_tokens'] as int?,
      completionTokens: json['completion_tokens'] as int,
      timeToFirstToken: timeToFirstTokenMs == null
          ? null
          : _durationFromMs(timeToFirstTokenMs),
      duration: _durationFromMs(json['duration_ms'] as num),
    );
  }

  /// Converts this object to an OpenAI-style `usage` map, with
  /// `time_to_first_token_ms` and `duration_ms` added.
  Map<String, dynamic> toJson() {
    final timeToFirstToken = this.timeToFirstToken;
    return {
      'prompt_tokens': promptTokens,
      'completion_tokens': completionTokens,
      'total_tokens': totalTokens,
      if (cachedPromptTokens != null)
        'prompt_tokens_details': {'cached_tokens': cachedPromptTokens},
      if (timeToFirstToken != null)
        'time_to_first_token_ms': timeToFirstToken.inMicroseconds / 1000,
      'duration_ms': duration.inMicroseconds / 1000,
    };
  }

  static Duration _durationFromMs(num ms) =>
      Duration(microseconds: (ms * 1000).round());

  @override
  String toString() =>
      'LlamaGenerationUsage(promptTokens: $promptTokens, '
      'cachedPromptTokens: $cachedPromptTokens, '
      'completionTokens: $completionTokens, '
      'timeToFirstToken: $timeToFirstToken, duration: $duration)';
}
