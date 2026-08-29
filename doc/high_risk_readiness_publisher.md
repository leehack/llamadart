# High-Risk Readiness Publisher

This document specifies the authenticated exact-head publisher designed for
issue #419 and the separate administrator activation procedure.

## Current status: policy only, not operational

This repository contains a policy engine, protocol types, a publication-record
schema, adversarial tests, and inert configuration templates under
`tool/governance/`. It does **not** contain an authenticated HTTP/API adapter
for `AuthenticatedGitHubSource` or `ReadinessCheckPublisher`. The command
`tool/governance/high_risk_readiness_publish.dart --publish` deliberately exits
without reading or writing GitHub state.

No dedicated App, environment, workflow, secret, or ruleset is installed by
this change. The templates live outside `.github/workflows`, are not runnable
without the missing adapter, and must not be copied into place yet. Issue #419
is therefore not operationally complete. `--status` reports this fail-closed
state and exits 2.

## Ownership and trusted execution

The policy belongs here because it reuses the repository's existing,
CODEOWNERS-protected `HighRiskReadinessEvaluator`, evidence schema, and
high-risk classifier. Moving it to an unowned service would either duplicate
that policy or execute an unpublished copy. Native and Web runtime artifacts
remain owned by their sibling repositories; repository governance does not.

Location does not make a pull request trusted. An eventual deployment must:

- run the installed workflow only from `main`;
- check out `${{ github.workflow_sha }}`, the immutable revision containing the
  workflow, never the event-dependent `${{ github.sha }}` and never a pull
  request head;
- keep the attestation workflow top-level and non-reusable, and require its
  authenticated workflow-file revision to equal the authenticated `main`
  workflow-run head SHA; a caller-supplied `GITHUB_WORKFLOW_SHA` is not proof;
- reject a workflow run whose authenticated `head_branch`, `head_sha`,
  `workflow_sha`, event, path, or run attempt does not match the expected
  trusted dispatch;
- perform no checkout or process execution against the candidate tree; and
- obtain candidate-tree facts through authenticated GitHub API reads bound to
  one exact base/head pair.

The policy code has no subprocess path. `GitHubBackedRepositoryState` supplies
the existing evaluator with authenticated repository reads and refuses any
base/head pair other than the pair fixed for that attempt.

## Reuse of the PR #466 policy

`HighRiskReadinessEvaluator` and
`tool/testing/high_risk_readiness_evidence.schema.json` remain the sole
readiness-policy implementation. The publisher passes independently read PR
context and repository state into that evaluator, then adds the external
authentication and check-publication layer the evaluator intentionally cannot
provide.

Four predicates are shared rather than forked: exact SHA validation, GitHub
login validation, retired-`qa` detection, and repository-inventory validation.
The evaluator still returns `unverifiedPrerequisites` for internally valid
high-risk evidence; only the publisher may verify external prerequisites.

## Trust roots

Trusted only after strict response validation:

- the immutable `main` workflow revision;
- GitHub REST and GraphQL responses authenticated as the dedicated App or its
  exact single-repository installation; and
- a protected-environment approval returned by the Actions approvals API.

Never trusted as facts:

- PR bodies, titles, comments, reviews, files, workflows, or artifacts;
- evidence fields, workflow inputs, process environment values,
  `github.actor`, or the workflow dispatcher;
- App slug, App id, installation id, environment, PR, head, base, or ruleset
  claims supplied by a caller; or
- the retired standalone `qa` identity.

Credentials and object identifiers are transport inputs, not factual claims.
The adapter must authenticate with them and read every asserted identity and
state value back from GitHub. It must never log credentials, request headers,
evidence bytes, signed URLs, or raw response bodies.

## Required authenticated transport

The future adapter is a separate reviewed implementation. It must inject a
bounded HTTP/API client into the policy interfaces, reject non-2xx responses
unless a documented write reconciliation applies, validate every required
field and enum, follow every required page, reject duplicate or missing
objects, and apply timeouts. It may retry read-only requests. A write retry
must first reconcile live check state; `external_id` is not unique.

App identity requires both authentication levels:

1. Use an App JWT for `GET /app` and
   `GET /app/installations/{installation_id}`. An installation token cannot
   call these endpoints. Read the App slug/id, installation permissions,
   repository-selection mode, installation account, and installation id from
   those responses.
