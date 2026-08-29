@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../../tool/testing/classify_high_risk_changes.dart';
import '../../../tool/testing/high_risk_readiness.dart';

const baseSha = '1111111111111111111111111111111111111111';
const headSha = '2222222222222222222222222222222222222222';
const otherSha = '3333333333333333333333333333333333333333';
const compiledTest =
    'test/integration/core/grammar/generated_tool_schema_grammar_test.dart';
const backendTest = 'test/unit/backends/example_backend_test.dart';
const context = PullRequestContext(
  repository: 'leehack/llamadart',
  prNumber: 419,
  headSha: headSha,
  baseSha: baseSha,
  author: 'contributor-dev',
);

class FakeRepositoryState implements RepositoryStateReader {
  FakeRepositoryState({
    required this.changes,
    Set<String>? existingPaths,
    this.commitsExist = true,
    this.baseIsAncestor = true,
    this.pathProbeThrows = false,
  }) : existingPaths =
           existingPaths ??
           changes
               .where((change) => change.kind != RepositoryChangeKind.deleted)
               .map((change) => change.path)
               .toSet();

  final List<RepositoryChange> changes;
  final Set<String> existingPaths;
  final bool commitsExist;
  final bool baseIsAncestor;
  final bool pathProbeThrows;
  var repositoryCallCount = 0;

  @override
  Future<bool> commitExists(String sha, {String? workingDirectory}) async {
    repositoryCallCount++;
    return commitsExist;
  }

  @override
  Future<bool> isAncestor(
    String ancestor,
    String descendant, {
    String? workingDirectory,
  }) async {
    repositoryCallCount++;
    return baseIsAncestor;
  }

  @override
  Future<List<RepositoryChange>> changedFiles(
    String baseSha,
    String headSha, {
    String? workingDirectory,
  }) async {
    repositoryCallCount++;
    return changes;
  }

  @override
  Future<bool> pathIsRegularFileAt(
    String headSha,
    String path, {
    String? workingDirectory,
  }) async {
    repositoryCallCount++;
    if (pathProbeThrows) {
      throw StateError('candidate-tree probe failed');
    }
    return existingPaths.contains(path);
  }
}

Map<String, dynamic> structuredEvidence() => <String, dynamic>{
  'schema': 'llamadart.high-risk-readiness-evidence',
  'schema_version': '1.0.0',
  'timestamp': '2026-08-28T12:00:00.000Z',
  'correlation_id': 'issue-419-audit-1',
  'repository': context.repository,
  'pr_number': context.prNumber,
  'expected_pr_head_sha': context.headSha,
  'current_base_sha': context.baseSha,
  'pr_author': context.author,
  'classification': 'high-risk',
  'surfaces': ['structuredOutput'],
  'required_matrix_row_ids': [
    'high-risk-exact-head-independent-qa',
    'structured-output-adversarial',
  ],
  'matrix_row_evidence': {
    'high-risk-exact-head-independent-qa': {
      'row_id': 'high-risk-exact-head-independent-qa',
      'result': 'pass',
      'command': 'fresh Codex audit of exact head and base',
      'evidence_notes': 'Production call sites and deletion-sensitive tests.',
    },
    'structured-output-adversarial': {
      'row_id': 'structured-output-adversarial',
      'result': 'pass',
      'command': './tool/testing/run_template_parity_suites.sh',
      'evidence_notes': 'Compiled acceptance and rejection completed.',
    },
  },
  'independent_audit': {
    'auditor_identity': 'codex-audit-419',
    'audit_kind': 'codex-adversarial',
    'audit_head_sha': context.headSha,
    'audit_base_sha': context.baseSha,
    'decision': 'accepted',
    'unresolved_review_threads': 0,
    'known_pr_caused_p1_regressions': 0,
    'summary': 'Independent audit completed against production call sites.',
  },
  'structured_output_evidence': {
    'coverage': {
      'compiled_grammar_acceptance': [compiledTest],
      'compiled_grammar_rejection': [compiledTest],
      'schema_reconstruction': [compiledTest],
      'streaming_rollback': [compiledTest],
      'tool_choice_thinking': [compiledTest],
      'upstream_parity': [compiledTest],
    },
    'families': [
      {
        'family': 'qwen3',
        'status': 'tested',
        'evidence_test_paths': [compiledTest],
        'rationale': 'Affected-family production fixture was exercised.',
      },
    ],
  },
  'affected_test_paths': [compiledTest],
  'evaluation': null,
};

Map<String, dynamic> backendEvidence() {
  final evidence = structuredEvidence();
  evidence['surfaces'] = ['backendRuntime'];
  evidence['required_matrix_row_ids'] = ['high-risk-exact-head-independent-qa'];
  evidence['matrix_row_evidence'] = {
    'high-risk-exact-head-independent-qa':
        (evidence['matrix_row_evidence']
            as Map<String, dynamic>)['high-risk-exact-head-independent-qa'],
  };
  evidence['structured_output_evidence'] = null;
  evidence['affected_test_paths'] = [backendTest];
  return evidence;
}

