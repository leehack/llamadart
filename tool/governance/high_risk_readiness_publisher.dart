import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../testing/classify_high_risk_changes.dart';
import '../testing/high_risk_readiness.dart';
import 'readiness_publication_protocol.dart';

/// Repository the dedicated readiness App is scoped to.
const String defaultReadinessRepository = 'leehack/llamadart';

/// Default branch the readiness publisher is allowed to govern.
const String defaultReadinessBranch = 'main';

/// Check-run name the publisher owns exclusively.
const String defaultReadinessCheckName = 'High-Risk Readiness';

/// Slug of the dedicated GitHub App. Nothing else may publish this check.
const String defaultReadinessAppSlug = 'llamadart-high-risk-readiness';

/// Protected environment that gates the attestation mode.
const String defaultReadinessEnvironment = 'high-risk-readiness-attestation';

/// Workflow path allowed to run the attestation mode.
const String defaultReadinessWorkflowPath =
    '.github/workflows/high_risk_readiness_publish.yml';

/// Adapts the trusted evaluator's repository reads onto authenticated live
/// GitHub reads.
///
/// The evaluator is reused verbatim; only its state source changes. Nothing
/// here touches a working tree, so the publisher cannot execute a mutable PR
/// checkout even if one exists on disk. `workingDirectory` is deliberately
/// ignored for the same reason.
class GitHubBackedRepositoryState implements RepositoryStateReader {
  const GitHubBackedRepositoryState({
    required this.source,
    required this.inventory,
    required this.headSha,
    required this.baseSha,
  });

  final AuthenticatedGitHubSource source;
  final List<RepositoryChange> inventory;
  final String headSha;
  final String baseSha;

  @override
  Future<bool> commitExists(String sha, {String? workingDirectory}) =>
      source.commitExists(sha);

  @override
  Future<bool> isAncestor(
    String ancestor,
    String descendant, {
    String? workingDirectory,
  }) => source.isAncestor(ancestor, descendant);

  @override
  Future<List<RepositoryChange>> changedFiles(
    String baseSha,
    String headSha, {
    String? workingDirectory,
  }) async {
    if (baseSha != this.baseSha || headSha != this.headSha) {
      throw StateError(
        'The live inventory is bound to one exact base-to-head pair.',
      );
    }
    return inventory;
  }

  @override
  Future<bool> pathIsRegularFileAt(
    String headSha,
    String path, {
    String? workingDirectory,
  }) {
    if (headSha != this.headSha) {
      throw StateError('Candidate-tree reads are bound to the exact head.');
    }
    return source.pathIsRegularFileAt(headSha, path);
  }
}

/// Publishes the dedicated exact-head readiness check for one pull request.
///
/// Every fact is read from [source] immediately before it is used, re-read
/// under a compare-and-swap before publication, and bound into the published
/// check. Claims made by a PR body, a PR comment, a PR-authored file, a
/// workflow artifact, or a process environment variable are never trust roots.
class HighRiskReadinessPublisher {
  const HighRiskReadinessPublisher({
    required this.source,
    required this.checkPublisher,
    this.repository = defaultReadinessRepository,
    this.appSlug = defaultReadinessAppSlug,
    this.environment = defaultReadinessEnvironment,
    this.workflowPath = defaultReadinessWorkflowPath,
    this.defaultBranch = defaultReadinessBranch,
    this.checkName = defaultReadinessCheckName,
    this.clock = _defaultClock,
  });

  final AuthenticatedGitHubSource source;
  final ReadinessCheckPublisher checkPublisher;
  final String repository;
  final String appSlug;
  final String environment;
  final String workflowPath;
  final String defaultBranch;
  final String checkName;
  final DateTime Function() clock;

  static DateTime _defaultClock() => DateTime.now();

  /// Maximum permission level the dedicated App may hold.
  ///
  /// `checks: write` is the only write scope required to create and update the
  /// App's own check runs; anything beyond this table means the installation is
  /// not the reviewed dedicated App.
  static const Map<String, String> _allowedAppPermissions = <String, String>{
    'actions': 'read',
    'checks': 'write',
    'contents': 'read',
    'pull_requests': 'read',
    'metadata': 'read',
    'statuses': 'read',
  };

  static const int _summaryLimit = 4000;
  static const String _externalIdPrefix = 'llamadart-hr:v1:';

