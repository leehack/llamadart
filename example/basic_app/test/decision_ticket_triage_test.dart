import 'dart:convert';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart_basic_example/services/decision_ticket_triage.dart';
import 'package:test/test.dart';

const _usage = DecisionUsage(inputTokens: 230, outputTokens: 0);

DecisionResult _triage({String choice = 'billing', double refund = 0.91693}) =>
    DecisionResult(
      model: 'laya-rl-agent',
      answers: {
        'department': ChoiceAnswer(
          choice: choice,
          probabilities: {
            'billing': 0.95644,
            'technical': 0.03356,
            'other': 0.01,
          },
          confidence: 0.83621,
          actProbability: 1,
        ),
        'urgency': ScoreAnswer(
          score: 0.86204,
          legend: {
            '0': 'not urgent',
            '1': {'eta': '1d'},
            '2': null,
          },
          probabilities: {'0': 0.32133, '1': 0.49538, '2': 0.18329},
          confidence: 0.06811,
          actProbability: 0.25,
        ),
        'refund': NoulAnswer(
          noul: refund,
          confidence: 0.91693,
          actProbability: 0.5,
        ),
      },
      usage: _usage,
      questions: ticketTriageQuestions,
    );

void main() {
  test('ticketTriageQuestions are the Laya ticket questions in key order', () {
    expect(
      {
        for (final MapEntry(:key, :value) in ticketTriageQuestions.entries)
          key: value.toJson(),
      },
      {
        'department': {
          'type': 'choice',
          'instructions': 'Which department should handle this request?',
          'criteria': {
            'billing': 'invoices, payments, refunds',
            'technical': 'bugs, outages, system errors',
            'other': null,
          },
        },
        'urgency': {
          'type': 'score',
          'instructions': 'How urgent is this request?',
          'criteria': ['not urgent', 'soon', 'critical'],
        },
        'refund': {
          'type': 'noul',
          'instructions': 'Does the user request a refund?',
        },
      },
    );
  });

  test('formatTicketTriage prints every answer in question order', () {
    expect(
      formatTicketTriage(_triage()),
      'department (choice): billing\n'
      '  probabilities: billing: 0.9564, technical: 0.0336, other: 0.0100\n'
      '  confidence 0.8362, actProbability 1.0000\n'
      'urgency (score): 0.8620 (expected level)\n'
      '  probabilities: 0 not urgent: 0.3213, 1 {"eta":"1d"}: 0.4954, '
      '2: 0.1833\n'
      '  confidence 0.0681, actProbability 0.2500\n'
      'refund (noul): 0.9169 (true)\n'
      '  confidence 0.9169, actProbability 0.5000\n',
    );
  });

  test('formatTicketTriage prints the chosen Department', () {
    expect(
      formatTicketTriage(_triage(choice: 'technical')),
      startsWith('department (choice): technical\n'),
    );
  });

  test('formatTicketTriage reports a refund noul of 0.5 or more as true', () {
    expect(
      formatTicketTriage(_triage(refund: 0.4999)),
      contains('refund (noul): 0.4999 (false)\n'),
    );
    expect(
      formatTicketTriage(_triage(refund: 0.5)),
      contains('refund (noul): 0.5000 (true)\n'),
    );
  });

  test('formatTicketTriage rejects a result of JSON-parsed questions', () {
    final parsed = DecisionResult(
      model: 'laya-rl-agent',
      answers: _triage().answers,
      usage: _usage,
      questions: {
        for (final MapEntry(:key, :value) in ticketTriageQuestions.entries)
          key: DecisionQuestion.fromJson(value.toJson()),
      },
    );

    expect(
      () => formatTicketTriage(parsed),
      throwsA(isA<LlamaDecisionException>()),
    );
  });

  test('formatDecisionJson is indented Laya JSON of the result', () {
    final result = _triage();

    final text = formatDecisionJson(result);

    expect(text, startsWith('{\n  "model": "laya-rl-agent",\n'));
    expect(jsonDecode(text), result.toJson());
  });

  test('decisionValueText keeps text and encodes other values as JSON', () {
    expect(decisionValueText('Billed twice.'), 'Billed twice.');
    expect(
      decisionValueText({'body': 'Billed twice.'}),
      '{"body":"Billed twice."}',
    );
    expect(decisionValueText(null), 'null');
  });
}
