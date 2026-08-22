@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

import '../../../tool/testing/check_high_risk_pr_contract.dart';

const _head = '1111111111111111111111111111111111111111';
const _base = '2222222222222222222222222222222222222222';
const _state = HighRiskPrState(
  headSha: _head,
  baseSha: _base,
  behind: 0,
  ahead: 6,
  unresolvedThreads: 0,
);

const _pr391Files = <String>[
  'lib/src/core/template/chat_format.dart',
  'lib/src/core/template/chat_template_engine.dart',
  'lib/src/core/template/handlers/llama_cpp_specialized_handlers.dart',
  'test/integration/core/template/llama_cpp_template_detection_integration_test.dart',
  'test/unit/core/template/chat_template_engine_test.dart',
  'test/unit/core/template/handlers/llama_cpp_specialized_handlers_test.dart',
];

String _validBody() =>
    '''
## High-risk regression gate
- **High-risk classification:** high-risk
- **Implementation task:** codex://threads/implementation-391-recovery
- **Independent blocking QA task:** codex://threads/independent-adversarial-qa
- **Exact head SHA:** $_head
- **Current base SHA:** $_base
- **Current base distance:** 0 behind / 6 ahead
- **Independent QA verdict:** PASS
- **Production call sites inspected:** PASS: production handler, engine routing, and grammar call sites inspected
- **Positive production-path evidence:** PASS: production path valid emissions pass durable tests
- **Negative/adversarial production-path evidence:** PASS: production path adversarial malformed and version-skew cases pass
- **Deletion/bypass/miswire sensitivity:** PASS: delete, bypass, and miswire mutations each fail the focused regression tests
- **Known PR-caused P1 regressions:** 0
- **Unresolved review threads:** 0
- **Affected-family real model/artifact evidence:** N/A: exact Kimi K3 weights unavailable; primary upstream emissions and durable fixture evidence used
- **Unrelated representative smoke:** pipeline-only: Qwen proves the shared runtime pipeline, not affected-family syntax
- **Compiled grammar valid upstream emissions:** PASS: compiled grammars accept actual upstream emitted valid shapes
- **Compiled grammar rejection matrix:** PASS: compiled grammars reject unknown, missing, wrong-type, and malformed structures
- **Schema-directed types and empty values:** PASS: string, number, boolean, null, object, array, and empty values retain schema types
- **Partial/final streaming and rollback:** PASS: partial markup is suppressed and final malformed content uses rollback preservation
- **Tool choice and thinking prefixes:** PASS: auto, required, and none tool choice pass with thinking prefixes
- **Pinned/current upstream template/parser parity:** PASS: pinned and current upstream parity passed via run_template_parity_suites.sh
- **Exact affected-format evidence:** N/A: Kimi K3 and MiniMax M3 weights unavailable; upstream emissions plus durable fixture coverage used
''';

HighRiskContractResult _validate(
  String body, {
  Iterable<String> files = _pr391Files,
  HighRiskPrState state = _state,
}) => validateHighRiskContract(changedFiles: files, body: body, state: state);

String _replaceField(String body, String label, String replacement) {
  return body.replaceFirst(
    RegExp('^- \\*\\*$label:\\*\\*.*\$', multiLine: true),
    '- **$label:** $replacement',
  );
}