Map<String, dynamic> standardEvidence() {
  final evidence = backendEvidence();
  evidence['classification'] = 'standard';
  evidence['surfaces'] = <String>[];
  evidence['required_matrix_row_ids'] = <String>[];
  evidence['matrix_row_evidence'] = <String, dynamic>{};
  evidence['independent_audit'] = null;
  evidence['affected_test_paths'] = <String>[];
  return evidence;
}

HighRiskReadinessEvaluator evaluatorFor(
  List<RepositoryChange> changes, {
  Set<String>? existingPaths,
  bool commitsExist = true,
  bool baseIsAncestor = true,
  bool pathProbeThrows = false,
}) => HighRiskReadinessEvaluator(
  repositoryState: FakeRepositoryState(
    changes: changes,
    existingPaths: existingPaths,
    commitsExist: commitsExist,
    baseIsAncestor: baseIsAncestor,
    pathProbeThrows: pathProbeThrows,
  ),
  clock: () => DateTime.utc(2026, 8, 28, 13),
);

const structuredChanges = <RepositoryChange>[
  RepositoryChange(
    path: 'lib/src/core/template/chat_template_handler.dart',
    kind: RepositoryChangeKind.modified,
  ),
  RepositoryChange(path: compiledTest, kind: RepositoryChangeKind.modified),
];

const backendChanges = <RepositoryChange>[
  RepositoryChange(
    path: 'lib/src/backends/example_backend.dart',
    kind: RepositoryChangeKind.modified,
  ),
  RepositoryChange(path: backendTest, kind: RepositoryChangeKind.added),
];

Future<HighRiskReadinessResult> evaluateStructured(
  Map<String, dynamic> evidence, {
  List<RepositoryChange> changes = structuredChanges,
  Set<String>? existingPaths,
}) => evaluatorFor(
  changes,
  existingPaths: existingPaths,
).evaluate(evidence: evidence, context: context);

void expectFailure(
  HighRiskReadinessResult result,
  ReadinessFailureClassification failure,
) {
  expect(result.decision, ReadinessDecision.rejected);
  expect(result.failureClassification, failure);
  expect(result.isReady, isFalse);
}

void expectEmittedIdentity(
  HighRiskReadinessResult result, {
  required String repository,
  required int prNumber,
  required String headSha,
  required String baseSha,
  required String author,
}) {
  for (final output in <Map<String, Object?>>[
    result.evidence,
    result.toJson(),
  ]) {
    expect(output['repository'], repository);
    expect(output['pr_number'], prNumber);
    expect(output['expected_pr_head_sha'], headSha);
    expect(output['current_base_sha'], baseSha);
    expect(output['pr_author'], author);
  }
  expect(() => jsonEncode(result.toJson()), returnsNormally);
}

void expectContextBoundIdentity(HighRiskReadinessResult result) =>
    expectEmittedIdentity(
      result,
      repository: context.repository,
      prNumber: context.prNumber,
      headSha: context.headSha,
      baseSha: context.baseSha,
      author: context.author,
    );

void mutateIdentityToOtherValidValues(Map<String, dynamic> evidence) {
  evidence['repository'] = 'attacker/fork';
  evidence['pr_number'] = 420;
  evidence['expected_pr_head_sha'] = otherSha;
  evidence['current_base_sha'] = otherSha;
  evidence['pr_author'] = 'other-author';
}

