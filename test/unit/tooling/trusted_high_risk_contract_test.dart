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
    'test/e2e/template/specialized_tool_grammar_validation_e2e_test.dart';
const _parserTest = 'test/unit/core/template/chat_template_engine_test.dart';
const _state = HighRiskPrState(
  headSha: _head,
  baseSha: _base,
  behind: 0,
  ahead: 6,
  unresolvedThreads: 0,
  authorLogin: 'implementation-author',
  reviews: [
    HighRiskReview(
      id: 1,
      authorLogin: 'independent-reviewer',
      commitSha: _head,
      state: 'APPROVED',
      body:
          '''High-risk QA task: $_qaTask
Head: $_head
Base: $_base
Verdict: PASS''',
    ),
  ],
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
  'upstreamRefs': {
    'repository': 'ggml-org/llama.cpp',
    'pinned': 'b10549',
    'current': 'd775b8967a46d8beb110d444aa3b8938179e0dd8',
  },
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
  Set<String>? verifiedUpstreamRefs,
}) => validateHighRiskContract(
  changedFiles: files,
  deletedFiles: deletedFiles,
  body: body ?? _validBody(),
  state: state,
  evidence: evidence ?? _validEvidence(),
  evidencePath: evidencePath,
  verifiedUpstreamRefs:
      verifiedUpstreamRefs ??
      const {'b10549', 'd775b8967a46d8beb110d444aa3b8938179e0dd8'},
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
        'lib/src/core/models/chat/chat_message.dart',
        'lib/src/core/models/chat/chat_template_result.dart',
        'lib/src/core/models/chat/content_part.dart',
        'lib/src/core/models/tools/tool_definition.dart',
        'lib/src/core/engine/engine.dart',
        'lib/src/core/engine/chat_session.dart',
        'lib/src/core/engine/chat_completion_request_planner.dart',
      ]);

      expect(assessment.surfaces, contains(HighRiskSurface.structuredOutput));
    });

    test('covers backend capabilities and artifact consumers', () {
      final assessment = assessHighRiskFiles(const [
        'lib/src/core/models/download/model_download_manager_base.dart',
        'lib/src/hook/native_bundle_config.dart',
        'example/chat_app/web/index.html',
        'lib/src/platform/io/model_download_manager_io.dart',
        'lib/src/core/models/config/gpu_backend.dart',
        'lib/llamadart.dart',
        'pubspec.yaml',
        'hook/build.dart',
        'tool/testing/check_webgpu_bridge_tag.dart',
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
        '.github/actions/release/action.yml',
        'tool/testing/verify_release_docs_versions.dart',
        'tool/testing/check_platform_boundaries.dart',
        'tool/testing/native_prompt_reuse_parity.dart',
        'tool/testing/run_local_e2e.dart',
        'tool/testing/run_template_parity_suites.sh',
        'test/e2e/template/specialized_tool_grammar_validation_e2e_test.dart',
        'test/unit/tooling/high_risk_pr_contract_test.dart',
        '.github/high-risk-evidence/419.json',
      ]);

      expect(
        assessment.surfaces,
        containsAll(const {
          HighRiskSurface.releaseAutomation,
          HighRiskSurface.structuredOutput,
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

    test('preserves exact path spelling instead of normalizing aliases', () {
      final assessment = assessHighRiskFiles(const [
        r'lib\src\core\template\chat_format.dart',
        'lib/src/core/template/chat_format.dart ',
      ]);

      expect(assessment.isHighRisk, isTrue);
      expect(
        assessment.changedFiles,
        equals(const [
          r'lib\src\core\template\chat_format.dart',
          'lib/src/core/template/chat_format.dart ',
        ]),
      );
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

    test('requires valid task references to be distinct', () {
      var body = _replaceField(
        _validBody(),
        'Independent blocking QA task',
        _implementationTask,
      );
      final evidence = _validEvidence()
        ..['independentQaTask'] = _implementationTask;

      expect(
        _validate(body: body, evidence: evidence).errors,
        contains('Independent QA task must differ from implementation task.'),
      );
    });

    test('requires an independent exact-head approving QA attestation', () {
      const noApproval = HighRiskPrState(
        headSha: _head,
        baseSha: _base,
        behind: 0,
        ahead: 6,
        unresolvedThreads: 0,
        authorLogin: 'implementation-author',
        reviews: [],
      );

      expect(
        _validate(state: noApproval).errors.join('\n'),
        contains('current-head APPROVED review'),
      );
    });

    test('rejects author, stale-head, and incomplete QA approvals', () {
      for (final review in const [
        HighRiskReview(
          id: 1,
          authorLogin: 'implementation-author',
          commitSha: _head,
          state: 'APPROVED',
          body:
              '''High-risk QA task: $_qaTask
Head: $_head
Base: $_base
Verdict: PASS''',
        ),
        HighRiskReview(
          id: 1,
          authorLogin: 'independent-reviewer',
          commitSha: _base,
          state: 'APPROVED',
          body:
              '''High-risk QA task: $_qaTask
Head: $_head
Base: $_base
Verdict: PASS''',
        ),
        HighRiskReview(
          id: 1,
          authorLogin: 'independent-reviewer',
          commitSha: _head,
          state: 'APPROVED',
          body: 'Looks good',
        ),
      ]) {
        final state = HighRiskPrState(
          headSha: _head,
          baseSha: _base,
          behind: 0,
          ahead: 6,
          unresolvedThreads: 0,
          authorLogin: 'implementation-author',
          reviews: [review],
        );
        expect(
          _validate(state: state).errors.join('\n'),
          contains('current-head APPROVED review'),
        );
      }
    });

    test('rejects a QA approval superseded by a later review', () {
      final state = HighRiskPrState(
        headSha: _head,
        baseSha: _base,
        behind: 0,
        ahead: 6,
        unresolvedThreads: 0,
        authorLogin: 'implementation-author',
        reviews: const [
          HighRiskReview(
            id: 10,
            authorLogin: 'independent-reviewer',
            commitSha: _head,
            state: 'APPROVED',
            body:
                '''High-risk QA task: $_qaTask
Head: $_head
Base: $_base
Verdict: PASS''',
          ),
          HighRiskReview(
            id: 11,
            authorLogin: 'independent-reviewer',
            commitSha: _head,
            state: 'CHANGES_REQUESTED',
            body: 'A later review found a blocker.',
          ),
        ],
      );

      expect(
        _validate(state: state).errors.join('\n'),
        contains('current-head APPROVED review'),
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
          authorLogin: 'implementation-author',
          reviews: [],
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
          authorLogin: 'implementation-author',
          reviews: [],
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

    test('does not echo untrusted evidence values in diagnostics', () {
      const secretLikeValue = 'https://signed.example/model?secret=do-not-log';
      final evidence = _validEvidence();
      final production =
          evidence['productionEvidence']! as Map<String, dynamic>;
      production['positiveTests'] = [secretLikeValue];
      evidence['affectedFamilies'] = [secretLikeValue];
      evidence['affectedFamilyEvidence'] = {secretLikeValue: 'invalid'};

      final errors = _validate(evidence: evidence).errors.join('\n');

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
      expect(errors, contains('not changed by the same PR'));
      expect(errors, contains('deleted or renamed-away test'));
    });

    test('does not alias whitespace-bearing test paths', () {
      final evidence = _validEvidence();
      final production =
          evidence['productionEvidence']! as Map<String, dynamic>;
      production['positiveTests'] = ['$_parserTest '];

      final errors = _validate(evidence: evidence).errors.join('\n');

      expect(errors, contains('exact spelling'));
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

    test('requires distinct pinned and current upstream roles', () {
      final evidence = _validEvidence()
        ..['upstreamRefs'] = {
          'repository': 'ggml-org/llama.cpp',
          'pinned': 'b10549',
          'current': 'b10549',
        };

      expect(
        _validate(evidence: evidence).errors.join('\n'),
        contains('distinct concrete tags or commits'),
      );
    });

    test('requires exact repository-qualified refs resolved by trust code', () {
      final wrongRepository = _validEvidence();
      (wrongRepository['upstreamRefs']! as Map<String, dynamic>)['repository'] =
          'example/fork';
      expect(
        _validate(evidence: wrongRepository).errors.join('\n'),
        contains('distinct concrete tags or commits'),
      );

      expect(
        _validate(verifiedUpstreamRefs: const {}).errors.join('\n'),
        contains('resolve both upstream refs'),
      );
    });
  });

  group('trusted workflow contract', () {
    test('runs only base policy and treats head files as API data', () {
      final workflow = File(
        '.github/workflows/trusted_high_risk_regression_gate.yml',
      ).readAsStringSync();

      expect(workflow, contains('pull_request_target:'));
      expect(
        workflow,
        contains('actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803'),
      );
      expect(
        workflow,
        contains(
          'dart-lang/setup-dart@65eb853c7ba17dde3be364c3d2858773e7144260',
        ),
      );
      expect(workflow, contains('workflow_run:'));
      expect(workflow, contains('workflows: [CI, High-Risk Review Signal]'));
      expect(workflow, contains('Check out trusted default-branch policy'));
      expect(workflow, contains(r'repository: ${{ github.repository }}'));
      expect(workflow, contains('ref: main'));
      expect(
        workflow,
        isNot(contains(r'ref: ${{ github.event.pull_request.head.sha }}')),
      );
      expect(workflow, contains('pulls/\$PR_NUMBER/files?per_page=100'));
      expect(workflow, contains('.previous_filename'));
      expect(workflow, contains('status == "removed" or .status == "renamed"'));
      expect(workflow, contains('Changed paths cannot contain CR or LF.'));
      expect(workflow, contains('persist-credentials: false'));
      expect(workflow, contains('statuses: write'));
      expect(
        workflow,
        contains('Publish pending status for the event PR head'),
      );
      expect(workflow, contains('-f state=pending'));
      expect(
        workflow,
        contains(r'EVENT_HEAD_SHA: ${{ steps.event.outputs.head_sha }}'),
      );
      expect(workflow, contains(r'[[ "$head_sha" == "$EVENT_HEAD_SHA" ]]'));
      expect(
        workflow,
        contains(r'HEAD_SHA: ${{ steps.event.outputs.head_sha }}'),
      );
      expect(workflow, contains('ready_for_review'));
      expect(workflow, contains('review_requested'));
      expect(workflow, contains('review_request_removed'));
      expect(workflow, contains('auto_merge_enabled'));
      expect(workflow, contains('reviewThreads(first:100)'));
      expect(workflow, contains(r'pulls/$PR_NUMBER/reviews?per_page=100'));
      expect(workflow, contains('sort_by(.id)'));
      expect(workflow, contains('Capture trusted mutable-input snapshot'));
      expect(workflow, contains('Mutable PR evidence changed'));
      expect(
        workflow,
        contains('Resolve declared upstream refs in the owning repository'),
      );
      expect(workflow, contains(r'repos/ggml-org/llama.cpp/commits/$pinned'));
      expect(workflow, contains('Require a successful exact-head CI result'));
      expect(
        workflow,
        contains(r'repos/$REPOSITORY/actions/workflows/ci.yml/runs'),
      );
      expect(workflow, contains(r'.head_sha == $head'));
      expect(workflow, contains(r'statuses/$HEAD_SHA'));
      expect(workflow, contains(r'live_head="$('));
      expect(workflow, contains(r'live_base="$('));
      expect(
        workflow,
        contains(
          r'[[ "$live_head" != "$HEAD_SHA" || "$live_base" != "$BASE_SHA" ]]',
        ),
      );
      expect(
        workflow,
        contains(
          'High-Risk Regression Gate / Trusted exact-head adversarial evidence',
        ),
      );
      expect(workflow, contains('enforce_high_risk_pr_contract.dart'));

      final signal = File(
        '.github/workflows/high_risk_review_signal.yml',
      ).readAsStringSync();
      expect(signal, contains('pull_request_review:'));
      expect(signal, contains('types: [submitted, edited, dismissed]'));
      expect(signal, contains('pull_request_review_comment:'));
      expect(signal, contains('types: [created, edited, deleted]'));
      expect(signal, contains('contents: read'));
      expect(signal, isNot(contains('statuses: write')));
    });

    test('documents bootstrap and repository-settings closure gates', () {
      final agents = File('AGENTS.md').readAsStringSync();
      final matrix = File('doc/testing_matrix.md').readAsStringSync();
      final template = File(
        '.github/pull_request_template.md',
      ).readAsStringSync();

      expect(agents, contains('treats pull-request files as untrusted data'));
      expect(matrix, contains('head status context'));
      expect(matrix, contains('require conversation'));
      expect(matrix, contains('conversation-resolution'));
      expect(matrix, contains('up to date with `main`'));
      expect(matrix, contains('deliberate base advance'));
      expect(matrix, contains('review submission/dismissal'));
      expect(matrix, contains('review-comment'));
      expect(template, contains('Evidence manifest'));
    });
  });
}
