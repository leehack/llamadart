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
- a trusted-default-branch GitHub Actions advisory.

It does **not** provide an authenticated GitHub App publisher, protected
environment provenance, conditional ruleset enforcement, or an authenticated
independent-auditor identity. Consequently:

- a valid local high-risk evaluation returns
  `unverifiedPrerequisites` and exits 2;
- no local JSON field, command-line flag, process environment variable, or
  credential-shaped value can produce an operational-ready result;
- the advisory workflow reports that limitation instead of enforcing it, and
  must not be selected as a required status check;
- high-risk merge readiness is established by manual repository-local review and
  evidence, which is how issue #419 was closed as completed.

Protected external enforcement is intentionally unconfigured and is not a
pending merge requirement. Adopting it would need a separate approved
governance change satisfying the boundary in
[Missing external prerequisites](#missing-external-prerequisites).

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

## Trusted-default-branch advisory workflow

`.github/workflows/high_risk_readiness.yml` runs under
`pull_request_target` but checks out only the immutable `github.sha`
revision that supplied the trusted default-branch workflow, with credential
persistence disabled. It has no branch-selectable manual-dispatch trigger. The
workflow grants read-only contents and pull-request permissions, validates the
PR number, fetches metadata/files through the read-only GitHub API, verifies the
complete paginated file count, rejects ambiguous control-character paths, and
classifies both current and previous rename paths.

It does not check out or execute the PR branch and does not consume PR comments,
PR-authored evidence files, workflow artifacts, or PR-authored workflows.

- Standard-risk changes receive a successful, explicitly non-required advisory.
- High-risk changes succeed with a `::warning` and a job summary stating that
  the protected publisher is absent, so readiness must be established by the
  repository-local review, evaluator run, and independent audit described above.
- Invalid PR metadata, GitHub API failures, incomplete or ambiguous file
  inventories, head/base/changed-file drift, and classifier failures still exit
  nonzero.
- No failure is hidden with `|| true`, and no advisory evidence payload is
  fabricated.

The workflow name and job name intentionally say `advisory`. It is not a
required check, so it deliberately does not fail merely because the protected
publisher was never adopted; that absence is reported, not enforced.
Configuring it as a required check could make standard-risk PRs depend on a
gate that is not intended for them.

## Missing external prerequisites

Repository administrators must not add credentials or a required check until a
separate reviewed implementation supplies all of these controls:

1. A dedicated GitHub App installed only on `leehack/llamadart`, with
   read-only contents/pull-request access and only the minimum permission needed
   to publish its own check.
2. A protected execution environment whose branch/actor controls are verified
   independently of ordinary process environment variables.
3. An evidence ingress controlled by the App. PR bodies, comments, PR-authored
   files, PR workflow artifacts, and caller-provided environment values are not
   acceptable trust roots.
4. Authenticated creator binding for the independent auditor, with proof that
   the actor differs from the PR author and is not the retired `qa` identity.
5. Live read-only queries for repository, PR, author, exact head/base, changed
   files, and unresolved review threads immediately before publication.
6. Evaluation using a reviewed immutable revision from the default branch, not
   a mutable PR checkout.
7. Publication bound to the exact head SHA, with stale/pending conclusions
   superseded promptly when head, base, evidence, or review state changes.
8. A tested enforcement design that blocks only classified high-risk changes.
   GitHub required-check behavior must be validated before activation so a
   missing conditional status cannot leave standard-risk PRs pending.
9. Adversarial test PRs proving self-attestation, head/base drift, renamed and
   deleted evidence, malformed JSON, and missing evidence all fail closed.

Only after those controls exist and are verified should a separate change add
protected credentials or ruleset enforcement. This repository-local change
does not request, store, or validate any secret.