  /// Evaluates and publishes the readiness check for [prNumber].
  ///
  /// [PublicationMode.classification] runs unattended from the trusted default
  /// branch and can only publish `success` for a standard-risk diff or
  /// `action_required` for a high-risk one. [PublicationMode.attestation] is
  /// the only mode that can accept evidence, and it additionally requires an
  /// authenticated protected-environment approver.
  Future<ReadinessPublicationRecord> publish({
    required int prNumber,
    PublicationMode mode = PublicationMode.classification,
  }) async {
    final publishedAt = clock().toUtc();
    LiveAppIdentity? app;
    LivePullRequest? pullRequest;
    LiveProtectedApproval? approval;
    LiveProtectedEnvironment? protectedEnvironment;
    EvidenceIngress? ingress;
    String? evidenceDigest;
    int? evidenceRunId;
    var inventory = const <RepositoryChange>[];
    int? unresolvedThreads;
    LiveHeadCheckState? headCheckState;
    LiveRulesetEnforcement? ruleset;
    var prerequisites = GovernancePrerequisites.unavailable;
    ReadinessDecision? evaluatorDecision;
    ReadinessFailureClassification? evaluatorFailure;
    String? evaluatorMessage;

    ReadinessPublicationRecord build({
      required ReadinessPublicationDecision decision,
      required ReadinessPublicationFailure failure,
      required String message,
      ReadinessCheckConclusion? conclusion,
      int? checkRunId,
      List<int> superseded = const <int>[],
    }) => ReadinessPublicationRecord(
      publishedAt: publishedAt,
      mode: mode,
      repository: repository,
      checkName: checkName,
      prNumber: prNumber,
      decision: decision,
      failure: failure,
      message: message,
      app: app,
      pullRequest: pullRequest,
      approval: approval,
      protectedEnvironment: protectedEnvironment,
      evidenceIngress: ingress,
      evidenceDigest: evidenceDigest,
      changedFiles: inventory,
      unresolvedReviewThreads: unresolvedThreads,
      headCheckState: headCheckState,
      ruleset: ruleset,
      prerequisites: prerequisites,
      evaluatorDecision: evaluatorDecision,
      evaluatorFailureClassification: evaluatorFailure,
      evaluatorMessage: evaluatorMessage,
      checkConclusion: conclusion,
      checkRunId: checkRunId,
      supersededCheckRunIds: superseded,
    );

    ReadinessPublicationRecord refuse(
      ReadinessPublicationFailure failure,
      String message,
    ) => build(
      decision: ReadinessPublicationDecision.refused,
      failure: failure,
      message: message,
    );

    Future<ReadinessPublicationRecord?> revalidatePassingSnapshot(
      LivePullRequest head,
    ) async {
      final expectedApp = app!;
      final expectedInventory = inventory;
      final expectedApproval = approval;
      final expectedEnvironment = protectedEnvironment;
      final expectedUnresolvedThreads = unresolvedThreads;
      final expectedHeadCheckState = headCheckState;
      final expectedRuleset = ruleset;
      late final LiveAppIdentity confirmedApp;
      late final List<RepositoryChange> confirmedInventory;
      LiveProtectedApproval? confirmedApproval;
      LiveProtectedEnvironment? confirmedEnvironment;
      AuthenticatedEvidenceSubmission? confirmedSubmission;
      int? confirmedUnresolvedThreads;
      LiveHeadCheckState? confirmedHeadCheckState;
      LiveRulesetEnforcement? confirmedRuleset;
      try {
        confirmedApp = await source.readAppIdentity();
        if (mode == PublicationMode.attestation) {
          confirmedApproval = await source.readProtectedApproval();
          confirmedEnvironment = await source.readProtectedEnvironment(
            environment,
          );
          confirmedSubmission = await source.readEvidenceSubmission();
        }
        confirmedInventory = await source.readChangedFiles(
          prNumber,
          expectedCount: head.changedFileCount,
        );
        if (mode == PublicationMode.attestation) {
          confirmedUnresolvedThreads = await source
              .readUnresolvedReviewThreadCount(prNumber);
          confirmedHeadCheckState = await source.readHeadCheckState(
            head.headSha,
            excludedCheckName: checkName,
            excludedAppId: expectedApp.appId,
          );
          if (ruleset != null) {
            confirmedRuleset = await source.readRulesetEnforcement(
              defaultBranch: defaultBranch,
            );
          }
        }
      } on Object {
        return refuse(
          ReadinessPublicationFailure.liveReadFailed,
          'Authenticated live state could not be re-read immediately before '
          'a passing publication.',
        );
      }

      final appError = _validateAppIdentity(confirmedApp);
      if (appError != null || !_sameApp(expectedApp, confirmedApp)) {
        return refuse(
          ReadinessPublicationFailure.untrustedAppIdentity,
          'The authenticated App identity or installation scope changed '
          'immediately before publication.',
        );
      }
      if (confirmedInventory.length != head.changedFileCount ||
          validateRepositoryChangeInventory(
                confirmedInventory,
                requireSafePaths: true,
              ) !=
              RepositoryInventoryValidation.valid ||
          !_sameInventory(expectedInventory, confirmedInventory)) {
        return refuse(
          ReadinessPublicationFailure.liveInventoryInconsistent,
          'The exact rename- and deletion-aware inventory changed immediately '
          'before publication.',
        );
      }
      if (mode != PublicationMode.attestation) return null;

      final approvalValue = confirmedApproval;
      final environmentValue = confirmedEnvironment;
      final submissionValue = confirmedSubmission;
      final unresolved = confirmedUnresolvedThreads;
      final checkState = confirmedHeadCheckState;
      if (approvalValue == null ||
          environmentValue == null ||
          submissionValue == null ||
          unresolved == null ||
          checkState == null) {
        return refuse(
          ReadinessPublicationFailure.liveReadFailed,
          'Authenticated live state was incomplete immediately before a '
          'passing publication.',
        );
      }
      final approvalError = _validateApproval(approvalValue, head);
      if (approvalError != null ||
          !_sameApproval(expectedApproval, approvalValue)) {
        return refuse(
          ReadinessPublicationFailure.liveStateRaced,
          'The authenticated approval changed immediately before publication.',
        );
      }
      final environmentError = _validateEnvironment(environmentValue);
      if (environmentError != null ||
          !_sameEnvironment(expectedEnvironment!, environmentValue)) {
        return refuse(
          ReadinessPublicationFailure.liveStateRaced,
          'The protected environment changed immediately before publication.',
        );
      }
      if (submissionValue.ingress != ingress ||
          submissionValue.runId != evidenceRunId ||
          submissionValue.digest != evidenceDigest) {
        return refuse(
          ReadinessPublicationFailure.liveStateRaced,
          'The evidence ingress changed immediately before publication.',
        );
      }
      if (unresolved != expectedUnresolvedThreads ||
          unresolved < 0 ||
          !_sameHeadCheckState(expectedHeadCheckState!, checkState) ||
          checkState.headSha != head.headSha ||
          !_isValidHeadCheckState(checkState)) {
        return refuse(
          ReadinessPublicationFailure.liveStateRaced,
          'Review-thread or exact-head check state changed immediately before '
          'publication.',
        );
      }
      if (expectedRuleset != null &&
          (confirmedRuleset == null ||
              !_isValidRuleset(confirmedRuleset) ||
              !_sameRuleset(expectedRuleset, confirmedRuleset))) {
        return refuse(
          ReadinessPublicationFailure.liveStateRaced,
          'The effective ruleset changed immediately before publication.',
        );
      }
      return null;
    }

    Future<ReadinessPublicationRecord> publishCheck({
      required ReadinessPublicationDecision decision,
      required ReadinessPublicationFailure failure,
      required ReadinessCheckConclusion conclusion,
      required String title,
      required String message,
    }) async {
      final head = pullRequest!;
      final currentAppId = app!.appId;
      late final LivePullRequest confirmed;
      try {
        confirmed = await source.readPullRequest(prNumber);
      } on Object {
        return refuse(
          ReadinessPublicationFailure.liveReadFailed,
          'The pull request could not be re-read immediately before '
          'publication.',
        );
      }
      if (!head.matches(confirmed)) {
        return refuse(
          ReadinessPublicationFailure.liveStateRaced,
          'The pull request changed immediately before publication, so no '
          'conclusion may be bound to the stale candidate.',
        );
      }
      if (conclusion == ReadinessCheckConclusion.success) {
        final revalidation = await revalidatePassingSnapshot(confirmed);
        if (revalidation != null) return revalidation;
      }

      final superseded = <int>[];
      final externalId = _externalId(
        head: head,
        mode: mode,
        evidenceDigest: evidenceDigest,
        decision: decision,
        conclusion: conclusion,
      );
      late final ReadinessCheckRun run;
      try {
        superseded.addAll(
          await _supersedeStale(
            prNumber: prNumber,
            keepHeadSha: head.headSha,
            appId: currentAppId,
            reason:
                'Superseded by readiness evaluation of head ${head.headSha}.',
          ),
        );
        final written = await _writeCheck(
          prNumber: prNumber,
          headSha: head.headSha,
          appId: currentAppId,
          conclusion: conclusion,
          title: title,
          summary: _summary(
            title: title,
            message: message,
            head: head,
            decision: decision,
            failure: failure,
          ),
          externalId: externalId,
        );
        run = written.$1;
        superseded.addAll(written.$2);
      } on Object {
        return build(
          decision: ReadinessPublicationDecision.refused,
          failure: ReadinessPublicationFailure.checkPublicationFailed,
          message: 'The readiness check run could not be written.',
          superseded: superseded,
        );
      }
      late final LivePullRequest afterWrite;
      try {
        afterWrite = await source.readPullRequest(prNumber);
      } on Object {
        try {
          await _cancelOwnedRun(
            run,
            appId: currentAppId,
            reason: 'Live pull-request state could not be re-read after write.',
          );
          superseded.add(run.id);
        } on Object {
          return build(
            decision: ReadinessPublicationDecision.refused,
            failure: ReadinessPublicationFailure.checkPublicationFailed,
            message:
                'The pull request could not be re-read after publication and '
                'the just-written check could not be cancelled.',
            superseded: superseded,
          );
        }
        return build(
          decision: ReadinessPublicationDecision.refused,
          failure: ReadinessPublicationFailure.liveReadFailed,
          message:
              'The pull request could not be re-read after publication; the '
              'just-written check was cancelled.',
          superseded: superseded,
        );
      }
      if (!head.matches(afterWrite)) {
        try {
          await _cancelOwnedRun(
            run,
            appId: currentAppId,
            reason: 'The pull request changed immediately after publication.',
          );
          superseded.add(run.id);
        } on Object {
          return build(
            decision: ReadinessPublicationDecision.refused,
            failure: ReadinessPublicationFailure.checkPublicationFailed,
            message:
                'The pull request changed immediately after publication and '
                'the stale check could not be cancelled.',
            superseded: superseded,
          );
        }
        return build(
          decision: ReadinessPublicationDecision.refused,
          failure: ReadinessPublicationFailure.liveStateRaced,
          message:
              'The pull request changed immediately after publication; the '
              'stale check was cancelled.',
          superseded: superseded,
        );
      }
      return build(
        decision: decision,
        failure: failure,
        message: message,
        conclusion: conclusion,
        checkRunId: run.id,
        superseded: superseded,
      );
    }

    Future<ReadinessPublicationRecord?> publishBlockingLiveState() async {
      final threadCount = unresolvedThreads;
      final checks = headCheckState;
      if (threadCount == null || checks == null) {
        return refuse(
          ReadinessPublicationFailure.invalidLiveState,
          'Merge-blocking live state is incomplete.',
        );
      }
      if (threadCount != 0) {
        return publishCheck(
          decision: ReadinessPublicationDecision.blocked,
          failure: ReadinessPublicationFailure.unresolvedReviewThreads,
          conclusion: ReadinessCheckConclusion.failure,
          title: 'Unresolved review threads',
          message: 'The live unresolved review-thread count is $threadCount.',
        );
      }
      switch (checks.aggregate) {
        case LiveCheckAggregate.failure:
          return publishCheck(
            decision: ReadinessPublicationDecision.blocked,
            failure: ReadinessPublicationFailure.headCheckStateNotGreen,
            conclusion: ReadinessCheckConclusion.failure,
            title: 'Failing checks on the exact head',
            message:
                '${checks.failingContexts.length} check context(s) are failing '
                'on the exact head.',
          );
        case LiveCheckAggregate.pending:
          return publishCheck(
            decision: ReadinessPublicationDecision.blocked,
            failure: ReadinessPublicationFailure.headCheckStateNotGreen,
            conclusion: ReadinessCheckConclusion.actionRequired,
            title: 'Pending checks on the exact head',
            message:
                '${checks.pendingContexts.length} check context(s) are pending '
                'on the exact head.',
          );
        case LiveCheckAggregate.success:
          break;
      }
      if (!prerequisites.allVerified) {
        return publishCheck(
          decision: ReadinessPublicationDecision.blocked,
          failure:
              ReadinessPublicationFailure.governancePrerequisitesUnavailable,
          conclusion: ReadinessCheckConclusion.actionRequired,
          title: 'Governance prerequisites unavailable',
          message:
              'Unverified controls: ${prerequisites.missing.join(', ')}. '
              'Readiness fails closed until every control is verified live.',
        );
      }
      return null;
    }

    try {
      app = await source.readAppIdentity();
    } on Object {
      return refuse(
        ReadinessPublicationFailure.liveReadFailed,
        'The authenticated GitHub App identity could not be read.',
      );
    }
    final appError = _validateAppIdentity(app);
    if (appError != null) {
      return refuse(ReadinessPublicationFailure.untrustedAppIdentity, appError);
    }
    prerequisites = const GovernancePrerequisites(
      appIdentityVerified: true,
      protectedEnvironmentVerified: false,
      independentAuditorAuthenticated: false,
      rulesetEnforced: false,
    );

    try {
      pullRequest = await source.readPullRequest(prNumber);
    } on Object {
      return refuse(
        ReadinessPublicationFailure.liveReadFailed,
        'Live pull-request state could not be read.',
      );
    }
    final prError = _validatePullRequest(pullRequest, prNumber);
    if (prError != null) return refuse(prError.$1, prError.$2);

    if (mode == PublicationMode.attestation) {
      try {
        approval = await source.readProtectedApproval();
      } on Object {
        return refuse(
          ReadinessPublicationFailure.liveReadFailed,
          'The protected-environment approval record could not be read.',
        );
      }
      final approvalError = _validateApproval(approval, pullRequest);
      if (approvalError != null) {
        return refuse(approvalError.$1, approvalError.$2);
      }
      try {
        protectedEnvironment = await source.readProtectedEnvironment(
          environment,
        );
      } on Object {
        return refuse(
          ReadinessPublicationFailure.liveReadFailed,
          'The protected-environment configuration could not be read.',
        );
      }
      final environmentError = _validateEnvironment(protectedEnvironment);
      if (environmentError != null) {
        return refuse(
          ReadinessPublicationFailure.governancePrerequisitesUnavailable,
          environmentError,
        );
      }
      prerequisites = const GovernancePrerequisites(
        appIdentityVerified: true,
        protectedEnvironmentVerified: true,
        independentAuditorAuthenticated: false,
        rulesetEnforced: false,
      );
    }

    try {
      inventory = await source.readChangedFiles(
        prNumber,
        expectedCount: pullRequest.changedFileCount,
      );
    } on Object {
      return refuse(
        ReadinessPublicationFailure.liveInventoryInconsistent,
        'The complete rename- and deletion-aware changed-file inventory could '
        'not be read consistently.',
      );
    }
    if (inventory.length != pullRequest.changedFileCount) {
      return refuse(
        ReadinessPublicationFailure.liveInventoryInconsistent,
        'The live inventory length does not match the live changed-file count.',
      );
    }
    if (validateRepositoryChangeInventory(inventory, requireSafePaths: true) !=
        RepositoryInventoryValidation.valid) {
      return refuse(
        ReadinessPublicationFailure.liveInventoryInconsistent,
        'The live inventory contains a malformed, duplicate, or unsupported '
        'repository change.',
      );
    }

    late final LivePullRequest afterInventory;
    try {
      afterInventory = await source.readPullRequest(prNumber);
    } on Object {
      return refuse(
        ReadinessPublicationFailure.liveReadFailed,
        'Live pull-request state could not be confirmed after the inventory '
        'read.',
      );
    }
    if (!pullRequest.matches(afterInventory)) {
      return refuse(
        ReadinessPublicationFailure.liveStateRaced,
        'Head, base, author, draft state, or file count changed while the live '
        'inventory was being read.',
      );
    }

    final assessment = assessHighRiskFiles(<String>[
      for (final change in inventory) ...<String>[
        change.path,
        if (change.previousPath != null) change.previousPath!,
      ],
    ]);

    if (mode == PublicationMode.classification) {
      if (!assessment.isHighRisk) {
        return publishCheck(
          decision: ReadinessPublicationDecision.notApplicable,
          failure: ReadinessPublicationFailure.none,
          conclusion: ReadinessCheckConclusion.success,
          title: 'Standard risk: readiness attestation not required',
          message:
              'The exact live inventory reaches no high-risk surface, so the '
              'dedicated readiness check passes without an attestation.',
        );
      }
      return publishCheck(
        decision: ReadinessPublicationDecision.blocked,
        failure: ReadinessPublicationFailure.attestationModeRequired,
        conclusion: ReadinessCheckConclusion.actionRequired,
        title: 'High risk: authenticated attestation required',
        message:
            'The exact live inventory reaches high-risk surfaces '
            '(${_sorted(assessment.surfaces.map((s) => s.name)).join(', ')}). '
            'An authenticated independent audit must be published through the '
            'protected attestation environment.',
      );
    }

    try {
      unresolvedThreads = await source.readUnresolvedReviewThreadCount(
        prNumber,
      );
    } on Object {
      return refuse(
        ReadinessPublicationFailure.liveReadFailed,
        'The live unresolved review-thread count could not be read.',
      );
    }
    if (unresolvedThreads < 0) {
      unresolvedThreads = null;
      return refuse(
        ReadinessPublicationFailure.invalidLiveState,
        'The live unresolved review-thread count is not a valid count.',
      );
    }

    try {
      headCheckState = await source.readHeadCheckState(
        pullRequest.headSha,
        excludedCheckName: checkName,
        excludedAppId: app.appId,
      );
    } on Object {
      return refuse(
        ReadinessPublicationFailure.liveReadFailed,
        'Live check state for the exact head could not be read.',
      );
    }
    if (headCheckState.headSha != pullRequest.headSha) {
      return refuse(
        ReadinessPublicationFailure.liveStateRaced,
        'Live check state was returned for a different head SHA.',
      );
    }
    if (!_isValidHeadCheckState(headCheckState)) {
      return refuse(
        ReadinessPublicationFailure.invalidLiveState,
        'Live check state was malformed or internally inconsistent.',
      );
    }

    late final LivePullRequest afterReads;
    try {
      afterReads = await source.readPullRequest(prNumber);
    } on Object {
      return refuse(
        ReadinessPublicationFailure.liveReadFailed,
        'Live pull-request state could not be confirmed after the inventory '
        'read.',
      );
    }
    if (!pullRequest.matches(afterReads)) {
      return refuse(
        ReadinessPublicationFailure.liveStateRaced,
        'Head, base, author, draft state, or file count changed while live '
        'facts were being read.',
      );
    }

    late final AuthenticatedEvidenceSubmission submission;
    try {
      submission = await source.readEvidenceSubmission();
    } on Object {
      return refuse(
        ReadinessPublicationFailure.liveReadFailed,
        'The authenticated evidence submission could not be read.',
      );
    }
    ingress = submission.ingress;
    evidenceDigest = submission.digest;
    evidenceRunId = submission.runId;
    if (ingress != EvidenceIngress.protectedEnvironmentApproval) {
      return refuse(
        ReadinessPublicationFailure.untrustedEvidenceIngress,
        'The evidence bytes are not bound to an authenticated '
        'protected-environment approval.',
      );
    }
    if (submission.runId != approval!.runId ||
        approval.attestedPrNumber != pullRequest.number ||
        approval.attestedHeadSha != pullRequest.headSha ||
        approval.attestedBaseSha != pullRequest.baseSha ||
        approval.attestedEvidenceDigest != evidenceDigest) {
      return refuse(
        ReadinessPublicationFailure.untrustedEvidenceIngress,
        'The protected approval does not bind this run, pull request, exact '
        'head/base pair, and evidence digest.',
      );
    }

    late final Map<String, dynamic> evidence;
    try {
      evidence = decodeStrictJsonObject(submission.evidenceJson);
    } on Object {
      return refuse(
        ReadinessPublicationFailure.malformedEvidence,
        'The submitted evidence is not a strict, duplicate-key-free JSON '
        'object.',
      );
    }

    if (assessment.isHighRisk) {
      final audit = evidence['independent_audit'];
      final declaredAuditor = audit is Map<String, dynamic>
          ? audit['auditor_identity']
          : null;
      if (declaredAuditor is! String ||
          declaredAuditor.toLowerCase() !=
              approval.approverLogin.toLowerCase()) {
        return refuse(
          ReadinessPublicationFailure.auditorIdentityMismatch,
          'The declared auditor identity is not the authenticated '
          'protected-environment approver.',
        );
      }
    }
    prerequisites = const GovernancePrerequisites(
      appIdentityVerified: true,
      protectedEnvironmentVerified: true,
      independentAuditorAuthenticated: true,
      rulesetEnforced: false,
    );

    late final HighRiskReadinessResult result;
    try {
      result =
          await HighRiskReadinessEvaluator(
            repositoryState: GitHubBackedRepositoryState(
              source: source,
              inventory: inventory,
              headSha: pullRequest.headSha,
              baseSha: pullRequest.baseSha,
            ),
            clock: clock,
          ).evaluate(
            evidence: evidence,
            context: PullRequestContext(
              repository: pullRequest.repository,
              prNumber: pullRequest.number,
              headSha: pullRequest.headSha,
              baseSha: pullRequest.baseSha,
              author: pullRequest.author,
            ),
          );
    } on Object {
      return refuse(
        ReadinessPublicationFailure.liveReadFailed,
        'The trusted evaluator could not complete against live repository '
        'state.',
      );
    }
    evaluatorDecision = result.decision;
    evaluatorFailure = result.failureClassification;
    evaluatorMessage = _safeEvaluatorMessage(result);

    switch (result.decision) {
      case ReadinessDecision.rejected:
        return publishCheck(
          decision: ReadinessPublicationDecision.blocked,
          failure: ReadinessPublicationFailure.evidenceRejected,
          conclusion: ReadinessCheckConclusion.failure,
          title: 'Readiness evidence rejected',
          message:
              'The trusted evaluator rejected the evidence '
              '(${result.failureClassification.name}).',
        );
      case ReadinessDecision.standardRiskDiagnostic:
        return publishCheck(
          decision: ReadinessPublicationDecision.notApplicable,
          failure: ReadinessPublicationFailure.none,
          conclusion: ReadinessCheckConclusion.success,
          title: 'Standard risk: readiness attestation not required',
          message:
              'The trusted evaluator confirmed that the exact live inventory '
              'is standard risk.',
        );
      case ReadinessDecision.unverifiedPrerequisites:
        break;
    }

    try {
      ruleset = await source.readRulesetEnforcement(
        defaultBranch: defaultBranch,
      );
    } on Object {
      return refuse(
        ReadinessPublicationFailure.liveReadFailed,
        'Live ruleset enforcement state could not be read.',
      );
    }
    prerequisites = GovernancePrerequisites(
      appIdentityVerified: true,
      protectedEnvironmentVerified: true,
      independentAuditorAuthenticated: true,
      rulesetEnforced:
          _isValidRuleset(ruleset) && ruleset.requires(checkName, app.appId),
    );

    if (pullRequest.isDraft) {
      return publishCheck(
        decision: ReadinessPublicationDecision.blocked,
        failure: ReadinessPublicationFailure.pullRequestNotReady,
        conclusion: ReadinessCheckConclusion.actionRequired,
        title: 'Draft pull request',
        message:
            'A draft pull request cannot hold an accepted readiness '
            'attestation.',
      );
    }
    final initialBlockingState = await publishBlockingLiveState();
    if (initialBlockingState != null) return initialBlockingState;

    // Passing publication gets a second authenticated read of every mutable
    // trust root. The earlier reads are needed to evaluate the evidence; these
    // reads close the acceptance-to-publication window. Immutable candidate
    // tree probes need not be repeated once the exact head and inventory remain
    // unchanged.
    late final LiveAppIdentity confirmedApp;
    late final LiveProtectedApproval? confirmedApproval;
    late final LiveProtectedEnvironment confirmedEnvironment;
    late final AuthenticatedEvidenceSubmission confirmedSubmission;
    late final List<RepositoryChange> confirmedInventory;
    late final int confirmedUnresolvedThreads;
    late final LiveHeadCheckState confirmedHeadCheckState;
    late final LiveRulesetEnforcement confirmedRuleset;
    late final LivePullRequest confirmedPullRequest;
    try {
      confirmedApp = await source.readAppIdentity();
      confirmedApproval = await source.readProtectedApproval();
      confirmedEnvironment = await source.readProtectedEnvironment(environment);
      confirmedSubmission = await source.readEvidenceSubmission();
      confirmedInventory = await source.readChangedFiles(
        prNumber,
        expectedCount: pullRequest.changedFileCount,
      );
      confirmedUnresolvedThreads = await source.readUnresolvedReviewThreadCount(
        prNumber,
      );
      confirmedHeadCheckState = await source.readHeadCheckState(
        pullRequest.headSha,
        excludedCheckName: checkName,
        excludedAppId: app.appId,
      );
      confirmedRuleset = await source.readRulesetEnforcement(
        defaultBranch: defaultBranch,
      );
      confirmedPullRequest = await source.readPullRequest(prNumber);
    } on Object {
      return refuse(
        ReadinessPublicationFailure.liveReadFailed,
        'Authenticated live state could not be re-read immediately before a '
        'passing publication.',
      );
    }

    final confirmedAppError = _validateAppIdentity(confirmedApp);
    if (confirmedAppError != null || !_sameApp(app, confirmedApp)) {
      return refuse(
        ReadinessPublicationFailure.untrustedAppIdentity,
        'The authenticated App identity or installation scope changed before '
        'publication.',
      );
    }
    final confirmedApprovalError = _validateApproval(
      confirmedApproval,
      pullRequest,
    );
    if (confirmedApprovalError != null ||
        !_sameApproval(approval, confirmedApproval)) {
      return refuse(
        ReadinessPublicationFailure.unauthenticatedAuditor,
        'The authenticated approval changed before publication.',
      );
    }
    final confirmedEnvironmentError = _validateEnvironment(
      confirmedEnvironment,
    );
    if (confirmedEnvironmentError != null) {
      return refuse(
        ReadinessPublicationFailure.governancePrerequisitesUnavailable,
        'The protected environment changed before publication: '
        '$confirmedEnvironmentError',
      );
    }
    if (confirmedSubmission.ingress !=
            EvidenceIngress.protectedEnvironmentApproval ||
        confirmedSubmission.runId != submission.runId ||
        confirmedSubmission.digest != evidenceDigest) {
      return refuse(
        ReadinessPublicationFailure.untrustedEvidenceIngress,
        'The evidence ingress, run, or exact bytes changed before publication.',
      );
    }
    if (confirmedInventory.length != pullRequest.changedFileCount ||
        validateRepositoryChangeInventory(
              confirmedInventory,
              requireSafePaths: true,
            ) !=
            RepositoryInventoryValidation.valid ||
        !_sameInventory(inventory, confirmedInventory)) {
      return refuse(
        ReadinessPublicationFailure.liveInventoryInconsistent,
        'The exact rename- and deletion-aware inventory changed before '
        'publication.',
      );
    }
    if (confirmedUnresolvedThreads < 0 ||
        confirmedHeadCheckState.headSha != pullRequest.headSha ||
        !_isValidHeadCheckState(confirmedHeadCheckState)) {
      return refuse(
        ReadinessPublicationFailure.invalidLiveState,
        'Review-thread or exact-head check state was malformed during the '
        'pre-publication re-read.',
      );
    }
    if (!pullRequest.matches(confirmedPullRequest)) {
      return refuse(
        ReadinessPublicationFailure.liveStateRaced,
        'The pull request changed during the final authenticated live-state '
        'read.',
      );
    }

    app = confirmedApp;
    approval = confirmedApproval;
    protectedEnvironment = confirmedEnvironment;
    inventory = confirmedInventory;
    unresolvedThreads = confirmedUnresolvedThreads;
    headCheckState = confirmedHeadCheckState;
    ruleset = confirmedRuleset;
    prerequisites = GovernancePrerequisites(
      appIdentityVerified: true,
      protectedEnvironmentVerified: true,
      independentAuditorAuthenticated: true,
      rulesetEnforced:
          _isValidRuleset(ruleset) && ruleset.requires(checkName, app.appId),
    );

    final finalBlockingState = await publishBlockingLiveState();
    if (finalBlockingState != null) return finalBlockingState;

    return publishCheck(
      decision: ReadinessPublicationDecision.accepted,
      failure: ReadinessPublicationFailure.none,
      conclusion: ReadinessCheckConclusion.success,
      title: 'High-risk readiness accepted',
      message:
          'Authenticated independent audit by ${approval!.approverLogin} is '
          'bound to head ${pullRequest.headSha} and base '
          '${pullRequest.baseSha}.',
    );
  }

