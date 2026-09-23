import 'decision_question.dart';

/// The model's answer to one [DecisionQuestion].
///
/// Values are unrounded; Laya rounds its JSON to 4 decimals.
sealed class DecisionAnswer {
  DecisionAnswer._({required this.confidence, required this.actProbability});

  /// Kind of the question this answers.
  DecisionQuestionType get type;

  /// Confidence in the answer, from 0 to 1.
  final double confidence;

  /// Probability of the act head's first action, Laya's
  /// `action.act_probability`.
  final double actProbability;

  /// Converts this answer to Laya's response format.
  Map<String, Object?> toJson();

  Map<String, Object?> get _action => {'act_probability': actProbability};
}

/// Answer to a [ChoiceQuestion].
final class ChoiceAnswer extends DecisionAnswer {
  /// Creates a choice answer.
  ChoiceAnswer({
    required this.choice,
    required Map<String, double> probabilities,
    required super.confidence,
    required super.actProbability,
  }) : probabilities = Map.unmodifiable(probabilities),
       super._();

  /// The most probable label.
  final String choice;

  /// Probability of each label, in option order.
  final Map<String, double> probabilities;

  @override
  DecisionQuestionType get type => DecisionQuestionType.choice;

  @override
  Map<String, Object?> toJson() => {
    'type': type.name,
    'choice': choice,
    'probabilities': probabilities,
    'confidence': confidence,
    'action': _action,
  };
}

/// Answer to a [ScoreQuestion].
final class ScoreAnswer extends DecisionAnswer {
  /// Creates a score answer.
  ScoreAnswer({
    required this.score,
    required Map<String, Object?> legend,
    required Map<String, double> probabilities,
    required super.confidence,
    required super.actProbability,
  }) : legend = Map.unmodifiable(legend),
       probabilities = Map.unmodifiable(probabilities),
       super._();

  /// Expected level, the probability-weighted mean of the level indices.
  final double score;

  /// Level descriptions keyed `'0'`, `'1'`, and so on.
  final Map<String, Object?> legend;

  /// Probability of each level, keyed like [legend].
  final Map<String, double> probabilities;

  @override
  DecisionQuestionType get type => DecisionQuestionType.score;

  @override
  Map<String, Object?> toJson() => {
    'type': type.name,
    'score': score,
    'legend': legend,
    'probabilities': probabilities,
    'confidence': confidence,
    'action': _action,
  };
}

/// Answer to a [NoulQuestion].
final class NoulAnswer extends DecisionAnswer {
  /// Creates a noul answer.
  NoulAnswer({
    required this.noul,
    required super.confidence,
    required super.actProbability,
  }) : super._();

  /// Probability that the statement is true.
  final double noul;

  @override
  DecisionQuestionType get type => DecisionQuestionType.noul;

  @override
  Map<String, Object?> toJson() => {
    'type': type.name,
    'noul': noul,
    'confidence': confidence,
    'action': _action,
  };
}

/// Token usage of a decision call.
class DecisionUsage {
  /// Creates a usage record.
  const DecisionUsage({required this.inputTokens, required this.outputTokens});

  /// Tokens across all encoded sequences.
  final int inputTokens;

  /// Generated tokens; decision models generate none.
  final int outputTokens;

  /// Converts this record to Laya's `usage` format.
  Map<String, Object?> toJson() => {
    'input_tokens': inputTokens,
    'output_tokens': outputTokens,
  };
}

/// Answers to a decision request.
class DecisionResult {
  /// Creates a result.
  DecisionResult({
    required this.model,
    required Map<String, DecisionAnswer> answers,
    required this.usage,
  }) : answers = Map.unmodifiable(answers);

  /// Model name reported in the response.
  final String model;

  /// Answers by question id, in question order.
  final Map<String, DecisionAnswer> answers;

  /// Token usage.
  final DecisionUsage usage;

  /// The [ChoiceAnswer]s in [answers], in question order.
  Map<String, ChoiceAnswer> get choices => _answersOf<ChoiceAnswer>();

  /// The [ScoreAnswer]s in [answers], in question order.
  Map<String, ScoreAnswer> get scores => _answersOf<ScoreAnswer>();

  /// The [NoulAnswer]s in [answers], in question order.
  Map<String, NoulAnswer> get nouls => _answersOf<NoulAnswer>();

  /// Converts this result to Laya's `{model, answers, usage}` response format.
  Map<String, Object?> toJson() => {
    'model': model,
    'answers': {
      for (final MapEntry(:key, :value) in answers.entries) key: value.toJson(),
    },
    'usage': usage.toJson(),
  };

  Map<String, T> _answersOf<T extends DecisionAnswer>() => Map.unmodifiable({
    for (final MapEntry(:key, :value) in answers.entries)
      if (value is T) key: value,
  });
}
