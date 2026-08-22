@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

import '../../../tool/testing/enforce_high_risk_pr_contract.dart';

const _head = '1111111111111111111111111111111111111111';
const _base = '2222222222222222222222222222222222222222';
const _implementationTask =
    'codex://tasks/root/structured_output_implementation';
const _qaTask = 'codex://tasks/root/structured_output_independent_qa';
const _evidencePath = '.github/high-risk-evidence/394.json';
const _grammarTest =
    'test/integration/core/grammar/compiled_chat_grammar_test.dart';
const _parserTest = 'test/unit/core/template/chat_template_engine_test.dart';
const _state = HighRiskPrState(
  headSha: _head,
  baseSha: _base,
  behind: 0,
  ahead: 6,
  unresolvedThreads: 0,
);

const _structuredFiles = <String>[
  'lib/src/core/template/chat_format.dart',
  _grammarTest,
  _parserTest,
  _evidencePath,
];

String _validBody() =>
    '''
## High-risk regression gate
- **High-risk classification:** high-risk
- **Evidence manifest:** $_evidencePath
- **Implementation task:** $_implementationTask
- **Independent blocking QA task:** $_qaTask
- **Exact head SHA:** $_head
- **Current base SHA:** $_base
- **Current base distance:** 0 behind / 6 ahead
- **Independent QA verdict:** PASS
- **Known PR-caused P1 regressions:** 0
- **Unresolved review threads:** 0
''';

Map<String, dynamic> _validEvidence() => {
  'schema': 1,
  'issue': 394,
  'surfaces': ['structuredOutput', 'regressionPolicy'],
  'implementationTask': _implementationTask,
  'independentQaTask': _qaTask,
  'productionEvidence': {
    'positiveTests': [_parserTest],
    'negativeTests': [_parserTest],
    'adversarialTests': [_parserTest],
    'deletionSensitivityTests': [_parserTest],
  },
  'affectedFamilies': ['MiniMax M1', 'MiniMax M3'],
  'affectedFamilyEvidence': {
    'MiniMax M1': 'upstream+fixture',
    'MiniMax M3': 'real-model',
  },
  'upstreamRefs': ['b10549', 'd775b8967a46d8beb110d444aa3b8938179e0dd8'],
  'structuredOutput': {
    'compiledAcceptanceTests': [_grammarTest],
    'compiledRejectionTests': [_grammarTest],
    'schemaDirectedTypeTests': [_parserTest],
    'partialFinalStreamingTests': [_parserTest],
    'toolChoiceThinkingTests': [_parserTest],
    'upstreamParityCommand': './tool/testing/run_template_parity_suites.sh',
    'requiredCoverage': [
      'unknown-field',
      'missing-field',
      'mismatched-type',
      'malformed-output',
      'string',
      'number',
      'boolean',
      'null',
      'object',
      'array',
      'zero-argument',
      'empty-container',
      'partial',
      'final',
      'rollback',
      'auto',
      'required',
      'none',
      'thinking-prefix',
    ],
  },
};

HighRiskContractResult _validate({
  String? body,
  Iterable<String> files = _structuredFiles,
  Iterable<String> deletedFiles = const [],
  Map<String, dynamic>? evidence,
  String? evidencePath = _evidencePath,
  HighRiskPrState state = _state,
}) => validateHighRiskContract(
  changedFiles: files,
  deletedFiles: deletedFiles,
  body: body ?? _validBody(),
  state: state,
  evidence: evidence ?? _validEvidence(),
  evidencePath: evidencePath,
);

String _replaceField(String body, String label, String replacement) =>
    body.replaceFirst(
      RegExp('^- \\*\\*$label:\\*\\*.*\$', multiLine: true),
      '- **$label:** $replacement',
    );

