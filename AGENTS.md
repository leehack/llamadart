# AGENTS.md

Guidance for agentic coding assistants working in this repository. Keep this
file as the compact entrypoint for durable repo rules; put detailed matrices and
long procedures in discoverable docs.

## Quick Commands

```bash
dart run tool/prepare_workspace.dart
dart format .
dart format --output=none --set-exit-if-changed .
dart analyze
dart test -p vm -j 1 --exclude-tags local-only
dart test -p chrome --exclude-tags local-only
```

The workspace preparation command resolves the root package and every
maintained example, and fails if any example or companion package is missing or
unclassified. Run it from a clean checkout before the root format/analyze
gates; CI uses the same entry point and fails if it leaves tracked files
modified. Never hand-edit a `pubspec.lock`: pin the offending dependency in
`pubspec.yaml` and let pub regenerate the lock, so its `sdks:` block stays one
pub can actually produce. Companion packages retain their own dependency,
analyze, test, SwiftPM, and publish-validation lanes.
Run repository-wide quality gates with the exact Flutter SDK CI pins: `3.47.1`,
recorded in `.flutter-version` at the repo root and in every
`subosito/flutter-action` step. Older Dart formatters produce different source
layouts, so a different SDK makes `dart format --set-exit-if-changed` disagree
with CI in both directions. Bumping the pin is its own PR: update
`.flutter-version` and the workflow steps together, and carry any reformatting
the new `dart_style` demands in that same PR.

Use the testing matrix to choose validation for non-trivial changes:

```bash
dart run tool/testing/test_matrix.dart --list
dart run tool/testing/test_matrix.dart --pr-template
dart run tool/testing/test_matrix.dart --tier essential
dart run tool/testing/run_local_e2e.dart --list
dart run tool/testing/run_local_e2e.dart --scenario <name> --dry-run
```

For docs and release-sensitive snippets:

```bash
./tool/docs/build_site.sh
./tool/docs/validate_links.sh
dart run tool/testing/verify_release_docs_versions.dart
```

For chat-template handler, parser, or grammar changes, run the pinned upstream
suite plus compiled specialized-grammar acceptance checks:

```bash
tool/testing/run_template_parity_suites.sh
```

For coverage when `lib/` behavior changes or coverage is in doubt:

```bash
dart test -p vm --coverage=coverage
dart pub global run coverage:format_coverage --lcov --in=coverage/test --out=coverage/lcov.info --report-on=lib --check-ignore
dart run tool/testing/check_lcov_threshold.dart coverage/lcov.info 70
```

Heavy or device/model-backed scenarios stay out of default CI. Discover them
through `tool/testing/test_matrix.dart` and `tool/testing/run_local_e2e.dart`,
then record row ID, command or CI workflow, platform/device, model, backend,
PASS/FAIL/N/A, and log/artifact notes in the PR.

Do not add one-off repro scripts under `tool/testing/` unless they are wired
into `tool/testing/run_local_e2e.dart`, represented in
`tool/testing/test_matrix.dart`, and documented where contributors can find
them. Prefer durable assertions in `test/unit/`, `test/integration/`, or
`test/e2e/`.

For Web chat app validation after bridge/runtime or UI changes, use the local
E2E runner instead of ad hoc build/server steps. Preserve the runner's
`--base-href`, static headers, Playwright options, and macOS Chromium ANGLE
settings when debugging helpers directly.

For llama.cpp n-gram speculative output-hash mismatches, compare the same prompt
and sampling settings against upstream `llama-server` before classifying the
mismatch as Dart-only. Use the benchmark runner's `--include-output` flag when
the exact generated text matters.

## Code Style

### Design Principles

- Favor SOLID, DRY, and KISS: keep responsibilities focused, remove meaningful
  duplication, and choose the simplest design that satisfies the current
  requirement.
- Add abstractions only when they reduce real complexity, protect a stable
  boundary, or match an established repo pattern.
- Prefer small, reviewable changes over broad refactors unless the broader
  cleanup is necessary for correctness or maintainability.

### Dart Style

