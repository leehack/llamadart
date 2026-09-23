import 'dart:convert';

import 'package:llamadart/llamadart.dart';

/// Support ticket triaged when `--state` is not given.
const Map<String, Object?> defaultTicketState = {
  'from': 'user@acme.com',
  'subject': 'Duplicate charge on invoice #4411',
  'body': 'We were billed twice for March. Please refund the duplicate.',
};

/// Department that should handle a ticket; the options of [ticketDepartment].
enum Department {
  /// Invoices, payments and refunds.
  billing,

  /// Bugs, outages and system errors.
  technical,

  /// Any other request.
  other,
}

/// Choice of the [Department] that should handle the ticket.
final ChoiceKey<Department> ticketDepartment = ChoiceKey.enumOf(
  'department',
  'Which department should handle this request?',
  criteria: {
    Department.billing: 'invoices, payments, refunds',
    Department.technical: 'bugs, outages, system errors',
    Department.other: null,
  },
);

/// Score of how urgent the ticket is, from level 0 (`not urgent`) to 2
/// (`critical`).
final ScoreKey ticketUrgency = ScoreKey.of(
  'urgency',
  'How urgent is this request?',
  levels: ['not urgent', 'soon', 'critical'],
);

/// Yes/no question: whether the ticket asks for a refund.
final NoulKey ticketRefund = NoulKey.of(
  'refund',
  'Does the user request a refund?',
);

/// Triage questions by id, built from [ticketDepartment], [ticketUrgency] and
/// [ticketRefund].
final Map<String, DecisionQuestion> ticketTriageQuestions =
    DecisionKey.questionsOf([ticketDepartment, ticketUrgency, ticketRefund]);

/// Formats [value] for display: a [String] as-is, anything else as JSON.
String decisionValueText(Object? value) =>
    value is String ? value : jsonEncode(value);

/// Formats the triage answers in [result], read through the triage keys, with
/// their confidence and act probability.
///
/// Throws [LlamaDecisionException] when a triage key cannot read its answer
/// from [result]; see [DecisionResultKeys.answerOf].
String formatTicketTriage(DecisionResult result) {
  final department = result.answerOf(ticketDepartment);
  final urgency = result.answerOf(ticketUrgency);
  final refund = result.answerOf(ticketRefund);
  String level(String key) => switch (urgency.legend[key]) {
    null => key,
    final description => '$key ${decisionValueText(description)}',
  };
  final buffer = StringBuffer()
    ..writeln('${ticketDepartment.id} (choice): ${department.value.name}')
    ..writeln(
      '  ${_formatProbabilities(department.probabilities, (label) => label)}',
    )
    ..writeln(_formatConfidence(department.answer))
    ..writeln(
      '${ticketUrgency.id} (score): ${_fixed(urgency.score)} (expected level)',
    )
    ..writeln('  ${_formatProbabilities(urgency.probabilities, level)}')
    ..writeln(_formatConfidence(urgency))
    ..writeln(
      '${ticketRefund.id} (noul): ${_fixed(refund.noul)} '
      '(${refund.noul >= 0.5})',
    )
    ..writeln(_formatConfidence(refund));
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

String _formatConfidence(DecisionAnswer answer) =>
    '  confidence ${_fixed(answer.confidence)}, '
    'actProbability ${_fixed(answer.actProbability)}';

String _fixed(double value) => value.toStringAsFixed(4);