void main() {
  group('high-risk classifier', () {
    test('classifies the production scope of PR #391 as structured output', () {
      final assessment = assessHighRiskFiles(_pr391Files);

      expect(assessment.isHighRisk, isTrue);
      expect(assessment.isStructuredOutput, isTrue);
    });

    test('classifies backend, artifact, release, and policy surfaces', () {
      final assessment = assessHighRiskFiles(const [
        'lib/src/backends/llama_cpp/worker.dart',
        'hook/build.dart',
        '.github/workflows/release_on_prep_merge.yml',
        '.github/pull_request_template.md',
      ]);

      expect(
        assessment.surfaces,
        containsAll(const {
          HighRiskSurface.backendRuntime,
          HighRiskSurface.artifactConsumer,
          HighRiskSurface.releaseAutomation,
          HighRiskSurface.regressionPolicy,
        }),
      );
    });

    test('does not classify ordinary docs or tests alone as high risk', () {
      final assessment = assessHighRiskFiles(const [
        'website/docs/guides/embeddings.md',
        'test/unit/core/models/model_test.dart',
        'test/unit/core/template/chat_template_engine_test.dart',
      ]);

      expect(assessment.isHighRisk, isFalse);
    });
  });

  group('high-risk evidence contract', () {
    test('accepts complete exact-head structured-output evidence', () {
      final result = _validate(_validBody());

      expect(result.errors, isEmpty);
    });

    test('binds independent QA to the exact head, base, and distance', () {
      var body = _validBody();
      body = _replaceField(body, 'Exact head SHA', 'deadbeef');
      body = _replaceField(body, 'Current base SHA', 'cafebabe');
      body = _replaceField(body, 'Current base distance', '1 behind / 5 ahead');
      body = _replaceField(
        body,
        'Independent blocking QA task',
        'codex://threads/implementation-391-recovery',
      );

      final errors = _validate(body).errors.join('\n');

      expect(errors, contains('Exact head SHA'));
      expect(errors, contains('Current base SHA'));
      expect(errors, contains('Current base distance'));
      expect(errors, contains('must differ from the implementation task'));
    });

    test('blocks when live review threads remain unresolved', () {
      final result = _validate(
        _replaceField(_validBody(), 'Unresolved review threads', '1'),
        state: const HighRiskPrState(
          headSha: _head,
          baseSha: _base,
          behind: 0,
          ahead: 6,
          unresolvedThreads: 1,
        ),
      );

      expect(
        result.errors,
        contains('High-risk PRs cannot pass with unresolved review threads.'),
      );
    });

    test('requires independent QA after integrating current base', () {
      final result = _validate(
        _replaceField(
          _validBody(),
          'Current base distance',
          '1 behind / 6 ahead',
        ),
        state: const HighRiskPrState(
          headSha: _head,
          baseSha: _base,
          behind: 1,
          ahead: 6,
          unresolvedThreads: 0,
        ),
      );

      expect(
        result.errors.join('\n'),
        contains('must integrate the current base before mark-ready'),
      );
    });

    test('requires durable tests on high-risk policy changes', () {
      final result = _validate(
        _validBody(),
        files: const ['.github/pull_request_template.md'],
      );

      expect(
        result.errors.join('\n'),
        contains('require a durable *_test.dart change'),
      );
    });

    test('workflow reruns on evidence and ready-state changes', () {
      final workflow = File(
        '.github/workflows/high_risk_regression_gate.yml',
      ).readAsStringSync();
      final template = File(
        '.github/pull_request_template.md',
      ).readAsStringSync();
      final owners = File('.github/CODEOWNERS').readAsStringSync();
      final agents = File('AGENTS.md').readAsStringSync();
      final matrixDoc = File('doc/testing_matrix.md').readAsStringSync();

      expect(workflow, contains('edited'));
      expect(workflow, contains('ready_for_review'));
      expect(workflow, contains('github.event.pull_request.head.sha'));
      expect(workflow, contains('git fetch --no-tags origin'));
      expect(workflow, contains('reviewThreads(first:100)'));
      expect(workflow, contains('check_high_risk_pr_contract.dart'));
      expect(workflow, contains('persist-credentials: false'));
      expect(template, contains('Known PR-caused P1 regressions'));
      expect(template, contains('Compiled grammar rejection matrix'));
      expect(owners, contains('check_high_risk_pr_contract.dart @leehack'));
      expect(agents, contains('stop lower-priority merge work'));
      expect(matrixDoc, contains('cohesive recovery PR'));
    });
  });

  group('PR #391 regression failure classes', () {
    final cases = <String, ({String field, String weakEvidence})>{
      '#394/#399 envelope and quoted-name acceptance': (
        field: 'Compiled grammar valid upstream emissions',
        weakEvidence: 'PASS: grammar string contains a root rule',
      ),
      '#395/#396/#407 schema-exact rejection and delimiters': (
        field: 'Compiled grammar rejection matrix',
        weakEvidence: 'PASS: malformed output test exists',
      ),
      '#397/#398 partial protocol leakage and final preservation': (
        field: 'Partial/final streaming and rollback',
        weakEvidence: 'PASS: complete parsing passes',
      ),
      '#402/#406 required-tool reasoning prefixes': (
        field: 'Tool choice and thinking prefixes',
        weakEvidence: 'PASS: auto tool choice passes',
      ),
      '#408/#410 empty and schema-directed values': (
        field: 'Schema-directed types and empty values',
        weakEvidence: 'PASS: JSON-like values decode',
      ),
    };

    for (final MapEntry(key: name, value: testCase) in cases.entries) {
      test('blocks weak evidence for $name', () {
        final result = _validate(
          _replaceField(_validBody(), testCase.field, testCase.weakEvidence),
        );

        expect(result.errors, isNotEmpty);
      });
    }

    test('rejects unrelated real-model smoke as affected-format proof', () {
      final body = _replaceField(
        _validBody(),
        'Affected-family real model/artifact evidence',
        'Qwen real-model smoke passed',
      );

      expect(
        _validate(body).errors.join('\n'),
        contains('exact unavailable family'),
      );
    });

    test('requires zero known P1 regressions before merge', () {
      final body = _replaceField(
        _validBody(),
        'Known PR-caused P1 regressions',
        '1 deferred to follow-up',
      );

      expect(
        _validate(body).errors.join('\n'),
        contains('must be exactly "0"'),
      );
    });
  });
}
