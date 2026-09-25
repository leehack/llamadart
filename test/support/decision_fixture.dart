import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

// Laya 0.3.5 reference rows; provenance is in fixtures/decision/README.md.
const decisionFixturePath =
    'packages/llamadart_validation/assets/decision/laya_0_3_5_reference.json';

// Laya rounds answers to 4 decimals and decodes in float32.
const decisionAnswerTolerance = 6e-5;

/// Expects the JSON-like [actual] to equal [expected], with map keys in the
/// same order and numbers outside lists within [decisionAnswerTolerance];
/// lists must be equal. [path] names the value in failure messages.
void expectDecisionJsonClose(Object? actual, Object? expected, String path) {
  switch (expected) {
    case num():
      expect(actual, isA<num>(), reason: path);
      expect(
        actual as num,
        closeTo(expected, decisionAnswerTolerance),
        reason: path,
      );
    case Map():
      expect(actual, isA<Map>(), reason: path);
      final map = actual as Map;
      expect(map.keys, orderedEquals(expected.keys), reason: path);
      for (final key in expected.keys) {
        expectDecisionJsonClose(map[key], expected[key], '$path.$key');
      }
    default:
      expect(actual, expected, reason: path);
  }
}

final class DecisionFixture {
  DecisionFixture._(Map<String, Object?> json)
    : clsToken = _specialToken(json, 'cls'),
      sepToken = _specialToken(json, 'sep'),
      maskToken = _specialToken(json, 'mask'),
      temperature = _doubles(json['temperature']),
      temperatureByOptions = {
        for (final MapEntry(:key, :value)
            in (json['temperatureByOptions'] as Map).entries)
          key as String: (value as num).toDouble(),
      },
      rows = [
        for (final row in json['rows'] as List)
          DecisionFixtureRow._(row as Map<String, Object?>),
      ],
      pieces = {
        for (final MapEntry(:key, :value) in (json['pieces'] as Map).entries)
          key as String: _ints(value),
      };

  factory DecisionFixture.load() => DecisionFixture._(
    jsonDecode(File(decisionFixturePath).readAsStringSync())
        as Map<String, Object?>,
  );

  final int clsToken;
  final int sepToken;
  final int maskToken;
  final List<double> temperature;
  final Map<String, double> temperatureByOptions;
  final List<DecisionFixtureRow> rows;
  final Map<String, List<int>> pieces;
}

final class DecisionFixtureRow {
  DecisionFixtureRow._(Map<String, Object?> json)
    : id = json['id'] as String,
      state = json['state'],
      question = json['question'] as Map<String, Object?>,
      ids = _ints(json['ids']),
      markers = _ints(json['markers']),
      rawLogits = _doubles(json['rawLogits']),
      rawActLogits = _doubles(json['rawActLogits']),
      answer = json['answer'] as Map<String, Object?>;

  final String id;
  final Object? state;
  final Map<String, Object?> question;
  final List<int> ids;
  final List<int> markers;
  final List<double> rawLogits;
  final List<double> rawActLogits;
  final Map<String, Object?> answer;

  String get caseId => id.split('/').first;

  String get questionId => id.split('/').last;
}

int _specialToken(Map<String, Object?> json, String name) =>
    (json['specialTokens'] as Map)[name] as int;

List<int> _ints(Object? value) => [for (final v in value as List) v as int];

List<double> _doubles(Object? value) => [
  for (final v in value as List) (v as num).toDouble(),
];