2. Use the short-lived installation token for paginated
   `GET /installation/repositories` and repository reads/writes. Require the
   listed scope to be exactly `leehack/llamadart`. The token used for this read
   must expose the full installation; pre-narrowing it to one repository would
   conceal an over-broad installation and is prohibited.
3. Require this exact permission map: `actions: read`, `checks: write`,
   `contents: read`, `metadata: read`, `pull_requests: read`, and
   `statuses: read`. `checks` is the only write permission. Missing and extra
   permissions both fail closed.

`high_risk_readiness_publish.dart --protocol` lists the endpoint contract for
every source and publisher method. It is a design contract, not a transport
implementation.

The least-privilege App can read active effective branch rules with
`metadata: read`, but GitHub does not return ruleset bypass actors to a caller
that lacks write access to the ruleset. Do not grant Administration write to
this publisher merely to inspect that field. Absence of bypass actors is an
administrator activation/read-back control; the live publisher verifies the
effective required-check and pull-request rules, not immutability against later
administrator reconfiguration.

## Approval and evidence binding

Workflow-dispatch inputs are claims. The workflow-run REST response does not
return those inputs, so the adapter must not invent such a binding. The
attestation environment reviewer instead places this exact, single-line value
in the authenticated deployment approval comment:

```text
llamadart-high-risk-readiness/v1 pr=<positive decimal> head=<40 lowercase hex> base=<40 lowercase hex> evidence_sha256=<64 lowercase hex>
```

`parseProtectedApprovalAttestation` rejects whitespace changes, extra fields,
duplicate fields, uppercase or abbreviated digests, and trailing data. The
adapter must parse the comment returned by the Actions approvals API, not a
caller-provided copy.

For an attended run, the auditor must review the exact UTF-8 evidence bytes,
compute their full SHA-256 independently without adding a newline, and read the
current PR head/base from GitHub before approving. The approval comment must be
entered on that exact pending environment deployment. A digest supplied by the
dispatcher is not evidence; if the auditor cannot inspect the exact bytes or
cannot reproduce the digest, the deployment must be rejected.

The policy additionally requires:

- the authenticated run and submission run ids to match;
- first attempt only;
- repository `leehack/llamadart`, event `workflow_dispatch`, path
  `.github/workflows/high_risk_readiness_publish.yml`, branch `main`, and an
  exact workflow-file SHA equal to the authenticated workflow-run head SHA.
  This repository's installed publisher is a top-level, non-reusable workflow;
  the run revision need not equal the pull-request base SHA;
- the attested PR/head/base to equal the immediately read live PR;
- the full SHA-256 of the exact evidence bytes to equal the approved digest;
- the authenticated approver to differ from the requester and PR author; and
- the evidence auditor identity to equal that authenticated approver.

The live environment read must show required reviewers, prevent-self-review,
and a custom deployment branch policy containing only `main`.

## Complete live state

Immediately before evaluation the adapter must read and validate:

- open PR number, repository, author, base ref, exact head/base SHA, draft
  state, and changed-file count;
- every page of the PR file list, preserving rename/copy `previous_filename`,
  deletion, and type changes;
- a destination-path-unique inventory whose count exactly matches the PR,
  whose paths are safe repository-relative paths, and whose statuses are
  supported;
- the candidate tree through literal, non-recursive tree traversal so regular
  blobs are distinguished from symlinks, submodules, and missing paths;
- all GraphQL review-thread pages and the unresolved count;
- all check-run pages plus the combined commit status for the exact head,
  excluding only a check whose name **and** App id identify the dedicated
  publisher. A foreign App check or legacy status with the same name remains
  part of the aggregate; and
- the active effective rules for `main`, including strict required-status-check
  policy and the `High-Risk Readiness` context bound to the exact App numeric
  id, plus required review-thread resolution.

Before a passing write, the App and installation, protected approval,
environment, exact inventory, exact evidence bytes, unresolved-thread count,
exact-head check state, effective rules, and PR are all read again from their
authenticated sources. A new unresolved thread or non-green check publishes a
blocking supersession instead of preserving the earlier passing decision. The
PR is also re-read immediately before any check write and after the write. A
change to repository, number, author, head, base, base ref, state, draft flag,
or file count loses the compare-and-swap. A just-written run is cancelled when
the post-write re-read detects movement. Head movement makes the old check
irrelevant; strict up-to-date status-check enforcement blocks a same-head check
after base movement until reevaluation.

