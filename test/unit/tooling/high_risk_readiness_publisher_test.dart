@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../../tool/governance/high_risk_readiness_publish.dart';
import '../../../tool/governance/high_risk_readiness_publisher.dart';
import '../../../tool/governance/readiness_publication_protocol.dart';
import '../../../tool/testing/high_risk_readiness.dart';

const repository = 'leehack/llamadart';
const prNumber = 419;
const author = 'contributor-dev';
const auditor = 'reviewer-two';
const readinessAppId = 4190001;
const readinessInstallationId = 4190002;
const runId = 987654;
const ownedExternalId =
    'llamadart-hr:v1:attestation:'
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const headSha = '1111111111111111111111111111111111111111';
const baseSha = '2222222222222222222222222222222222222222';
const movedHeadSha = '3333333333333333333333333333333333333333';
const governanceTest =
    'test/unit/tooling/high_risk_readiness_publisher_test.dart';

LivePullRequest livePr({
  String head = headSha,
  String base = baseSha,
  String prAuthor = author,
  String baseRef = defaultReadinessBranch,
  String state = 'open',
  bool draft = false,
  int changedFileCount = 2,
  String repo = repository,
  int number = prNumber,
}) => LivePullRequest(
  repository: repo,
  number: number,
  author: prAuthor,
  headSha: head,
  baseSha: base,
  baseRef: baseRef,
  state: state,
  isDraft: draft,
  changedFileCount: changedFileCount,
);

LiveAppIdentity liveApp({
  String slug = defaultReadinessAppSlug,
  int appId = readinessAppId,
  int installationId = readinessInstallationId,
  String? installationAppSlug,
  int? installationAppId,
  String installationAccount = 'leehack',
  String repositorySelection = 'selected',
  List<String>? installations,
  Map<String, String>? permissions,
}) => LiveAppIdentity(
  slug: slug,
  appId: appId,
  installationId: installationId,
  installationAppSlug: installationAppSlug ?? slug,
  installationAppId: installationAppId ?? appId,
  installationAccount: installationAccount,
  repositorySelection: repositorySelection,
  installationRepositories: installations ?? const <String>[repository],
  permissions:
      permissions ??
      const <String, String>{
        'actions': 'read',
        'checks': 'write',
        'contents': 'read',
        'pull_requests': 'read',
        'metadata': 'read',
        'statuses': 'read',
      },
);

LiveProtectedApproval liveApproval({
  String approver = auditor,
  String requester = author,
  String environment = defaultReadinessEnvironment,
  String workflowPath = defaultReadinessWorkflowPath,
  String event = 'workflow_dispatch',
  String headBranch = defaultReadinessBranch,
  String repo = repository,
  int attestedPr = prNumber,
  String attestedHead = headSha,
  String attestedBase = baseSha,
  String evidenceDigest =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  String workflowSha = baseSha,
  String runHeadSha = baseSha,
  int attempt = 1,
  int approvalRunId = runId,
}) => LiveProtectedApproval(
  repository: repo,
  runId: approvalRunId,
  runAttempt: attempt,
  workflowPath: workflowPath,
  workflowSha: workflowSha,
  event: event,
  headBranch: headBranch,
  headSha: runHeadSha,
  environment: environment,
  approverLogin: approver,
  requesterLogin: requester,
  attestedPrNumber: attestedPr,
  attestedHeadSha: attestedHead,
  attestedBaseSha: attestedBase,
  attestedEvidenceDigest: evidenceDigest,
);

LiveProtectedEnvironment liveEnvironment({
  String repo = repository,
  String name = defaultReadinessEnvironment,
  bool hasRequiredReviewers = true,
  bool preventSelfReview = true,
  bool protectedBranches = false,
  List<String> branches = const <String>[defaultReadinessBranch],
}) => LiveProtectedEnvironment(
  repository: repo,
  name: name,
  hasRequiredReviewers: hasRequiredReviewers,
  preventSelfReview: preventSelfReview,
  protectedBranches: protectedBranches,
  customBranchPolicies: branches,
);

LiveRulesetEnforcement liveRuleset({
  bool enforcing = true,
  bool strict = true,
  bool resolveReviewThreads = true,
  int integrationId = readinessAppId,
}) => LiveRulesetEnforcement(
  defaultBranchProtected: enforcing,
  strictRequiredStatusChecks: strict,
  reviewThreadsMustBeResolved: resolveReviewThreads,
  requiredChecks: enforcing
      ? <LiveRequiredCheck>[
          LiveRequiredCheck(
            context: defaultReadinessCheckName,
            integrationId: integrationId,
          ),
        ]
      : const <LiveRequiredCheck>[],
  rulesetNames: const <String>['default-branch-protection'],
);

List<RepositoryChange> highRiskInventory() => <RepositoryChange>[
  const RepositoryChange(
    path: 'AGENTS.md',
    kind: RepositoryChangeKind.modified,
  ),
  const RepositoryChange(
    path: governanceTest,
    kind: RepositoryChangeKind.modified,
  ),
];

List<RepositoryChange> standardInventory() => <RepositoryChange>[
  const RepositoryChange(
    path: 'website/docs/intro.md',
    kind: RepositoryChangeKind.modified,
  ),
];

Map<String, dynamic> highRiskEvidence({
  String head = headSha,
  String base = baseSha,
  String evidenceAuditor = auditor,
  String prAuthor = author,
  int unresolvedThreads = 0,
  int knownP1 = 0,
  String auditDecision = 'accepted',
  List<String>? affectedTestPaths,
}) => <String, dynamic>{
  'schema': 'llamadart.high-risk-readiness-evidence',
  'schema_version': '1.0.0',
  'timestamp': '2026-08-28T12:00:00.000Z',
  'correlation_id': 'issue-419-attestation-1',
  'repository': repository,
  'pr_number': prNumber,
  'expected_pr_head_sha': head,
  'current_base_sha': base,
  'pr_author': prAuthor,
  'classification': 'high-risk',
  'surfaces': <String>['regressionPolicy'],
  'required_matrix_row_ids': <String>['high-risk-exact-head-independent-qa'],
  'matrix_row_evidence': <String, dynamic>{
    'high-risk-exact-head-independent-qa': <String, dynamic>{
      'row_id': 'high-risk-exact-head-independent-qa',
      'result': 'pass',
      'command': 'independent blocking-only review of the exact head and base',
      'evidence_notes':
          'Production call sites and deletion-sensitive tests inspected.',
    },
  },
  'independent_audit': <String, dynamic>{
    'auditor_identity': evidenceAuditor,
    'audit_kind': 'operator-owned',
    'audit_head_sha': head,
    'audit_base_sha': base,
    'decision': auditDecision,
    'unresolved_review_threads': unresolvedThreads,
    'known_pr_caused_p1_regressions': knownP1,
    'summary': 'Adversarial review of the governance publisher boundary.',
  },
  'structured_output_evidence': null,
  'affected_test_paths': affectedTestPaths ?? <String>[governanceTest],
  'evaluation': null,
};

Map<String, dynamic> standardEvidence() => <String, dynamic>{
  'schema': 'llamadart.high-risk-readiness-evidence',
  'schema_version': '1.0.0',
  'timestamp': '2026-08-28T12:00:00.000Z',
  'correlation_id': 'issue-419-attestation-standard',
  'repository': repository,
  'pr_number': prNumber,
  'expected_pr_head_sha': headSha,
  'current_base_sha': baseSha,
  'pr_author': author,
  'classification': 'standard',
  'surfaces': const <String>[],
  'required_matrix_row_ids': const <String>[],
  'matrix_row_evidence': const <String, dynamic>{},
  'independent_audit': null,
  'structured_output_evidence': null,
  'affected_test_paths': const <String>[],
  'evaluation': null,
};

T sequenceValue<T>(List<T>? values, int index, T fallback) {
  if (values == null || values.isEmpty) return fallback;
  return values[index < values.length ? index : values.length - 1];
}

class FakeGitHubSource implements AuthenticatedGitHubSource {
  FakeGitHubSource({
    LiveAppIdentity? app,
    List<LivePullRequest>? pullRequestReads,
    List<RepositoryChange>? inventory,
    this.inventoryReads,
    this.unresolvedThreads = 0,
    this.unresolvedThreadReads,
    this.aggregate = LiveCheckAggregate.success,
    this.pendingContexts = const <String>[],
    this.failingContexts = const <String>[],
    this.headCheckStateReads,
    LiveProtectedApproval? approval,
    this.approvalIsNull = false,
    LiveProtectedEnvironment? protectedEnvironment,
    this.protectedEnvironmentReads,
    LiveRulesetEnforcement? ruleset,
    this.submission,
    this.submissionReads,
    Set<String>? headPaths,
    this.commitsExist = true,
    this.baseIsAncestor = true,
    this.appReadThrows = false,
    this.inventoryReadThrows = false,
    this.headCheckStateSha,
  }) : app = app ?? liveApp(),
       pullRequestReads = pullRequestReads ?? <LivePullRequest>[livePr()],
       inventory = inventory ?? highRiskInventory(),
       approval =
           approval ??
           liveApproval(
             evidenceDigest:
                 submission?.digest ??
                 submissionReads?.first.digest ??
                 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
           ),
       protectedEnvironment = protectedEnvironment ?? liveEnvironment(),
       ruleset = ruleset ?? liveRuleset(),
       headPaths =
           headPaths ??
           (inventory ?? highRiskInventory())
               .where((change) => change.kind != RepositoryChangeKind.deleted)
               .map((change) => change.path)
               .toSet();

