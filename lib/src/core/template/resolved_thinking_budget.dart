import '../models/inference/generation_params.dart';

/// Template-derived budget settings carried with the request to the backend.
final class ResolvedThinkingBudget extends ThinkingBudget {
  /// Retains the caller text so native-message routing can skip the prefix.
  ResolvedThinkingBudget({
    required super.maxTokens,
    required super.startTag,
    required super.endTag,
    required super.forcedMessage,
    required this.originalForcedMessage,
    required List<String> naturalEndTags,
    required this.grammarReplayEndIndex,
  }) : naturalEndTags = List.unmodifiable(naturalEndTags);

  /// Caller text before applying the template close prefix.
  final String? originalForcedMessage;

  /// Complete ordered list of natural delimiters.
  final List<String> naturalEndTags;

  /// Natural delimiter to replay to the paused grammar, if any.
  final int? grammarReplayEndIndex;
}
