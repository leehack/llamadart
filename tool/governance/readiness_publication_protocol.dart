import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../testing/high_risk_readiness.dart';

/// Trigger that produced a readiness publication attempt.
///
/// `classification` runs automatically from the trusted default branch and can
/// never publish a passing conclusion for a high-risk diff. `attestation` runs
/// only behind the protected environment and is the sole mode able to consume
/// authenticated independent-audit evidence.
enum PublicationMode { classification, attestation }

/// Outcome of one publication attempt.
enum ReadinessPublicationDecision {
  /// High-risk evidence was authenticated and the check was published passing.
  accepted,

  /// The exact diff is standard risk; the dedicated check was published passing
  /// so a required-check configuration cannot strand standard-risk PRs.
  notApplicable,

  /// A check was published with a blocking conclusion.
  blocked,

  /// Nothing could be trusted enough to mutate any check run.
  refused,
}

/// Stable failure classification emitted by the publisher.
enum ReadinessPublicationFailure {
  none,
  untrustedAppIdentity,
  untrustedEvidenceIngress,
  unauthenticatedAuditor,
  auditorIdentityMismatch,
  selfAttestationProhibited,
  retiredQaIdentityProhibited,
  repositoryMismatch,
  pullRequestMismatch,
  invalidLiveState,
  liveInventoryInconsistent,
  liveStateRaced,
  malformedEvidence,
  evidenceRejected,
  unresolvedReviewThreads,
  headCheckStateNotGreen,
  pullRequestNotReady,
  governancePrerequisitesUnavailable,
  attestationModeRequired,
  checkPublicationFailed,
  liveReadFailed,
}

/// Conclusion written to the dedicated readiness check run.
enum ReadinessCheckConclusion {
  success('success'),
  failure('failure'),
  actionRequired('action_required'),
  cancelled('cancelled');

  const ReadinessCheckConclusion(this.wireValue);

  /// Value accepted by the GitHub check-runs API.
  final String wireValue;
}

/// Provenance of an evidence document, derived from authenticated live reads.
///
/// Only [protectedEnvironmentApproval] is an acceptable trust root. The other
/// values exist so a refusal can name the rejected ingress instead of silently
/// discarding it.
enum EvidenceIngress {
  /// Workflow-dispatch bytes whose full SHA-256 digest and exact PR/head/base
  /// tuple were authenticated in the protected-environment approval record.
  protectedEnvironmentApproval,
  pullRequestBody,
  pullRequestComment,
  pullRequestFile,
  workflowArtifact,
  processEnvironment,
  unknown,
}

/// Identity and installation scope of the authenticated GitHub App.
class LiveAppIdentity {
  const LiveAppIdentity({
    required this.slug,
    required this.appId,
    required this.installationId,
    required this.installationAppSlug,
    required this.installationAppId,
    required this.installationAccount,
    required this.repositorySelection,
    required this.installationRepositories,
    required this.permissions,
  });

  final String slug;
  final int appId;
  final int installationId;
  final String installationAppSlug;
  final int installationAppId;
  final String installationAccount;
  final String repositorySelection;
  final List<String> installationRepositories;
  final Map<String, String> permissions;

  Map<String, Object?> toJson() => <String, Object?>{
    'slug': slug,
    'app_id': appId,
    'installation_id': installationId,
    'installation_app_slug': installationAppSlug,
    'installation_app_id': installationAppId,
    'installation_account': installationAccount,
    'repository_selection': repositorySelection,
    'installation_repositories': installationRepositories.toList()..sort(),
    'permissions': <String, Object?>{
      for (final key in permissions.keys.toList()..sort())
        key: permissions[key],
    },
  };
}

/// Live pull-request facts read immediately before a decision is made.
class LivePullRequest {
  const LivePullRequest({
    required this.repository,
    required this.number,
    required this.author,
    required this.headSha,
    required this.baseSha,
    required this.baseRef,
    required this.state,
    required this.isDraft,
    required this.changedFileCount,
  });

  final String repository;
  final int number;
  final String author;
  final String headSha;
  final String baseSha;
  final String baseRef;
  final String state;
  final bool isDraft;
  final int changedFileCount;