  final LiveAppIdentity app;
  final List<LivePullRequest> pullRequestReads;
  final List<RepositoryChange> inventory;
  final List<List<RepositoryChange>>? inventoryReads;
  final int unresolvedThreads;
  final List<int>? unresolvedThreadReads;
  final LiveCheckAggregate aggregate;
  final List<String> pendingContexts;
  final List<String> failingContexts;
  final List<LiveHeadCheckState>? headCheckStateReads;
  final LiveProtectedApproval approval;
  final bool approvalIsNull;
  final LiveProtectedEnvironment protectedEnvironment;
  final List<LiveProtectedEnvironment>? protectedEnvironmentReads;
  final LiveRulesetEnforcement ruleset;
  final AuthenticatedEvidenceSubmission? submission;
  final List<AuthenticatedEvidenceSubmission>? submissionReads;
  final Set<String> headPaths;
  final bool commitsExist;
  final bool baseIsAncestor;
  final bool appReadThrows;
  final bool inventoryReadThrows;
  final String? headCheckStateSha;

  var pullRequestReadCount = 0;
  var evidenceReadCount = 0;
  var inventoryReadCount = 0;
  var unresolvedThreadReadCount = 0;
  var headCheckStateReadCount = 0;
  var approvalReadCount = 0;
  var protectedEnvironmentReadCount = 0;
  var rulesetReadCount = 0;
  int? lastExpectedInventoryCount;
  int? lastExcludedCheckAppId;

  @override
  Future<LiveAppIdentity> readAppIdentity() async {
    if (appReadThrows) throw StateError('app identity unavailable');
    return app;
  }

  @override
  Future<LivePullRequest> readPullRequest(int number) async {
    final index = pullRequestReadCount < pullRequestReads.length
        ? pullRequestReadCount
        : pullRequestReads.length - 1;
    pullRequestReadCount++;
    return pullRequestReads[index];
  }

  @override
  Future<List<RepositoryChange>> readChangedFiles(
    int number, {
    required int expectedCount,
  }) async {
    lastExpectedInventoryCount = expectedCount;
    if (inventoryReadThrows) {
      throw StateError('paginated inventory count did not match');
    }
    final value = sequenceValue(inventoryReads, inventoryReadCount, inventory);
    inventoryReadCount++;
    return value;
  }

  @override
  Future<int> readUnresolvedReviewThreadCount(int number) async {
    final value = sequenceValue(
      unresolvedThreadReads,
      unresolvedThreadReadCount,
      unresolvedThreads,
    );
    unresolvedThreadReadCount++;
    return value;
  }

  @override
  Future<LiveHeadCheckState> readHeadCheckState(
    String sha, {
    required String excludedCheckName,
    required int excludedAppId,
  }) async {
    lastExcludedCheckAppId = excludedAppId;
    final fallback = LiveHeadCheckState(
      headSha: headCheckStateSha ?? sha,
      aggregate: aggregate,
      pendingContexts: pendingContexts,
      failingContexts: failingContexts,
    );
    final value = sequenceValue(
      headCheckStateReads,
      headCheckStateReadCount,
      fallback,
    );
    headCheckStateReadCount++;
    return value;
  }

  @override
  Future<LiveProtectedApproval?> readProtectedApproval() async {
    approvalReadCount++;
    return approvalIsNull ? null : approval;
  }

  @override
  Future<LiveProtectedEnvironment> readProtectedEnvironment(String name) async {
    final value = sequenceValue(
      protectedEnvironmentReads,
      protectedEnvironmentReadCount,
      protectedEnvironment,
    );
    protectedEnvironmentReadCount++;
    return value;
  }

  @override
  Future<LiveRulesetEnforcement> readRulesetEnforcement({
    required String defaultBranch,
  }) async {
    rulesetReadCount++;
    return ruleset;
  }

  @override
  Future<AuthenticatedEvidenceSubmission> readEvidenceSubmission() async {
    final value = sequenceValue(submissionReads, evidenceReadCount, submission);
    evidenceReadCount++;
    if (value == null) throw StateError('no submission configured');
    return value;
  }

  @override
  Future<bool> commitExists(String sha) async => commitsExist;

  @override
  Future<bool> isAncestor(String ancestor, String descendant) async =>
      baseIsAncestor;

  @override
  Future<bool> pathIsRegularFileAt(String sha, String path) async =>
      headPaths.contains(path);
}

class FakeCheckPublisher implements ReadinessCheckPublisher {
  FakeCheckPublisher({List<ReadinessCheckRun>? seed})
    : runs = <ReadinessCheckRun>[...?seed];

  final List<ReadinessCheckRun> runs;
  final createdHeads = <String>[];
  final updatedIds = <int>[];
  final externalIds = <String>[];
  final summaries = <String>[];
  var nextId = 5000;
  var createdPendingStatus = 'in_progress';
  var throwAfterNextCreate = false;
  ReadinessCheckRun? conflictWinner;
  var createThrows = false;
  var updateThrows = false;
  var malformedCreateResponse = false;
  var returnForeignRuns = false;

  @override
  Future<List<ReadinessCheckRun>> listReadinessCheckRuns({
    required int prNumber,
    required String checkName,
    required int appId,
  }) async => runs
      .where(
        (run) =>
            run.name == checkName && (returnForeignRuns || run.appId == appId),
      )
      .toList(growable: false);

  @override
  Future<ReadinessCheckRun> createCheckRun({
    required String name,
    required String headSha,
    required ReadinessCheckConclusion? conclusion,
    required String title,
    required String summary,
    required String externalId,
  }) async {
    if (createThrows) throw StateError('create unavailable');
    createdHeads.add(headSha);
    externalIds.add(externalId);
    summaries.add(summary);
    final run = ReadinessCheckRun(
      id: nextId++,
      name: name,
      headSha: headSha,
      status: conclusion == null ? createdPendingStatus : 'completed',
      conclusion: conclusion?.wireValue,
      appId: readinessAppId,
      externalId: malformedCreateResponse ? 'ambiguous' : externalId,
    );
    runs.add(run);
    if (throwAfterNextCreate) {
      throwAfterNextCreate = false;
      final winner = conflictWinner;
      if (winner != null) runs.add(winner);
      throw StateError('create response lost');
    }
    return run;
  }

  @override
  Future<ReadinessCheckRun> updateCheckRun({
    required int checkRunId,
    required ReadinessCheckConclusion conclusion,
    required String title,
    required String summary,
    required String externalId,
  }) async {
    if (updateThrows) throw StateError('update unavailable');
    updatedIds.add(checkRunId);
    externalIds.add(externalId);
    summaries.add(summary);
    final index = runs.indexWhere((run) => run.id == checkRunId);
    if (index < 0) throw StateError('unknown check run $checkRunId');
    final updated = ReadinessCheckRun(
      id: runs[index].id,
      name: runs[index].name,
      headSha: runs[index].headSha,
      status: 'completed',
      conclusion: conclusion.wireValue,
      appId: runs[index].appId,
      externalId: externalId,
    );
    runs[index] = updated;
    return updated;
  }

  ReadinessCheckRun runById(int id) => runs.firstWhere((run) => run.id == id);
}

AuthenticatedEvidenceSubmission dispatched(
  Object? evidence, {
  EvidenceIngress ingress = EvidenceIngress.protectedEnvironmentApproval,
  int submissionRunId = runId,
}) => AuthenticatedEvidenceSubmission(
  ingress: ingress,
  runId: submissionRunId,
  evidenceJson: evidence is String ? evidence : jsonEncode(evidence),
);

HighRiskReadinessPublisher publisherFor(
  FakeGitHubSource source,
  FakeCheckPublisher checks,
) => HighRiskReadinessPublisher(
  source: source,
  checkPublisher: checks,
  clock: () => DateTime.utc(2026, 8, 28, 12),
);

Future<ReadinessPublicationRecord> attest(
  FakeGitHubSource source,
  FakeCheckPublisher checks,
) => publisherFor(
  source,
  checks,
).publish(prNumber: prNumber, mode: PublicationMode.attestation);

Future<ReadinessPublicationRecord> classify(
  FakeGitHubSource source,
  FakeCheckPublisher checks,
) => publisherFor(
  source,
  checks,
).publish(prNumber: prNumber, mode: PublicationMode.classification);