## Conditional publication

GitHub required status checks are unconditional. Omitting a high-risk-only
check would strand every standard-risk PR. Both modes therefore own the same
dedicated check name:

| Mode | Exact live inventory | Result |
| --- | --- | --- |
| `classification` | Standard risk | `success` / not applicable |
| `classification` | High risk | `action_required` / attestation required |
| `attestation` | Standard risk | `success` / not applicable |
| `attestation` | High risk with any failed control | non-passing or refusal |
| `attestation` | High risk with every live control verified | `success` |

Classification never reads evidence, approval, environment, or ruleset state
and can never produce `accepted`. A malformed or unauthenticated attestation
does not cancel an existing current-head standard-risk success; otherwise an
attacker could strand ordinary PRs by submitting a refused attempt.

The two workflow templates deliberately use separate concurrency groups. An
attestation waiting for an environment reviewer must not occupy the unattended
classification queue. Cross-mode writes can therefore race; exact-head
reconciliation makes them safe. A delayed classifier can conservatively return
a high-risk head to `action_required`, after which the valid attestation is
rerun. It cannot create an unauthorized success.

A refusal reached before publication authority is established performs no
check mutation. After an authenticated attempt starts reconciliation, a
post-write compare-and-swap failure or ambiguous write can still return a
refusal after cancelling only App-owned runs; the refusal never claims a final
conclusion or authoritative run id. Once an attempt is authenticated and ready
to publish, it cancels authoritative App-owned runs found on older commits
still reachable through the fully paginated PR commit connection. A
force-pushed-away head may no longer be discoverable through that connection,
but its exact-head check cannot satisfy the required check on the current SHA.
Current-head duplicate runs are reconciled during the write.

## Check ownership, races, and errors

The adapter must page the GraphQL PR commit connection, validate its
`totalCount`, list every check-run page for those commit OIDs with `check_name`,
`filter=all`, and the exact `app_id`, and reject duplicate objects. It must
still validate every returned run's id, name, App id, head, status, conclusion,
and publisher-owned external-id prefix.

The writer:

1. reuses an exact completed replay when present;
2. otherwise creates an `in_progress` run, never a passing run;
3. re-lists because a create response may be lost and another creator may race;
4. selects the newest exact external-id replay, or otherwise the newest owned
   run for that head;
5. cancels other authoritative owned runs on that head;
6. updates the selected run to the final conclusion; and
7. re-lists after an ambiguous update and accepts it only if every expected
   field matches exactly.

The external id is a full SHA-256 over repository, PR, head, base, mode,
evidence digest, decision, and conclusion. GitHub does not enforce external-id
uniqueness, so no logic relies on a `422` conflict or uniqueness guarantee.
Create or update errors leave no new passing result; ambiguous responses fail
closed. The App API also prevents one App from updating another App's check,
and policy response validation independently enforces the expected App id.
Queued and in-progress runs must have a null conclusion; completed runs must
have a non-null supported conclusion. Any inconsistent response is malformed.

## Publication record and diagnostics

`tool/governance/readiness_publication_record.schema.json` matches every
emitted field, nullable state, enum, unique array, rename/copy invariant, and
decision-local conditional. Accepted records require attestation mode, a
non-draft PR, green exact-head checks, full evidence digest, approval and
environment records, zero unresolved threads, all four external prerequisites,
an evaluator `unverifiedPrerequisites` decision, and a passing check-run id.
Cross-object equality, including approval-to-PR SHAs, evidence digest, App and
installation ids, and required-check integration id, is enforced by the
publisher before serialization; standard JSON Schema cannot express those
dynamic equalities and the record is not itself a trust root. Refused records
cannot claim a conclusion or run id, although recovery may report App-owned
runs it cancelled.

Evidence bytes and evidence-originated text are never copied to the record or
check summary. Evaluator diagnostics are reduced to stable decision and failure
enums. Check summaries contain only independently read identity/state fields
and fixed publisher messages.

## Separate administrator activation runbook

