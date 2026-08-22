## Summary
-

## Production-readiness scope
- **User-facing scope:** <!-- What can users do after this merges? -->
- **Supported platforms/paths:** <!-- Native/WebGPU/Flutter app/docs-only/etc. -->
- **Unsupported or intentionally unavailable paths:** <!-- Include the error, disabled UI, or fallback users see. Do not silently succeed. -->
- **Out of scope / follow-ups:** <!-- Link GitHub issues for non-blocking future work, or write "None". -->

## Completeness checklist
- [ ] Declared scope is fully implemented, or explicitly reduced above.
- [ ] Unsupported platform/option combinations fail loudly with actionable diagnostics or are clearly documented as unavailable.
- [ ] Public API docs, README/website docs, examples, support matrices, and changelog entries are updated where relevant.
- [ ] Regression coverage covers the original issue plus key negative/version-skew paths where relevant.
- [ ] Security/privacy review completed: no secrets, bearer tokens, signed URLs, or raw secret-bearing paths leak through logs, cache keys, metadata, errors, or snapshots.
- [ ] Follow-up work that is useful but not required for this PR is tracked in GitHub Issues, or explicitly marked "None" above.

## PR type guidance
<!-- Keep the relevant line(s), or mark N/A with a short reason. -->
- **Feature PR:** include API/docs/example updates, platform matrix, unsupported-path behavior, and tests for both happy and negative paths.
- **Bugfix PR:** include the regression root cause, targeted regression test or documented reason one is impractical, and affected platform matrix.
- **Docs-only PR:** confirm no runtime behavior changes and note any commands used to validate docs links/builds.

## Test Plan
<!-- Mark commands as N/A with a short reason for docs-only/template-only changes. -->
- [ ] `dart format --output=none --set-exit-if-changed .`
- [ ] `dart analyze`
- [ ] `dart test -p vm -j 1 --exclude-tags local-only`
- [ ] `dart test -p chrome --exclude-tags local-only` <!-- N/A with reason if not relevant -->
- [ ] Other targeted/local-only validation: <!-- Use `dart run tool/testing/test_matrix.dart --list` and `dart run tool/testing/run_local_e2e.dart --list`; e.g. Web mock smoke, WebGPU smoke, Flutter app E2E, docs build, N/A -->

## Matrix Evidence
<!-- Generate rows with `dart run tool/testing/test_matrix.dart --pr-template`; keep applicable rows and mark skipped rows N/A with a concrete reason. -->
| Matrix row | Scope covered | Platform / model / backend | Result | Evidence / notes |
| --- | --- | --- | --- | --- |
|  |  |  |  |  |

## Review Notes
- Independent review status: <!-- reviewer/tool/verdict, or N/A for trivial docs-only changes -->
- CI status / head SHA: <!-- fill after CI runs -->

## High-risk regression gate
<!--
Required when production changes touch parsers, grammars, streaming protocols,
backend/runtime routing, capability probes, artifact consumers, release
automation, or this regression policy. Run
`dart run tool/testing/test_matrix.dart --tier high-risk` and follow
`doc/testing_matrix.md`. Do not mark a high-risk PR ready until the
"High-Risk Regression Gate" check passes against the exact head/current base.
The QA task must be independent from the implementation task and blocking-only.
For a standard PR, set only High-risk classification to `standard`; the
remaining fields may stay as comments.
-->
- **High-risk classification:** <!-- `standard` or `high-risk` -->
- **Implementation task:** <!-- Stable task/review identifier. -->
- **Independent blocking QA task:** <!-- Must differ from implementation task. -->
- **Exact head SHA:** <!-- Full 40-character SHA reviewed by independent QA. -->
- **Current base SHA:** <!-- Full current base SHA used by independent QA. -->
- **Current base distance:** <!-- Exact `N behind / N ahead`. -->
- **Independent QA verdict:** <!-- Exact `PASS`. -->
- **Production call sites inspected:** <!-- `PASS:` plus exact call sites; helpers alone are insufficient. -->
- **Positive production-path evidence:** <!-- `PASS:` plus issue-specific production-path evidence. -->
- **Negative/adversarial production-path evidence:** <!-- `PASS:` plus malformed/version-skew/boundary evidence. -->
- **Deletion/bypass/miswire sensitivity:** <!-- `PASS:` explain how deleting, bypassing, and miswiring the production branch fails tests. -->
- **Known PR-caused P1 regressions:** <!-- Exact `0`; a known P1 cannot be deferred. -->
- **Unresolved review threads:** <!-- Exact live count; must be `0`. -->
- **Affected-family real model/artifact evidence:** <!-- `PASS:` or `N/A:` naming the exact unavailable family and primary upstream/durable fixture proof. -->
- **Unrelated representative smoke:** <!-- `pipeline-only:` or `N/A:`; never affected-family proof. -->

### Structured-output adversarial evidence
<!-- Required for parser, grammar, template, tool-call, thinking, or streaming changes. -->
- **Compiled grammar valid upstream emissions:** <!-- `PASS:` must cite compiled acceptance of actual upstream-emitted shapes. -->
- **Compiled grammar rejection matrix:** <!-- `PASS:` must cover unknown, missing, wrong-type, and malformed structures. -->
- **Schema-directed types and empty values:** <!-- `PASS:` cover string, number, boolean, null, object, array, and empty values. -->
- **Partial/final streaming and rollback:** <!-- `PASS:` cover partial suppression, final malformed rollback, and content preservation. -->
- **Tool choice and thinking prefixes:** <!-- `PASS:` cover auto/required/none with thinking/reasoning prefixes. -->
- **Pinned/current upstream template/parser parity:** <!-- `PASS:` cite pinned/current upstream and run_template_parity_suites.sh. -->
- **Exact affected-format evidence:** <!-- `PASS:` or `N/A:` naming every unavailable family plus primary upstream emissions and durable fixtures. -->
