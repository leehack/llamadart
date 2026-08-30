# High-Risk Pre-Merge Readiness Contract

This document defines the repository-local contract for issue #419 and the
external controls that are still required before it can enforce merge
readiness.

## Current status

The repository currently provides:

- a strict evidence schema;
- a read-only Dart evaluator bound to independently supplied repository, PR,
  author, head, and base values;
- a Git-derived name-status inventory that preserves deletions and both sides
  of renames;
- candidate-tree checks for changed production tests;
- a trusted-default-branch GitHub Actions diagnostic.

It also provides an unactivated publisher policy engine, protocol, record
schema, tests, and inert templates under `tool/governance/`, specified in
`doc/high_risk_readiness_publisher.md`. No authenticated API adapter implements
the protocol, so this is the design for the external boundary, not the boundary
itself.

It does **not** provide an authenticated GitHub App publisher, protected
environment provenance, conditional ruleset enforcement, an authenticated
independent-auditor identity, or an authenticated GitHub transport for the
publisher engine. Consequently:

- a valid local high-risk evaluation returns
  `unverifiedPrerequisites` and exits 2;
- no local JSON field, command-line flag, process environment variable, or
  credential-shaped value can produce an operational-ready result;
- the diagnostic workflow must not be selected as a required status check;
- issue #419 is not operationally complete.

## Threat model

The contract fails closed against:

1. stale or mismatched repository, PR, author, head, or base claims;
2. self-approval and the retired standalone `qa` identity;
3. duplicate JSON keys, unknown fields, wrong scalar/container types, and
   caller-declared decisions;
4. caller-forged changed-file lists;
5. deleted, renamed-old, unchanged, absolute, traversal, wildcard, non-test, or
   phantom evidence paths;
6. boolean-only structured-output attestations without named production tests;
7. PR-authored workflow or evidence execution;
8. ordinary environment variables masquerading as protected App provenance.

## Evidence document

The canonical schema is
`tool/testing/high_risk_readiness_evidence.schema.json`.
Input documents set `evaluation` to `null`. The evaluator owns that field and
replaces it with its decision, failure classification, exact changed-file
inventory, diagnostic, and external-prerequisite state.

The input binds:

- `repository`, `pr_number`, `pr_author`;
- `expected_pr_head_sha` and `current_base_sha`;
- `classification` and the exact classified `surfaces`;
- the exact required matrix row IDs and matching row evidence;
- an independent audit record for high-risk changes;
- changed production tests under `test/**/_test.dart`;
- structured-output coverage and affected-family evidence when applicable.

The evaluator rejects missing and unknown keys at every object level. Lists
must contain correctly typed, non-empty, unique values. SHAs are nonzero,
lowercase, full 40-character SHA-1 values. Timestamps are RFC 3339 UTC strings.
Repository names, GitHub authors, correlation IDs, and auditor identities have
bounded character sets.

### Exact changed-file and tree binding

The CLI never accepts `changedFiles` from JSON or a command-line option. It
derives the inventory with:

```bash
git diff --name-status -z --find-renames <base>...<head>
```

Both commits must exist and the base must be an ancestor of the head. Rename
source and destination paths are both classified. Every cited test must:

- be a normalized, wildcard-free repository-relative `test/**/_test.dart` path;
- appear in the exact base-to-head inventory;
- not be deleted or the old side of a rename;
- resolve literally to one regular blob in the exact candidate tree via
  `git ls-tree`.

This intentionally rejects unchanged tests as issue-specific proof. Existing
coverage can still inform a human audit, but it cannot satisfy the changed
production-test evidence field.

### Independent audit

High-risk evidence requires an audit whose head and base exactly match the PR
context, whose decision is `accepted`, and whose known PR-caused P1 regression
and unresolved-thread counts are both zero. The auditor must differ from the PR
author and must not use a retired `qa` identity.

These repository-local checks establish internal consistency only. They do not
authenticate the auditor. That requires the missing external boundary described
below.

### Structured-output proof

Structured-output evidence names changed production tests for every axis:

- compiled grammar acceptance;
- compiled grammar rejection;
- schema-directed scalar and container reconstruction;
- partial-stream suppression and malformed-final rollback;
- `auto`, `required`, and `none` tool choice with thinking prefixes;
- pinned/current upstream parity.

Acceptance and rejection must cite at least one changed compiled production
grammar test:

- `test/integration/core/grammar/generated_tool_schema_grammar_test.dart`; or
- `test/e2e/template/specialized_tool_grammar_validation_e2e_test.dart`.