- Use `dart format` defaults.
- Keep imports ordered as SDK, package, then relative imports, separated by blank
  lines.
- Avoid `show`/`hide` unless needed for deconfliction.
- Public APIs need explicit parameter, return, and field types.
- Local `var`/`final` inference is fine when the type is obvious.
- Public members require `///` Dartdoc with useful Markdown.
- Avoid new TODO/FIXME comments in source. Existing generated/template platform
  files may contain upstream TODOs; do not copy that pattern into maintained
  Dart or workflow code.

### Names And Structure

- Classes: `PascalCase`.
- Functions, methods, variables, parameters, and constants: `lowerCamelCase`.
- Files and directories: `snake_case`.
- Public exports live in `lib/llamadart.dart`; implementation stays under
  `lib/src/`.
- Keep `LlamaEngine` free of `dart:ffi` and `dart:io` so web support remains
  viable.
- Use conditional imports for platform-specific backends.
- Tests should mirror source structure under `test/unit/` or
  `test/integration/`.

### Error Handling

- Use the `LlamaException` hierarchy from `lib/src/core/exceptions.dart`.
- Throw `LlamaUnsupportedException` or a typed subtype for unsupported public
  paths instead of silently reporting success.
- Include actionable diagnostics: missing capability, platform/runtime
  condition, and version requirement where known.

### Compatibility

- New public APIs require tests and Dartdoc.
- Capability-dependent behavior needs both happy-path and unsupported or
  version-skew tests.
- Generated files that should not count against coverage must include
  `// coverage:ignore-file`.
- Close ports, streams, and controllers in test cleanup.

## Architecture Rules

- Zero-patch strategy: do not patch upstream native or web bridge sources in
  this repository.
- Native build/source ownership lives in `llamadart-native`.
- Web bridge source/build ownership lives in `llama-web-bridge`.
- Web bridge runtime asset publishing lives in `llama-web-bridge-assets`.
- Keep local native integration focused on hook/config/bindings consumption.
- Keep local web integration focused on bridge tag pinning, fetch flow, and
  runtime wiring.
- Prefer explicit capability probes over structural/interface checks when
  behavior depends on runtime assets, platform support, browser APIs, or native
  feature availability.
- Keep README, website docs/support matrix, examples, and changelog aligned with
  any public capability or platform-support change.

## Web And WebGPU

WebGPU bridge features are versioned runtime capabilities. When changing bridge
behavior, verify the pinned asset tag/manifest, direct bridge calls, worker
path, Dart interop wrapper, public engine API, docs, and examples together.
`tool/testing/check_webgpu_bridge_tag.dart` enforces the tag half of that: every
site pinning the tag must match the default in
`scripts/fetch_webgpu_bridge_assets.sh`. Capability floors (`v0.1.30+`) and
changelog entries keep their own values and are not checked.

Flutter Web builds exclude the gitignored generated bridge assets. Deployment
and real-model Web E2E flows must use `scripts/build_chat_app_web.sh`, which
builds the app, stages the pinned assets into the final output, and validates
the runtime files and checksums. Use
`scripts/validate_chat_app_web_build.sh` when intentionally reusing a build.

The required `Web Chat Contract` CI job covers chat-app VM/Chrome tests, the
deployable artifact, deterministic UI behavior, and a real worker/WASM/GGUF
smoke. Keep it independent of large or availability-sensitive remote models;
full Gemma 4 GGUF and LiteRT-LM Web smokes remain targeted validation.

Document browser durability precisely. Web bridge filesystem paths may be
virtual or in-memory unless the active bridge documents durable backing storage;
durable browser storage can require app-level export/import outside Dart file
helpers.

Unsupported platform or option combinations must fail loudly with typed,
actionable errors or be explicitly disabled/documented.

LiteRT-LM Web streams directly and rejects native worker batching controls.
Keep `streamBatchTokenThreshold` and `streamBatchByteThreshold` at their
defaults on Web, and run chat-app parameter tests on both VM and Chrome when
changing LiteRT-LM generation settings.

## Multi-Repo Ownership

Many maintainer checkouts keep sibling repos one level above this repo:

```text
../llamadart
../llamadart-native
../llama-web-bridge
../llama-web-bridge-assets
```

Verify sibling paths before operating on them. Cross-repo runtime changes should
flow in ownership order:

1. Change the owning repo (`llamadart-native` or `llama-web-bridge`).
2. Commit and push there.
3. Publish/update owning artifacts.
4. Update pins, tags, hooks, docs, and tests in `llamadart`.
5. Run `dart analyze` and relevant tests here before the final commit.

## Native And Web Asset Sync

Prefer the repository workflow for native version and binding updates:
`.github/workflows/sync_native_bindings.yml`.

Stable `llamadart-native` distribution tags use strict
`vMAJOR.MINOR.PATCH`. A wrapper-only rebuild of upstream `vM.m.p` uses
`vM.m.p-N`, preserving the exact upstream prefix; native release ordering treats
`-N` as a forward wrapper sequence despite generic SemVer prerelease ordering.
New wrapper and nightly releases are GitHub prereleases and must be selected
explicitly. Historical `bNNNN` and `bNNNN-llamadart.N` artifacts may retain
older `prerelease=false` metadata, but remain explicit compatibility inputs;
`latest` accepts only unsuffixed `vMAJOR.MINOR.PATCH` regardless of GitHub
metadata. Build-hook overrides must always name an explicit tag; only maintainer
synchronization and header/binding regeneration accept `latest`. Nightly cores
use canonical decimal spelling (`b0` or a nonzero first digit), and rebuild
counters start at 1 without leading zeros.
New nightly wrapper rebuilds use `bNNNN-N`; existing
`bNNNN-llamadart.N` artifacts remain explicit consumption-only compatibility
inputs. New stable or nightly wrapper forms require manifests containing both
`native_release_tag` and the legacy `tag` alias. Stable syncs must validate
manifest provenance, hook contract, bundle coverage, checksums, upstream/native
tag separation, and forward version movement before changing the default pin.
The manual workflow requires its explicit `allow_nightly_channel` input before
moving a stable pin back to the nightly channel.

For local native regeneration:

```bash
tool/native/sync_native_headers_and_bindings.sh --tag latest
```

For local WebGPU bridge asset refreshes in `example/chat_app/web`:

```bash
WEBGPU_BRIDGE_ASSETS_TAG=<tag> ./scripts/fetch_webgpu_bridge_assets.sh
```

See `website/docs/maintainers/native-and-web-sync.md` for the full maintainer
procedure.

## Changelog And Releases

- Never add unreleased work to an already-published version section in
  `CHANGELOG.md` or `website/docs/changelog/recent-releases.md`.
- If the latest section is a concrete released version, create `## Unreleased`
  above it for new PR entries.
- Only move `Unreleased` entries into a numbered version section during an
  explicit release/version-bump task.
- Keep changelog entries concise and user-facing: one short bullet per
  independently useful change; put implementation details, validation, and
  migration notes in PRs or maintainer docs instead.
- Release prep PRs must not publish by themselves. After merge,
  `release_on_prep_merge.yml` is the publishing approval boundary.
- Do not manually push companion or core release tags unless release automation
  is disabled, blocked, or being repaired.
- Keep release-sensitive paths covered by `.github/CODEOWNERS`; enforcement
  depends on GitHub branch protection or rulesets.
- Never log `RELEASE_AUTOMATION_TOKEN` or remotes/URLs derived from credentials.

Before release prep or current install-snippet changes, run:

```bash
dart run tool/testing/verify_release_docs_versions.dart
dart run tool/testing/verify_release_docs_versions.dart --release-prep
```

The default run reports a companion whose `Package.swift` pin is still only in
its `## Unreleased` section as a pending bump; `--release-prep` fails on it.
Resolve every pending bump in the release-prep PR, because the post-merge
workflow skips a companion version that already exists on pub.dev.

After release automation runs, verify the release workflow, package publication,
GitHub Release, docs cut, docs pages deployment, and docs version selector
before calling the release complete. Use
`website/docs/maintainers/release-workflow.md` for the detailed checklist.

## PR Readiness