void main() {
  group('accepted attestation', () {
    test('publishes a passing check bound to the exact head', () async {
      final source = FakeGitHubSource(
        submission: dispatched(highRiskEvidence()),
      );
      final checks = FakeCheckPublisher();

      final record = await attest(source, checks);

      expect(record.decision, ReadinessPublicationDecision.accepted);
      expect(record.failure, ReadinessPublicationFailure.none);
      expect(record.checkConclusion, ReadinessCheckConclusion.success);
      expect(record.isAccepted, isTrue);
      expect(checks.createdHeads, <String>[headSha]);
      expect(checks.runById(record.checkRunId!).headSha, headSha);
      expect(record.prerequisites.allVerified, isTrue);
      expect(
        record.evidenceIngress,
        EvidenceIngress.protectedEnvironmentApproval,
      );
      expect(record.evidenceDigest, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(
        record.evaluatorDecision,
        ReadinessDecision.unverifiedPrerequisites,
      );
      expect(record.approval!.approverLogin, auditor);
      expect(record.changedFiles.map((c) => c.path), contains('AGENTS.md'));
      expect(source.lastExcludedCheckAppId, readinessAppId);
    });

    test(
      'rejects a workflow-file revision distinct from the authenticated run head',
      () async {
        final submission = dispatched(highRiskEvidence());
        final source = FakeGitHubSource(
          approval: liveApproval(
            workflowSha: '4444444444444444444444444444444444444444',
            runHeadSha: '5555555555555555555555555555555555555555',
            evidenceDigest: submission.digest,
          ),
          submission: submission,
        );

        final record = await attest(source, FakeCheckPublisher());

        expect(record.decision, ReadinessPublicationDecision.refused);
        expect(
          record.failure,
          ReadinessPublicationFailure.unauthenticatedAuditor,
        );
      },
    );

    test(
      'binds the live inventory count into the authenticated read',
      () async {
        final source = FakeGitHubSource(
          submission: dispatched(highRiskEvidence()),
        );
        await attest(source, FakeCheckPublisher());

        expect(source.lastExpectedInventoryCount, 2);
      },
    );

    test('replays idempotently onto the same run for the same head', () async {
      final firstChecks = FakeCheckPublisher();
      await attest(
        FakeGitHubSource(submission: dispatched(highRiskEvidence())),
        firstChecks,
      );
      final firstExternalId = firstChecks.runs.single.externalId;

      final replayChecks = FakeCheckPublisher(seed: firstChecks.runs.toList());
      final replay = await attest(
        FakeGitHubSource(submission: dispatched(highRiskEvidence())),
        replayChecks,
      );

      expect(replayChecks.createdHeads, isEmpty);
      expect(replayChecks.updatedIds, isEmpty);
      expect(replayChecks.externalIds, isEmpty);
      expect(replayChecks.runs.single.externalId, firstExternalId);
      expect(replay.decision, ReadinessPublicationDecision.accepted);
    });
  });

  group('authenticated identity', () {
    test('refuses a forged App slug without touching any check', () async {
      final checks = FakeCheckPublisher(
        seed: <ReadinessCheckRun>[
          const ReadinessCheckRun(
            id: 11,
            name: defaultReadinessCheckName,
            headSha: headSha,
            status: 'completed',
            conclusion: 'success',
            appId: readinessAppId,
            externalId: ownedExternalId,
          ),
        ],
      );
      final record = await attest(
        FakeGitHubSource(
          app: liveApp(slug: 'attacker-app'),
          submission: dispatched(highRiskEvidence()),
        ),
        checks,
      );

      expect(record.decision, ReadinessPublicationDecision.refused);
      expect(record.failure, ReadinessPublicationFailure.untrustedAppIdentity);
      expect(checks.updatedIds, isEmpty);
      expect(checks.createdHeads, isEmpty);
    });

    test('refuses an installation scoped beyond the repository', () async {
      final record = await attest(
        FakeGitHubSource(
          app: liveApp(
            installations: const <String>[repository, 'attacker/other'],
          ),
          submission: dispatched(highRiskEvidence()),
        ),
        FakeCheckPublisher(),
      );

      expect(record.failure, ReadinessPublicationFailure.untrustedAppIdentity);
    });

    test(
      'refuses duplicate repository objects across installation pages',
      () async {
        final record = await attest(
          FakeGitHubSource(
            app: liveApp(installations: const <String>[repository, repository]),
            submission: dispatched(highRiskEvidence()),
          ),
          FakeCheckPublisher(),
        );

        expect(
          record.failure,
          ReadinessPublicationFailure.untrustedAppIdentity,
        );
      },
    );

    test(
      'refuses forged installation identity and selection metadata',
      () async {
        for (final app in <LiveAppIdentity>[
          liveApp(installationId: 0),
          liveApp(installationAppId: readinessAppId + 1),
          liveApp(installationAppSlug: 'another-app'),
          liveApp(installationAccount: 'attacker'),
          liveApp(repositorySelection: 'all'),
        ]) {
          final record = await attest(
            FakeGitHubSource(
              app: app,
              submission: dispatched(highRiskEvidence()),
            ),
            FakeCheckPublisher(),
          );

          expect(
            record.failure,
            ReadinessPublicationFailure.untrustedAppIdentity,
          );
        }
      },
    );

    test('refuses an App holding a permission beyond its own checks', () async {
      final record = await attest(
        FakeGitHubSource(
          app: liveApp(
            permissions: const <String, String>{
              'checks': 'write',
              'contents': 'write',
            },
          ),
          submission: dispatched(highRiskEvidence()),
        ),
        FakeCheckPublisher(),
      );

      expect(record.failure, ReadinessPublicationFailure.untrustedAppIdentity);
    });

    test('refuses an App that cannot publish its own checks', () async {
      final record = await attest(
        FakeGitHubSource(
          app: liveApp(
            permissions: const <String, String>{
              'contents': 'read',
              'pull_requests': 'read',
            },
          ),
          submission: dispatched(highRiskEvidence()),
        ),
        FakeCheckPublisher(),
      );

      expect(record.failure, ReadinessPublicationFailure.untrustedAppIdentity);
    });

    test(
      'refuses an App missing either authenticated read permission',
      () async {
        for (final missing in const <String>['actions', 'statuses']) {
          final permissions = Map<String, String>.of(liveApp().permissions)
            ..remove(missing);
          final record = await attest(
            FakeGitHubSource(
              app: liveApp(permissions: permissions),
              submission: dispatched(highRiskEvidence()),
            ),
            FakeCheckPublisher(),
          );

          expect(
            record.failure,
            ReadinessPublicationFailure.untrustedAppIdentity,
            reason: missing,
          );
        }
      },
    );
  });

  group('authenticated auditor', () {
    test('rejects self-attestation by the pull-request author', () async {
      final record = await attest(
        FakeGitHubSource(
          approval: liveApproval(approver: author, requester: 'maintainer-one'),
          submission: dispatched(highRiskEvidence(evidenceAuditor: author)),
        ),
        FakeCheckPublisher(),
      );

      expect(
        record.failure,
        ReadinessPublicationFailure.selfAttestationProhibited,
      );
      expect(record.decision, ReadinessPublicationDecision.refused);
    });

    test('rejects an approver who also requested the deployment', () async {
      final record = await attest(
        FakeGitHubSource(
          approval: liveApproval(approver: auditor, requester: auditor),
          submission: dispatched(highRiskEvidence()),
        ),
        FakeCheckPublisher(),
      );

      expect(
        record.failure,
        ReadinessPublicationFailure.selfAttestationProhibited,
      );
    });

    test('rejects the retired standalone qa identity', () async {
      for (final identity in const <String>[
        'qa',
        'QA',
        'QA-Agent',
        'qa-profile',
        'qa-task',
      ]) {
        final record = await attest(
          FakeGitHubSource(
            approval: liveApproval(approver: identity),
            submission: dispatched(highRiskEvidence(evidenceAuditor: identity)),
          ),
          FakeCheckPublisher(),
        );

        expect(
          record.failure,
          ReadinessPublicationFailure.retiredQaIdentityProhibited,
          reason: identity,
        );
      }
    });

    test(
      'rejects an approver login that GitHub could not have issued',
      () async {
        for (final identity in const <String>[
          'qa_profile',
          '-qa',
          'qa--agent',
        ]) {
          final record = await attest(
            FakeGitHubSource(
              approval: liveApproval(approver: identity),
              submission: dispatched(highRiskEvidence()),
            ),
            FakeCheckPublisher(),
          );

          expect(
            record.failure,
            ReadinessPublicationFailure.unauthenticatedAuditor,
            reason: identity,
          );
        }
      },
    );

    test('rejects a declared auditor that is not the approver', () async {
      final record = await attest(
        FakeGitHubSource(
          submission: dispatched(
            highRiskEvidence(evidenceAuditor: 'someone-else'),
          ),
        ),
        FakeCheckPublisher(),
      );

      expect(
        record.failure,
        ReadinessPublicationFailure.auditorIdentityMismatch,
      );
    });

    test('rejects the pull-request author named as evidence auditor', () async {
      final record = await attest(
        FakeGitHubSource(
          submission: dispatched(highRiskEvidence(evidenceAuditor: author)),
        ),
        FakeCheckPublisher(),
      );

      expect(
        record.failure,
        ReadinessPublicationFailure.auditorIdentityMismatch,
      );
    });

    test('rejects a missing protected-environment approval', () async {
      final record = await attest(
        FakeGitHubSource(
          approvalIsNull: true,
          submission: dispatched(highRiskEvidence()),
        ),
        FakeCheckPublisher(),
      );

      expect(
        record.failure,
        ReadinessPublicationFailure.unauthenticatedAuditor,
      );
    });

    test(
      'rejects forged environment, workflow, branch, and event claims',
      () async {
        final forgeries = <String, LiveProtectedApproval>{
          'environment': liveApproval(environment: 'build'),
          'workflow': liveApproval(
            workflowPath: '.github/workflows/attacker.yml',
          ),
          'event': liveApproval(event: 'pull_request_target'),
          'branch': liveApproval(headBranch: 'attacker-branch'),
          'repository': liveApproval(repo: 'attacker/other'),
        };
        for (final entry in forgeries.entries) {
          final record = await attest(
            FakeGitHubSource(
              approval: entry.value,
              submission: dispatched(highRiskEvidence()),
            ),
            FakeCheckPublisher(),
          );

          expect(
            record.failure,
            ReadinessPublicationFailure.unauthenticatedAuditor,
            reason: entry.key,
          );
        }
      },
    );

    test(
      'rejects approval fields not bound to the exact run and candidate',
      () async {
        final submission = dispatched(highRiskEvidence());
        final forgeries = <String, LiveProtectedApproval>{
          'rerun': liveApproval(attempt: 2, evidenceDigest: submission.digest),
          'malformed workflow revision': liveApproval(
            workflowSha: 'not-a-sha',
            evidenceDigest: submission.digest,
          ),
          'malformed run revision': liveApproval(
            runHeadSha: 'not-a-sha',
            evidenceDigest: submission.digest,
          ),
          'workflow revision has invalid shape': liveApproval(
            workflowSha: '444444444444444444444444444444444444444',
            evidenceDigest: submission.digest,
          ),
          'pull request': liveApproval(
            attestedPr: prNumber + 1,
            evidenceDigest: submission.digest,
          ),
          'head': liveApproval(
            attestedHead: movedHeadSha,
            evidenceDigest: submission.digest,
          ),
          'base': liveApproval(
            attestedBase: movedHeadSha,
            evidenceDigest: submission.digest,
          ),
        };
        for (final entry in forgeries.entries) {
          final record = await attest(
            FakeGitHubSource(approval: entry.value, submission: submission),
            FakeCheckPublisher(),
          );

          expect(
            record.failure,
            ReadinessPublicationFailure.unauthenticatedAuditor,
            reason: entry.key,
          );
        }
      },
    );

    test(
      'rejects an approval whose run or digest does not bind the bytes',
      () async {
        final submission = dispatched(highRiskEvidence());
        for (final approval in <LiveProtectedApproval>[
          liveApproval(
            approvalRunId: runId + 1,
            evidenceDigest: submission.digest,
          ),
          liveApproval(
            evidenceDigest:
                'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
          ),
        ]) {
          final record = await attest(
            FakeGitHubSource(approval: approval, submission: submission),
            FakeCheckPublisher(),
          );

          expect(
            record.failure,
            ReadinessPublicationFailure.untrustedEvidenceIngress,
          );
        }
      },
    );
  });

  group('protected environment', () {
    test('refuses forged or weakened live environment configuration', () async {
      final environments = <String, LiveProtectedEnvironment>{
        'repository': liveEnvironment(repo: 'attacker/other'),
        'name': liveEnvironment(name: 'build'),
        'reviewers': liveEnvironment(hasRequiredReviewers: false),
        'self review': liveEnvironment(preventSelfReview: false),
        'protected branches': liveEnvironment(protectedBranches: true),
        'extra branch': liveEnvironment(
          branches: const <String>[defaultReadinessBranch, 'release'],
        ),
        'duplicate branch': liveEnvironment(
          branches: const <String>[
            defaultReadinessBranch,
            defaultReadinessBranch,
          ],
        ),
      };
      for (final entry in environments.entries) {
        final record = await attest(
          FakeGitHubSource(
            protectedEnvironment: entry.value,
            submission: dispatched(highRiskEvidence()),
          ),
          FakeCheckPublisher(),
        );

        expect(
          record.failure,
          ReadinessPublicationFailure.governancePrerequisitesUnavailable,
          reason: entry.key,
        );
        expect(record.checkRunId, isNull, reason: entry.key);
      }
    });
  });

  group('evidence ingress', () {
    test('refuses every ingress that is not an approved submission', () async {
      for (final ingress in EvidenceIngress.values) {
        if (ingress == EvidenceIngress.protectedEnvironmentApproval) continue;
        final record = await attest(
          FakeGitHubSource(
            submission: dispatched(highRiskEvidence(), ingress: ingress),
          ),
          FakeCheckPublisher(),
        );

        expect(
          record.failure,
          ReadinessPublicationFailure.untrustedEvidenceIngress,
          reason: ingress.name,
        );
        expect(record.decision, ReadinessPublicationDecision.refused);
      }
    });

    test('refuses duplicate-key evidence JSON', () async {
      const duplicate =
          '{"schema": "llamadart.high-risk-readiness-evidence", '
          '"schema": "llamadart.high-risk-readiness-evidence"}';
      final record = await attest(
        FakeGitHubSource(submission: dispatched(duplicate)),
        FakeCheckPublisher(),
      );

      expect(record.failure, ReadinessPublicationFailure.malformedEvidence);
    });

    test('refuses malformed evidence JSON', () async {
      final record = await attest(
        FakeGitHubSource(submission: dispatched('{"schema": ')),
        FakeCheckPublisher(),
      );

      expect(record.failure, ReadinessPublicationFailure.malformedEvidence);
    });

    test('refuses a non-object evidence document', () async {
      final record = await attest(
        FakeGitHubSource(submission: dispatched('[1, 2, 3]')),
        FakeCheckPublisher(),
      );

      expect(record.failure, ReadinessPublicationFailure.malformedEvidence);
    });
  });

  group('exact head and base binding', () {
    test('blocks stale evidence head', () async {
      final record = await attest(
        FakeGitHubSource(
          submission: dispatched(highRiskEvidence(head: movedHeadSha)),
        ),
        FakeCheckPublisher(),
      );

      expect(record.decision, ReadinessPublicationDecision.blocked);
      expect(record.failure, ReadinessPublicationFailure.evidenceRejected);
      expect(
        record.evaluatorFailureClassification,
        ReadinessFailureClassification.headMismatch,
      );
      expect(record.checkConclusion, ReadinessCheckConclusion.failure);
    });

    test('blocks stale evidence base', () async {
      final record = await attest(
        FakeGitHubSource(
          submission: dispatched(highRiskEvidence(base: movedHeadSha)),
        ),
        FakeCheckPublisher(),
      );

      expect(
        record.evaluatorFailureClassification,
        ReadinessFailureClassification.baseMismatch,
      );
    });

    test('refuses when the head moves between live reads', () async {
      final record = await attest(
        FakeGitHubSource(
          pullRequestReads: <LivePullRequest>[
            livePr(),
            livePr(head: movedHeadSha),
          ],
          submission: dispatched(highRiskEvidence()),
        ),
        FakeCheckPublisher(),
      );

      expect(record.failure, ReadinessPublicationFailure.liveStateRaced);
      expect(record.decision, ReadinessPublicationDecision.refused);
    });

    test('refuses without publishing when the head moves immediately before '
        'publication', () async {
      final checks = FakeCheckPublisher(
        seed: <ReadinessCheckRun>[
          const ReadinessCheckRun(
            id: 77,
            name: defaultReadinessCheckName,
            headSha: headSha,
            status: 'completed',
            conclusion: 'success',
            appId: readinessAppId,
            externalId: ownedExternalId,
          ),
        ],
      );
      final record = await attest(
        FakeGitHubSource(
          pullRequestReads: <LivePullRequest>[
            livePr(),
            livePr(),
            livePr(head: movedHeadSha),
          ],
          submission: dispatched(highRiskEvidence()),
        ),
        checks,
      );

      expect(record.failure, ReadinessPublicationFailure.liveStateRaced);
      expect(record.decision, ReadinessPublicationDecision.refused);
      expect(record.checkConclusion, isNull);
      expect(record.supersededCheckRunIds, isEmpty);
      expect(checks.runById(77).conclusion, 'success');
      expect(
        checks.runs.where(
          (run) => run.headSha == movedHeadSha && run.conclusion == 'success',
        ),
        isEmpty,
      );
    });

    test('refuses when the author changes between live reads', () async {
      final record = await attest(
        FakeGitHubSource(
          pullRequestReads: <LivePullRequest>[
            livePr(),
            livePr(prAuthor: 'someone-else'),
          ],
          submission: dispatched(highRiskEvidence()),
        ),
        FakeCheckPublisher(),
      );

      expect(record.failure, ReadinessPublicationFailure.liveStateRaced);
    });

    test(
      'cancels a just-written check when the base moves after write',
      () async {
        final checks = FakeCheckPublisher();
        final record = await attest(
          FakeGitHubSource(
            pullRequestReads: <LivePullRequest>[
              livePr(),
              livePr(),
              livePr(),
              livePr(),
              livePr(),
              livePr(base: movedHeadSha),
            ],
            submission: dispatched(highRiskEvidence()),
          ),
          checks,
        );

        expect(record.failure, ReadinessPublicationFailure.liveStateRaced);
        expect(record.decision, ReadinessPublicationDecision.refused);
        expect(record.checkRunId, isNull);
        expect(record.supersededCheckRunIds, <int>[5000]);
        expect(checks.runById(5000).conclusion, 'cancelled');
      },
    );

    test(
      'cancels a just-written check when the head moves after write',
      () async {
        final checks = FakeCheckPublisher();
        final record = await attest(
          FakeGitHubSource(
            pullRequestReads: <LivePullRequest>[
              livePr(),
              livePr(),
              livePr(),
              livePr(),
              livePr(),
              livePr(head: movedHeadSha),
            ],
            submission: dispatched(highRiskEvidence()),
          ),
          checks,
        );

        expect(record.failure, ReadinessPublicationFailure.liveStateRaced);
        expect(record.checkRunId, isNull);
        expect(record.supersededCheckRunIds, <int>[5000]);
        expect(checks.runById(5000).conclusion, 'cancelled');
        expect(
          checks.runs.where(
            (run) => run.headSha == movedHeadSha && run.conclusion == 'success',
          ),
          isEmpty,
        );
      },
    );

    test('refuses head check state returned for another head', () async {
      final record = await attest(
        FakeGitHubSource(
          headCheckStateSha: movedHeadSha,
          submission: dispatched(highRiskEvidence()),
        ),
        FakeCheckPublisher(),
      );

      expect(record.failure, ReadinessPublicationFailure.liveStateRaced);
    });

    test(
      'supersedes acceptance when a review thread appears before publication',
      () async {
        final checks = FakeCheckPublisher();
        final record = await attest(
          FakeGitHubSource(
            unresolvedThreadReads: const <int>[0, 1],
            submission: dispatched(highRiskEvidence()),
          ),
          checks,
        );

        expect(record.decision, ReadinessPublicationDecision.blocked);
        expect(
          record.failure,
          ReadinessPublicationFailure.unresolvedReviewThreads,
        );
        expect(record.checkConclusion, ReadinessCheckConclusion.failure);
        expect(checks.runs.single.conclusion, 'failure');
      },
    );

    test(
      'supersedes acceptance when exact-head CI becomes pending before publication',
      () async {
        final checks = FakeCheckPublisher();
        final record = await attest(
          FakeGitHubSource(
            headCheckStateReads: const <LiveHeadCheckState>[
              LiveHeadCheckState(
                headSha: headSha,
                aggregate: LiveCheckAggregate.success,
                pendingContexts: <String>[],
                failingContexts: <String>[],
              ),
              LiveHeadCheckState(
                headSha: headSha,
                aggregate: LiveCheckAggregate.pending,
                pendingContexts: <String>['late-check'],
                failingContexts: <String>[],
              ),
            ],
            submission: dispatched(highRiskEvidence()),
          ),
          checks,
        );

        expect(record.decision, ReadinessPublicationDecision.blocked);
        expect(
          record.failure,
          ReadinessPublicationFailure.headCheckStateNotGreen,
        );
        expect(record.checkConclusion, ReadinessCheckConclusion.actionRequired);
        expect(checks.runs.single.conclusion, 'action_required');
      },
    );

    test('refuses evidence bytes changed after evaluation', () async {
      final first = dispatched(highRiskEvidence());
      final changedEvidence = highRiskEvidence()
        ..['correlation_id'] = 'issue-419-attestation-changed';
      final second = dispatched(changedEvidence);
      final checks = FakeCheckPublisher();
      final record = await attest(
        FakeGitHubSource(
          submissionReads: <AuthenticatedEvidenceSubmission>[first, second],
        ),
        checks,
      );

      expect(record.decision, ReadinessPublicationDecision.refused);
      expect(
        record.failure,
        ReadinessPublicationFailure.untrustedEvidenceIngress,
      );
      expect(checks.runs, isEmpty);
    });

    test('refuses an inventory changed after evaluation', () async {
      final checks = FakeCheckPublisher();
      final record = await attest(
        FakeGitHubSource(
          inventoryReads: <List<RepositoryChange>>[
            highRiskInventory(),
            const <RepositoryChange>[
              RepositoryChange(
                path: 'CONTRIBUTING.md',
                kind: RepositoryChangeKind.modified,
              ),
              RepositoryChange(
                path: governanceTest,
                kind: RepositoryChangeKind.modified,
              ),
            ],
          ],
          submission: dispatched(highRiskEvidence()),
        ),
        checks,
      );

      expect(record.decision, ReadinessPublicationDecision.refused);
      expect(
        record.failure,
        ReadinessPublicationFailure.liveInventoryInconsistent,
      );
      expect(checks.runs, isEmpty);
    });

    test('refuses an environment weakened after evaluation', () async {
      final checks = FakeCheckPublisher();
      final record = await attest(
        FakeGitHubSource(
          protectedEnvironmentReads: <LiveProtectedEnvironment>[
            liveEnvironment(),
            liveEnvironment(preventSelfReview: false),
          ],
          submission: dispatched(highRiskEvidence()),
        ),
        checks,
      );

      expect(record.decision, ReadinessPublicationDecision.refused);
      expect(
        record.failure,
        ReadinessPublicationFailure.governancePrerequisitesUnavailable,
      );
      expect(checks.runs, isEmpty);
    });
  });

  group('deletion-aware inventory and evidence paths', () {
    test('blocks evidence citing a deleted test', () async {
      final record = await attest(
        FakeGitHubSource(
          inventory: <RepositoryChange>[
            const RepositoryChange(
              path: 'AGENTS.md',
              kind: RepositoryChangeKind.modified,
            ),
            const RepositoryChange(
              path: governanceTest,
              kind: RepositoryChangeKind.deleted,
            ),
          ],
          submission: dispatched(highRiskEvidence()),
        ),
        FakeCheckPublisher(),
      );

      expect(
        record.evaluatorFailureClassification,
        ReadinessFailureClassification.deletedEvidencePath,
      );
      expect(record.checkConclusion, ReadinessCheckConclusion.failure);
    });

    test('blocks evidence citing the old side of a rename', () async {
      final record = await attest(
        FakeGitHubSource(
          inventory: <RepositoryChange>[
            const RepositoryChange(
              path: 'AGENTS.md',
              kind: RepositoryChangeKind.modified,
            ),
            const RepositoryChange(
              path: 'test/unit/tooling/renamed_publisher_test.dart',
              previousPath: governanceTest,
              kind: RepositoryChangeKind.renamed,
            ),
          ],
          submission: dispatched(highRiskEvidence()),
        ),
        FakeCheckPublisher(),
      );

      expect(
        record.evaluatorFailureClassification,
        ReadinessFailureClassification.renamedEvidencePath,
      );
    });

    test(
      'blocks a phantom evidence path absent from the candidate tree',
      () async {
        final record = await attest(
          FakeGitHubSource(
            headPaths: const <String>{'AGENTS.md'},
            submission: dispatched(highRiskEvidence()),
          ),
          FakeCheckPublisher(),
        );

        expect(
          record.evaluatorFailureClassification,
          ReadinessFailureClassification.missingTestPath,
        );
      },
    );

    test('blocks evidence citing a test outside the exact inventory', () async {
      final record = await attest(
        FakeGitHubSource(
          submission: dispatched(
            highRiskEvidence(
              affectedTestPaths: <String>['test/unit/other_test.dart'],
            ),
          ),
        ),
        FakeCheckPublisher(),
      );

      expect(
        record.evaluatorFailureClassification,
        ReadinessFailureClassification.unchangedEvidencePath,
      );
    });

    test(
      'refuses an inventory that disagrees with the live file count',
      () async {
        final record = await attest(
          FakeGitHubSource(
            pullRequestReads: <LivePullRequest>[livePr(changedFileCount: 5)],
            submission: dispatched(highRiskEvidence()),
          ),
          FakeCheckPublisher(),
        );

        expect(
          record.failure,
          ReadinessPublicationFailure.liveInventoryInconsistent,
        );
      },
    );

    test('refuses when the paginated inventory read fails', () async {
      final record = await attest(
        FakeGitHubSource(
          inventoryReadThrows: true,
          submission: dispatched(highRiskEvidence()),
        ),
        FakeCheckPublisher(),
      );

      expect(
        record.failure,
        ReadinessPublicationFailure.liveInventoryInconsistent,
      );
    });

    test(
      'refuses malformed, duplicate, and unsupported inventory entries',
      () async {
        final inventories = <String, List<RepositoryChange>>{
          'duplicate destination': const <RepositoryChange>[
            RepositoryChange(
              path: 'AGENTS.md',
              kind: RepositoryChangeKind.modified,
            ),
            RepositoryChange(
              path: 'AGENTS.md',
              kind: RepositoryChangeKind.added,
            ),
          ],
          'rename without source': const <RepositoryChange>[
            RepositoryChange(
              path: 'AGENTS.md',
              kind: RepositoryChangeKind.renamed,
            ),
            RepositoryChange(
              path: governanceTest,
              kind: RepositoryChangeKind.modified,
            ),
          ],
          'source on modification': const <RepositoryChange>[
            RepositoryChange(
              path: 'AGENTS.md',
              previousPath: 'README.md',
              kind: RepositoryChangeKind.modified,
            ),
            RepositoryChange(
              path: governanceTest,
              kind: RepositoryChangeKind.modified,
            ),
          ],
          'parent traversal': const <RepositoryChange>[
            RepositoryChange(
              path: '../AGENTS.md',
              kind: RepositoryChangeKind.modified,
            ),
            RepositoryChange(
              path: governanceTest,
              kind: RepositoryChangeKind.modified,
            ),
          ],
          'unknown status': const <RepositoryChange>[
            RepositoryChange(
              path: 'AGENTS.md',
              kind: RepositoryChangeKind.unknown,
            ),
            RepositoryChange(
              path: governanceTest,
              kind: RepositoryChangeKind.modified,
            ),
          ],
        };
        for (final entry in inventories.entries) {
          final checks = FakeCheckPublisher();
          final record = await attest(
            FakeGitHubSource(
              inventory: entry.value,
              submission: dispatched(highRiskEvidence()),
            ),
            checks,
          );

          expect(
            record.failure,
            ReadinessPublicationFailure.liveInventoryInconsistent,
            reason: entry.key,
          );
          expect(checks.runs, isEmpty, reason: entry.key);
        }
      },
    );

    test(
      'type changes remain high risk and cannot bypass classification',
      () async {
        final inventory = <RepositoryChange>[
          const RepositoryChange(
            path: 'AGENTS.md',
            kind: RepositoryChangeKind.typeChanged,
          ),
        ];
        final record = await classify(
          FakeGitHubSource(
            pullRequestReads: <LivePullRequest>[
              livePr(changedFileCount: inventory.length),
            ],
            inventory: inventory,
          ),
          FakeCheckPublisher(),
        );

        expect(record.decision, ReadinessPublicationDecision.blocked);
        expect(
          record.failure,
          ReadinessPublicationFailure.attestationModeRequired,
        );
      },
    );
  });

  group('live merge-blocking state', () {
    test('blocks on live unresolved review threads', () async {
      final record = await attest(
        FakeGitHubSource(
          unresolvedThreads: 3,
          submission: dispatched(highRiskEvidence()),
        ),
        FakeCheckPublisher(),
      );

      expect(
        record.failure,
        ReadinessPublicationFailure.unresolvedReviewThreads,
      );
      expect(record.checkConclusion, ReadinessCheckConclusion.failure);
      expect(record.unresolvedReviewThreads, 3);
    });

    test('blocks when evidence understates unresolved threads', () async {
      final record = await attest(
        FakeGitHubSource(
          unresolvedThreads: 2,
          submission: dispatched(highRiskEvidence(unresolvedThreads: 0)),
        ),
        FakeCheckPublisher(),
      );

      expect(record.decision, ReadinessPublicationDecision.blocked);
    });

    test('rejects evidence declaring its own unresolved threads', () async {
      final record = await attest(
        FakeGitHubSource(
          submission: dispatched(highRiskEvidence(unresolvedThreads: 1)),
        ),
        FakeCheckPublisher(),
      );

      expect(
        record.evaluatorFailureClassification,
        ReadinessFailureClassification.unresolvedReviewThreads,
      );
    });

    test('blocks pending head checks with action_required', () async {
      final record = await attest(
        FakeGitHubSource(
          aggregate: LiveCheckAggregate.pending,
          pendingContexts: const <String>['Web Chat Contract'],
          submission: dispatched(highRiskEvidence()),
        ),
        FakeCheckPublisher(),
      );

      expect(
        record.failure,
        ReadinessPublicationFailure.headCheckStateNotGreen,
      );
      expect(record.checkConclusion, ReadinessCheckConclusion.actionRequired);
    });

    test('blocks failing head checks', () async {
      final record = await attest(
        FakeGitHubSource(
          aggregate: LiveCheckAggregate.failure,
          failingContexts: const <String>['ci'],
          submission: dispatched(highRiskEvidence()),
        ),
        FakeCheckPublisher(),
      );

      expect(record.checkConclusion, ReadinessCheckConclusion.failure);
    });

    test(
      'refuses internally inconsistent or ambiguous check aggregates',
      () async {
        final states = <(LiveCheckAggregate, List<String>, List<String>)>[
          (
            LiveCheckAggregate.success,
            const <String>['pending'],
            const <String>[],
          ),
          (LiveCheckAggregate.pending, const <String>[], const <String>[]),
          (LiveCheckAggregate.failure, const <String>[], const <String>[]),
          (
            LiveCheckAggregate.failure,
            const <String>[],
            const <String>['duplicate', 'duplicate'],
          ),
        ];
        for (final state in states) {
          final record = await attest(
            FakeGitHubSource(
              aggregate: state.$1,
              pendingContexts: state.$2,
              failingContexts: state.$3,
              submission: dispatched(highRiskEvidence()),
            ),
            FakeCheckPublisher(),
          );

          expect(record.failure, ReadinessPublicationFailure.invalidLiveState);
          expect(record.checkRunId, isNull);
        }
      },
    );

    test('blocks a draft pull request', () async {
      final record = await attest(
        FakeGitHubSource(
          pullRequestReads: <LivePullRequest>[livePr(draft: true)],
          submission: dispatched(highRiskEvidence()),
        ),
        FakeCheckPublisher(),
      );

      expect(record.failure, ReadinessPublicationFailure.pullRequestNotReady);
      expect(record.checkConclusion, ReadinessCheckConclusion.actionRequired);
    });

    test('refuses a closed or non-default-branch pull request', () async {
      for (final pr in <LivePullRequest>[
        livePr(state: 'closed'),
        livePr(baseRef: 'release/0.8'),
      ]) {
        final record = await attest(
          FakeGitHubSource(
            pullRequestReads: <LivePullRequest>[pr],
            submission: dispatched(highRiskEvidence()),
          ),
          FakeCheckPublisher(),
        );

        expect(record.failure, ReadinessPublicationFailure.invalidLiveState);
      }
    });

    test('refuses a pull request from another repository', () async {
      final record = await attest(
        FakeGitHubSource(
          pullRequestReads: <LivePullRequest>[livePr(repo: 'attacker/other')],
          submission: dispatched(highRiskEvidence()),
        ),
        FakeCheckPublisher(),
      );

      expect(record.failure, ReadinessPublicationFailure.repositoryMismatch);
    });

    test('refuses a mismatched pull-request number', () async {
      final record = await attest(
        FakeGitHubSource(
          pullRequestReads: <LivePullRequest>[livePr(number: 420)],
          submission: dispatched(highRiskEvidence()),
        ),
        FakeCheckPublisher(),
      );

      expect(record.failure, ReadinessPublicationFailure.pullRequestMismatch);
    });
  });

  group('governance prerequisites', () {
    test('blocks acceptance while no ruleset requires the check', () async {
      final record = await attest(
        FakeGitHubSource(
          ruleset: liveRuleset(enforcing: false),
          submission: dispatched(highRiskEvidence()),
        ),
        FakeCheckPublisher(),
      );

      expect(
        record.failure,
        ReadinessPublicationFailure.governancePrerequisitesUnavailable,
      );
      expect(record.checkConclusion, ReadinessCheckConclusion.actionRequired);
      expect(record.prerequisites.allVerified, isFalse);
      expect(record.prerequisites.missing, <String>['ruleset_enforced']);
    });

    test(
      'blocks a non-strict rule, unresolved-thread policy, or wrong App',
      () async {
        for (final ruleset in <LiveRulesetEnforcement>[
          liveRuleset(strict: false),
          liveRuleset(resolveReviewThreads: false),
          liveRuleset(integrationId: readinessAppId + 1),
        ]) {
          final record = await attest(
            FakeGitHubSource(
              ruleset: ruleset,
              submission: dispatched(highRiskEvidence()),
            ),
            FakeCheckPublisher(),
          );

          expect(
            record.failure,
            ReadinessPublicationFailure.governancePrerequisitesUnavailable,
          );
          expect(
            record.checkConclusion,
            ReadinessCheckConclusion.actionRequired,
          );
        }
      },
    );

    test('blocks malformed or ambiguous effective ruleset state', () async {
      final rulesets = <LiveRulesetEnforcement>[
        LiveRulesetEnforcement(
          defaultBranchProtected: true,
          strictRequiredStatusChecks: true,
          reviewThreadsMustBeResolved: true,
          requiredChecks: const <LiveRequiredCheck>[
            LiveRequiredCheck(
              context: defaultReadinessCheckName,
              integrationId: readinessAppId,
            ),
          ],
          rulesetNames: const <String>['duplicate', 'duplicate'],
        ),
        LiveRulesetEnforcement(
          defaultBranchProtected: true,
          strictRequiredStatusChecks: true,
          reviewThreadsMustBeResolved: true,
          requiredChecks: const <LiveRequiredCheck>[
            LiveRequiredCheck(
              context: defaultReadinessCheckName,
              integrationId: readinessAppId,
            ),
            LiveRequiredCheck(context: 'bad\u0000context', integrationId: 7),
          ],
          rulesetNames: const <String>['default-branch-protection'],
        ),
        LiveRulesetEnforcement(
          defaultBranchProtected: true,
          strictRequiredStatusChecks: true,
          reviewThreadsMustBeResolved: true,
          requiredChecks: const <LiveRequiredCheck>[
            LiveRequiredCheck(
              context: defaultReadinessCheckName,
              integrationId: readinessAppId,
            ),
            LiveRequiredCheck(
              context: defaultReadinessCheckName,
              integrationId: readinessAppId + 1,
            ),
          ],
          rulesetNames: const <String>['default-branch-protection'],
        ),
      ];
      for (final ruleset in rulesets) {
        final record = await attest(
          FakeGitHubSource(
            ruleset: ruleset,
            submission: dispatched(highRiskEvidence()),
          ),
          FakeCheckPublisher(),
        );

        expect(
          record.failure,
          ReadinessPublicationFailure.governancePrerequisitesUnavailable,
        );
        expect(record.checkConclusion, ReadinessCheckConclusion.actionRequired);
      }
    });

    test('reports the shipped repository state as fail-closed', () async {
      final status = readinessGovernanceStatus();

      expect(status['authenticated_transport_bound'], isFalse);
      expect(
        status['governance_prerequisites'],
        GovernancePrerequisites.unavailable.toJson(),
      );
      expect((status['unverified_controls']! as List<Object?>).length, 4);
    });
  });

  group('conditional classification', () {
    test('publishes a passing check for a standard-risk diff', () async {
      final source = FakeGitHubSource(
        pullRequestReads: <LivePullRequest>[livePr(changedFileCount: 1)],
        inventory: standardInventory(),
      );
      final checks = FakeCheckPublisher();

      final record = await classify(source, checks);

      expect(record.decision, ReadinessPublicationDecision.notApplicable);
      expect(record.checkConclusion, ReadinessCheckConclusion.success);
      expect(checks.createdHeads, <String>[headSha]);
      expect(source.evidenceReadCount, 0);
      expect(source.approvalReadCount, 0);
      expect(source.unresolvedThreadReadCount, 0);
      expect(source.headCheckStateReadCount, 0);
    });

    test(
      'a refused attestation cannot strand a standard-risk success',
      () async {
        final checks = FakeCheckPublisher();
        final standardSource = FakeGitHubSource(
          pullRequestReads: <LivePullRequest>[livePr(changedFileCount: 1)],
          inventory: standardInventory(),
        );
        final classified = await classify(standardSource, checks);
        final checkId = classified.checkRunId!;

        final refused = await attest(
          FakeGitHubSource(
            pullRequestReads: <LivePullRequest>[livePr(changedFileCount: 1)],
            inventory: standardInventory(),
            submission: dispatched(
              standardEvidence(),
              ingress: EvidenceIngress.pullRequestBody,
            ),
          ),
          checks,
        );

        expect(classified.decision, ReadinessPublicationDecision.notApplicable);
        expect(refused.decision, ReadinessPublicationDecision.refused);
        expect(checks.runById(checkId).conclusion, 'success');
      },
    );

    test('blocks a high-risk diff pending authenticated attestation', () async {
      final record = await classify(FakeGitHubSource(), FakeCheckPublisher());

      expect(record.decision, ReadinessPublicationDecision.blocked);
      expect(
        record.failure,
        ReadinessPublicationFailure.attestationModeRequired,
      );
      expect(record.checkConclusion, ReadinessCheckConclusion.actionRequired);
    });

    test('never accepts evidence in classification mode', () async {
      final source = FakeGitHubSource(
        submission: dispatched(highRiskEvidence()),
      );

      final record = await classify(source, FakeCheckPublisher());

      expect(record.decision, isNot(ReadinessPublicationDecision.accepted));
      expect(record.evidenceIngress, isNull);
      expect(record.evidenceDigest, isNull);
      expect(source.evidenceReadCount, 0);
      expect(source.rulesetReadCount, 0);
    });

    test('publishes a passing check for standard-risk attestation', () async {
      final record = await attest(
        FakeGitHubSource(
          pullRequestReads: <LivePullRequest>[livePr(changedFileCount: 1)],
          inventory: standardInventory(),
          submission: dispatched(standardEvidence()),
        ),
        FakeCheckPublisher(),
      );

      expect(record.decision, ReadinessPublicationDecision.notApplicable);
      expect(record.checkConclusion, ReadinessCheckConclusion.success);
      expect(
        record.evaluatorDecision,
        ReadinessDecision.standardRiskDiagnostic,
      );
    });

    test('rejects high-risk evidence declared for a standard diff', () async {
      final record = await attest(
        FakeGitHubSource(
          pullRequestReads: <LivePullRequest>[livePr(changedFileCount: 1)],
          inventory: standardInventory(),
          submission: dispatched(highRiskEvidence()),
        ),
        FakeCheckPublisher(),
      );

      expect(
        record.evaluatorFailureClassification,
        ReadinessFailureClassification.classificationMismatch,
      );
    });
  });

  group('stale check supersession', () {
    test('cancels authoritative runs left on superseded heads', () async {
      final checks = FakeCheckPublisher(
        seed: <ReadinessCheckRun>[
          const ReadinessCheckRun(
            id: 21,
            name: defaultReadinessCheckName,
            headSha: '4444444444444444444444444444444444444444',
            status: 'completed',
            conclusion: 'success',
            appId: readinessAppId,
            externalId: ownedExternalId,
          ),
          const ReadinessCheckRun(
            id: 22,
            name: defaultReadinessCheckName,
            headSha: '5555555555555555555555555555555555555555',
            status: 'in_progress',
            conclusion: null,
            appId: readinessAppId,
            externalId: ownedExternalId,
          ),
          const ReadinessCheckRun(
            id: 23,
            name: defaultReadinessCheckName,
            headSha: '6666666666666666666666666666666666666666',
            status: 'completed',
            conclusion: 'failure',
            appId: readinessAppId,
            externalId: ownedExternalId,
          ),
          const ReadinessCheckRun(
            id: 24,
            name: 'Some Other Check',
            headSha: '7777777777777777777777777777777777777777',
            status: 'completed',
            conclusion: 'success',
            appId: 999,
            externalId: 'foreign',
          ),
        ],
      );

      final record = await attest(
        FakeGitHubSource(submission: dispatched(highRiskEvidence())),
        checks,
      );

      expect(record.decision, ReadinessPublicationDecision.accepted);
      expect(record.supersededCheckRunIds, <int>[21, 22]);
      expect(checks.runById(21).conclusion, 'cancelled');
      expect(checks.runById(22).conclusion, 'cancelled');
      expect(checks.runById(23).conclusion, 'failure');
      expect(checks.runById(24).conclusion, 'success');
    });

    test(
      'an untrusted refused attempt cannot cancel an accepted run',
      () async {
        final checks = FakeCheckPublisher(
          seed: <ReadinessCheckRun>[
            const ReadinessCheckRun(
              id: 31,
              name: defaultReadinessCheckName,
              headSha: headSha,
              status: 'completed',
              conclusion: 'success',
              appId: readinessAppId,
              externalId: ownedExternalId,
            ),
          ],
        );

        final record = await attest(
          FakeGitHubSource(
            submission: dispatched(
              highRiskEvidence(),
              ingress: EvidenceIngress.pullRequestComment,
            ),
          ),
          checks,
        );

        expect(record.decision, ReadinessPublicationDecision.refused);
        expect(checks.runById(31).conclusion, 'success');
        expect(checks.updatedIds, isEmpty);
      },
    );

    test('cancels duplicate authoritative runs on the current head', () async {
      final checks = FakeCheckPublisher(
        seed: <ReadinessCheckRun>[
          const ReadinessCheckRun(
            id: 41,
            name: defaultReadinessCheckName,
            headSha: headSha,
            status: 'completed',
            conclusion: 'success',
            appId: readinessAppId,
            externalId: ownedExternalId,
          ),
          const ReadinessCheckRun(
            id: 42,
            name: defaultReadinessCheckName,
            headSha: headSha,
            status: 'in_progress',
            conclusion: null,
            appId: readinessAppId,
            externalId: ownedExternalId,
          ),
        ],
      );

      final record = await attest(
        FakeGitHubSource(submission: dispatched(highRiskEvidence())),
        checks,
      );

      expect(record.checkRunId, 42);
      expect(record.supersededCheckRunIds, contains(41));
      expect(checks.runById(41).conclusion, 'cancelled');
      expect(checks.runById(42).conclusion, 'success');
    });

    test('accepts a queued check run immediately after creation', () async {
      final checks = FakeCheckPublisher()..createdPendingStatus = 'queued';

      final record = await attest(
        FakeGitHubSource(submission: dispatched(highRiskEvidence())),
        checks,
      );

      expect(record.decision, ReadinessPublicationDecision.accepted);
      expect(record.checkRunId, 5000);
      expect(checks.updatedIds, contains(5000));
      expect(checks.runById(5000).status, 'completed');
      expect(checks.runById(5000).conclusion, 'success');
    });

    test(
      'recovers a lost create response and cancels a concurrent run',
      () async {
        final checks = FakeCheckPublisher()
          ..throwAfterNextCreate = true
          ..conflictWinner = const ReadinessCheckRun(
            id: 51,
            name: defaultReadinessCheckName,
            headSha: headSha,
            status: 'in_progress',
            conclusion: null,
            appId: readinessAppId,
            externalId: ownedExternalId,
          );

        final record = await attest(
          FakeGitHubSource(submission: dispatched(highRiskEvidence())),
          checks,
        );

        expect(record.decision, ReadinessPublicationDecision.accepted);
        expect(record.checkRunId, 5000);
        expect(checks.createdHeads, <String>[headSha]);
        expect(checks.runById(51).conclusion, 'cancelled');
        expect(checks.runById(5000).conclusion, 'success');
      },
    );

    test('never updates a same-name check owned by another App', () async {
      final checks = FakeCheckPublisher(
        seed: <ReadinessCheckRun>[
          const ReadinessCheckRun(
            id: 61,
            name: defaultReadinessCheckName,
            headSha: headSha,
            status: 'completed',
            conclusion: 'success',
            appId: 999,
            externalId: 'foreign-app-run',
          ),
        ],
      )..returnForeignRuns = true;

      final record = await attest(
        FakeGitHubSource(submission: dispatched(highRiskEvidence())),
        checks,
      );

      expect(record.decision, ReadinessPublicationDecision.refused);
      expect(
        record.failure,
        ReadinessPublicationFailure.checkPublicationFailed,
      );
      expect(record.checkRunId, isNull);
      expect(checks.runById(61).conclusion, 'success');
      expect(checks.updatedIds, isNot(contains(61)));
      expect(checks.createdHeads, isEmpty);
    });

    test('create failures never leave a passing check', () async {
      final checks = FakeCheckPublisher()..createThrows = true;

      final record = await attest(
        FakeGitHubSource(submission: dispatched(highRiskEvidence())),
        checks,
      );

      expect(
        record.failure,
        ReadinessPublicationFailure.checkPublicationFailed,
      );
      expect(checks.runs.where((run) => run.conclusion == 'success'), isEmpty);
    });

    test('update failures leave only a blocking pending run', () async {
      final checks = FakeCheckPublisher()..updateThrows = true;

      final record = await attest(
        FakeGitHubSource(submission: dispatched(highRiskEvidence())),
        checks,
      );

      expect(
        record.failure,
        ReadinessPublicationFailure.checkPublicationFailed,
      );
      expect(checks.runs.single.status, 'in_progress');
      expect(checks.runs.single.conclusion, isNull);
    });

    test('ambiguous create responses fail closed as pending', () async {
      final checks = FakeCheckPublisher()..malformedCreateResponse = true;

      final record = await attest(
        FakeGitHubSource(submission: dispatched(highRiskEvidence())),
        checks,
      );

      expect(
        record.failure,
        ReadinessPublicationFailure.checkPublicationFailed,
      );
      expect(checks.runs.single.status, 'in_progress');
      expect(checks.runs.single.conclusion, isNull);
    });

    test('malformed check status and conclusion pairs fail closed', () async {
      for (final malformed in const <ReadinessCheckRun>[
        ReadinessCheckRun(
          id: 71,
          name: defaultReadinessCheckName,
          headSha: headSha,
          status: 'completed',
          conclusion: null,
          appId: readinessAppId,
          externalId: ownedExternalId,
        ),
        ReadinessCheckRun(
          id: 72,
          name: defaultReadinessCheckName,
          headSha: headSha,
          status: 'in_progress',
          conclusion: 'success',
          appId: readinessAppId,
          externalId: ownedExternalId,
        ),
      ]) {
        final checks = FakeCheckPublisher(seed: <ReadinessCheckRun>[malformed]);
        final record = await attest(
          FakeGitHubSource(submission: dispatched(highRiskEvidence())),
          checks,
        );

        expect(
          record.failure,
          ReadinessPublicationFailure.checkPublicationFailed,
          reason: '${malformed.status}/${malformed.conclusion}',
        );
        expect(checks.updatedIds, isEmpty);
      }
    });
  });

  group('immutable trusted-revision execution', () {
    test('binds candidate-tree reads to one exact base-to-head pair', () async {
      const state = GitHubBackedRepositoryState(
        source: _UnusedSource(),
        inventory: <RepositoryChange>[],
        headSha: headSha,
        baseSha: baseSha,
      );

      expect(
        () => state.changedFiles(baseSha, movedHeadSha),
        throwsA(isA<StateError>()),
      );
      expect(
        () => state.changedFiles(movedHeadSha, headSha),
        throwsA(isA<StateError>()),
      );
      expect(
        () => state.pathIsRegularFileAt(movedHeadSha, 'AGENTS.md'),
        throwsA(isA<StateError>()),
      );
    });

    test('publisher sources never execute a process or a checkout', () {
      const sources = <String>[
        'tool/governance/readiness_publication_protocol.dart',
        'tool/governance/high_risk_readiness_publisher.dart',
        'tool/governance/high_risk_readiness_publish.dart',
      ];
      const forbidden = <String>[
        'Process.run',
        'Process.start',
        'Process.runSync',
        'Process.startSync',
        'dart:mirrors',
        'Isolate.spawnUri',
      ];

      for (final path in sources) {
        final contents = File(path).readAsStringSync();
        for (final token in forbidden) {
          expect(
            contents,
            isNot(contains(token)),
            reason: '$path must not contain $token',
          );
        }
      }
    });

    test(
      'active and inert workflows pin the workflow revision, not event SHA',
      () {
        for (final path in const <String>[
          '.github/workflows/high_risk_readiness.yml',
          'tool/governance/deploy/high_risk_readiness_classify.yml.template',
          'tool/governance/deploy/high_risk_readiness_publish.yml.template',
        ]) {
          final contents = File(path).readAsStringSync();
          expect(
            contents,
            contains(r'ref: ${{ github.workflow_sha }}'),
            reason: path,
          );
          expect(
            contents,
            isNot(contains(r'ref: ${{ github.sha }}')),
            reason: path,
          );
          expect(
            contents,
            isNot(contains('github.event.pull_request.head.sha')),
            reason: path,
          );
        }

        final runbook = File(
          'doc/high_risk_readiness_publisher.md',
        ).readAsStringSync();
        expect(
          runbook,
          contains('workflow-file SHA equal to the authenticated workflow-run'),
        );
        expect(
          runbook,
          isNot(contains('neither is required to equal the other')),
        );
      },
    );

    test('inert workflows do not conceal a broader App installation', () {
      for (final path in const <String>[
        'tool/governance/deploy/high_risk_readiness_classify.yml.template',
        'tool/governance/deploy/high_risk_readiness_publish.yml.template',
      ]) {
        final contents = File(path).readAsStringSync();
        expect(contents, isNot(contains('repositories: llamadart')));
        expect(
          contents,
          contains(r'${{ steps.app-token.outputs.installation-id }}'),
        );
        expect(contents, contains('NOT RUNNABLE'));
      }

      final classification = File(
        'tool/governance/deploy/high_risk_readiness_classify.yml.template',
      ).readAsStringSync();
      final attestation = File(
        'tool/governance/deploy/high_risk_readiness_publish.yml.template',
      ).readAsStringSync();
      expect(attestation, contains(r"github.ref != 'refs/heads/main' ||"));
      expect(attestation, contains(r'github.workflow_sha != github.sha'));
      expect(classification, contains('high-risk-readiness-classify-'));
      expect(classification, contains('cancel-in-progress: true'));
      expect(attestation, contains('high-risk-readiness-attest-'));
      expect(attestation, contains('cancel-in-progress: false'));
    });

    test('inert ruleset binds the App and keeps review threads blocking', () {
      final template =
          jsonDecode(
                File(
                  'tool/governance/deploy/readiness_ruleset.json.template',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final rules = (template['rules']! as List<dynamic>)
          .cast<Map<String, dynamic>>();
      final status = rules.singleWhere(
        (rule) => rule['type'] == 'required_status_checks',
      );
      final pullRequest = rules.singleWhere(
        (rule) => rule['type'] == 'pull_request',
      );
      final requiredChecks =
          ((status['parameters']!
                      as Map<String, dynamic>)['required_status_checks']!
                  as List<dynamic>)
              .cast<Map<String, dynamic>>();

      expect(template['enforcement'], 'disabled');
      expect(template['bypass_actors'], isEmpty);
      final ruleTypes = rules.map((rule) => rule['type']);
      expect(ruleTypes, isNot(contains('non_fast_forward')));
      expect(ruleTypes, isNot(contains('deletion')));
      expect(
        status['parameters'],
        containsPair('strict_required_status_checks_policy', true),
      );
      expect(requiredChecks.single['context'], defaultReadinessCheckName);
      expect(requiredChecks.single['integration_id'], contains('dedicated'));
      expect(
        pullRequest['parameters'],
        containsPair('required_review_thread_resolution', true),
      );
    });

    test('the publisher never reads a working directory', () async {
      final source = FakeGitHubSource(
        submission: dispatched(highRiskEvidence()),
      );
      final record = await attest(source, FakeCheckPublisher());

      expect(record.decision, ReadinessPublicationDecision.accepted);
      expect(
        File(
          'tool/governance/high_risk_readiness_publisher.dart',
        ).readAsStringSync(),
        isNot(contains('GitRepositoryStateReader')),
      );
    });
  });

  group('protocol and record contracts', () {
    test('approval grammar accepts only one exact bound attestation', () {
      const valid =
          'llamadart-high-risk-readiness/v1 pr=419 '
          'head=$headSha base=$baseSha '
          'evidence_sha256='
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      final parsed = parseProtectedApprovalAttestation(valid);

      expect(parsed.prNumber, prNumber);
      expect(parsed.headSha, headSha);
      expect(parsed.baseSha, baseSha);
      expect(parsed.evidenceDigest, hasLength(64));

      for (final invalid in <String>[
        '$valid\n',
        '$valid extra=true',
        valid.replaceFirst('pr=419', 'pr=0'),
        valid.replaceFirst('head=$headSha', 'head=caller-controlled'),
        valid.replaceFirst('evidence_sha256=', 'evidence_sha256=00 '),
        '$valid pr=419',
      ]) {
        expect(
          () => parseProtectedApprovalAttestation(invalid),
          throwsA(isA<FormatException>()),
          reason: invalid,
        );
      }
    });

    test('the endpoint contract covers every source and publisher method', () {
      final protocol = File(
        'tool/governance/readiness_publication_protocol.dart',
      ).readAsStringSync();
      final declared = RegExp(
        r'^\s{2}Future<[^>]*>\s+(\w+)\(',
        multiLine: true,
      ).allMatches(protocol).map((match) => match.group(1)!).toSet();

      expect(declared, isNotEmpty);
      expect(
        readinessSourceEndpointContract.keys.toSet(),
        containsAll(declared),
      );
      for (final endpoints in readinessSourceEndpointContract.values) {
        expect(endpoints, isNotEmpty);
      }
    });

    test(
      'the publication record schema matches the emitted document',
      () async {
        final record = await attest(
          FakeGitHubSource(submission: dispatched(highRiskEvidence())),
          FakeCheckPublisher(),
        );
        final emitted = record.toJson();
        final schema =
            jsonDecode(
                  File(
                    'tool/governance/readiness_publication_record.schema.json',
                  ).readAsStringSync(),
                )
                as Map<String, dynamic>;
        final required = (schema['required'] as List<dynamic>).cast<String>();
        final properties = (schema['properties'] as Map<String, dynamic>).keys;

        expect(emitted.keys.toSet(), required.toSet());
        expect(emitted.keys.toSet(), properties.toSet());
        expect(record.toFormattedJson(), contains('"decision": "accepted"'));
      },
    );

    test('records never carry credential-shaped values', () async {
      final record = await attest(
        FakeGitHubSource(submission: dispatched(highRiskEvidence())),
        FakeCheckPublisher(),
      );
      final serialized = record.toFormattedJson().toLowerCase();

      for (final token in const <String>[
        'token',
        'secret',
        'private_key',
        'authorization',
        'bearer',
        'ghs_',
        'ghp_',
      ]) {
        expect(serialized, isNot(contains(token)), reason: token);
      }
    });

    test('evidence text cannot enter records or check summaries', () async {
      const marker = 'ATTACKER_MARKDOWN_PAYLOAD';
      final evidence = highRiskEvidence()..['unexpected'] = '```$marker\u0000';
      final checks = FakeCheckPublisher();
      final record = await attest(
        FakeGitHubSource(submission: dispatched(evidence)),
        checks,
      );

      expect(record.failure, ReadinessPublicationFailure.evidenceRejected);
      expect(record.toFormattedJson(), isNot(contains(marker)));
      expect(checks.summaries.join('\n'), isNot(contains(marker)));
      expect(
        record.evaluatorMessage,
        contains(ReadinessFailureClassification.schemaViolation.name),
      );
    });

    test('schema encodes accepted-state structural invariants', () {
      final schema =
          jsonDecode(
                File(
                  'tool/governance/readiness_publication_record.schema.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final properties = schema['properties']! as Map<String, dynamic>;
      final definitions = schema[r'$defs']! as Map<String, dynamic>;
      final conditionals = (schema['allOf']! as List<dynamic>)
          .cast<Map<String, dynamic>>();
      final accepted = conditionals.singleWhere(
        (entry) =>
            (entry['description'] as String).startsWith('An accepted decision'),
      );
      final classification = conditionals.singleWhere(
        (entry) =>
            (entry['description'] as String).startsWith('Classification never'),
      );
      final acceptedProperties =
          (accepted['then']! as Map<String, dynamic>)['properties']!
              as Map<String, dynamic>;
      final classificationProperties =
          (classification['then']! as Map<String, dynamic>)['properties']!
              as Map<String, dynamic>;
      final digest = definitions['sha256']! as Map<String, dynamic>;
      final appIdentity = definitions['appIdentity']! as Map<String, dynamic>;
      final appProperties = appIdentity['properties']! as Map<String, dynamic>;
      final ruleset = definitions['ruleset']! as Map<String, dynamic>;
      final rulesetProperties = ruleset['properties']! as Map<String, dynamic>;

      expect(digest['pattern'], r'^[0-9a-f]{64}$');
      expect(properties['repository'], <String, dynamic>{
        'const': defaultReadinessRepository,
      });
      expect(properties['check_name'], <String, dynamic>{
        'const': defaultReadinessCheckName,
      });
      expect(properties['pr_number'], containsPair('minimum', 1));
      expect(properties, contains('protected_environment'));
      expect(appProperties, contains('installation_id'));
      expect(appProperties, contains('installation_app_slug'));
      expect(appProperties, contains('installation_app_id'));
      expect(appProperties, contains('installation_account'));
      expect(appProperties, contains('repository_selection'));
      expect(rulesetProperties, contains('strict_required_status_checks'));
      expect(rulesetProperties, contains('review_threads_must_be_resolved'));
      expect(rulesetProperties, contains('required_checks'));
      expect(
        jsonEncode(acceptedProperties['pull_request']),
        contains('"draft":{"const":false}'),
      );
      expect(
        jsonEncode(acceptedProperties['head_check_state']),
        contains('"aggregate":{"const":"success"}'),
      );
      for (final key in const <String>[
        'unresolved_review_threads',
        'head_check_state',
        'ruleset',
      ]) {
        expect(classificationProperties[key], <String, dynamic>{
          'type': 'null',
        });
      }
    });
  });
}

class _UnusedSource implements AuthenticatedGitHubSource {
  const _UnusedSource();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('the trusted adapter must not reach the network here');
}
