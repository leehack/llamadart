@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../../tool/testing/enforce_high_risk_pr_contract.dart';

const _head = '1111111111111111111111111111111111111111';
const _base = '2222222222222222222222222222222222222222';
const _implementationTask =
    'codex://tasks/root/structured_output_implementation';
const _qaTask = 'codex://tasks/root/structured_output_independent_qa';
const _bodyDigest =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _evidencePath = '.github/high-risk-evidence/394.json';
const _grammarTest =
    'test/integration/core/grammar/generated_tool_schema_grammar_test.dart';
const _parserTest = 'test/unit/core/template/chat_template_engine_test.dart';
const _pinnedCommit = '3333333333333333333333333333333333333333';
const _currentCommit = '4444444444444444444444444444444444444444';
const _prNumber = 420;
const _headRepository = 'implementation/repo';
const _ciPullRequests = [
  HighRiskCiPullRequest(
    number: 420,
    headSha: _head,
    baseSha: _base,
    headRepository: 'implementation/repo',
  ),
];
const _state = HighRiskPrState(
  number: _prNumber,
  headRepository: _headRepository,
  headSha: _head,
  baseSha: _base,
  behind: 0,
  ahead: 6,
  unresolvedThreads: 0,
  authorLogin: 'implementation-author',
  prBodyDigest: _bodyDigest,
  reviews: [
    HighRiskReview(
      id: 1,
      authorLogin: 'independent-reviewer',
      authorAssociation: 'COLLABORATOR',
      commitSha: _head,
      state: 'APPROVED',
      body:
          '''High-risk QA task: $_qaTask
Head: $_head
Base: $_base
PR body SHA-256: $_bodyDigest
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

List<HighRiskCiRun> _successfulCiRuns() => [
  HighRiskCiRun(
    id: 100,
    runAttempt: 1,
    runStartedAt: DateTime.utc(2026, 8, 22, 12),
    headSha: _head,
    event: 'pull_request',
    path: '.github/workflows/ci.yml',
    status: 'completed',
    conclusion: 'success',
    pullRequests: _ciPullRequests,
  ),
];

Map<String, dynamic> _validTrustedParityEvidence() => {
  'schema': 1,
  'headSha': _head,
  'result': 'PASS',
  'source': 'trusted-default-branch',
  'command': './tool/testing/run_template_parity_suites.sh',
  'canonicalUpstreamCommits': {
    'pinned': _pinnedCommit,
    'current': _currentCommit,
  },
};

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
  'knownPrCausedP1Regressions': 0,
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
    'upstreamParityTests': [_parserTest],
    'requiredCoverage': [
      'unknown-field',
      'missing-field',
      'mismatched-type',
      'wrong-type',
      'malformed-output',
      'escaped-name',
      'quoted-name',
      'schema-exact',
      'delimiter',
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

Map<String, dynamic> _validPolicyEvidence() => {
  'schema': 1,
  'issue': 419,
  'knownPrCausedP1Regressions': 0,
  'surfaces': ['regressionPolicy'],
  'implementationTask': _implementationTask,
  'independentQaTask': _qaTask,
  'productionEvidence': {
    'positiveTests': ['test/unit/tooling/trusted_high_risk_contract_test.dart'],
    'negativeTests': ['test/unit/tooling/trusted_high_risk_contract_test.dart'],
    'adversarialTests': [
      'test/unit/tooling/trusted_high_risk_contract_test.dart',
    ],
    'deletionSensitivityTests': [
      'test/unit/tooling/trusted_high_risk_contract_test.dart',
    ],
  },
  'affectedFamilies': <String>[],
  'affectedFamilyEvidence': <String, dynamic>{},
  'upstreamRefs': <dynamic>[],
  'notApplicableReason':
      'Policy-only bootstrap; it does not change a runtime or model family.',
  'structuredOutput': null,
};

HighRiskContractResult _validate({
  String? body,
  Iterable<String> files = _structuredFiles,
  Iterable<String> deletedFiles = const [],
  Map<String, dynamic>? evidence,
  String? evidencePath = _evidencePath,
  HighRiskPrState state = _state,
  Map<String, String>? verifiedUpstreamCommits,
  Set<String> compiledGrammarTests = const {_grammarTest},
  Set<String> protectedEvidencePaths = const {},
  Set<String> baselineEvidencePaths = const {},
  Set<String> structuredOutputParityDependencies = const {
    _parserTest,
    'test/unit/core/template/',
  },
  Set<String>? proposedCompiledGrammarTests,
  Set<String>? proposedStructuredOutputParityDependencies,
  List<HighRiskCiRun>? ciRuns,
  Map<String, dynamic>? trustedUpstreamParityEvidence,
}) => validateHighRiskContract(
  changedFiles: files,
  deletedFiles: deletedFiles,
  body: body ?? _validBody(),
  state: state,
  evidence: evidence ?? _validEvidence(),
  evidencePath: evidencePath,
  verifiedUpstreamCommits:
      verifiedUpstreamCommits ??
      const {'pinned': _pinnedCommit, 'current': _currentCommit},
  compiledGrammarTests: compiledGrammarTests,
  protectedEvidencePaths: protectedEvidencePaths,
  baselineEvidencePaths: baselineEvidencePaths,
  structuredOutputParityDependencies: structuredOutputParityDependencies,
  proposedCompiledGrammarTests: proposedCompiledGrammarTests,
  proposedStructuredOutputParityDependencies:
      proposedStructuredOutputParityDependencies,
  ciRuns: ciRuns ?? _successfulCiRuns(),
  trustedUpstreamParityEvidence:
      trustedUpstreamParityEvidence ?? _validTrustedParityEvidence(),
);

String _replaceField(String body, String label, String replacement) =>
    body.replaceFirst(
      RegExp('^- \\*\\*$label:\\*\\*.*\$', multiLine: true),
      '- **$label:** $replacement',
    );

HighRiskContractResult _validatePolicyEvidence(Map<String, dynamic> evidence) {
  const evidencePath = '.github/high-risk-evidence/419.json';
  final body = _replaceField(_validBody(), 'Evidence manifest', evidencePath);
  return _validate(
    body: body,
    files: const [
      '.github/workflows/ci.yml',
      'test/unit/tooling/trusted_high_risk_contract_test.dart',
      evidencePath,
    ],
    evidence: evidence,
    evidencePath: evidencePath,
  );
}

void main() {
  group('high-risk classifier', () {
    test('covers structured API and streaming surfaces', () {
      final assessment = assessHighRiskFiles(const [
        'lib/llamadart.dart',
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

    test('classifies public exports and the trusted policy registry', () {
      expect(
        assessHighRiskFiles(const ['lib/llamadart.dart']).surfaces,
        contains(HighRiskSurface.structuredOutput),
      );
      expect(
        assessHighRiskFiles(const ['.github/high-risk-policy.json']).surfaces,
        contains(HighRiskSurface.regressionPolicy),
      );
    });

    test('covers backend capabilities and artifact consumers', () {
      final assessment = assessHighRiskFiles(const [
        'lib/src/core/models/download/model_download_manager_base.dart',
        'lib/src/hook/native_bundle_config.dart',
        'example/chat_app/web/index.html',
        'lib/src/platform/io/model_download_manager_io.dart',
        'lib/src/core/models/config/gpu_backend.dart',
        'lib/src/core/cache_policy.dart',
        'test/unit/core/cache_policy_test.dart',
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

    test('protects tests referenced by trusted-base evidence manifests', () {
      const protected = 'test/unit/core/cache_policy_test.dart';
      final assessment = assessHighRiskFiles(
        const [protected],
        protectedEvidencePaths: const {protected},
      );

      expect(
        assessment.surfaces,
        containsAll(const {
          HighRiskSurface.backendRuntime,
          HighRiskSurface.regressionPolicy,
        }),
      );
    });

    test('covers release and regression enforcement surfaces', () {
      final assessment = assessHighRiskFiles(const [
        '.github/high-risk-policy.json',
        '.github/workflows/docs_version_cut.yml',
        '.github/workflows/ci.yml',
        '.github/actions/release/action.yml',
        'tool/testing/verify_release_docs_versions.dart',
        'tool/testing/check_platform_boundaries.dart',
        'tool/testing/native_prompt_reuse_parity.dart',
        'tool/testing/run_local_e2e.dart',
        'tool/testing/run_template_parity_suites.sh',
        'test/integration/core/grammar/grammar_regression_test.dart',
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

    test('classifies every trusted parity dependency as structured policy', () {
      final policy =
          jsonDecode(File('.github/high-risk-policy.json').readAsStringSync())
              as Map<String, dynamic>;
      final dependencies =
          (policy['structuredOutputParityDependencies'] as List)
              .cast<String>()
              .toSet();

      for (final dependency in dependencies) {
        final candidate = dependency.endsWith('/')
            ? Directory(
                dependency,
              ).listSync(recursive: true).whereType<File>().first.path
            : dependency;
        final assessment = assessHighRiskFiles([
          candidate,
        ], structuredOutputParityDependencies: dependencies);

        expect(
          assessment.surfaces,
          containsAll(const {
            HighRiskSurface.structuredOutput,
            HighRiskSurface.regressionPolicy,
          }),
          reason: candidate,
        );
      }
    });

    test('trusted parity dependencies cannot use policy-only evidence', () {
      final policy =
          jsonDecode(File('.github/high-risk-policy.json').readAsStringSync())
              as Map<String, dynamic>;
      final dependencies =
          (policy['structuredOutputParityDependencies'] as List)
              .cast<String>()
              .toSet();
      const policyEvidencePath = '.github/high-risk-evidence/419.json';
      final body = _replaceField(
        _validBody(),
        'Evidence manifest',
        policyEvidencePath,
      );

      for (final dependency in dependencies) {
        final candidate = dependency.endsWith('/')
            ? Directory(
                dependency,
              ).listSync(recursive: true).whereType<File>().first.path
            : dependency;
        final result = _validate(
          body: body,
          files: [
            candidate,
            'test/unit/tooling/trusted_high_risk_contract_test.dart',
            policyEvidencePath,
          ],
          evidence: _validPolicyEvidence(),
          evidencePath: policyEvidencePath,
          structuredOutputParityDependencies: dependencies,
        );

        expect(
          result.errors,
          contains(
            'Structured-output changes require structuredOutput evidence.',
          ),
          reason: candidate,
        );
      }
    });

    test('registered compiled grammar tests require structured evidence', () {
      final policy =
          jsonDecode(File('.github/high-risk-policy.json').readAsStringSync())
              as Map<String, dynamic>;
      final compiledTests = (policy['compiledGrammarTests'] as List)
          .cast<String>()
          .toSet();
      const policyEvidencePath = '.github/high-risk-evidence/419.json';
      final body = _replaceField(
        _validBody(),
        'Evidence manifest',
        policyEvidencePath,
      );

      for (final compiledTest in compiledTests) {
        final assessment = assessHighRiskFiles([
          compiledTest,
        ], compiledGrammarTests: compiledTests);
        expect(
          assessment.surfaces,
          containsAll(const {
            HighRiskSurface.structuredOutput,
            HighRiskSurface.regressionPolicy,
          }),
          reason: compiledTest,
        );

        final result = _validate(
          body: body,
          files: [
            compiledTest,
            'test/unit/tooling/trusted_high_risk_contract_test.dart',
            policyEvidencePath,
          ],
          evidence: _validPolicyEvidence(),
          evidencePath: policyEvidencePath,
          compiledGrammarTests: compiledTests,
        );
        expect(
          result.errors,
          contains(
            'Structured-output changes require structuredOutput evidence.',
          ),
          reason: compiledTest,
        );
      }
    });

    test('does not classify unrelated tests or docs', () {
      final assessment = assessHighRiskFiles(const [
        'test/unit/core/models/model_test.dart',
        'test/unit/core/template/chat_template_engine_test.dart',
        'website/docs/guides/embeddings.md',
      ]);

      expect(assessment.isHighRisk, isFalse);
    });

    test('untouched standard PR template passes standard classification', () {
      final result = validateHighRiskContract(
        changedFiles: const ['website/docs/guides/embeddings.md'],
        body: File('.github/pull_request_template.md').readAsStringSync(),
        state: _state,
      );

      expect(result.assessment.isHighRisk, isFalse);
      expect(result.errors, isEmpty);
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
        number: _prNumber,
        headRepository: _headRepository,
        headSha: _head,
        baseSha: _base,
        behind: 0,
        ahead: 6,
        unresolvedThreads: 0,
        authorLogin: 'implementation-author',
        prBodyDigest: _bodyDigest,
        reviews: [],
      );

      expect(
        _validate(state: noApproval).errors.join('\n'),
        contains('current-head APPROVED review'),
      );
    });

    test('binds independent QA approval to the evaluated PR body digest', () {
      final review = _state.reviews.single;
      final state = HighRiskPrState(
        number: _prNumber,
        headRepository: _headRepository,
        headSha: _state.headSha,
        baseSha: _state.baseSha,
        behind: _state.behind,
        ahead: _state.ahead,
        unresolvedThreads: _state.unresolvedThreads,
        authorLogin: _state.authorLogin,
        prBodyDigest: _bodyDigest,
        reviews: [
          HighRiskReview(
            id: review.id,
            authorLogin: review.authorLogin,
            authorAssociation: review.authorAssociation,
            commitSha: review.commitSha,
            state: review.state,
            body: review.body.replaceFirst(
              _bodyDigest,
              'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
            ),
          ),
        ],
      );

      expect(
        _validate(state: state).errors.join('\n'),
        contains('PR-body digest'),
      );
    });

    test('rejects author, stale-head, and incomplete QA approvals', () {
      for (final review in const [
        HighRiskReview(
          id: 1,
          authorLogin: 'implementation-author',
          authorAssociation: 'OWNER',
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
          authorAssociation: 'COLLABORATOR',
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
          authorAssociation: 'COLLABORATOR',
          commitSha: _head,
          state: 'APPROVED',
          body: 'Looks good',
        ),
        HighRiskReview(
          id: 1,
          authorLogin: 'external-reviewer',
          authorAssociation: 'NONE',
          commitSha: _head,
          state: 'APPROVED',
          body:
              '''High-risk QA task: $_qaTask
Head: $_head
Base: $_base
Verdict: PASS''',
        ),
      ]) {
        final state = HighRiskPrState(
          number: _prNumber,
          headRepository: _headRepository,
          headSha: _head,
          baseSha: _base,
          behind: 0,
          ahead: 6,
          unresolvedThreads: 0,
          authorLogin: 'implementation-author',
          prBodyDigest: _bodyDigest,
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
        number: _prNumber,
        headRepository: _headRepository,
        headSha: _head,
        baseSha: _base,
        behind: 0,
        ahead: 6,
        unresolvedThreads: 0,
        authorLogin: 'implementation-author',
        prBodyDigest: _bodyDigest,
        reviews: const [
          HighRiskReview(
            id: 10,
            authorLogin: 'independent-reviewer',
            authorAssociation: 'COLLABORATOR',
            commitSha: _head,
            state: 'APPROVED',
            body:
                '''High-risk QA task: $_qaTask
Head: $_head
Base: $_base
PR body SHA-256: $_bodyDigest
Verdict: PASS''',
          ),
          HighRiskReview(
            id: 11,
            authorLogin: 'independent-reviewer',
            authorAssociation: 'COLLABORATOR',
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
          number: _prNumber,
          headRepository: _headRepository,
          headSha: _head,
          baseSha: _base,
          behind: 1,
          ahead: 6,
          unresolvedThreads: 0,
          authorLogin: 'implementation-author',
          prBodyDigest: _bodyDigest,
          reviews: [],
        ),
      ).errors.join('\n');

      expect(errors, contains('Exact head SHA'));
      expect(errors, contains('Current base SHA'));
      expect(errors, contains('must integrate the current base'));
    });

    test('ignores hidden gate fields and rejects duplicate visible labels', () {
      for (final hiddenBody in [
        '<!--\n${_validBody()}\n-->',
        '```markdown\n${_validBody()}\n```',
        '~~~\n${_validBody()}\n~~~',
      ]) {
        expect(
          _validate(body: hiddenBody).errors.join('\n'),
          contains('High-risk classification'),
        );
      }

      final hiddenDuplicate =
          '${_validBody()}\n<!--\n- **Exact head SHA:** ffffffffffffffffffffffffffffffffffffffff\n-->';
      expect(_validate(body: hiddenDuplicate).errors, isEmpty);

      final duplicate =
          '${_validBody()}\n- **Exact head SHA:** ffffffffffffffffffffffffffffffffffffffff';
      expect(
        _validate(body: duplicate).errors,
        contains('PR body contains duplicate evidence field: Exact head SHA.'),
      );
    });

    test('requires top-level fields and exact CommonMark fence closure', () {
      final indented = _validBody()
          .split('\n')
          .map((line) => '    $line')
          .join('\n');
      final tabIndented = _validBody()
          .split('\n')
          .map((line) => '\t$line')
          .join('\n');
      for (final hiddenBody in [indented, tabIndented]) {
        expect(
          _validate(body: hiddenBody).errors.join('\n'),
          contains('High-risk classification'),
        );
      }

      for (final marker in ['`', '~']) {
        final opener = List.filled(4, marker).join();
        final shorterClose = List.filled(3, marker).join();
        final exactClose = List.filled(4, marker).join();
        final longerClose = List.filled(5, marker).join();
        final pseudoClosed =
            '$opener\n$shorterClose\n${_validBody()}\n$exactClose';
        expect(
          _validate(body: pseudoClosed).errors.join('\n'),
          contains('High-risk classification'),
          reason: '$marker shorter close must leave the fence open',
        );

        for (final close in [exactClose, longerClose]) {
          final visibleAfterClose =
              '$opener\nhidden gate prose\n$close\n${_validBody()}';
          expect(
            _validate(body: visibleAfterClose).errors,
            isEmpty,
            reason: '$marker fence must accept an equal-or-longer close',
          );
        }
      }
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
          number: _prNumber,
          headRepository: _headRepository,
          headSha: _head,
          baseSha: _base,
          behind: 0,
          ahead: 6,
          unresolvedThreads: 1,
          authorLogin: 'implementation-author',
          prBodyDigest: _bodyDigest,
          reviews: [],
        ),
      );

      expect(
        result.errors,
        contains('High-risk PRs cannot pass with unresolved review threads.'),
      );
    });

    test('a newer rerun revokes an older exact-head CI success', () {
      final runs = [
        ..._successfulCiRuns(),
        HighRiskCiRun(
          id: 100,
          runAttempt: 2,
          runStartedAt: DateTime.utc(2026, 8, 22, 13),
          headSha: _head,
          event: 'pull_request',
          path: '.github/workflows/ci.yml',
          status: 'completed',
          conclusion: 'failure',
          pullRequests: _ciPullRequests,
        ),
      ];

      expect(selectLatestExactHeadCiRun(runs, _state)?.runAttempt, 2);
      expect(
        _validate(ciRuns: runs).errors,
        contains('The latest exact-head CI run must succeed.'),
      );
    });

    test('a later-created run wins even if an older run finishes later', () {
      final runs = [
        HighRiskCiRun(
          id: 99,
          runAttempt: 1,
          runStartedAt: DateTime.utc(2026, 8, 22, 12),
          headSha: _head,
          event: 'pull_request',
          path: '.github/workflows/ci.yml',
          status: 'completed',
          conclusion: 'success',
          pullRequests: _ciPullRequests,
        ),
        HighRiskCiRun(
          id: 101,
          runAttempt: 1,
          runStartedAt: DateTime.utc(2026, 8, 22, 13),
          headSha: _head,
          event: 'pull_request',
          path: '.github/workflows/ci.yml',
          status: 'completed',
          conclusion: 'failure',
          pullRequests: _ciPullRequests,
        ),
      ];

      expect(selectLatestExactHeadCiRun(runs, _state)?.id, 101);
      expect(
        _validate(ciRuns: runs).errors,
        contains('The latest exact-head CI run must succeed.'),
      );
    });

    test('a rerun start outranks a run created later but started earlier', () {
      final runs = [
        HighRiskCiRun(
          id: 99,
          runAttempt: 2,
          runStartedAt: DateTime.utc(2026, 8, 22, 14),
          headSha: _head,
          event: 'pull_request',
          path: '.github/workflows/ci.yml',
          status: 'completed',
          conclusion: 'failure',
          pullRequests: _ciPullRequests,
        ),
        HighRiskCiRun(
          id: 101,
          runAttempt: 1,
          runStartedAt: DateTime.utc(2026, 8, 22, 13),
          headSha: _head,
          event: 'pull_request',
          path: '.github/workflows/ci.yml',
          status: 'completed',
          conclusion: 'success',
          pullRequests: _ciPullRequests,
        ),
      ];

      expect(selectLatestExactHeadCiRun(runs, _state)?.id, 99);
      expect(
        _validate(ciRuns: runs).errors,
        contains('The latest exact-head CI run must succeed.'),
      );
    });

    test('ignores same-SHA CI runs associated with another PR', () {
      final foreignPullRequests = [
        const HighRiskCiPullRequest(
          number: 421,
          headSha: _head,
          baseSha: _base,
          headRepository: 'implementation/repo',
        ),
      ];
      final runs = [
        HighRiskCiRun(
          id: 100,
          runAttempt: 1,
          runStartedAt: DateTime.utc(2026, 8, 22, 12),
          headSha: _head,
          event: 'pull_request',
          path: '.github/workflows/ci.yml',
          status: 'completed',
          conclusion: 'failure',
          pullRequests: _ciPullRequests,
        ),
        HighRiskCiRun(
          id: 101,
          runAttempt: 1,
          runStartedAt: DateTime.utc(2026, 8, 22, 13),
          headSha: _head,
          event: 'pull_request',
          path: '.github/workflows/ci.yml',
          status: 'completed',
          conclusion: 'success',
          pullRequests: foreignPullRequests,
        ),
      ];

      expect(selectLatestExactHeadCiRun(runs, _state)?.id, 100);
      expect(
        _validate(ciRuns: runs).errors,
        contains('The latest exact-head CI run must succeed.'),
      );
    });

    test('blocks deletion or rename of prior trusted evidence tests', () {
      for (final scenario in const [
        (
          path: 'test/unit/core/cache_policy_test.dart',
          protected: {'test/unit/core/cache_policy_test.dart'},
        ),
        (
          path: 'test/unit/core/template/new_handler_test.dart',
          protected: {'test/unit/core/template/'},
        ),
      ]) {
        final result = _validate(
          files: [scenario.path],
          deletedFiles: [scenario.path],
          protectedEvidencePaths: scenario.protected,
        );

        expect(result.assessment.isHighRisk, isTrue);
        expect(
          result.errors,
          contains(
            'Trusted policy or evidence paths cannot be deleted or renamed.',
          ),
        );
      }
    });

    test('trusted policy edits may add but cannot remove registry entries', () {
      const policyPath = '.github/high-risk-policy.json';
      const policyEvidencePath = '.github/high-risk-evidence/419.json';
      const trustedDependencies = {
        'tool/testing/run_template_parity_suites.sh',
        'test/unit/core/template/',
      };
      final body = _replaceField(
        _validBody(),
        'Evidence manifest',
        policyEvidencePath,
      );
      HighRiskContractResult validatePolicy({
        required Set<String> proposedGrammar,
        required Set<String> proposedDependencies,
      }) => _validate(
        body: body,
        files: const [
          policyPath,
          'test/unit/tooling/trusted_high_risk_contract_test.dart',
          policyEvidencePath,
        ],
        evidence: _validPolicyEvidence(),
        evidencePath: policyEvidencePath,
        structuredOutputParityDependencies: trustedDependencies,
        proposedCompiledGrammarTests: proposedGrammar,
        proposedStructuredOutputParityDependencies: proposedDependencies,
      );

      final additive = validatePolicy(
        proposedGrammar: const {_grammarTest, 'test/new_grammar_test.dart'},
        proposedDependencies: const {
          ...trustedDependencies,
          'test/new_parity_test.dart',
        },
      );
      expect(
        additive.errors,
        isNot(
          contains(
            'High-risk policy edits must preserve every trusted '
            'compiled-grammar test and structured-output parity dependency.',
          ),
        ),
      );

      for (final weakened in [
        (grammar: <String>{}, dependencies: trustedDependencies),
        (
          grammar: const {_grammarTest},
          dependencies: const {'tool/testing/run_template_parity_suites.sh'},
        ),
      ]) {
        expect(
          validatePolicy(
            proposedGrammar: weakened.grammar,
            proposedDependencies: weakened.dependencies,
          ).errors,
          contains(
            'High-risk policy edits must preserve every trusted '
            'compiled-grammar test and structured-output parity dependency.',
          ),
        );
      }
    });

    test('base control files cannot be deleted or renamed away', () {
      const controls = {
        '.github/high-risk-policy.json',
        '.github/workflows/ci.yml',
        '.github/workflows/high_risk_review_signal.yml',
        '.github/workflows/trusted_high_risk_regression_gate.yml',
        'tool/testing/enforce_high_risk_pr_contract.dart',
      };
      for (final control in controls) {
        final result = _validate(
          files: [control],
          deletedFiles: [control],
          protectedEvidencePaths: controls,
          proposedCompiledGrammarTests:
              control == '.github/high-risk-policy.json'
              ? const {_grammarTest}
              : null,
          proposedStructuredOutputParityDependencies:
              control == '.github/high-risk-policy.json' ? const {} : null,
        );

        expect(
          result.errors,
          contains(
            'Trusted policy or evidence paths cannot be deleted or renamed.',
          ),
          reason: control,
        );
      }
    });

    test('requires one changed machine-readable manifest', () {
      final result = _validate(
        files: _structuredFiles.where((path) => path != _evidencePath),
        evidencePath: null,
      );

      expect(result.errors.join('\n'), contains('exactly one changed'));
      expect(result.errors.join('\n'), contains('Trusted workflow'));
    });

    test('preserves every trusted-base manifest evidence path', () {
      expect(
        _validate(baselineEvidencePaths: const {_parserTest}).errors,
        isEmpty,
      );
      expect(
        _validate(
          baselineEvidencePaths: const {
            'test/unit/core/template/removed_durable_test.dart',
          },
        ).errors,
        contains(
          'A proposed evidence manifest must preserve every durable test path referenced by its trusted-base version.',
        ),
      );
    });

    test('binds the manifest issue to its numeric filename', () {
      final evidence = _validEvidence()..['issue'] = 410;

      expect(
        _validate(evidence: evidence).errors,
        contains('Manifest issue must match its numeric evidence filename.'),
      );
    });

    test('binds the zero-regression claim to exact-head evidence', () {
      final evidence = _validEvidence()..['knownPrCausedP1Regressions'] = 1;

      expect(
        _validate(evidence: evidence).errors,
        contains('Manifest must report zero known PR-caused P1 regressions.'),
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

    test('accepts an exactly empty family-evidence object for N/A scope', () {
      expect(_validatePolicyEvidence(_validPolicyEvidence()).errors, isEmpty);
    });

    test('accepts exact family N/A for structured policy-test changes', () {
      final evidence = _validEvidence()
        ..['affectedFamilies'] = <String>[]
        ..['affectedFamilyEvidence'] = <String, dynamic>{}
        ..['notApplicableReason'] =
            'Policy-test coverage changes do not affect a runtime model family.';

      expect(
        _validate(
          evidence: evidence,
          files: const [_grammarTest, _parserTest, _evidencePath],
        ).errors,
        isEmpty,
      );
    });

    test('rejects malformed or stale family evidence for N/A scope', () {
      for (final invalid in <Object?>[
        const <String>[],
        const {'stale-family': 'real-model'},
      ]) {
        final evidence = _validPolicyEvidence()
          ..['affectedFamilyEvidence'] = invalid;
        expect(
          _validatePolicyEvidence(evidence).errors,
          contains(
            'Empty affectedFamilies requires affectedFamilyEvidence to be an exactly empty object.',
          ),
        );
      }
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

    test('compiled grammar eligibility comes from the trusted registry', () {
      final evidence = _validEvidence();
      final structured = evidence['structuredOutput']! as Map<String, dynamic>;
      structured['compiledAcceptanceTests'] = [_parserTest];
      structured['compiledRejectionTests'] = [_parserTest];

      expect(
        _validate(
          evidence: evidence,
          compiledGrammarTests: const {_parserTest},
        ).errors,
        isEmpty,
      );
    });

    final requiredCoverage = <String, String>{
      '#394/#399 envelope and quoted-name acceptance': 'unknown-field',
      '#394 escaped-name acceptance': 'escaped-name',
      '#399 quoted-name acceptance': 'quoted-name',
      '#395/#396/#407 schema rejection and delimiters': 'mismatched-type',
      '#395 schema-exact rejection': 'schema-exact',
      '#396 delimiter rejection': 'delimiter',
      '#407 wrong-type rejection': 'wrong-type',
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

    test('rejects different ref spellings resolving to the same commit', () {
      expect(
        _validate(
          verifiedUpstreamCommits: const {
            'pinned': _pinnedCommit,
            'current': _pinnedCommit,
          },
        ).errors,
        contains(
          'Pinned and current upstream refs must resolve to distinct canonical commits.',
        ),
      );
    });

    test('binds upstream parity to changed tests and trusted-base proof', () {
      final forgedArtifact = _validTrustedParityEvidence()
        ..['source'] = 'pull-request-ci';
      expect(
        _validate(trustedUpstreamParityEvidence: forgedArtifact).errors,
        contains(
          'Trusted-base upstream parity evidence must exactly bind the head, canonical refs, command, and PASS result.',
        ),
      );

      final evidence = _validEvidence();
      final structured = evidence['structuredOutput']! as Map<String, dynamic>;
      structured['upstreamParityTests'] = ['test/unit/not_changed_test.dart'];
      expect(
        _validate(evidence: evidence).errors.join('\n'),
        contains('not changed by the same PR'),
      );

      final unrelated = _validEvidence();
      final unrelatedStructured =
          unrelated['structuredOutput']! as Map<String, dynamic>;
      unrelatedStructured['upstreamParityTests'] = [_grammarTest];
      expect(
        _validate(evidence: unrelated).errors,
        contains(
          'structuredOutput.upstreamParityTests must reference trusted structured-output parity dependencies.',
        ),
      );

      final prefixChild = _validEvidence();
      final prefixStructured =
          prefixChild['structuredOutput']! as Map<String, dynamic>;
      prefixStructured['upstreamParityTests'] = [
        'test/unit/core/template/chat_template_engine_test.dart',
      ];
      expect(
        _validate(
          evidence: prefixChild,
          files: [
            ..._structuredFiles,
            'test/unit/core/template/chat_template_engine_test.dart',
          ],
        ).errors,
        isEmpty,
      );
    });

    test('requires exact repository-qualified refs resolved by trust code', () {
      final wrongRepository = _validEvidence();
      (wrongRepository['upstreamRefs']! as Map<String, dynamic>)['repository'] =
          'example/fork';
      expect(
        _validate(evidence: wrongRepository).errors.join('\n'),
        contains('upstreamRefs.repository must be ggml-org/llama.cpp'),
      );

      expect(
        _validate(verifiedUpstreamCommits: const {}).errors.join('\n'),
        contains('canonical upstream commits'),
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
      expect(workflow, contains('types: [in_progress, completed]'));
      expect(workflow, contains('Check out trusted default-branch policy'));
      expect(workflow, contains(r'repository: ${{ github.repository }}'));
      expect(workflow, contains('ref: main'));
      expect(
        workflow,
        isNot(contains(r'ref: ${{ github.event.pull_request.head.sha }}')),
      );
      expect(workflow, contains('pulls/\$PR_NUMBER/files?per_page=100'));
      expect(workflow, contains('.previous_filename'));
      expect(workflow, contains('.status == "removed"'));
      expect(workflow, contains('.status == "deleted"'));
      expect(workflow, contains('.status == "renamed"'));
      expect(workflow, contains('Changed paths cannot contain CR or LF.'));
      expect(workflow, contains('persist-credentials: false'));
      expect(workflow, contains('statuses: write'));
      expect(workflow, contains('actions: read'));
      expect(
        workflow,
        contains("github.event.workflow_run.event == 'pull_request'"),
      );
      expect(
        workflow,
        isNot(contains("github.event.workflow_run.event != 'push'")),
      );
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
      expect(workflow, contains('author_association'));
      expect(workflow, contains('sort_by(.id)'));
      expect(workflow, contains('Capture trusted mutable-input snapshot'));
      expect(
        workflow,
        contains('Fail closed when trusted setup cannot capture a snapshot'),
      );
      expect(
        workflow,
        contains('Trusted high-risk setup failed before evaluation'),
      );
      expect(workflow, contains("steps.snapshot.outputs.digest == ''"));
      expect(workflow, contains('-f state=failure'));
      expect(workflow, contains('max_by(.id).target_url // ""'));
      expect(workflow, contains('BASH_REMATCH[1] > GITHUB_RUN_ID'));
      expect(workflow, contains('Mutable PR evidence changed'));
      expect(
        workflow,
        contains('Resolve declared upstream refs in the owning repository'),
      );
      expect(
        workflow,
        contains('Canonical upstream refs changed during trusted evaluation.'),
      );
      expect(
        workflow,
        contains('Canonical upstream refs changed before status publication.'),
      );
      expect(workflow, contains(r'jq -cS . "$UPSTREAM_FILE"'));
      expect(workflow, contains(r'repos/ggml-org/llama.cpp/commits/$pinned'));
      expect(
        workflow,
        contains(
          'Require latest exact-head CI and collect advisory parity artifact',
        ),
      );
      expect(
        workflow,
        contains(r'repos/$REPOSITORY/actions/workflows/ci.yml/runs'),
      );
      final ciWorkflow = File('.github/workflows/ci.yml').readAsStringSync();
      expect(ciWorkflow, contains('High-Risk Upstream Parity Evidence'));
      expect(ciWorkflow, contains('.structuredOutput.upstreamParityTests |'));
      expect(ciWorkflow, contains('high-risk-upstream-parity-'));
      expect(ciWorkflow, contains(r'${{ github.run_attempt }}'));
      expect(ciWorkflow, contains('Resolve immutable upstream parity commits'));
      expect(
        ciWorkflow.indexOf('Resolve immutable upstream parity commits'),
        lessThan(ciWorkflow.indexOf('Run pinned and current upstream parity')),
      );
      expect(
        ciWorkflow,
        contains(r'[[ "$(git -C "$source_dir" rev-parse HEAD)" == "$ref" ]]'),
      );
      expect(
        workflow,
        contains(r'high-risk-upstream-parity-$HEAD_SHA-$run_attempt'),
      );
      expect(
        workflow,
        contains('Advisory exact-head parity artifact is unavailable.'),
      );
      expect(
        workflow,
        contains('Independently reproduce parity with trusted-base code'),
      );
      expect(
        workflow,
        contains(r'--trusted-upstream-parity-evidence "$TRUSTED_PARITY_FILE"'),
      );
      for (final control in const [
        '.github/high-risk-policy.json',
        '.github/workflows/ci.yml',
        '.github/workflows/high_risk_review_signal.yml',
        '.github/workflows/trusted_high_risk_regression_gate.yml',
        'tool/testing/enforce_high_risk_pr_contract.dart',
      ]) {
        expect(workflow, contains("'$control'"), reason: control);
      }
      expect(workflow, contains(r'.head_sha == $head'));
      expect(
        RegExp(r'any\(\.pull_requests\[\]\?;').allMatches(workflow),
        hasLength(4),
      );
      expect(workflow, contains(r'.number == $pr'));
      expect(workflow, contains(r'.base.sha == $base'));
      expect(workflow, contains(r'.head.repo.url =='));
      expect(
        workflow,
        contains(r'--baseline-evidence-paths "$BASELINE_EVIDENCE_PATHS"'),
      );
      expect(
        workflow,
        contains('sort_by(.run_started_at, .id, .run_attempt) | last // empty'),
      );
      expect(workflow, contains('The latest exact-head CI run must succeed'));
      expect(workflow, contains(r'[[ "$run_status" != "completed" ]]'));
      expect(workflow, contains(r'statuses/$HEAD_SHA'));
      expect(
        workflow,
        contains(
          'Mutable PR or CI evidence changed before status publication.',
        ),
      );
      final finalDigestMismatch = workflow.indexOf(
        r'if [[ "$final_digest" != "$SNAPSHOT_DIGEST" ]]',
      );
      final finalStatusPost = workflow.lastIndexOf(
        r'gh api --method POST "repos/$REPOSITORY/statuses/$HEAD_SHA"',
      );
      expect(finalDigestMismatch, greaterThanOrEqualTo(0));
      expect(finalStatusPost, greaterThan(finalDigestMismatch));
      expect(
        workflow.substring(finalDigestMismatch, finalStatusPost),
        contains('state=failure'),
      );
      expect(
        workflow,
        contains("description='Mutable PR or CI evidence changed'"),
      );
      expect(workflow, contains(r'final_base_ref="$('));
      expect(workflow, contains(r'[[ "$final_base_ref" != "main" ]]'));
      expect(
        workflow,
        contains('Canceled or completed evaluations cannot publish status.'),
      );
      expect(
        workflow,
        contains('A newer trusted evaluation owns the exact-head status.'),
      );
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
      expect(signal, contains('high-risk-review-signal-pr-'));
      expect(signal, contains('pull_request_review:'));
      expect(signal, contains('types: [submitted, edited, dismissed]'));
      expect(signal, contains('pull_request_review_comment:'));
      expect(signal, contains('types: [created, edited, deleted]'));
      expect(signal, contains('contents: read'));
      expect(signal, isNot(contains('statuses: write')));
      expect(workflow, contains('EVENT_SIGNAL_TITLE'));
      expect(workflow, contains('High-Risk Review Signal'));
      expect(workflow, contains('event-live-pull-request.json'));
      expect(workflow, contains("jq -r '.base.ref'"));

      expect(ciWorkflow, contains(r'parity_tests="$RUNNER_TEMP/'));
      expect(ciWorkflow, contains(r'done < "$parity_tests"'));
      expect(ciWorkflow, isNot(contains('done < <(\n              jq -r')));

      final generatedGrammarTest = File(
        'test/integration/core/grammar/generated_tool_schema_grammar_test.dart',
      ).readAsStringSync();
      expect(generatedGrammarTest, contains('tools: [tool]'));
      expect(generatedGrammarTest, contains('toolChoice: ToolChoice.required'));
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
      expect(template, contains('**High-risk classification:** standard'));
      final policy = File('.github/high-risk-policy.json').readAsStringSync();
      expect(policy, contains('compiledGrammarTests'));
      final decodedPolicy = jsonDecode(policy) as Map<String, dynamic>;
      for (final path in decodedPolicy['compiledGrammarTests'] as List) {
        expect(File(path as String).existsSync(), isTrue, reason: path);
      }
      const parityDependencies = {
        'tool/testing/run_template_parity_suites.sh',
        'tool/testing/run_llama_cpp_chat_tests.sh',
        'tool/testing/prepare_llama_cpp_source.sh',
        'tool/testing/llama_cpp_templates.ref',
        'test/e2e/template/llama_cpp_chat_tests_e2e_test.dart',
        'test/integration/core/template/llama_cpp_template_detection_integration_test.dart',
        'test/integration/core/template/llama_cpp_template_parse_samples.dart',
        'test/integration/core/template/template_diagnostic_integration_test.dart',
        'test/fixtures/templates/',
        'test/unit/core/template/',
      };
      expect(
        (decodedPolicy['structuredOutputParityDependencies'] as List).toSet(),
        equals(parityDependencies),
      );
      for (final path in parityDependencies) {
        final exists = path.endsWith('/')
            ? Directory(path).existsSync()
            : File(path).existsSync();
        expect(exists, isTrue, reason: path);
      }

      final compiledTest = File(_grammarTest).readAsStringSync();
      expect(compiledTest, contains('ToolGrammarGenerator.generate'));
      expect(compiledTest, contains('_generateThroughProductionTools'));
      expect(compiledTest, contains('jsonDecode(call.function?.arguments'));
      expect(compiledTest, contains('undefined-generated-rule'));
      expect(compiledTest, contains('LlamaInferenceException'));
    });
  });
}