  Future<List<int>> _supersedeStale({
    required int prNumber,
    required String? keepHeadSha,
    required int appId,
    required String reason,
  }) async {
    final runs = await checkPublisher.listReadinessCheckRuns(
      prNumber: prNumber,
      checkName: checkName,
      appId: appId,
    );
    _validateOwnedRunList(runs, appId);
    final superseded = <int>[];
    for (final run in runs) {
      if (keepHeadSha != null && run.headSha == keepHeadSha) continue;
      if (!run.isAuthoritative) continue;
      await _cancelOwnedRun(run, appId: appId, reason: reason);
      superseded.add(run.id);
    }
    return superseded;
  }

  /// Writes the check for the exact head and reconciles concurrent creators.
  ///
  /// GitHub does not make `external_id` unique. The publisher therefore
  /// re-lists after every create, chooses one deterministic App-owned run, and
  /// cancels every other authoritative App-owned run on the same head.
  Future<(ReadinessCheckRun, List<int>)> _writeCheck({
    required int prNumber,
    required String headSha,
    required int appId,
    required ReadinessCheckConclusion conclusion,
    required String title,
    required String summary,
    required String externalId,
  }) async {
    Future<List<ReadinessCheckRun>> onHead() async {
      final runs = await checkPublisher.listReadinessCheckRuns(
        prNumber: prNumber,
        checkName: checkName,
        appId: appId,
      );
      _validateOwnedRunList(runs, appId);
      final owned = <ReadinessCheckRun>[];
      for (final run in runs) {
        if (run.headSha == headSha) owned.add(run);
      }
      owned.sort((a, b) => b.id.compareTo(a.id));
      return owned;
    }

    var existing = await onHead();
    if (existing.isEmpty) {
      ReadinessCheckRun? created;
      try {
        created = await checkPublisher.createCheckRun(
          name: checkName,
          headSha: headSha,
          conclusion: null,
          title: title,
          summary: summary,
          externalId: externalId,
        );
        _validatePendingCreatedRun(
          created,
          expectedAppId: appId,
          expectedHeadSha: headSha,
          expectedExternalId: externalId,
        );
      } on Object {
        final recovered = await onHead();
        final matching = recovered
            .where((run) => run.externalId == externalId)
            .toList(growable: false);
        if (matching.isEmpty) rethrow;
        created = matching.first;
      }
      existing = await onHead();
      if (!existing.any((run) => run.id == created!.id)) {
        existing = <ReadinessCheckRun>[created, ...existing]
          ..sort((a, b) => b.id.compareTo(a.id));
      }
    }

    final exactReplay = existing
        .where((run) => run.externalId == externalId)
        .toList(growable: false);
    final target = exactReplay.isNotEmpty ? exactReplay.first : existing.first;
    final duplicates = <int>[];
    for (final duplicate in existing.where((run) => run.id != target.id)) {
      if (!duplicate.isAuthoritative) continue;
      await _cancelOwnedRun(
        duplicate,
        appId: appId,
        reason: 'A duplicate readiness run for the same head was superseded.',
      );
      duplicates.add(duplicate.id);
    }
    if (target.status == 'completed' &&
        target.conclusion == conclusion.wireValue &&
        target.externalId == externalId) {
      return (target, duplicates);
    }
    try {
      final updated = await checkPublisher.updateCheckRun(
        checkRunId: target.id,
        conclusion: conclusion,
        title: title,
        summary: summary,
        externalId: externalId,
      );
      _validateWrittenRun(
        updated,
        expectedAppId: appId,
        expectedHeadSha: headSha,
        expectedExternalId: externalId,
        expectedConclusion: conclusion,
      );
      return (updated, duplicates);
    } on Object {
      final recovered = await onHead();
      final updated = recovered.where((run) => run.id == target.id).single;
      _validateWrittenRun(
        updated,
        expectedAppId: appId,
        expectedHeadSha: headSha,
        expectedExternalId: externalId,
        expectedConclusion: conclusion,
      );
      return (updated, duplicates);
    }
  }

