#!/usr/bin/env dart

import 'dart:convert';
import 'dart:io';

import 'high_risk_readiness_publisher.dart';
import 'readiness_publication_protocol.dart';

/// GitHub endpoints each authenticated source or publisher method must bind to.
///
/// The publisher decides policy; this table is the whole of its ingress. Any
/// binding that resolves a fact from somewhere else — a PR body, a PR comment,
/// a PR-authored file, a workflow artifact, or a process environment value —
/// is outside the contract and must be rejected in review.
const Map<String, List<String>>
readinessSourceEndpointContract = <String, List<String>>{
  'readAppIdentity': <String>[
    'GET /app (App JWT; authenticated slug and id)',
    'GET /app/installations/{installation_id} (App JWT; app id, slug, '
        'repository selection, and granted permissions)',
    'GET /installation/repositories?per_page=100 (unrestricted installation '
        'token; paginate the full installation scope, never a token-narrowed '
        'view)',
  ],
  'readPullRequest': <String>['GET /repos/{owner}/{repo}/pulls/{number}'],
  'readChangedFiles': <String>[
    'GET /repos/{owner}/{repo}/pulls/{number}/files?per_page=100 (paginated;'
        ' status and previous_filename preserved)',
  ],
  'readUnresolvedReviewThreadCount': <String>[
    'POST /graphql (repository.pullRequest.reviewThreads isResolved)',
  ],
  'readHeadCheckState': <String>[
    'GET /repos/{owner}/{repo}/commits/{sha}/check-runs?filter=all&per_page=100 '
        '(paginate all checks; exclude only the run whose name and App id both '
        'match excludedCheckName and excludedAppId)',
    'GET /repos/{owner}/{repo}/commits/{sha}/status (preserve every legacy '
        'status, including a same-name status from another producer)',
  ],
  'readProtectedApproval': <String>[
    'GET /repos/{owner}/{repo}/actions/runs/{run_id}',
    'GET /repos/{owner}/{repo}/actions/runs/{run_id}/approvals',
    'the reviewed top-level workflow is non-reusable, so its immutable '
        'workflow-file revision must equal the authenticated main run head SHA',
    'exact approval comment grammar binds PR, head, base, and full evidence '
        'SHA-256 digest; workflow-run responses do not expose dispatch inputs',
  ],
  'readProtectedEnvironment': <String>[
    'GET /repos/{owner}/{repo}/environments/{environment_name}',
    'GET /repos/{owner}/{repo}/environments/{environment_name}/deployment-branch-policies?per_page=100 (paginated)',
  ],
  'readRulesetEnforcement': <String>[
    'GET /repos/{owner}/{repo}/rules/branches/{branch}',
    'GET /repos/{owner}/{repo}/rulesets (paginated names; effective branch '
        'rule must require strict status checks and bind context and '
        'integration_id, and its pull-request rule must require review-thread '
        'resolution)',
  ],
  'readEvidenceSubmission': <String>[
    'exact workflow_dispatch evidence bytes are claims only; accept them only '
        'when their full SHA-256 digest and run id match readProtectedApproval',
  ],
  'commitExists': <String>['GET /repos/{owner}/{repo}/commits/{sha}'],
  'isAncestor': <String>[
    'GET /repos/{owner}/{repo}/compare/{base}...{head} (merge_base_commit '
        'must equal base)',
  ],
  'pathIsRegularFileAt': <String>[
    'GET /repos/{owner}/{repo}/git/trees/{tree_sha} (non-recursive literal '
        'path traversal; final mode 100644/100755 and type blob)',
  ],
  'listReadinessCheckRuns': <String>[
    'POST /graphql (repository.pullRequest.commits nodes.commit.oid; cursor '
        'pagination and totalCount validation)',
    'GET /repos/{owner}/{repo}/commits/{sha}/check-runs?check_name={name}&filter=all&app_id={app_id} (all calls paginated)',
  ],
  'createCheckRun': <String>['POST /repos/{owner}/{repo}/check-runs'],
  'updateCheckRun': <String>[
    'PATCH /repos/{owner}/{repo}/check-runs/{check_run_id}',
  ],
};

/// Credential-free governance status for the readiness publisher.
///
/// The publisher policy engine is implemented and tested, but no authenticated
/// transport, App installation, protected environment, or ruleset is bound in
/// this repository. This document reports that state so CI and operators can
/// assert governance is still inert instead of assuming it.
Map<String, Object?> readinessGovernanceStatus() => <String, Object?>{
  'schema': 'llamadart.high-risk-readiness-publication-status',
  'schema_version': '1.0.0',
  'repository': defaultReadinessRepository,
  'default_branch': defaultReadinessBranch,
  'check_name': defaultReadinessCheckName,
  'app_slug': defaultReadinessAppSlug,
  'protected_environment': defaultReadinessEnvironment,
  'attestation_workflow_path': defaultReadinessWorkflowPath,
  'authenticated_transport_bound': false,
  'governance_prerequisites': GovernancePrerequisites.unavailable.toJson(),
  'unverified_controls': GovernancePrerequisites.unavailable.missing,
  'message':
      'The readiness publisher policy engine is implemented and adversarially '
      'tested, '
      'but no authenticated GitHub transport is bound, no dedicated App is '
      'installed, no protected environment exists, and no ruleset requires the '
      'dedicated check. High-risk readiness therefore remains fail-closed and '
      'issue #419 is not operationally complete. See '
      'doc/high_risk_readiness_publisher.md.',
};

/// Message emitted when publication is requested without a bound transport.
const String unboundTransportMessage =
    'Refusing to publish: no authenticated GitHub transport is bound. '
    'AuthenticatedGitHubSource and ReadinessCheckPublisher have no '
    'implementation in this repository, so no live fact can be read and no '
    'check can be written. See doc/high_risk_readiness_publisher.md.';

String _usage() =>
    '''Usage: dart run tool/governance/high_risk_readiness_publish.dart <mode>

Modes:
  --status      Print credential-free governance status. Exits 2 while the
                external prerequisites are unavailable.
  --protocol    Print the API endpoint contract each authenticated source and
                publisher binding must satisfy.
  -h, --help    Show this help.

This command never accepts a token, private key, App credential, evidence
document, or readiness override. Publication requires an authenticated
transport that does not exist in this repository yet, so --publish fails
closed.
''';

Future<void> main(List<String> args) async {
  const encoder = JsonEncoder.withIndent('  ');
  if (args.isEmpty) {
    stderr.write(_usage());
    exitCode = 64;
    return;
  }
  if (args.contains('--publish')) {
    stderr.writeln(unboundTransportMessage);
    exitCode = 69;
    return;
  }
  if (args.length != 1) {
    stderr.write(_usage());
    exitCode = 64;
    return;
  }
  switch (args.single) {
    case '--help':
    case '-h':
      stdout.write(_usage());
    case '--protocol':
      stdout.writeln(encoder.convert(readinessSourceEndpointContract));
    case '--status':
      stdout.writeln(encoder.convert(readinessGovernanceStatus()));
      exitCode = 2;
    default:
      stderr.write(_usage());
      exitCode = 64;
  }
}