Treat `main` as production-ready. Before opening or updating a non-trivial PR,
make sure the PR template can honestly state:

- User-facing scope and explicit out-of-scope behavior.
- Platform matrix rows and validation evidence.
- Unsupported combinations fail loudly or are clearly documented.
- README, website docs, examples, support matrices, and changelog match public
  behavior.
- Regression coverage covers the issue plus important negative/version-skew
  paths where applicable.
- Logs, cache keys, metadata, errors, and snapshots avoid credentials, bearer
  tokens, signed URLs, and raw secret-bearing paths.
- Useful non-blocking follow-ups are tracked in GitHub Issues before merge.

Before merging, reply to and resolve every review thread. For comments that are
outdated, superseded, or intentionally non-actionable, record the concrete
rationale in the thread before resolving it; classification alone is not a
substitute for closing the thread. Do not merge while any review thread remains
unresolved.

Treat parser, grammar, streaming-protocol, backend/runtime-routing, capability-
probe, artifact-consumer, release-automation, and regression-policy changes as
high risk. Before mark-ready, run a blocking-only QA pass that is independent
from the implementation task and reviews the exact PR head against the current
base. Classify changed paths with
`tool/testing/classify_high_risk_changes.dart`. Inspect production call sites
and require issue-specific positive and negative tests that fail if the
relevant branch is deleted, bypassed, or miswired.
Record zero known PR-caused P1 regressions and zero unresolved review threads
in the PR's high-risk block.

Structured-output changes must cover compiled grammar acceptance and rejection,
schema-directed scalar and container reconstruction, partial-streaming
suppression and malformed-final rollback, `auto`/`required`/`none` tool choice
with thinking prefixes, and pinned/current upstream parity as applicable. Use
the closest affected-family model or artifact. If exact weights are unavailable,
name every unavailable family and use primary upstream emissions plus durable
fixtures; an unrelated representative model is pipeline-only evidence.

Post-merge QA remains mandatory, but it must not be the first adversarial pass.
If it finds a PR-caused P1, stop lower-priority merge work, file a causally
accurate issue, and prepare one cohesive recovery before resuming feature work.
Security-sensitive required-check publication and repository settings remain a
separate owner-controlled boundary; do not weaken these review requirements
while that enforcement is absent or being changed.

For docs-only PRs, state that runtime behavior is unchanged and list docs
validation. If implementation scope changed, reduce and state the scope rather
than merging incomplete behavior.

### PR Branch Integrity and Mutation Contract

- Repository-local mutations to open PR branches must enforce an expected-head
  compare-and-swap (CAS) plus fast-forward-only contract (`tool/git/safe_pr_head_update.dart`).
  Immediately before mutation, the remote head must match the caller's expected
  head, and the proposed new head must equal that head for an idempotent retry or
  descend from it.
- The helper uses a normal push guarded by the remote OID advertised to a
  one-shot `pre-push` hook. Stale ancestor restorations, force options,
  `+refspec` updates, and blind overwrites are strictly rejected. Read the exact
  target ref back before claiming success.
- Consequence of unexpected transitions (#434 incident): Any unexpected
  branch-head transition invalidates prior CI runs, review approvals, and
  independent QA evidence recorded against that head. If the remote head moves,
  all validation and QA blocks must be re-executed against the exact new head.
- Residual governance boundaries: checkout-local tooling governs only writers
  that invoke it. It cannot govern GitHub web UI updates, Dependabot, installed
  apps, or other server-side writers. The repository relies on branch protection
  and rulesets to block force pushes and enforce linear history, status checks,
  and CODEOWNERS reviews across those paths. See the bounded writer inventory
  and incident evidence in `doc/pr_branch_writer_inventory.md`.

## AGENTS.md Maintenance

- Update this file when a task reveals a durable workflow rule, command,
  ownership boundary, release gate, or validation expectation.
- Remove or replace outdated guidance when repo workflows change.
- Keep this file concise. Prefer pointers to `doc/testing_matrix.md` and
  maintainer website docs over copying long checklists here.
- Avoid session logs, one-off incident details, and duplicated advice.