  Future<void> _cancelOwnedRun(
    ReadinessCheckRun run, {
    required int appId,
    required String reason,
  }) async {
    _validateObservedOwnedRun(run, appId);
    final externalId = '${_externalIdPrefix}cancelled:${run.id}';
    final updated = await checkPublisher.updateCheckRun(
      checkRunId: run.id,
      conclusion: ReadinessCheckConclusion.cancelled,
      title: 'Superseded readiness check',
      summary: _fence(reason),
      externalId: externalId,
    );
    _validateWrittenRun(
      updated,
      expectedAppId: appId,
      expectedHeadSha: run.headSha,
      expectedExternalId: externalId,
      expectedConclusion: ReadinessCheckConclusion.cancelled,
    );
  }

  void _validateOwnedRunList(List<ReadinessCheckRun> runs, int appId) {
    final ids = <int>{};
    for (final run in runs) {
      if (!ids.add(run.id) || run.name != checkName || run.appId != appId) {
        throw const FormatException(
          'GitHub returned duplicate or incorrectly filtered check runs.',
        );
      }
      _validateObservedOwnedRun(run, appId);
    }
  }

  void _validateObservedOwnedRun(ReadinessCheckRun run, int appId) {
    if (run.id < 1 ||
        run.name != checkName ||
        run.appId != appId ||
        !isExactSha(run.headSha) ||
        !const {'queued', 'in_progress', 'completed'}.contains(run.status) ||
        !const {
          null,
          'success',
          'failure',
          'neutral',
          'cancelled',
          'skipped',
          'timed_out',
          'action_required',
          'stale',
          'startup_failure',
        }.contains(run.conclusion) ||
        !run.externalId.startsWith(_externalIdPrefix) ||
        (run.status == 'completed') != (run.conclusion != null)) {
      throw const FormatException(
        'GitHub returned an ambiguous readiness check-run response.',
      );
    }
  }

