import 'dart:convert';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart_basic_example/services/decision_ticket_triage.dart';
import 'package:test/test.dart';

DecisionResult _result(Map<String, DecisionAnswer> answers) => DecisionResult(
  model: 'laya-rl-agent',
  answers: answers,
  usage: const DecisionUsage(inputTokens: 230, outputTokens: 0),
);

void main() {
  test('formatDecisionAnswers prints every answer in question order', () {
    final result = _result({
      'department': ChoiceAnswer(
        choice: 'billing',
        probabilities: {'billing': 0.95644, 'technical': 0.04356},
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
        noul: 0.91693,
        confidence: 0.91693,
        actProbability: 0.5,
      ),
    });

    expect(
      formatDecisionAnswers(result),
      'department (choice): billing\n'
      '  probabilities: billing: 0.9564, technical: 0.0436\n'
      '  confidence 0.8362, actProbability 1.0000\n'
      'urgency (score): 0.8620 (expected level)\n'
      '  probabilities: 0 not urgent: 0.3213, 1 {"eta":"1d"}: 0.4954, '
      '2: 0.1833\n'
      '  confidence 0.0681, actProbability 0.2500\n'
      'refund (noul): 0.9169 (true)\n'
      '  confidence 0.9169, actProbability 0.5000\n',
    );
  });

  test('formatDecisionAnswers reports a noul of 0.5 or more as true', () {
    final result = _result({
      'below': NoulAnswer(noul: 0.4999, confidence: 0.5001, actProbability: 1),
      'tie': NoulAnswer(noul: 0.5, confidence: 0.5, actProbability: 1),
    });

    final text = formatDecisionAnswers(result);

    expect(text, contains('below (noul): 0.4999 (false)\n'));
    expect(text, contains('tie (noul): 0.5000 (true)\n'));
  });

  test('formatDecisionJson is indented Laya JSON of the result', () {
    final result = _result({
      'refund': NoulAnswer(noul: 0.9, confidence: 0.9, actProbability: 1),
    });

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