  /// Whether two live reads describe the same immutable candidate.
  ///
  /// Any difference invalidates every fact gathered between the two reads, so
  /// the publisher treats it as a lost compare-and-swap rather than continuing
  /// with a partially refreshed snapshot.
  bool matches(LivePullRequest other) =>
      repository == other.repository &&
      number == other.number &&
      author == other.author &&
      headSha == other.headSha &&
      baseSha == other.baseSha &&
      baseRef == other.baseRef &&
      state == other.state &&
      isDraft == other.isDraft &&
      changedFileCount == other.changedFileCount;

  Map<String, Object?> toJson() => <String, Object?>{
    'repository': repository,
    'pr_number': number,
    'pr_author': author,
    'head_sha': headSha,
    'base_sha': baseSha,
    'base_ref': baseRef,
    'state': state,
    'draft': isDraft,
    'changed_file_count': changedFileCount,
  };
}

/// Authenticated protected-environment deployment approval.
class LiveProtectedApproval {
  const LiveProtectedApproval({
    required this.repository,
    required this.runId,
    required this.runAttempt,
    required this.workflowPath,
    required this.workflowSha,
    required this.event,
    required this.headBranch,
    required this.headSha,
    required this.environment,
    required this.approverLogin,
    required this.requesterLogin,
    required this.attestedPrNumber,
    required this.attestedHeadSha,
    required this.attestedBaseSha,
    required this.attestedEvidenceDigest,
  });

  final String repository;
  final int runId;
  final int runAttempt;
  final String workflowPath;

  /// Immutable commit resolved for the top-level workflow file.
  ///
  /// The reviewed publisher workflow is not reusable, so the authenticated
  /// workflow-run response must bind this to the same `main` commit as
  /// [headSha]. A caller-provided `GITHUB_WORKFLOW_SHA` is not authoritative.
  final String workflowSha;
  final String event;
  final String headBranch;
  final String headSha;
  final String environment;
  final String approverLogin;
  final String requesterLogin;
  final int attestedPrNumber;
  final String attestedHeadSha;
  final String attestedBaseSha;
  final String attestedEvidenceDigest;

  Map<String, Object?> toJson() => <String, Object?>{
    'repository': repository,
    'run_id': runId,
    'run_attempt': runAttempt,
    'workflow_path': workflowPath,
    'workflow_sha': workflowSha,
    'event': event,
    'head_branch': headBranch,
    'head_sha': headSha,
    'environment': environment,
    'approver_login': approverLogin,
    'requester_login': requesterLogin,
    'attested_pr_number': attestedPrNumber,
    'attested_head_sha': attestedHeadSha,
    'attested_base_sha': attestedBaseSha,
    'attested_evidence_digest': attestedEvidenceDigest,
  };
}

/// Exact fields encoded in one protected-environment approval comment.
class ProtectedApprovalAttestation {
  const ProtectedApprovalAttestation({
    required this.prNumber,
    required this.headSha,
    required this.baseSha,
    required this.evidenceDigest,
  });

  final int prNumber;
  final String headSha;
  final String baseSha;
  final String evidenceDigest;
}

/// Parses the only accepted protected-environment approval comment grammar.
///
/// The future GitHub adapter must pass the authenticated approval comment from
/// the Actions approvals API through this parser. Workflow inputs and process
/// environment values are not substitutes for that API response.
ProtectedApprovalAttestation parseProtectedApprovalAttestation(String comment) {
  final match = RegExp(
    r'^llamadart-high-risk-readiness/v1 '
    r'pr=([1-9][0-9]*) '
    r'head=([0-9a-f]{40}) '
    r'base=([0-9a-f]{40}) '
    r'evidence_sha256=([0-9a-f]{64})$',
  ).firstMatch(comment);
  if (match == null) {
    throw const FormatException(
      'The approval comment does not match the readiness attestation grammar.',
    );
  }
  final prNumber = int.tryParse(match.group(1)!);
  if (prNumber == null || prNumber < 1) {
    throw const FormatException(
      'The approval comment contains an invalid pull-request number.',
    );
  }
  return ProtectedApprovalAttestation(
    prNumber: prNumber,
    headSha: match.group(2)!,
    baseSha: match.group(3)!,
    evidenceDigest: match.group(4)!,
  );
}