  void _validateWrittenRun(
    ReadinessCheckRun run, {
    required int expectedAppId,
    required String expectedHeadSha,
    required String expectedExternalId,
    required ReadinessCheckConclusion expectedConclusion,
  }) {
    _validateObservedOwnedRun(run, expectedAppId);
    if (run.headSha != expectedHeadSha ||
        run.externalId != expectedExternalId ||
        run.status != 'completed' ||
        run.conclusion != expectedConclusion.wireValue) {
      throw const FormatException(
        'GitHub did not confirm the exact requested check-run state.',
      );
    }
  }

  void _validatePendingCreatedRun(
    ReadinessCheckRun run, {
    required int expectedAppId,
    required String expectedHeadSha,
    required String expectedExternalId,
  }) {
    _validateObservedOwnedRun(run, expectedAppId);
    if (run.headSha != expectedHeadSha ||
        run.externalId != expectedExternalId ||
        !const {'queued', 'in_progress'}.contains(run.status) ||
        run.conclusion != null) {
      throw const FormatException(
        'GitHub did not confirm the exact pending check-run state.',
      );
    }
  }

  String? _validateAppIdentity(LiveAppIdentity app) {
    if (app.slug != appSlug) {
      return 'The authenticated App is not the dedicated readiness App.';
    }
    if (app.appId < 1) {
      return 'The authenticated App reported an invalid application id.';
    }
    final separator = repository.indexOf('/');
    if (separator < 1 || separator == repository.length - 1) {
      return 'The configured readiness repository is malformed.';
    }
    final expectedAccount = repository.substring(0, separator);
    if (app.installationId < 1 ||
        app.installationAppId != app.appId ||
        app.installationAppSlug != app.slug ||
        app.installationAccount != expectedAccount ||
        app.repositorySelection != 'selected') {
      return 'The authenticated installation record does not belong to the '
          'dedicated App, account, and selected-repository scope.';
    }
    if (app.installationRepositories.toSet().length !=
            app.installationRepositories.length ||
        app.installationRepositories.length != 1 ||
        !app.installationRepositories.contains(repository)) {
      return 'The App installation must cover exactly $repository.';
    }
    if (app.permissions.length != _allowedAppPermissions.length ||
        !_allowedAppPermissions.entries.every(
          (entry) => app.permissions[entry.key] == entry.value,
        )) {
      return 'The App permission set does not exactly match the reviewed '
          'read-only plus own-checks scope.';
    }
    return null;
  }

