@TestOn('vm')
@Tags(<String>['local-only', 'e2e'])
@Timeout(Duration(minutes: 15))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/core/decision/decision_decoder.dart';
import 'package:llamadart/src/core/decision/decision_sequence.dart';
import 'package:test/test.dart';

import '../../support/decision_fixture.dart';

const _modelPathKey = 'LLAMADART_DECISION_MODEL_PATH';
const _headPathKey = 'LLAMADART_DECISION_HEAD_PATH';
const _configPathKey = 'LLAMADART_DECISION_CONFIG_PATH';
const _backendKey = 'LLAMADART_DECISION_BACKEND';
const _logitToleranceKey = 'LLAMADART_DECISION_LOGIT_TOLERANCE';
const _probToleranceKey = 'LLAMADART_DECISION_PROB_TOLERANCE';

void main() {
  test('matches the Laya 0.3.5 reference on every fixture row', () async {
    final modelPath = _requiredFile(_modelPathKey);
    final headPath = _requiredFile(_headPathKey);
    if (modelPath == null || headPath == null) {
      return;
    }
    final configPath = _optionalFile(_configPathKey);
    final backend = _backend();
    final logitTolerance = _tolerance(_logitToleranceKey, 0.25);
    final probTolerance = _tolerance(_probToleranceKey, 0.05);
    final fixture = DecisionFixture.load();
    final failures = <String>[];

    final engine = LlamaEngine(LlamaBackend());
    BackendDecisionHeadInfo? rawHead;
    DecisionEngine? decisions;
    try {
      await engine.loadModel(
        modelPath,
        modelParams: ModelParams(
          contextSize: 512,
          preferredBackend: backend,
          gpuLayers: backend == GpuBackend.cpu ? 0 : ModelParams.maxGpuLayers,
        ),
      );
      final capabilities = await DecisionEngine.capabilitiesFor(engine);
      expect(
        capabilities.isSupported,
        isTrue,
        reason: capabilities.unsupportedReason,
      );

      final head = rawHead = await engine.loadDecisionHeadBackend(
        headPath,
        configPath: configPath,
      );
      final config = DecisionHeadConfig.fromJson(
        jsonDecode(head.configJson) as Map<String, Object?>,
      );
      final spec = DecisionSequenceSpec(
        clsToken: head.clsToken,
        sepToken: head.sepToken,
        maskToken: head.maskToken,
        maskText: head.maskText,
        maxTokens: config.maxTokens,
        headMaxTokens: config.headMaxTokens,
      );

      for (final row in fixture.rows) {
        final sequence = (await buildDecisionSequences(
          DecisionRequest(
            state: row.state,
            questions: {
              row.questionId: DecisionQuestion.fromJson(row.question),
            },
          ),
          spec,
          (text) => engine.tokenize(text, addSpecial: false),
        )).single;
        if (!_listEquals(sequence.tokens, row.ids)) {
          failures.add('${row.id}: token ids ${sequence.tokens} != ${row.ids}');
        }
        if (!_listEquals(sequence.markers, row.markers)) {
          failures.add(
            '${row.id}: markers ${sequence.markers} != ${row.markers}',
          );
        }
      }

      final inputs = [
        for (final row in fixture.rows)
          BackendDecisionSequence(
            tokens: Int32List.fromList(row.ids),
            markers: Int32List.fromList(row.markers),
            questionType: DecisionQuestion.fromJson(row.question).type.index,
          ),
      ];
      await engine.runDecisionBackend(head.handle, inputs.sublist(0, 1));
      final rawWatch = Stopwatch()..start();
      final outputs = await engine.runDecisionBackend(head.handle, inputs);
      rawWatch.stop();
      expect(outputs, hasLength(fixture.rows.length));

      final logitDiff = _Worst();
      final actLogitDiff = _Worst();
      for (final (index, row) in fixture.rows.indexed) {
        final output = outputs[index];
        if (output.logits.length != row.rawLogits.length) {
          failures.add(
            '${row.id}: ${output.logits.length} logits, expected '
            '${row.rawLogits.length}',
          );
          continue;
        }
        for (var i = 0; i < row.rawLogits.length; i++) {
          final diff = (output.logits[i] - row.rawLogits[i]).abs();
          logitDiff.record(diff, row.id);
          if (!(diff <= logitTolerance)) {
            failures.add(
              '${row.id}: logit $i ${output.logits[i]} vs '
              '${row.rawLogits[i]} (diff $diff > $logitTolerance)',
            );
          }
        }
        for (var i = 0; i < row.rawActLogits.length; i++) {
          if (i < output.actLogits.length) {
            actLogitDiff.record(
              (output.actLogits[i] - row.rawActLogits[i]).abs(),
              row.id,
            );
          }
        }
      }

      final decisionEngine = decisions = await DecisionEngine.load(
        engine,
        headPath: headPath,
        configPath: configPath,
      );
      final cases = <String, List<DecisionFixtureRow>>{};
      for (final row in fixture.rows) {
        (cases[row.caseId] ??= []).add(row);
      }
      Future<DecisionResult> answer(List<DecisionFixtureRow> rows) =>
          decisionEngine.systemOne(
            state: rows.first.state,
            questions: {
              for (final row in rows)
                row.questionId: DecisionQuestion.fromJson(row.question),
            },
          );

      await answer(cases.values.first);
      final probDiff = _Worst();
      final scoreDiff = _Worst();
      final answerWatch = Stopwatch();
      for (final rows in cases.values) {
        answerWatch.start();
        final result = await answer(rows);
        answerWatch.stop();
        expect(result.model, 'laya-rl-agent');
        final inputTokens = rows.fold(0, (sum, row) => sum + row.ids.length);
        if (result.usage.inputTokens != inputTokens) {
          failures.add(
            '${rows.first.caseId}: usage.inputTokens '
            '${result.usage.inputTokens} != $inputTokens',
          );
        }
        for (final row in rows) {
          final actual = result.answers[row.questionId];
          if (actual == null) {
            failures.add('${row.id}: no answer');
            continue;
          }
          _compareAnswer(
            row,
            actual,
            probTolerance,
            probDiff,
            scoreDiff,
            failures,
          );
        }
      }

      if (backend == GpuBackend.cpu &&
          decisionEngine.info.deviceName != 'CPU') {
        failures.add(
          'head device ${decisionEngine.info.deviceName} for a CPU model',
        );
      }
      final questions = fixture.rows.length;
      print(
        'RESULT decision_engine backend=${backend.name} '
        'engineBackend=${_oneWord(capabilities.backendName ?? 'unknown')} '
        'headDevice=${_oneWord(decisionEngine.info.deviceName)} '
        'rows=$questions '
        'failures=${failures.length} '
        'worstLogitDiff=${logitDiff.describe()} '
        'worstActLogitDiff=${actLogitDiff.describe()} '
        'worstProbDiff=${probDiff.describe()} '
        'worstScoreDiff=${scoreDiff.describe()} '
        'rawMsPerQuestion=${_ms(rawWatch, questions)} '
        'systemOneMsPerQuestion=${_ms(answerWatch, questions)}',
      );
      expect(failures, isEmpty, reason: failures.join('\n'));
    } finally {
      await decisions?.dispose();
      if (rawHead != null) {
        await engine.freeDecisionHeadBackend(rawHead.handle);
      }
      await engine.dispose();
    }
  });

  test('keeps the head on the CPU when the model offloads no layers', () async {
    final modelPath = _requiredFile(_modelPathKey);
    final headPath = _requiredFile(_headPathKey);
    if (modelPath == null || headPath == null) {
      return;
    }
    final fixture = DecisionFixture.load();
    final row = fixture.rows.first;
    final engine = LlamaEngine(LlamaBackend());
    DecisionEngine? decisions;
    try {
      await engine.loadModel(
        modelPath,
        modelParams: ModelParams(
          contextSize: 512,
          preferredBackend: _backend(),
          gpuLayers: 0,
        ),
      );
      decisions = await DecisionEngine.load(
        engine,
        headPath: headPath,
        configPath: _optionalFile(_configPathKey),
      );

      final result = await decisions.systemOne(
        state: row.state,
        questions: {row.questionId: DecisionQuestion.fromJson(row.question)},
      );

      print(
        'RESULT decision_engine_cpu_placement backend=${_backend().name} '
        'headDevice=${_oneWord(decisions.info.deviceName)}',
      );
      expect(decisions.info.deviceName, 'CPU');
      final failures = <String>[];
      _compareAnswer(
        row,
        result.answers[row.questionId]!,
        _tolerance(_probToleranceKey, 0.05),
        _Worst(),
        _Worst(),
        failures,
      );
      expect(failures, isEmpty, reason: failures.join('\n'));
    } finally {
      await decisions?.dispose();
      await engine.dispose();
    }
  });

  test('engine dispose frees a head that was not disposed', () async {
    final modelPath = _requiredFile(_modelPathKey);
    final headPath = _requiredFile(_headPathKey);
    if (modelPath == null || headPath == null) {
      return;
    }
    final backend = _backend();
    final engine = LlamaEngine(LlamaBackend());
    var engineDisposed = false;
    try {
      await engine.loadModel(
        modelPath,
        modelParams: ModelParams(
          contextSize: 512,
          preferredBackend: backend,
          gpuLayers: backend == GpuBackend.cpu ? 0 : ModelParams.maxGpuLayers,
        ),
      );
      final decisions = await DecisionEngine.load(
        engine,
        headPath: headPath,
        configPath: _optionalFile(_configPathKey),
      );
      final questions = {
        'refund': DecisionQuestion.noul('Does the user request a refund?'),
      };
      await decisions.systemOne(state: 'Refund me.', questions: questions);

      await engine.dispose();
      engineDisposed = true;

      await expectLater(
        decisions.systemOne(state: 'Refund me.', questions: questions),
        throwsA(isA<LlamaStateException>()),
      );
      await decisions.dispose();
    } finally {
      if (!engineDisposed) await engine.dispose();
    }
  });
}