/// Live configuration of the protected attestation environment.
class LiveProtectedEnvironment {
  const LiveProtectedEnvironment({
    required this.repository,
    required this.name,
    required this.hasRequiredReviewers,
    required this.preventSelfReview,
    required this.protectedBranches,
    required this.customBranchPolicies,
  });

  final String repository;
  final String name;
  final bool hasRequiredReviewers;
  final bool preventSelfReview;
  final bool protectedBranches;
  final List<String> customBranchPolicies;

  /// Whether only [branch] is allowed to deploy to this environment.
  bool allowsOnly(String branch) =>
      !protectedBranches &&
      customBranchPolicies.length == 1 &&
      customBranchPolicies.contains(branch);

  Map<String, Object?> toJson() => <String, Object?>{
    'repository': repository,
    'name': name,
    'has_required_reviewers': hasRequiredReviewers,
    'prevent_self_review': preventSelfReview,
    'protected_branches': protectedBranches,
    'custom_branch_policies': customBranchPolicies.toList()..sort(),
  };
}

/// Aggregate CI state observed on the exact head SHA.
enum LiveCheckAggregate { success, pending, failure }

/// Check and status state for one exact head SHA.
class LiveHeadCheckState {
  const LiveHeadCheckState({
    required this.headSha,
    required this.aggregate,
    required this.pendingContexts,
    required this.failingContexts,
  });

  final String headSha;
  final LiveCheckAggregate aggregate;
  final List<String> pendingContexts;
  final List<String> failingContexts;

  Map<String, Object?> toJson() => <String, Object?>{
    'head_sha': headSha,
    'aggregate': aggregate.name,
    'pending_contexts': pendingContexts,
    'failing_contexts': failingContexts,
  };
}

/// One required status-check binding returned by the effective rules API.
class LiveRequiredCheck {
  const LiveRequiredCheck({required this.context, required this.integrationId});

  final String context;
  final int integrationId;

  Map<String, Object?> toJson() => <String, Object?>{
    'context': context,
    'integration_id': integrationId,
  };
}

/// Live repository ruleset state for the default branch.
class LiveRulesetEnforcement {
  const LiveRulesetEnforcement({
    required this.defaultBranchProtected,
    required this.strictRequiredStatusChecks,
    required this.reviewThreadsMustBeResolved,
    required this.requiredChecks,
    required this.rulesetNames,
  });

  final bool defaultBranchProtected;
  final bool strictRequiredStatusChecks;
  final bool reviewThreadsMustBeResolved;
  final List<LiveRequiredCheck> requiredChecks;
  final List<String> rulesetNames;

  /// Whether an active ruleset makes [checkName] required on the default
  /// branch and binds it to [appId].
  bool requires(String checkName, int appId) {
    final matching = requiredChecks
        .where((check) => check.context == checkName)
        .toList(growable: false);
    return defaultBranchProtected &&
        strictRequiredStatusChecks &&
        reviewThreadsMustBeResolved &&
        matching.length == 1 &&
        matching.single.integrationId == appId;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'default_branch_protected': defaultBranchProtected,
    'strict_required_status_checks': strictRequiredStatusChecks,
    'review_threads_must_be_resolved': reviewThreadsMustBeResolved,
    'required_checks':
        (requiredChecks.toList()..sort((a, b) {
              final byContext = a.context.compareTo(b.context);
              return byContext != 0
                  ? byContext
                  : a.integrationId.compareTo(b.integrationId);
            }))
            .map((check) => check.toJson())
            .toList(),
    'ruleset_names': rulesetNames,
  };
}

/// Evidence document plus the provenance the App was able to authenticate.
class AuthenticatedEvidenceSubmission {
  const AuthenticatedEvidenceSubmission({
    required this.ingress,
    required this.runId,
    required this.evidenceJson,
  });

  final EvidenceIngress ingress;
  final int runId;
  final String evidenceJson;

  /// Digest of the exact submitted bytes, used for idempotency and audit.
  ///
  /// The document itself is never copied into operator output, so a submission
  /// cannot smuggle attacker-controlled text into logs or check summaries.
  String get digest => sha256.convert(utf8.encode(evidenceJson)).toString();
}

