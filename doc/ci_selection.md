# CI impact selection

`tool/ci/select_jobs.py` selects the core CI jobs and portable bundle targets
from a complete Git diff. Both workflows still report a final status for every
PR. A path filter must not prevent a required workflow from reporting.

## Selection boundary

| Changed inputs | Core checks | Portable builds |
|---|---|---|
| Documentation, website, docs tooling | Docs build/tool tests plus version and bridge-pin checks | None |
| One companion package | Root static checks, affected package's Flutter/SwiftPM/publish checks, root Linux coverage and full macOS/Windows VM checks, Web Chat consumer | Android, Web, iOS inputs |
| Validation package tests/profiles/schemas | Root static checks, private suite and provider/workspace/Flutter consumer contracts | None |
| Validation implementation/dependencies or provider/build helpers | Same validation checks | All desktop and app targets |
| Android/iOS/Web chat packaging | Root static checks; Web Chat for Web inputs | Affected app target |
| Other chat app implementation/dependencies | Static, private harness, Web Chat | All app targets |
| Chat app unit tests | Static and Web Chat | None |
| Root tests/fixtures | Static, full Linux coverage, Chrome and macOS/Windows VM inventories | None |
| Root runtime/hooks/dependencies, shared or unknown paths | Full behavioral graph | All targets |
| Workflow/selector changes | Full graph including synthetic artifact transport | All targets |
| Missing, empty or invalid diff; explicit manual bundle run | Full fallback | All targets |

Selections combine for mixed changes. Version checks already executed by the
root static job are not duplicated in the docs-only job. Provider root tests
already executed by full Linux coverage are not duplicated in a separate job.
The consumer job is omitted entirely only when both root coverage and Web Chat
(which runs all Flutter app tests) substitute its assertions. Mixed validation
and root-test changes still run the Flutter consumer assertions.
The private harness also checks APK integrity. Its separate consumer job runs
root provider/NPU/workspace tests and the Flutter validation controller/app tests.

PR diffs use the merge base of the immutable base/head revisions; push diffs use
the event's before/after revisions. Checkout fetches history. Renames include
both source and destination; deleted paths remain inputs. Git's NUL-delimited
output preserves whitespace and avoids API file-count limits. Missing history,
invalid event metadata and malformed inventory fall back to full work. Paths and
revision inputs are never interpolated into shell code. Changes to the selector
itself select every lane.

The existing `Test Linux & Web (with Coverage)` status now aggregates **all**
selected core jobs. It runs with `always()` and rejects failed, cancelled,
missing or unexpectedly skipped selected jobs. Only deliberately unselected
jobs may be skipped. The bundle result applies the same rule to target matrices.
This is executable job accounting, not a new repository protection setting.

Obsolete PR bundle runs cancel. Manual bundle runs have unique concurrency
groups and do not cancel one another. Bundle workflows do not automatically run
on main pushes; that candidate/artifact policy remains unchanged.

## Retained protections and separate work

Full runtime and shared changes still execute the existing Linux, macOS and
Windows VM inventories, tiny native inference and ABI checks, Windows process
and DLL-loader tests, macOS Apple companion cache-transition test, Chrome,
Web Chat and prompt-reuse parity. Isolated companion work still runs root
consumers, not just package-local tests. No model oracle or coverage threshold
changed. Build success does not qualify real GPU/NPU/device/model execution.

The synthetic Actions upload/download roundtrip now runs on workflow/selector
changes; ordinary runtime work retains real failure-diagnostic upload behavior.
The new workflow contract tests validate the actual selection/aggregate wiring.

Coverage tooling is pinned to **1.15.1**, with the **70%** threshold retained.
This version parses `--workers` but does not forward it to `HitMap.parseFiles`,
which loops over inputs sequentially. Adding `--workers 2` or `4` therefore
would not implement parallel formatting. Benchmark numbers must be identified
as local or hosted measurements and compared on identical raw coverage using
semantic LCOV records, including all hit counts, not just overall percentages.

Narrower runtime OS inventories and integration-repository cleanup remain
separate proposals tracked by #532. #384 remains the
coverage measurement work item; historical latency targets are not claims about
this implementation. No release, publication, runtime pin or settings change is
part of this batch.

## Verify changes

```bash
python3 -m unittest discover -s test/ci -p 'test_*.py'
dart run tool/testing/run_local_e2e.dart --scenario ci-selection
actionlint .github/workflows/ci.yml .github/workflows/validation_bundles.yml
```

Tests cover docs-only and package changes, shared/runtime/unknown inputs,
platform targets, workflow changes, actual Git rename/deletion histories,
invalid/truncated inventories, mixed changes, and aggregate failure/cancellation
semantics. Workflow tests verify every planned job is wired into the aggregate,
dynamic matrices consume the selector, full OS commands survive, and isolated
validation retains root/Flutter consumer tests.

Predicted savings come from omitted jobs and obsolete PR cancellation, not
faster runtime tests. Measure hosted wall time, queue delay and summed job time
separately after approved PR execution; do not report docs-only results as a
full-code speedup or local measurements as GitHub-hosted results.

## Tested Web deployment and previews

On canonical-repository main pushes, Web Chat Contract builds the production
root (`/`) once, runs mock and real tiny-GGUF browser smokes against those files,
and uploads the successful artifact. The production reusable workflow waits for
both Web Chat and the existing all-selected-checks aggregate to succeed. It
verifies the same run's artifact ID, archive digest, source commit/tree, pinned
Flutter version and production build target before uploading those files to HF.
It does not install Flutter or rebuild. HF's README remains hosting metadata.
A latest-main check before upload rejects obsolete deployments.

The former manual arbitrary-ref deployment is removed. Retry a failed deployment
through its original CI run while it remains current main and its seven-day
artifact is available; otherwise rerun the full current-main CI run. No artifact
from another run or untested rebuild is accepted. GitHub-hosted promotion and HF
upload must still be verified after an approved PR/merge; local tests do not
claim hosted deployment evidence.

PR previews default to non-draft same-repository changes selected for Web Chat
(including shared runtime dependencies and conservative unknown inputs).
Docs-only and mobile-only changes skip the build. A `preview` label explicitly
opts in, including drafts. Forks and Dependabot remain excluded. Selection runs
before Flutter setup; the build job has no deployment secrets. Deployment uses
the resulting artifact and verification scripts from the PR base. Closing a PR
always attempts cleanup regardless of paths, labels or draft status. Converting
a PR to draft or removing the label skips future ineligible builds; an existing
preview remains until close. Per-PR concurrency cancels obsolete runs.

To exercise the production layout locally, cache `stories15M.gguf` at
`.dart_tool/test_models/stories15M.gguf`, then run:

```bash
dart run tool/testing/run_local_e2e.dart --scenario chat-app-web-production-smoke
```

The runner builds once and starts two loopback servers: the unchanged app at
`--port` (default 7358), with HF's `require-corp` isolation policy, and the model
at the next port with CORS limited to that app origin. Both servers are cleaned
up on success or failure. `--model-url` overrides the model URL; `--skip-build`
validates and tests an existing build. Model files are never added to the
uploaded app. The corresponding matrix row is `web-production-artifact-smoke`.
The concrete saving is one removed production Flutter setup/dependency/build;
no hosted timing or cost percentage is claimed before measurement.