GpuBackend _backend() {
  final name = Platform.environment[_backendKey]?.trim();
  return GpuBackend.values.byName(name == null || name.isEmpty ? 'cpu' : name);
}

void _compareAnswer(
  DecisionFixtureRow row,
  DecisionAnswer actual,
  double tolerance,
  _Worst probDiff,
  _Worst scoreDiff,
  List<String> failures,
) {
  final expected = row.answer;
  if (actual.type.name != expected['type']) {
    failures.add('${row.id}: type ${actual.type.name} != ${expected['type']}');
    return;
  }
  void within(String field, double value, Object? reference, double limit) {
    final diff = (value - (reference as num)).abs();
    (field == 'score' ? scoreDiff : probDiff).record(diff, row.id);
    if (!(diff <= limit)) {
      failures.add(
        '${row.id}: $field $value vs $reference (diff $diff > $limit)',
      );
    }
  }

  void probabilities(Map<String, double> values) {
    final reference = (expected['probabilities'] as Map).cast<String, num>();
    if (!_listEquals(values.keys.toList(), reference.keys.toList())) {
      failures.add(
        '${row.id}: probability keys ${values.keys} != ${reference.keys}',
      );
      return;
    }
    for (final MapEntry(:key, :value) in values.entries) {
      within('probabilities[$key]', value, reference[key], tolerance);
    }
  }

  within('confidence', actual.confidence, expected['confidence'], tolerance);
  within(
    'act_probability',
    actual.actProbability,
    (expected['action'] as Map)['act_probability'],
    tolerance,
  );
  switch (actual) {
    case ChoiceAnswer(:final choice, probabilities: final values):
      probabilities(values);
      final reference = (expected['probabilities'] as Map).values
          .map((value) => (value as num).toDouble())
          .toList();
      reference.sort((a, b) => b.compareTo(a));
      final gap = reference.length < 2 ? 1.0 : reference[0] - reference[1];
      if (choice != expected['choice'] && gap > tolerance) {
        failures.add(
          '${row.id}: choice $choice != ${expected['choice']} '
          '(reference top-2 gap $gap)',
        );
      }
    case ScoreAnswer(:final score, probabilities: final values):
      probabilities(values);
      within('score', score, expected['score'], 2 * tolerance);
    case NoulAnswer(:final noul):
      within('noul', noul, expected['noul'], tolerance);
  }
}