Activation is a separate approval boundary. Do not perform any step below as
part of the policy PR, and do not begin until the authenticated adapter has
landed with integration tests against recorded, credential-free response
fixtures and a separate security review.

### 1. Review and land the transport

- Implement both interfaces without shelling out or reading a PR checkout.
- Use the API version and endpoints recorded by `--protocol`.
- Add pagination, malformed-response, duplicate-object, partial-write,
  timeout, and retry-reconciliation tests.
- Prove with a recorded workflow-run fixture that the installed top-level
  workflow's runtime `github.workflow_sha` equals the authenticated run
  `head_sha`; refuse activation if GitHub changes that contract.
- Make `--publish` accept locators and credential environment values only;
  facts must still come from live API responses.
- Update the templates from illustrative to runnable only after an end-to-end
  dry run succeeds in a non-required test environment.

Read back: `--status` changes only when the adapter is actually bound, and
`--publish` no longer takes the deliberate unbound exit.

### 2. Create and install the dedicated App

Use `tool/governance/deploy/github_app_manifest.yml.template` as a review
checklist. Create slug `llamadart-high-risk-readiness`, grant exactly the six
permissions listed above, subscribe to no events, and install it with "Only
select repositories" on only `leehack/llamadart`.

Read back with an App JWT and installation token: `/app` returns the expected
slug/id; the installation returns the exact permissions and selected mode; all
pages of `/installation/repositories` contain exactly one repository.

### 3. Create both environments before storing the key

Create `high-risk-readiness-classification` with no reviewers and a selected
branch policy containing only `main`. Create
`high-risk-readiness-attestation` with eligible independent maintainers as
required reviewers, prevent-self-review enabled, and only `main` allowed.

Read both environments back through the API. Do not rely on the settings form
success message.

### 4. Store credentials correctly

Create the non-secret numeric App-id variable expected by the reviewed adapter.
Store the App private key as an **environment secret** with the same reviewed
name in each readiness environment. A repository secret cannot be scoped to
selected environments; do not describe or use it as if it could. Do not place
the key in repository files, workflow inputs, command arguments, artifacts, or
logs.

Read back: both environments list the secret name with no value shown, and no
repository or organization secret of that name exists.

### 5. Install and rehearse workflows without enforcement

In a separately reviewed PR, copy the two templates to the documented active
paths, pin reviewed action revisions, add CODEOWNERS, and run actionlint. Keep
the ruleset disabled. Rehearse standard and high-risk classification, approval
grammar, PR-author approval rejection, stale head/base rejection, pending and
failing CI, unresolved threads, duplicate runs, and post-write movement.

Read back check runs through the API and verify their App id, exact head,
external id, and conclusion. Do not proceed on any mismatch.

### 6. Activate strict conditional enforcement

This step requires another explicit administrator approval. Apply the ruleset
template with the dedicated App numeric id, strict status checks enabled,
required review-thread resolution enabled, `main` as the only target, and no
bypass actors. The readiness ruleset does not add unrelated force-push,
deletion, approval-count, or CODEOWNERS policy; those remain owned by existing
repository governance. The committed template is deliberately `disabled`;
change it to `active` only at this approval boundary. Do not use the existing
default-branch diagnostic workflow as the required check.

Read back the effective `main` rules, not just the saved ruleset document.
Confirm the required context is strict and bound to the dedicated App id, the
pull-request rule requires conversation resolution, one standard-risk PR
resolves without human action, and one high-risk PR remains blocked until a
valid independent attestation.

### 7. Rotate the private key

Generate a second App key. Replace the environment secret in both environments,
rehearse both modes, and read back successful App identity and installation
scope. Only then revoke the old key. If validation fails, restore the prior key
while it is still valid and keep the ruleset disabled until the cause is fixed.

### 8. Roll back or deactivate

First disable the readiness ruleset and read back that the effective `main`
rules no longer require the check. Then remove the installed workflows, revoke
installation tokens/keys, uninstall the App, and delete both environment
secrets and the App-id variable. Removing publishers before disabling the
required check would strand every PR.

After activation or rollback, update `AGENTS.md`, `CONTRIBUTING.md`, and
`doc/high_risk_pre_merge_readiness.md` in a separate reviewed change so their
status claims match the live read-back.