  (ReadinessPublicationFailure, String)? _validatePullRequest(
    LivePullRequest pr,
    int prNumber,
  ) {
    if (pr.repository != repository) {
      return (
        ReadinessPublicationFailure.repositoryMismatch,
        'Live pull-request state belongs to a different repository.',
      );
    }
    if (pr.number != prNumber) {
      return (
        ReadinessPublicationFailure.pullRequestMismatch,
        'Live pull-request state belongs to a different pull request.',
      );
    }
    if (!isExactSha(pr.headSha) ||
        !isExactSha(pr.baseSha) ||
        pr.headSha == pr.baseSha) {
      return (
        ReadinessPublicationFailure.invalidLiveState,
        'Live head and base must be distinct exact SHA-1 values.',
      );
    }
    if (!isGitHubLogin(pr.author)) {
      return (
        ReadinessPublicationFailure.invalidLiveState,
        'The live pull-request author is not a valid GitHub login.',
      );
    }
    if (pr.baseRef != defaultBranch) {
      return (
        ReadinessPublicationFailure.invalidLiveState,
        'Readiness publication is restricted to $defaultBranch pull requests.',
      );
    }
    if (pr.state != 'open') {
      return (
        ReadinessPublicationFailure.invalidLiveState,
        'Readiness publication is restricted to open pull requests.',
      );
    }
    if (pr.changedFileCount < 1) {
      return (
        ReadinessPublicationFailure.invalidLiveState,
        'The live changed-file count is empty.',
      );
    }
    return null;
  }

