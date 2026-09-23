import 'dart:convert';

import 'package:llamadart/llamadart.dart';

/// Support ticket triaged when `--state` is not given.
const Map<String, Object?> defaultTicketState = {
  'from': 'user@acme.com',
  'subject': 'Duplicate charge on invoice #4411',
  'body': 'We were billed twice for March. Please refund the duplicate.',
};

/// Triage questions: one choice, one score and one noul.
final Map<String, DecisionQuestion> ticketTriageQuestions = {
  'department': DecisionQuestion.choice(
    'Which department should handle this request?',
    criteria: {
      'billing': 'invoices, payments, refunds',
      'technical': 'bugs, outages, system errors',
      'other': null,
    },
  ),
  'urgency': DecisionQuestion.score(
    'How urgent is this request?',
    levels: ['not urgent', 'soon', 'critical'],
  ),
  'refund': DecisionQuestion.noul('Does the user request a refund?'),
};

/// Formats [value] for display: a [String] as-is, anything else as JSON.
String decisionValueText(Object? value) =>
    value is String ? value : jsonEncode(value);

/// Formats every answer in [result] with its confidence and act probability.
String formatDecisionAnswers(DecisionResult result) {
  final buffer = StringBuffer();
  for (final MapEntry(key: id, value: answer) in result.answers.entries) {
    switch (answer) {
      case ChoiceAnswer(:final choice, :final probabilities):
        buffer
          ..writeln('$id (choice): $choice')
          ..writeln('  ${_formatProbabilities(probabilities, (key) => key)}');
      case ScoreAnswer(:final score, :final legend, :final probabilities):
        String level(String key) => switch (legend[key]) {
          null => key,
          final description => '$key ${decisionValueText(description)}',
        };
        buffer
          ..writeln('$id (score): ${_fixed(score)} (expected level)')
          ..writeln('  ${_formatProbabilities(probabilities, level)}');
      case NoulAnswer(:final noul):
        buffer.writeln('$id (noul): ${_fixed(noul)} (${noul >= 0.5})');
    }
    buffer.writeln(
      '  confidence ${_fixed(answer.confidence)}, '
      'actProbability ${_fixed(answer.actProbability)}',
    );
  }
  return buffer.toString();
}

/// Formats [result] as indented Laya `{model, answers, usage}` JSON.
String formatDecisionJson(DecisionResult result) =>
    const JsonEncoder.withIndent('  ').convert(result.toJson());

String _formatProbabilities(
  Map<String, double> probabilities,
  String Function(String key) label,
) {
  final options = [
    for (final MapEntry(:key, :value) in probabilities.entries)
      '${label(key)}: ${_fixed(value)}',
  ];
  return 'probabilities: ${options.join(', ')}';
}

String _fixed(double value) => value.toStringAsFixed(4);