void main() {
  group('strict JSON and schema shape', () {
    test('rejects duplicate root, nested, and escaped-equivalent keys', () {
      expect(
        () => decodeStrictJsonObject('{"a":1,"a":2}'),
        throwsFormatException,
      );
      expect(
        () => decodeStrictJsonObject('{"x":{"a":1,"a":2}}'),
        throwsFormatException,
      );
      expect(
        () => decodeStrictJsonObject('{"a":1,"\\u0061":2}'),
        throwsFormatException,
      );
    });

    test('accepts duplicate names in different JSON objects', () {
      expect(decodeStrictJsonObject('{"x":{"a":1},"y":{"a":2}}'), hasLength(2));
    });

    for (final mutation in <String, void Function(Map<String, dynamic>)>{
      'unknown root key': (value) => value['decision'] = 'ready',
      'wrong integer type': (value) => value['pr_number'] = '419',
      'wrong list member type': (value) => value['surfaces'] = [1],
      'wrong map type': (value) => value['matrix_row_evidence'] = <dynamic>[],
      'invalid classification enum': (value) =>
          value['classification'] = 'ready',
      'unknown surface enum': (value) => value['surfaces'] = ['parser'],
      'invalid timestamp': (value) =>
          value['timestamp'] = '2026-08-28T12:00:00-04:00',
      'invalid calendar timestamp': (value) =>
          value['timestamp'] = '2026-02-31T12:00:00Z',
      'invalid correlation identity': (value) =>
          value['correlation_id'] = '../escape',
      'uppercase SHA': (value) => value['expected_pr_head_sha'] =
          'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      'zero SHA': (value) => value['current_base_sha'] =
          '0000000000000000000000000000000000000000',
      'invalid GitHub author': (value) => value['pr_author'] = 'bad--author',
      'caller-declared evaluation': (value) =>
          value['evaluation'] = {'decision': 'ready'},
      'unknown nested audit key': (value) =>
          (value['independent_audit'] as Map<String, dynamic>)['trusted'] =
              true,
      'invalid audit kind enum': (value) =>
          (value['independent_audit'] as Map<String, dynamic>)['audit_kind'] =
              'qa',
      'negative audit count': (value) =>
          (value['independent_audit']
                  as Map<String, dynamic>)['unresolved_review_threads'] =
              -1,
      'invalid matrix result enum': (value) =>
          ((value['matrix_row_evidence']
                      as Map<String, dynamic>)['structured-output-adversarial']
                  as Map<String, dynamic>)['result'] =
              'passed',
      'invalid family status enum': (value) =>
          (((value['structured_output_evidence']
                              as Map<String, dynamic>)['families']
                          as List<dynamic>)
                      .single
                  as Map<String, dynamic>)['status'] =
              'skipped',
      'legacy boolean structured claim': (value) =>
          (value['structured_output_evidence']
                  as Map<String, dynamic>)['schema_exactness_covered'] =
              true,
      'duplicate declared row': (value) =>
          (value['required_matrix_row_ids'] as List<dynamic>).add(
            'structured-output-adversarial',
          ),
    }.entries) {
      test('rejects ${mutation.key}', () async {
        final evidence = structuredEvidence();
        mutation.value(evidence);
        expectFailure(
          await evaluateStructured(evidence),
          ReadinessFailureClassification.schemaViolation,
        );
      });
    }

    test(
      'malformed evidence still produces schema-safe rejection JSON',
      () async {
        final evidence = structuredEvidence()..['surfaces'] = [1];
        final result = await evaluateStructured(evidence);

        expectFailure(result, ReadinessFailureClassification.schemaViolation);
        final output = result.toJson();
        expect(() => jsonEncode(output), returnsNormally);
        expect(output['surfaces'], isEmpty);
        expect(
          (output['evaluation'] as Map<String, dynamic>)['decision'],
          ReadinessDecision.rejected.name,
        );
      },
    );

    test(
      'rejects row object type confusion and conflicting row identity',
      () async {
        final wrongType = structuredEvidence();
        final wrongRows = Map<String, dynamic>.from(
          wrongType['matrix_row_evidence'] as Map,
        );
        wrongRows['structured-output-adversarial'] = 'pass';
        wrongType['matrix_row_evidence'] = wrongRows;
        expectFailure(
          await evaluateStructured(wrongType),
          ReadinessFailureClassification.schemaViolation,
        );

        final conflict = structuredEvidence();
        ((conflict['matrix_row_evidence']
                    as Map<String, dynamic>)['structured-output-adversarial']
                as Map<String, dynamic>)['row_id'] =
            'high-risk-exact-head-independent-qa';
        expectFailure(
          await evaluateStructured(conflict),
          ReadinessFailureClassification.matrixRowFailed,
        );
      },
    );
  });

  group('exact PR and repository binding', () {
    for (final testCase
        in <
          (
            String,
            void Function(Map<String, dynamic>),
            ReadinessFailureClassification,
          )
        >[
          (
            'repository',
            (value) => value['repository'] = 'attacker/fork',
            ReadinessFailureClassification.repositoryMismatch,
          ),
          (
            'PR number',
            (value) => value['pr_number'] = 420,
            ReadinessFailureClassification.prMismatch,
          ),
          (
            'head',
            (value) => value['expected_pr_head_sha'] = otherSha,
            ReadinessFailureClassification.headMismatch,
          ),
          (
            'base',
            (value) => value['current_base_sha'] = otherSha,
            ReadinessFailureClassification.baseMismatch,
          ),
          (
            'author',
            (value) => value['pr_author'] = 'other-author',
            ReadinessFailureClassification.authorMismatch,
          ),
        ]) {
      test('rejects mismatched ${testCase.$1}', () async {
        final evidence = structuredEvidence();
        testCase.$2(evidence);
        final result = await evaluateStructured(evidence);
        expectFailure(result, testCase.$3);
        expectContextBoundIdentity(result);
      });
    }

    test(
      'emitted identity stays bound to the context for every identity field',
      () async {
        final mismatch = structuredEvidence();
        mutateIdentityToOtherValidValues(mismatch);
        final mismatchResult = await evaluateStructured(mismatch);
        expectFailure(
          mismatchResult,
          ReadinessFailureClassification.repositoryMismatch,
        );
        expectContextBoundIdentity(mismatchResult);

        final schemaViolation = structuredEvidence();
        mutateIdentityToOtherValidValues(schemaViolation);
        schemaViolation['surfaces'] = [1];
        final schemaResult = await evaluateStructured(schemaViolation);
        expectFailure(
          schemaResult,
          ReadinessFailureClassification.schemaViolation,
        );
        expectContextBoundIdentity(schemaResult);
      },
    );

    test('fails closed when commits or ancestry cannot be proven', () async {
      expectFailure(
        await evaluatorFor(
          structuredChanges,
          commitsExist: false,
        ).evaluate(evidence: structuredEvidence(), context: context),
        ReadinessFailureClassification.gitExecutionError,
      );
      expectFailure(
        await evaluatorFor(
          structuredChanges,
          baseIsAncestor: false,
        ).evaluate(evidence: structuredEvidence(), context: context),
        ReadinessFailureClassification.baseMismatch,
      );
    });

    test('rejects malformed context before any Git access', () async {
      for (final testCase
          in <(PullRequestContext, String, int, String, String, String)>[
            const (
              PullRequestContext(
                repository: '../../unsafe',
                prNumber: 419,
                headSha: headSha,
                baseSha: baseSha,
                author: 'contributor-dev',
              ),
              'invalid/invalid',
              419,
              headSha,
              baseSha,
              'contributor-dev',
            ),
            const (
              PullRequestContext(
                repository: 'leehack/llamadart',
                prNumber: 0,
                headSha: headSha,
                baseSha: baseSha,
                author: 'contributor-dev',
              ),
              'leehack/llamadart',
              1,
              headSha,
              baseSha,
              'contributor-dev',
            ),
            const (
              PullRequestContext(
                repository: 'leehack/llamadart',
                prNumber: 419,
                headSha: '--upload-pack=unsafe',
                baseSha: baseSha,
                author: 'contributor-dev',
              ),
              'leehack/llamadart',
              419,
              'ffffffffffffffffffffffffffffffffffffffff',
              baseSha,
              'contributor-dev',
            ),
            const (
              PullRequestContext(
                repository: 'leehack/llamadart',
                prNumber: 419,
                headSha: headSha,
                baseSha: '../unsafe',
                author: 'contributor-dev',
              ),
              'leehack/llamadart',
              419,
              headSha,
              'ffffffffffffffffffffffffffffffffffffffff',
              'contributor-dev',
            ),
            const (
              PullRequestContext(
                repository: 'leehack/llamadart',
                prNumber: 419,
                headSha: headSha,
                baseSha: baseSha,
                author: 'bad--author',
              ),
              'leehack/llamadart',
              419,
              headSha,
              baseSha,
              'invalid-author',
            ),
          ]) {
        final malformedContext = testCase.$1;
        final repositoryState = FakeRepositoryState(changes: structuredChanges);
        final evidence = structuredEvidence();
        mutateIdentityToOtherValidValues(evidence);
        final result = await HighRiskReadinessEvaluator(
          repositoryState: repositoryState,
          clock: () => DateTime.utc(2026, 8, 28, 13),
        ).evaluate(evidence: evidence, context: malformedContext);

        expectFailure(result, ReadinessFailureClassification.invalidInput);
        expect(repositoryState.repositoryCallCount, 0);
        expectEmittedIdentity(
          result,
          repository: testCase.$2,
          prNumber: testCase.$3,
          headSha: testCase.$4,
          baseSha: testCase.$5,
          author: testCase.$6,
        );
      }
    });

    test(
      'classifies rename source and destination from exact inventory',
      () async {
        final result = await evaluatorFor(const [
          RepositoryChange(
            path: 'website/docs/renamed.md',
            previousPath: 'lib/src/core/template/old_handler.dart',
            kind: RepositoryChangeKind.renamed,
          ),
        ]).evaluate(evidence: standardEvidence(), context: context);
        expectFailure(
          result,
          ReadinessFailureClassification.classificationMismatch,
        );
      },
    );

    test('rejects unknown and unmerged inventory statuses', () async {
      for (final kind in [
        RepositoryChangeKind.unknown,
        RepositoryChangeKind.unmerged,
      ]) {
        expectFailure(
          await evaluatorFor([
            RepositoryChange(
              path: 'lib/src/backends/example_backend.dart',
              kind: kind,
            ),
          ]).evaluate(evidence: backendEvidence(), context: context),
          ReadinessFailureClassification.changedFilesMismatch,
        );
      }
    });

    test(
      'rejects malformed and duplicate repository inventory entries',
      () async {
        for (final changes in <List<RepositoryChange>>[
          const [
            RepositoryChange(path: '', kind: RepositoryChangeKind.modified),
          ],
          const [
            RepositoryChange(
              path: backendTest,
              kind: RepositoryChangeKind.renamed,
            ),
          ],
          const [
            RepositoryChange(
              path: backendTest,
              previousPath: 'test/unit/backends/old_test.dart',
              kind: RepositoryChangeKind.modified,
            ),
          ],
          const [
            RepositoryChange(
              path: backendTest,
              kind: RepositoryChangeKind.added,
            ),
            RepositoryChange(
              path: backendTest,
              kind: RepositoryChangeKind.modified,
            ),
          ],
        ]) {
          final result = await evaluatorFor(
            changes,
          ).evaluate(evidence: backendEvidence(), context: context);
          expectFailure(
            result,
            ReadinessFailureClassification.changedFilesMismatch,
          );
          expect(() => jsonEncode(result.toJson()), returnsNormally);
        }
      },
    );
  });

  group('audit and matrix invariants', () {
    test('valid local evidence is never operationally ready', () async {
      final result = await evaluateStructured(structuredEvidence());
      expect(result.decision, ReadinessDecision.unverifiedPrerequisites);
      expect(
        result.failureClassification,
        ReadinessFailureClassification.externalPrerequisitesUnavailable,
      );
      expect(result.isReady, isFalse);
      final prerequisites =
          ((result.toJson()['evaluation']
                  as Map<String, dynamic>)['external_prerequisites']
              as Map<String, dynamic>);
      expect(prerequisites.values.whereType<bool>(), everyElement(isFalse));
    });

    test('rejects self approval and retired qa identities', () async {
      final self = structuredEvidence();
      (self['independent_audit'] as Map<String, dynamic>)['auditor_identity'] =
          context.author;
      expectFailure(
        await evaluateStructured(self),
        ReadinessFailureClassification.selfApprovalProhibited,
      );

      for (final identity in ['qa', 'QA', 'qa-agent', 'qa_agent', 'qa-task']) {
        final retired = structuredEvidence();
        (retired['independent_audit']
                as Map<String, dynamic>)['auditor_identity'] =
            identity;
        expectFailure(
          await evaluateStructured(retired),
          ReadinessFailureClassification.retiredQaProfileProhibited,
        );
      }
    });

    for (final testCase
        in <(String, String, Object, ReadinessFailureClassification)>[
          (
            'audit head',
            'audit_head_sha',
            otherSha,
            ReadinessFailureClassification.headMismatch,
          ),
          (
            'audit base',
            'audit_base_sha',
            otherSha,
            ReadinessFailureClassification.baseMismatch,
          ),
          (
            'audit decision',
            'decision',
            'blocked',
            ReadinessFailureClassification.auditRejected,
          ),
          (
            'review threads',
            'unresolved_review_threads',
            1,
            ReadinessFailureClassification.unresolvedReviewThreads,
          ),
          (
            'P1 regressions',
            'known_pr_caused_p1_regressions',
            1,
            ReadinessFailureClassification.knownP1Regressions,
          ),
        ]) {
      test('rejects invalid ${testCase.$1}', () async {
        final evidence = structuredEvidence();
        (evidence['independent_audit'] as Map<String, dynamic>)[testCase.$2] =
            testCase.$3;
        expectFailure(await evaluateStructured(evidence), testCase.$4);
      });
    }

    test(
      'rejects missing, extra, failed, and mismatched matrix rows',
      () async {
        final missing = structuredEvidence();
        (missing['required_matrix_row_ids'] as List<dynamic>).remove(
          'structured-output-adversarial',
        );
        expectFailure(
          await evaluateStructured(missing),
          ReadinessFailureClassification.missingRequiredMatrixRow,
        );

        final extra = structuredEvidence();
        (extra['required_matrix_row_ids'] as List<dynamic>).add('phantom-row');
        expectFailure(
          await evaluateStructured(extra),
          ReadinessFailureClassification.schemaViolation,
        );

        final failed = structuredEvidence();
        ((failed['matrix_row_evidence']
                    as Map<String, dynamic>)['structured-output-adversarial']
                as Map<String, dynamic>)['result'] =
            'fail';
        expectFailure(
          await evaluateStructured(failed),
          ReadinessFailureClassification.matrixRowFailed,
        );
      },
    );
  });

  group('candidate-tree evidence paths', () {
    test(
      'rejects traversal, absolute, non-test, and tool script paths',
      () async {
        for (final path in [
          '../test/escape_test.dart',
          '/test/absolute_test.dart',
          'test/../test/escape_test.dart',
          'lib/readme.dart',
          'tool/scripts/not_a_test.sh',
          'test/unit/not_a_test.dart.txt',
          'test/unit/backends/bad\u0000name_test.dart',
          'test/unit/backends/bad\nname_test.dart',
          'test/unit/backends/*_test.dart',
          'test/unit/backends/model?_test.dart',
          'test/unit/backends/[ab]_test.dart',
        ]) {
          final evidence = backendEvidence()..['affected_test_paths'] = [path];
          final changes = path.contains('\u0000')
              ? backendChanges
              : <RepositoryChange>[
                  backendChanges.first,
                  RepositoryChange(
                    path: path,
                    kind: RepositoryChangeKind.modified,
                  ),
                ];
          expectFailure(
            await evaluatorFor(
              changes,
            ).evaluate(evidence: evidence, context: context),
            ReadinessFailureClassification.nonTestPathCited,
          );
        }
      },
    );

    test(
      'rejects unchanged, deleted, renamed-old, and phantom paths',
      () async {
        expectFailure(
          await evaluatorFor([
            backendChanges.first,
          ]).evaluate(evidence: backendEvidence(), context: context),
          ReadinessFailureClassification.unchangedEvidencePath,
        );

        expectFailure(
          await evaluatorFor(const [
            RepositoryChange(
              path: 'lib/src/backends/example_backend.dart',
              kind: RepositoryChangeKind.modified,
            ),
            RepositoryChange(
              path: backendTest,
              kind: RepositoryChangeKind.deleted,
            ),
          ]).evaluate(evidence: backendEvidence(), context: context),
          ReadinessFailureClassification.deletedEvidencePath,
        );

        final renamed = backendEvidence()
          ..['affected_test_paths'] = [
            'test/unit/backends/old_backend_test.dart',
          ];
        expectFailure(
          await evaluatorFor(const [
            RepositoryChange(
              path: 'lib/src/backends/example_backend.dart',
              kind: RepositoryChangeKind.modified,
            ),
            RepositoryChange(
              path: backendTest,
              previousPath: 'test/unit/backends/old_backend_test.dart',
              kind: RepositoryChangeKind.renamed,
            ),
          ]).evaluate(evidence: renamed, context: context),
          ReadinessFailureClassification.renamedEvidencePath,
        );

        expectFailure(
          await evaluatorFor(
            backendChanges,
            existingPaths: {'lib/src/backends/example_backend.dart'},
          ).evaluate(evidence: backendEvidence(), context: context),
          ReadinessFailureClassification.missingTestPath,
        );
      },
    );

    test('does not treat a copy source as the old side of a rename', () async {
      final result = await evaluatorFor(const [
        RepositoryChange(
          path: 'lib/src/backends/example_backend.dart',
          kind: RepositoryChangeKind.modified,
        ),
        RepositoryChange(
          path: backendTest,
          kind: RepositoryChangeKind.modified,
        ),
        RepositoryChange(
          path: 'test/unit/backends/copied_backend_test.dart',
          previousPath: backendTest,
          kind: RepositoryChangeKind.copied,
        ),
      ]).evaluate(evidence: backendEvidence(), context: context);

      expect(result.decision, ReadinessDecision.unverifiedPrerequisites);
    });

    test(
      'serializes a fail-closed result when the tree probe errors',
      () async {
        final result = await evaluatorFor(
          backendChanges,
          pathProbeThrows: true,
        ).evaluate(evidence: backendEvidence(), context: context);

        expectFailure(result, ReadinessFailureClassification.gitExecutionError);
        expect(() => jsonEncode(result.toJson()), returnsNormally);
      },
    );
  });

  group('structured-output production proof', () {
    test('requires every explicit coverage axis and family evidence', () async {
      final missingAxis = structuredEvidence();
      ((missingAxis['structured_output_evidence']
                  as Map<String, dynamic>)['coverage']
              as Map<String, dynamic>)
          .remove('streaming_rollback');
      expectFailure(
        await evaluateStructured(missingAxis),
        ReadinessFailureClassification.schemaViolation,
      );

      final emptyAxis = structuredEvidence();
      ((emptyAxis['structured_output_evidence']
                  as Map<String, dynamic>)['coverage']
              as Map<String, dynamic>)['tool_choice_thinking'] =
          <String>[];
      expectFailure(
        await evaluateStructured(emptyAxis),
        ReadinessFailureClassification.schemaViolation,
      );

      final noFamilies = structuredEvidence();
      (noFamilies['structured_output_evidence']
              as Map<String, dynamic>)['families'] =
          <dynamic>[];
      expectFailure(
        await evaluateStructured(noFamilies),
        ReadinessFailureClassification.schemaViolation,
      );
    });

    test(
      'requires changed compiled acceptance and rejection production tests',
      () async {
        const ordinaryTest =
            'test/unit/core/template/example_handler_test.dart';
        final evidence = structuredEvidence();
        evidence['affected_test_paths'] = [ordinaryTest];
        final coverage =
            (evidence['structured_output_evidence']
                    as Map<String, dynamic>)['coverage']
                as Map<String, dynamic>;
        for (final key in coverage.keys) {
          coverage[key] = [ordinaryTest];
        }
        ((evidence['structured_output_evidence']
                    as Map<String, dynamic>)['families']
                as List<dynamic>)
            .cast<Map<String, dynamic>>()
            .single['evidence_test_paths'] = [
          ordinaryTest,
        ];
        expectFailure(
          await evaluateStructured(
            evidence,
            changes: const [
              RepositoryChange(
                path: 'lib/src/core/template/chat_template_handler.dart',
                kind: RepositoryChangeKind.modified,
              ),
              RepositoryChange(
                path: ordinaryTest,
                kind: RepositoryChangeKind.modified,
              ),
            ],
          ),
          ReadinessFailureClassification.missingStructuredOutputEvidence,
        );
      },
    );

    test(
      'rejects coverage and family paths outside changed affected tests',
      () async {
        const otherTest = 'test/unit/core/template/other_handler_test.dart';
        final axis = structuredEvidence();
        (((axis['structured_output_evidence']
                        as Map<String, dynamic>)['coverage']
                    as Map<String, dynamic>)['streaming_rollback']
                as List<dynamic>)
            .add(otherTest);
        expectFailure(
          await evaluateStructured(axis),
          ReadinessFailureClassification.unchangedEvidencePath,
        );

        final family = structuredEvidence();
        ((((family['structured_output_evidence']
                                as Map<String, dynamic>)['families']
                            as List<dynamic>)
                        .single
                    as Map<String, dynamic>)['evidence_test_paths']
                as List<dynamic>)
            .add(otherTest);
        expectFailure(
          await evaluateStructured(family),
          ReadinessFailureClassification.unchangedEvidencePath,
        );
      },
    );

    test(
      'accepts explicit unavailable-family semantics but stays unverified',
      () async {
        final evidence = structuredEvidence();
        final family =
            ((evidence['structured_output_evidence']
                            as Map<String, dynamic>)['families']
                        as List<dynamic>)
                    .single
                as Map<String, dynamic>;
        family['status'] = 'unavailable';
        family['rationale'] =
            'Exact weights unavailable; primary upstream fixture is covered.';
        final result = await evaluateStructured(evidence);
        expect(result.decision, ReadinessDecision.unverifiedPrerequisites);
      },
    );

    test('rejects duplicate affected-family names', () async {
      final evidence = structuredEvidence();
      final families =
          (evidence['structured_output_evidence']
                  as Map<String, dynamic>)['families']
              as List<dynamic>;
      final duplicate = Map<String, Object>.from(
        families.single as Map,
      )..['rationale'] = 'A duplicate family cannot stand in for completeness.';
      families.add(duplicate);

      expectFailure(
        await evaluateStructured(evidence),
        ReadinessFailureClassification.schemaViolation,
      );
    });
  });

  group('standard-risk diagnostic and schema/serializer parity', () {
    test(
      'standard risk remains non-ready and needs no high-risk evidence',
      () async {
        final result = await evaluatorFor(const [
          RepositoryChange(
            path: 'website/docs/guides/example.md',
            kind: RepositoryChangeKind.modified,
          ),
        ]).evaluate(evidence: standardEvidence(), context: context);
        expect(result.decision, ReadinessDecision.standardRiskDiagnostic);
        expect(
          result.failureClassification,
          ReadinessFailureClassification.none,
        );
        expect(result.isReady, isFalse);
      },
    );

    test('standard diff rejects high-risk classification and claims', () async {
      expectFailure(
        await evaluatorFor(const [
          RepositoryChange(
            path: 'website/docs/guides/example.md',
            kind: RepositoryChangeKind.modified,
          ),
        ]).evaluate(evidence: backendEvidence(), context: context),
        ReadinessFailureClassification.classificationMismatch,
      );
    });

    test('standard classification rejects attached high-risk claims', () async {
      final evidence = standardEvidence()
        ..['independent_audit'] = structuredEvidence()['independent_audit'];
      final result = await evaluatorFor(const [
        RepositoryChange(
          path: 'website/docs/guides/example.md',
          kind: RepositoryChangeKind.modified,
        ),
      ]).evaluate(evidence: evidence, context: context);

      expectFailure(result, ReadinessFailureClassification.schemaViolation);
    });

    test('emitted keys and enum values match the canonical schema', () async {
      final output = (await evaluateStructured(structuredEvidence())).toJson();
      final schema =
          jsonDecode(
                File(
                  'tool/testing/high_risk_readiness_evidence.schema.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      expect(output.keys.toSet(), (schema['required'] as List).toSet());
      expect(output.keys.toSet(), (schema['properties'] as Map).keys.toSet());

      final definitions = schema[r'$defs'] as Map<String, dynamic>;
      void expectExactKeys(Map<dynamic, dynamic> value, String definition) {
        final objectSchema = definitions[definition] as Map<String, dynamic>;
        expect(value.keys.toSet(), (objectSchema['required'] as List).toSet());
        expect(
          value.keys.toSet(),
          (objectSchema['properties'] as Map).keys.toSet(),
        );
      }

      expect(
        (schema['properties']
            as Map<String, dynamic>)['surfaces']['items']['enum'],
        HighRiskSurface.values.map((value) => value.name).toList(),
      );
      const matrixRows = <String>[
        'high-risk-exact-head-independent-qa',
        'structured-output-adversarial',
      ];
      expect(
        (schema['properties']
            as Map<
              String,
              dynamic
            >)['required_matrix_row_ids']['items']['enum'],
        matrixRows,
      );
      expect(
        (schema['properties']
            as Map<
              String,
              dynamic
            >)['matrix_row_evidence']['propertyNames']['enum'],
        matrixRows,
      );
      expect(
        (definitions['matrixRow']
            as Map<String, dynamic>)['properties']['row_id']['enum'],
        matrixRows,
      );

      final input = structuredEvidence();
      expectExactKeys(
        input['independent_audit'] as Map<String, dynamic>,
        'independentAudit',
      );
      expect(
        (definitions['independentAudit']
            as Map<String, dynamic>)['properties']['audit_kind']['enum'],
        const ['operator-owned', 'codex-adversarial'],
      );
      final matrixEvidence =
          input['matrix_row_evidence'] as Map<String, dynamic>;
      for (final row in matrixEvidence.values.cast<Map<String, dynamic>>()) {
        expectExactKeys(row, 'matrixRow');
      }
      final structured =
          input['structured_output_evidence'] as Map<String, dynamic>;
      expectExactKeys(structured, 'structuredOutputEvidence');
      final structuredSchema =
          definitions['structuredOutputEvidence'] as Map<String, dynamic>;
      final coverage = structured['coverage'] as Map<String, dynamic>;
      final coverageSchema =
          structuredSchema['properties']['coverage'] as Map<String, dynamic>;
      expect(
        coverage.keys.toSet(),
        (coverageSchema['required'] as List).toSet(),
      );
      expect(
        coverage.keys.toSet(),
        (coverageSchema['properties'] as Map).keys.toSet(),
      );
      final family =
          (structured['families'] as List<dynamic>).single
              as Map<String, dynamic>;
      final familySchema =
          (structuredSchema['properties']['families']['items']
              as Map<String, dynamic>);
      expect(family.keys.toSet(), (familySchema['required'] as List).toSet());
      expect(
        family.keys.toSet(),
        (familySchema['properties'] as Map).keys.toSet(),
      );
      expect(
        (familySchema['properties'] as Map<String, dynamic>)['status']['enum'],
        const ['tested', 'unavailable'],
      );

      final evaluationSchema =
          definitions['evaluation'] as Map<String, dynamic>;
      final evaluationProperties =
          evaluationSchema['properties'] as Map<String, dynamic>;
      final evaluation = output['evaluation'] as Map<String, dynamic>;
      expect(
        evaluation.keys.toSet(),
        (evaluationSchema['required'] as List).toSet(),
      );
      expect(evaluation.keys.toSet(), evaluationProperties.keys.toSet());
      expect(
        (evaluationProperties['decision'] as Map)['enum'],
        ReadinessDecision.values.map((value) => value.name).toList(),
      );
      expect(
        (evaluationProperties['failure_classification'] as Map)['enum'],
        ReadinessFailureClassification.values
            .map((value) => value.name)
            .toList(),
      );
      expect(evaluation['decision'], isNot('ready'));
      final changeSchema =
          definitions['repositoryChange'] as Map<String, dynamic>;
      final changedFiles = evaluation['changed_files'] as List<dynamic>;
      expect(changedFiles, isNotEmpty);
      for (final change in changedFiles.cast<Map<String, dynamic>>()) {
        expect(
          change.keys.toSet(),
          containsAll(changeSchema['required'] as List),
        );
        expect(
          change.keys,
          everyElement(
            isIn((changeSchema['properties'] as Map<String, dynamic>).keys),
          ),
        );
      }
      expect(
        ((changeSchema['properties'] as Map<String, dynamic>)['status']
            as Map<String, dynamic>)['enum'],
        RepositoryChangeKind.values.map((value) => value.name).toList(),
      );

      final prerequisites =
          evaluation['external_prerequisites'] as Map<String, dynamic>;
      expectExactKeys(prerequisites, 'externalPrerequisites');

      final testPathPattern = RegExp(
        (definitions['testPath'] as Map<String, dynamic>)['pattern'] as String,
      );
      expect(testPathPattern.hasMatch(backendTest), isTrue);
      for (final unsafePath in [
        'test/../escape_test.dart',
        r'test\escape_test.dart',
        'test/bad\u0000name_test.dart',
        'test/bad\nname_test.dart',
        'test/double//slash_test.dart',
        'test/unit/*_test.dart',
        'test/unit/model?_test.dart',
        'test/unit/[ab]_test.dart',
      ]) {
        expect(testPathPattern.hasMatch(unsafePath), isFalse);
      }
    });
  });

  group('Git inventory parser', () {
    test('preserves added, deleted, and both sides of renames', () {
      final changes = parseGitNameStatus(
        'A\u0000test/new_test.dart\u0000'
        'D\u0000test/deleted_test.dart\u0000'
        'R100\u0000lib/src/core/template/old.dart\u0000website/docs/new.md\u0000',
      );
      expect(changes, hasLength(3));
      expect(changes[0].kind, RepositoryChangeKind.added);
      expect(changes[1].kind, RepositoryChangeKind.deleted);
      expect(changes[2].kind, RepositoryChangeKind.renamed);
      expect(changes[2].previousPath, 'lib/src/core/template/old.dart');
      expect(changes[2].path, 'website/docs/new.md');
    });

    test('rejects malformed name-status output', () {
      for (final output in [
        'R100\u0000only-one-path\u0000',
        'R101\u0000old\u0000new\u0000',
        'modified\u0000path\u0000',
        'M\u0000unterminated',
      ]) {
        expect(() => parseGitNameStatus(output), throwsFormatException);
      }
    });

    test(
      'candidate-tree probe rejects symlinks and accepts regular blobs',
      () async {
        final symlinkReader = GitRepositoryStateReader(
          gitRunner: (args, {workingDirectory}) async =>
              ProcessResult(1, 0, '120000 blob abcdef\t$backendTest\u0000', ''),
        );
        expect(
          await symlinkReader.pathIsRegularFileAt(headSha, backendTest),
          isFalse,
        );

        final fileReader = GitRepositoryStateReader(
          gitRunner: (args, {workingDirectory}) async =>
              ProcessResult(1, 0, '100644 blob abcdef\t$backendTest\u0000', ''),
        );
        expect(
          await fileReader.pathIsRegularFileAt(headSha, backendTest),
          isTrue,
        );

        const wildcardTest = 'test/unit/backends/*_test.dart';
        late List<String> observedArgs;
        final wildcardReader = GitRepositoryStateReader(
          gitRunner: (args, {workingDirectory}) async {
            observedArgs = args;
            return ProcessResult(
              1,
              0,
              '100644 blob abcdef\t$backendTest\u0000',
              '',
            );
          },
        );
        expect(
          await wildcardReader.pathIsRegularFileAt(headSha, wildcardTest),
          isFalse,
        );
        expect(observedArgs.last, ':(top,literal)$wildcardTest');
      },
    );
  });
}