  (ReadinessPublicationFailure, String)? _validateApproval(
    LiveProtectedApproval? approval,
    LivePullRequest pr,
  ) {
    if (approval == null) {
      return (
        ReadinessPublicationFailure.unauthenticatedAuditor,
        'No protected-environment approval authenticates this attestation.',
      );
    }
    if (approval.repository != repository ||
        approval.environment != environment ||
        approval.workflowPath != workflowPath ||
        !isExactSha(approval.workflowSha) ||
        !isExactSha(approval.headSha) ||
        approval.workflowSha != approval.headSha ||
        approval.event != 'workflow_dispatch' ||
        approval.headBranch != defaultBranch ||
        approval.runId < 1 ||
        approval.runAttempt != 1 ||
        approval.attestedPrNumber != pr.number ||
        approval.attestedHeadSha != pr.headSha ||
        approval.attestedBaseSha != pr.baseSha ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(approval.attestedEvidenceDigest)) {
      return (
        ReadinessPublicationFailure.unauthenticatedAuditor,
        'The approval is not an exact first-attempt deployment of the trusted '
            '$workflowPath revision on $defaultBranch, bound to this pull '
            'request and exact head/base pair.',
      );
    }
    if (!isGitHubLogin(approval.approverLogin) ||
        !isGitHubLogin(approval.requesterLogin)) {
      return (
        ReadinessPublicationFailure.unauthenticatedAuditor,
        'The approval does not carry valid authenticated approver and '
            'requester logins.',
      );
    }
    if (approval.approverLogin.toLowerCase() ==
        approval.requesterLogin.toLowerCase()) {
      return (
        ReadinessPublicationFailure.selfAttestationProhibited,
        'The attestation requester also approved it; the protected '
            'environment must prevent self-review.',
      );
    }
    if (approval.approverLogin.toLowerCase() == pr.author.toLowerCase()) {
      return (
        ReadinessPublicationFailure.selfAttestationProhibited,
        'The authenticated approver is the pull-request author.',
      );
    }
    if (isRetiredQaIdentity(approval.approverLogin)) {
      return (
        ReadinessPublicationFailure.retiredQaIdentityProhibited,
        'The standalone qa identity is retired and cannot authenticate an '
            'attestation.',
      );
    }
    return null;
  }