The `families` list requires a unique family, `tested` or `unavailable`
status, changed evidence tests, and a rationale. An unavailable family is not a
boolean N/A shortcut; the audit must still explain the missing weights and the
primary upstream fixture used for the shared production path.

## CLI

```bash
dart run tool/testing/high_risk_readiness.dart \
  --evidence /path/to/evidence.json \
  --repository leehack/llamadart \
  --pr-number <number> \
  --head-sha <observed-pr-head> \
  --base-sha <observed-pr-base> \
  --pr-author <observed-author>
```

The binding values must come from an independent source such as a read-only
GitHub API query. Repeating values copied from the evidence file checks
consistency but does not create trust.

Exit codes:

| Code | Meaning |
| --- | --- |
| 0 | Standard-risk diagnostic only. |
| 1 | Evidence or repository-state rejection. |
| 2 | High-risk evidence is internally consistent, but external prerequisites are unavailable. |
| 64-66 | CLI usage, JSON, or file error. |

`--schema` prints the schema. There is deliberately no App credential,
environment trust, supplied changed-file inventory, or `ready` option.

## Trusted-default-branch diagnostic workflow

`.github/workflows/high_risk_readiness.yml` runs under
`pull_request_target` but checks out only the immutable
`github.workflow_sha` revision that supplied the trusted default-branch
workflow, with credential persistence disabled. The event-dependent
`github.sha` is not used as the workflow trust binding. It has no
branch-selectable manual-dispatch trigger. The workflow grants read-only
contents and pull-request permissions, validates the PR number, fetches
metadata/files through the read-only GitHub API, verifies the complete
paginated file count, rejects ambiguous control-character paths, and classifies
both current and previous rename paths.

It does not check out or execute the PR branch and does not consume PR comments,
PR-authored evidence files, workflow artifacts, or PR-authored workflows.

- Standard-risk changes receive a successful, explicitly non-required
  diagnostic.
- High-risk changes receive an explicit diagnostic warning and summary noting
  that high-risk paths were detected, the protected publisher is not installed,
  and operational readiness remains unavailable until separately activated. The
  bootstrap diagnostic succeeds so it does not block PRs before activation, but
  the local evaluator, publisher, and future protected readiness check continue
  to fail closed.
- No metadata or inventory validation failure is hidden with `|| true`, and no
  diagnostic evidence payload is fabricated.

The workflow name and job name intentionally say `diagnostic`. The diagnostic
workflow must never be configured as a required readiness check; configuring it
as a required check would create a false sense of enforcement while the
privileged publisher is unavailable and could make standard-risk PRs depend on a
gate that is not intended for them.

## Missing external prerequisites

`doc/high_risk_readiness_publisher.md` specifies how each control below is
satisfied, which parts are implemented, and the exact administrator activation
and read-back runbook. Repository administrators must not add credentials or a
required check until a separate reviewed implementation supplies all of these
controls:

1. A dedicated GitHub App installed only on `leehack/llamadart`, with exactly
   Actions, contents, metadata, pull requests, and statuses read plus checks
   write. App and installation identity must be read with the correct JWT and
   installation-token endpoints rather than copied from caller claims.
2. A protected execution environment whose required reviewers,
   prevent-self-review flag, and `main`-only branch policy are read back from
   the API.
3. Evidence bytes whose full SHA-256, PR, head, and base are bound by a strict
   authenticated environment-approval comment. Workflow inputs remain claims;
   PR bodies, PR comments, PR-authored files, workflow artifacts, and ordinary
   environment values are not trust roots.
4. Authenticated creator binding for the independent auditor, with proof that
   the actor differs from the PR author and is not the retired `qa` identity.
5. Live read-only queries for repository, PR, author, exact head/base, changed
   files, and unresolved review threads immediately before publication.
6. Evaluation using a reviewed immutable revision from the default branch, not
   a mutable PR checkout.
7. Publication bound to the exact head, with PR re-reads before and after the
   write, stale and duplicate App-owned runs superseded, and strict
   up-to-date-status enforcement covering base movement.
8. A two-mode required check: unattended classification reports success for
   standard-risk diffs and non-passing for high-risk diffs; protected
   attestation is the only high-risk success path. A refused attempt must not
   cancel a current standard-risk success.
9. Adversarial test PRs proving self-attestation, head/base drift, renamed and
   deleted evidence, malformed JSON, and missing evidence all fail closed.

Only after those controls exist and are verified should a separate change add
protected credentials or ruleset enforcement. This repository-local change
does not request, store, or validate any secret.