void main() {
  group('high-risk classifier', () {
    test('covers structured API and streaming surfaces', () {
      final assessment = assessHighRiskFiles(const [
        'lib/src/core/models/inference/tool_choice.dart',
        'lib/src/core/models/inference/structured_output.dart',
        'lib/src/core/models/inference/generation_params.dart',
        'lib/src/core/models/chat/completion_chunk.dart',
      ]);

      expect(assessment.surfaces, contains(HighRiskSurface.structuredOutput));
    });

    test('covers backend capabilities and artifact consumers', () {
      final assessment = assessHighRiskFiles(const [
        'lib/src/core/models/download/model_download_manager_base.dart',
        'lib/src/hook/native_bundle_config.dart',
        'example/chat_app/web/index.html',
      ]);

      expect(
        assessment.surfaces,
        containsAll(const {
          HighRiskSurface.backendRuntime,
          HighRiskSurface.artifactConsumer,
        }),
      );
    });

    test('covers release and regression enforcement surfaces', () {
      final assessment = assessHighRiskFiles(const [
        '.github/workflows/docs_version_cut.yml',
        '.github/workflows/ci.yml',
        'tool/testing/verify_release_docs_versions.dart',
        'test/unit/tooling/high_risk_pr_contract_test.dart',
        '.github/high-risk-evidence/419.json',
      ]);

      expect(
        assessment.surfaces,
        containsAll(const {
          HighRiskSurface.releaseAutomation,
          HighRiskSurface.regressionPolicy,
        }),
      );
    });

    test('does not classify unrelated tests or docs', () {
      final assessment = assessHighRiskFiles(const [
        'test/unit/core/models/model_test.dart',
        'test/unit/core/template/chat_template_engine_test.dart',
        'website/docs/guides/embeddings.md',
      ]);

      expect(assessment.isHighRisk, isFalse);
    });
  });

  group('trusted evidence binding', () {
    test('accepts exact structured evidence bound to changed tests', () {
      expect(_validate().errors, isEmpty);
    });

    test('requires stable, distinct task references', () {
      var body = _replaceField(_validBody(), 'Implementation task', 'abcde');
      body = _replaceField(body, 'Independent blocking QA task', 'abcde');

      expect(
        _validate(body: body).errors.join('\n'),
        contains('stable Codex task/thread or GitHub reference'),
      );
    });

    test('binds QA to exact current GitHub state', () {
      var body = _replaceField(_validBody(), 'Exact head SHA', 'deadbeef');
      body = _replaceField(body, 'Current base SHA', 'cafebabe');
      body = _replaceField(body, 'Current base distance', '1 behind / 6 ahead');

      final errors = _validate(
        body: body,
        state: const HighRiskPrState(
          headSha: _head,
          baseSha: _base,
          behind: 1,
          ahead: 6,
          unresolvedThreads: 0,
        ),
      ).errors.join('\n');

      expect(errors, contains('Exact head SHA'));
      expect(errors, contains('Current base SHA'));
      expect(errors, contains('must integrate the current base'));
    });

    test('blocks unresolved review threads', () {
      final body = _replaceField(
        _validBody(),
        'Unresolved review threads',
        '1',
      );
      final result = _validate(
        body: body,
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

    test('requires one changed machine-readable manifest', () {
      final result = _validate(
        files: _structuredFiles.where((path) => path != _evidencePath),
        evidencePath: null,
      );

      expect(result.errors.join('\n'), contains('exactly one changed'));
      expect(result.errors.join('\n'), contains('Trusted workflow'));
    });

    test('binds the manifest issue to its numeric filename', () {
      final evidence = _validEvidence()..['issue'] = 410;

      expect(
        _validate(evidence: evidence).errors,
        contains('Manifest issue must match its numeric evidence filename.'),
      );
    });

    test('does not echo untrusted PR fields in mismatch diagnostics', () {
      const secretLikeValue = 'https://signed.example/token?secret=do-not-log';
      final body = _replaceField(
        _validBody(),
        'Exact head SHA',
        secretLikeValue,
      );
      final errors = _validate(body: body).errors.join('\n');

      expect(errors, contains('Exact head SHA does not match'));
      expect(errors, isNot(contains(secretLikeValue)));
    });

    test('rejects tests that are absent, deleted, or not durable', () {
      final evidence = _validEvidence();
      final production =
          evidence['productionEvidence']! as Map<String, dynamic>;
      production['positiveTests'] = ['docs/not_a_test.md'];
      production['negativeTests'] = ['test/unit/not_changed_test.dart'];

      final errors = _validate(
        evidence: evidence,
        deletedFiles: const [_parserTest],
      ).errors.join('\n');

      expect(errors, contains('durable Dart test'));
      expect(errors, contains('must be changed by the same PR'));
      expect(errors, contains('cannot reference a deleted test'));
    });

    test('requires exact affected-family inventory and honest N/A proof', () {
      final evidence = _validEvidence();
      evidence['affectedFamilyEvidence'] = {
        'MiniMax M1': 'upstream-only',
        'unaffected Qwen': 'real-model',
      };

      final errors = _validate(evidence: evidence).errors.join('\n');

      expect(errors, contains('exactly equal affectedFamilies'));
    });
  });

  group('PR #391 / issues #394-#410 failure classes', () {
    test(
      'original PR #391 paths cannot substitute parser tests for compilation',
      () {
        const originalPr391 = [
          'lib/src/core/template/chat_format.dart',
          'lib/src/core/template/chat_template_engine.dart',
          'test/integration/core/template/llama_cpp_template_detection_integration_test.dart',
          _parserTest,
          _evidencePath,
        ];
        final evidence = _validEvidence();
        final structured =
            evidence['structuredOutput']! as Map<String, dynamic>;
        structured['compiledAcceptanceTests'] = [_parserTest];
        structured['compiledRejectionTests'] = [_parserTest];

        expect(
          _validate(files: originalPr391, evidence: evidence).errors.join('\n'),
          contains('compiled grammar production tests'),
        );
      },
    );

    final requiredCoverage = <String, String>{
      '#394/#399 envelope and quoted-name acceptance': 'unknown-field',
      '#395/#396/#407 schema rejection and delimiters': 'mismatched-type',
      '#397/#398 partial leakage and final preservation': 'rollback',
      '#402/#406 required-tool reasoning prefixes': 'thinking-prefix',
      '#408/#410 zero arguments and typed empty values': 'zero-argument',
    };
    for (final entry in requiredCoverage.entries) {
      test('blocks missing production proof for ${entry.key}', () {
        final evidence = _validEvidence();
        final structured =
            evidence['structuredOutput']! as Map<String, dynamic>;
        final coverage = (structured['requiredCoverage']! as List)
            .cast<String>();
        structured['requiredCoverage'] = coverage
            .where((value) => value != entry.value)
            .toList();

        expect(
          _validate(evidence: evidence).errors.join('\n'),
          contains(entry.value),
        );
      });
    }

    test('requires pinned upstream parity command', () {
      final evidence = _validEvidence();
      final structured = evidence['structuredOutput']! as Map<String, dynamic>;
      structured['upstreamParityCommand'] =
          'tool/testing/run_template_parity_suites.sh';

      expect(
        _validate(evidence: evidence).errors.join('\n'),
        contains('./tool/testing/run_template_parity_suites.sh'),
      );
    });
  });

  group('trusted workflow contract', () {
    test('runs only base policy and treats head files as API data', () {
      final workflow = File(
        '.github/workflows/trusted_high_risk_regression_gate.yml',
      ).readAsStringSync();

      expect(workflow, contains('pull_request_target:'));
      expect(workflow, contains('Check out trusted default-branch policy'));
      expect(
        workflow,
        isNot(contains(r'ref: ${{ github.event.pull_request.head.sha }}')),
      );
      expect(workflow, contains('pulls/\$PR_NUMBER/files?per_page=100'));
      expect(workflow, contains('.previous_filename'));
      expect(workflow, contains('status == "removed"'));
      expect(workflow, contains('persist-credentials: false'));
      expect(workflow, contains('ready_for_review'));
      expect(workflow, contains('review_requested'));
      expect(workflow, contains('review_request_removed'));
      expect(workflow, contains('auto_merge_enabled'));
      expect(workflow, contains('reviewThreads(first:100)'));
      expect(workflow, contains('enforce_high_risk_pr_contract.dart'));
    });

    test('documents bootstrap and repository-settings closure gates', () {
      final agents = File('AGENTS.md').readAsStringSync();
      final matrix = File('doc/testing_matrix.md').readAsStringSync();
      final template = File(
        '.github/pull_request_template.md',
      ).readAsStringSync();

      expect(agents, contains('treats pull-request files as untrusted data'));
      expect(matrix, contains('status check, require conversation'));
      expect(matrix, contains('conversation-resolution'));
      expect(matrix, contains('up to date with `main`'));
      expect(matrix, contains('deliberate base advance'));
      expect(template, contains('Evidence manifest'));
    });
  });
}