  String? _validateEnvironment(LiveProtectedEnvironment value) {
    if (value.repository != repository || value.name != environment) {
      return 'The live environment state belongs to a different repository '
          'or environment.';
    }
    if (!value.hasRequiredReviewers || !value.preventSelfReview) {
      return 'The attestation environment must require reviewers and prevent '
          'self-review.';
    }
    if (!value.allowsOnly(defaultBranch)) {
      return 'The attestation environment must allow deployments from only '
          '$defaultBranch.';
    }
    return null;
  }

  bool _isValidHeadCheckState(LiveHeadCheckState value) {
    bool validContexts(List<String> contexts) =>
        contexts.toSet().length == contexts.length &&
        contexts.every(
          (context) =>
              context.isNotEmpty &&
              context == context.trim() &&
              context.length <= 255 &&
              !RegExp(r'[\x00-\x1f\x7f]').hasMatch(context),
        );
    if (!validContexts(value.pendingContexts) ||
        !validContexts(value.failingContexts)) {
      return false;
    }
    return switch (value.aggregate) {
      LiveCheckAggregate.success =>
        value.pendingContexts.isEmpty && value.failingContexts.isEmpty,
      LiveCheckAggregate.pending =>
        value.pendingContexts.isNotEmpty && value.failingContexts.isEmpty,
      LiveCheckAggregate.failure => value.failingContexts.isNotEmpty,
    };
  }

  bool _isValidRuleset(LiveRulesetEnforcement value) =>
      value.rulesetNames.isNotEmpty &&
      value.rulesetNames.toSet().length == value.rulesetNames.length &&
      value.rulesetNames.every(
        (name) =>
            name.isNotEmpty &&
            name == name.trim() &&
            name.length <= 255 &&
            !RegExp(r'[\x00-\x1f\x7f]').hasMatch(name),
      ) &&
      value.requiredChecks.map((check) => check.context).toSet().length ==
          value.requiredChecks.length &&
      value.requiredChecks.every(
        (check) =>
            check.context.isNotEmpty &&
            check.context == check.context.trim() &&
            check.context.length <= 255 &&
            !RegExp(r'[\x00-\x1f\x7f]').hasMatch(check.context) &&
            check.integrationId > 0,
      );

  String _externalId({
    required LivePullRequest head,
    required PublicationMode mode,
    required String? evidenceDigest,
    required ReadinessPublicationDecision decision,
    required ReadinessCheckConclusion conclusion,
  }) {
    final material =
        '$repository|${head.number}|${head.headSha}|${head.baseSha}|'
        '${mode.name}|${evidenceDigest ?? 'none'}|${decision.name}|'
        '${conclusion.wireValue}';
    final digest = sha256.convert(utf8.encode(material)).toString();
    return '$_externalIdPrefix${mode.name}:$digest';
  }

  static String _safeEvaluatorMessage(HighRiskReadinessResult result) =>
      switch (result.decision) {
        ReadinessDecision.rejected =>
          'The trusted evaluator rejected the submitted evidence '
              '(${result.failureClassification.name}).',
        ReadinessDecision.standardRiskDiagnostic =>
          'The trusted evaluator classified the exact inventory as standard '
              'risk.',
        ReadinessDecision.unverifiedPrerequisites =>
          'The trusted evaluator found the high-risk evidence internally '
              'consistent; external governance remains publisher-owned.',
      };

  String _summary({
    required String title,
    required String message,
    required LivePullRequest head,
    required ReadinessPublicationDecision decision,
    required ReadinessPublicationFailure failure,
  }) {
    final lines = <String>[
      'repository: ${head.repository}',
      'pull_request: ${head.number}',
      'pr_author: ${head.author}',
      'head_sha: ${head.headSha}',
      'base_sha: ${head.baseSha}',
      'decision: ${decision.name}',
      'failure_classification: ${failure.name}',
    ];
    return '$title\n\n${_fence(lines.join('\n'))}\n\n${_fence(message)}';
  }

  /// Wraps operator-visible diagnostics so evidence-derived text cannot inject
  /// Markdown or shell-looking content into a check summary.
  static String _fence(String value) {
    final sanitized = value
        .replaceAll(RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]'), ' ')
        .replaceAll('`', "'");
    final clipped = sanitized.length > _summaryLimit
        ? '${sanitized.substring(0, _summaryLimit)}…'
        : sanitized;
    return '```text\n$clipped\n```';
  }

  static bool _sameApp(LiveAppIdentity left, LiveAppIdentity right) =>
      jsonEncode(left.toJson()) == jsonEncode(right.toJson());

  static bool _sameApproval(
    LiveProtectedApproval? left,
    LiveProtectedApproval? right,
  ) => jsonEncode(left?.toJson()) == jsonEncode(right?.toJson());

  static bool _sameEnvironment(
    LiveProtectedEnvironment left,
    LiveProtectedEnvironment right,
  ) => jsonEncode(left.toJson()) == jsonEncode(right.toJson());

  static bool _sameHeadCheckState(
    LiveHeadCheckState left,
    LiveHeadCheckState right,
  ) =>
      left.headSha == right.headSha &&
      left.aggregate == right.aggregate &&
      _sameStringList(left.pendingContexts, right.pendingContexts) &&
      _sameStringList(left.failingContexts, right.failingContexts);

  static bool _sameRuleset(
    LiveRulesetEnforcement left,
    LiveRulesetEnforcement right,
  ) {
    if (left.defaultBranchProtected != right.defaultBranchProtected ||
        left.strictRequiredStatusChecks != right.strictRequiredStatusChecks ||
        left.reviewThreadsMustBeResolved != right.reviewThreadsMustBeResolved) {
      return false;
    }
    List<String> requiredChecks(LiveRulesetEnforcement value) =>
        value.requiredChecks.map((check) => jsonEncode(check.toJson())).toList()
          ..sort();
    return _sameStringList(left.rulesetNames, right.rulesetNames) &&
        _sameStringList(requiredChecks(left), requiredChecks(right));
  }

  static bool _sameStringList(List<String> left, List<String> right) {
    final leftValues = left.toList()..sort();
    final rightValues = right.toList()..sort();
    if (leftValues.length != rightValues.length) return false;
    for (var index = 0; index < leftValues.length; index++) {
      if (leftValues[index] != rightValues[index]) return false;
    }
    return true;
  }

  static bool _sameInventory(
    List<RepositoryChange> left,
    List<RepositoryChange> right,
  ) {
    List<String> canonical(List<RepositoryChange> changes) =>
        changes.map((change) => jsonEncode(change.toJson())).toList()..sort();
    final leftValues = canonical(left);
    final rightValues = canonical(right);
    if (leftValues.length != rightValues.length) return false;
    for (var index = 0; index < leftValues.length; index++) {
      if (leftValues[index] != rightValues[index]) return false;
    }
    return true;
  }

  static List<String> _sorted(Iterable<String> values) =>
      values.toList(growable: false)..sort();
}