/// Read-only, App-authenticated access to live GitHub facts.
///
/// Every method must resolve its answer from the authenticated API. No
/// implementation may consult PR bodies, PR comments, PR-authored files,
/// workflow artifacts, or caller-provided environment values for facts.
abstract interface class AuthenticatedGitHubSource {
  Future<LiveAppIdentity> readAppIdentity();

  Future<LivePullRequest> readPullRequest(int prNumber);

  Future<List<RepositoryChange>> readChangedFiles(
    int prNumber, {
    required int expectedCount,
  });

  Future<int> readUnresolvedReviewThreadCount(int prNumber);

  Future<LiveHeadCheckState> readHeadCheckState(
    String headSha, {
    required String excludedCheckName,
    required int excludedAppId,
  });

  Future<LiveProtectedApproval?> readProtectedApproval();

  Future<LiveProtectedEnvironment> readProtectedEnvironment(String name);

  Future<LiveRulesetEnforcement> readRulesetEnforcement({
    required String defaultBranch,
  });

  Future<AuthenticatedEvidenceSubmission> readEvidenceSubmission();

  Future<bool> commitExists(String sha);

  Future<bool> isAncestor(String ancestor, String descendant);

  Future<bool> pathIsRegularFileAt(String headSha, String path);
}

/// One readiness check run observed on the repository.
class ReadinessCheckRun {
  const ReadinessCheckRun({
    required this.id,
    required this.name,
    required this.headSha,
    required this.status,
    required this.conclusion,
    required this.appId,
    required this.externalId,
  });

  final int id;
  final String name;
  final String headSha;
  final String status;
  final String? conclusion;
  final int appId;
  final String externalId;

  /// Whether this run still retains authority over merge readiness.
  ///
  /// Pending (queued or in-progress) and passing-shaped runs retain authority,
  /// so they must be superseded whenever the candidate they describe is no
  /// longer current.
  bool get isAuthoritative =>
      conclusion == null ||
      conclusion == 'success' ||
      conclusion == 'neutral' ||
      conclusion == 'skipped';

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'head_sha': headSha,
    'status': status,
    'conclusion': conclusion,
    'app_id': appId,
    'external_id': externalId,
  };
}

/// Write access limited to the App's own dedicated readiness check runs.
abstract interface class ReadinessCheckPublisher {
  Future<List<ReadinessCheckRun>> listReadinessCheckRuns({
    required int prNumber,
    required String checkName,
    required int appId,
  });

  Future<ReadinessCheckRun> createCheckRun({
    required String name,
    required String headSha,
    required ReadinessCheckConclusion? conclusion,
    required String title,
    required String summary,
    required String externalId,
  });

  Future<ReadinessCheckRun> updateCheckRun({
    required int checkRunId,
    required ReadinessCheckConclusion conclusion,
    required String title,
    required String summary,
    required String externalId,
  });
}

/// Governance controls the publisher verified live during one attempt.
class GovernancePrerequisites {
  const GovernancePrerequisites({
    required this.appIdentityVerified,
    required this.protectedEnvironmentVerified,
    required this.independentAuditorAuthenticated,
    required this.rulesetEnforced,
  });

  /// State reported whenever no control could be verified.
  static const GovernancePrerequisites unavailable = GovernancePrerequisites(
    appIdentityVerified: false,
    protectedEnvironmentVerified: false,
    independentAuditorAuthenticated: false,
    rulesetEnforced: false,
  );

  final bool appIdentityVerified;
  final bool protectedEnvironmentVerified;
  final bool independentAuditorAuthenticated;
  final bool rulesetEnforced;

  /// Whether every external control required for an accepted high-risk check
  /// was verified from an authenticated live source during this attempt.
  bool get allVerified =>
      appIdentityVerified &&
      protectedEnvironmentVerified &&
      independentAuditorAuthenticated &&
      rulesetEnforced;

  /// Names of the controls that were not verified, for operator diagnostics.
  List<String> get missing => <String>[
    if (!appIdentityVerified) 'app_identity_verified',
    if (!protectedEnvironmentVerified) 'protected_environment_configured',
    if (!independentAuditorAuthenticated) 'independent_auditor_authenticated',
    if (!rulesetEnforced) 'ruleset_enforced',
  ];