final class _Worst {
  double value = 0;
  String? id;

  void record(double diff, String rowId) {
    if (diff.isNaN || diff > value) {
      value = diff.isNaN ? double.infinity : diff;
      id = rowId;
    }
  }

  String describe() => id == null ? '0' : '${value.toStringAsFixed(4)}@$id';
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

String _ms(Stopwatch watch, int questions) =>
    (watch.elapsedMicroseconds / 1000 / math.max(1, questions)).toStringAsFixed(
      1,
    );

String _oneWord(String value) => value.replaceAll(RegExp(r'\s+'), '_');

double _tolerance(String environmentKey, double fallback) {
  final value = Platform.environment[environmentKey]?.trim();
  if (value == null || value.isEmpty) return fallback;
  final parsed = double.tryParse(value);
  if (parsed == null || !parsed.isFinite || parsed < 0) {
    throw StateError('$environmentKey must be a non-negative number.');
  }
  return parsed;
}

String? _requiredFile(String environmentKey) {
  final value = Platform.environment[environmentKey];
  if (value == null || value.isEmpty) {
    markTestSkipped('Set $environmentKey to run the decision engine E2E.');
    return null;
  }
  if (!File(value).existsSync()) {
    throw StateError('$environmentKey does not exist.');
  }
  return value;
}

String? _optionalFile(String environmentKey) {
  final value = Platform.environment[environmentKey];
  if (value == null || value.isEmpty) return null;
  if (!File(value).existsSync()) {
    throw StateError('$environmentKey does not exist.');
  }
  return value;
}