  Map<String, Object?> toJson() => <String, Object?>{
    'app_identity_verified': appIdentityVerified,
    'protected_environment_configured': protectedEnvironmentVerified,
    'independent_auditor_authenticated': independentAuditorAuthenticated,
    'ruleset_enforced': rulesetEnforced,
  };
}

/// Sanitized, credential-free record of one publication attempt.
class ReadinessPublicationRecord {
  const ReadinessPublicationRecord({
    required this.publishedAt,
    required this.mode,
    required this.repository,
    required this.checkName,
    required this.prNumber,
    required this.decision,
    required this.failure,
    required this.message,
    this.app,
    this.pullRequest,
    this.approval,
    this.protectedEnvironment,
    this.evidenceIngress,
    this.evidenceDigest,
    this.changedFiles = const <RepositoryChange>[],
    this.unresolvedReviewThreads,
    this.headCheckState,
    this.ruleset,
    this.prerequisites = GovernancePrerequisites.unavailable,
    this.evaluatorDecision,
    this.evaluatorFailureClassification,
    this.evaluatorMessage,
    this.checkConclusion,
    this.checkRunId,
    this.supersededCheckRunIds = const <int>[],
  });

  /// Schema identifier for the publication record.
  static const String schema = 'llamadart.high-risk-readiness-publication';

  /// Schema version for the publication record.
  static const String schemaVersion = '1.0.0';

  final DateTime publishedAt;
  final PublicationMode mode;
  final String repository;
  final String checkName;
  final int prNumber;
  final ReadinessPublicationDecision decision;
  final ReadinessPublicationFailure failure;
  final String message;
  final LiveAppIdentity? app;
  final LivePullRequest? pullRequest;
  final LiveProtectedApproval? approval;
  final LiveProtectedEnvironment? protectedEnvironment;
  final EvidenceIngress? evidenceIngress;
  final String? evidenceDigest;
  final List<RepositoryChange> changedFiles;
  final int? unresolvedReviewThreads;
  final LiveHeadCheckState? headCheckState;
  final LiveRulesetEnforcement? ruleset;
  final GovernancePrerequisites prerequisites;
  final ReadinessDecision? evaluatorDecision;
  final ReadinessFailureClassification? evaluatorFailureClassification;
  final String? evaluatorMessage;
  final ReadinessCheckConclusion? checkConclusion;
  final int? checkRunId;
  final List<int> supersededCheckRunIds;

  /// Whether this attempt published an authenticated passing high-risk check.
  bool get isAccepted => decision == ReadinessPublicationDecision.accepted;

  Map<String, Object?> toJson() => <String, Object?>{
    'schema': schema,
    'schema_version': schemaVersion,
    'published_at': publishedAt.toUtc().toIso8601String(),
    'mode': mode.name,
    'repository': repository,
    'check_name': checkName,
    'pr_number': prNumber,
    'decision': decision.name,
    'failure_classification': failure.name,
    'message': message,
    'app': app?.toJson(),
    'pull_request': pullRequest?.toJson(),
    'protected_approval': approval?.toJson(),
    'protected_environment': protectedEnvironment?.toJson(),
    'evidence_ingress': evidenceIngress?.name,
    'evidence_digest': evidenceDigest,
    'changed_files': changedFiles.map((change) => change.toJson()).toList(),
    'unresolved_review_threads': unresolvedReviewThreads,
    'head_check_state': headCheckState?.toJson(),
    'ruleset': ruleset?.toJson(),
    'governance_prerequisites': prerequisites.toJson(),
    'evaluator': <String, Object?>{
      'decision': evaluatorDecision?.name,
      'failure_classification': evaluatorFailureClassification?.name,
      'message': evaluatorMessage,
    },
    'check_conclusion': checkConclusion?.wireValue,
    'check_run_id': checkRunId,
    'superseded_check_run_ids': supersededCheckRunIds,
  };

  String toFormattedJson() =>
      const JsonEncoder.withIndent('  ').convert(toJson());
}
