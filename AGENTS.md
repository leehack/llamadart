# AGENTS.md

Open a linked doc before working in its area; it holds the procedure this file
leaves out.

## Build and test

```bash
dart run tool/prepare_workspace.dart
dart format --output=none --set-exit-if-changed .
dart analyze   # CI's Pana step also fails on any info in lib/
dart run tool/testing/check_platform_boundaries.dart
dart test -p vm -j 1 --exclude-tags local-only
dart test -p chrome --exclude-tags local-only
```

- Run `prepare_workspace.dart` first, on a clean checkout; CI fails if it leaves
  tracked files modified. Never hand-edit a `pubspec.lock`: constrain
  `pubspec.yaml` and let pub regenerate it.
- Use the Flutter SDK in `.flutter-version`; other SDKs format differently from
  CI. A pin bump is its own PR that updates `.flutter-version`, every workflow
  `flutter-version:`, and the reformat it causes.
- Root preparation, analysis and tests skip `packages/` (root format does
  not): companion packages keep their own dependency, analyze, test, SwiftPM
  and publish-validation lanes (`ci.yml`).
- Chat app changes: `(cd example/chat_app && flutter test)`, plus
  `flutter test --platform chrome test/chat_generation_service_test.dart` there
  for Web-only paths such as LiteRT-LM generation settings.
- Pick further validation from `dart run tool/testing/test_matrix.dart --list`
  (`doc/testing_matrix.md`) and put its `--pr-template` rows in the PR.
- Heavy, device- or model-backed checks stay out of default CI: tag such tests
  `local-only`, or wire the scenario into `run_local_e2e.dart` and
  `test_matrix.dart` and document it. Run one with `run_local_e2e.dart --list`,
  then `--scenario <name> --dry-run` before a real run. No one-off repro
  scripts in `tool/testing/`; prefer durable tests under `test/`.
- Build, serve or Playwright-smoke the Web chat app only through
  `run_local_e2e.dart` web scenarios or `scripts/build_chat_app_web.sh`; a plain
  `flutter build web` omits the gitignored bridge assets. Check a reused build
  with `scripts/validate_chat_app_web_build.sh`. To run a helper by hand, copy
  what `--dry-run` prints. Keep the required `Web Chat Contract` CI job free of
  large or availability-sensitive remote models.
- Before calling a llama.cpp n-gram speculative output-hash mismatch Dart-only,
  compare the same prompt and sampling settings against upstream `llama-server`.
- Docs: `./tool/docs/build_site.sh` fails on broken links.

## Code

- Prefer small, reviewable changes and simple, focused designs without
  meaningful duplication. Add an abstraction only to cut real complexity,
  protect a stable boundary or match a repo pattern; refactor beyond the task
  only when correctness or maintainability needs it.
- Order imports SDK, package, then relative, with a blank line between groups.
  Avoid `show`/`hide` on imports unless resolving a name clash.
- Names: `PascalCase` types; `lowerCamelCase` members, variables and
  constants; `snake_case` files and directories.
- No new TODO/FIXME comments in maintained Dart or workflow code.
- Export new public API from `lib/llamadart.dart` with explicit parameter,
  return and field types (locals may infer), useful `///` Dartdoc, and tests;
  implementation stays in `lib/src/`. Select platform-specific backends with
  conditional imports or exports.
- Throw the `LlamaException` hierarchy (`lib/src/core/exceptions.dart`). An
  unsupported platform or option combination throws `LlamaUnsupportedException`
  (or a typed subtype) naming the missing capability, the platform/runtime
  condition and, where known, the required version, or it is explicitly
  disabled and documented. It never reports success.
- When behavior depends on runtime assets, platform, browser APIs or native
  features, prefer an explicit capability probe to a structural or interface
  check, and test both the supported and the unsupported/version-skew path.
- If `test/unit/test_structure/mirrored_unit_structure_test.dart` demands a test
  for a file with no behavior (bare enum, marker interface, `external` interop
  only), add the file to its `behaviorlessSources`. Never assert something true
  by construction; assert wire values where they are consumed
  (`test/README.md`).
- Generated files that should not count toward coverage carry
  `// coverage:ignore-file`.
- Tests close the ports, streams and controllers they open.
- A public capability or platform-support change updates README, website
  docs/support matrix, examples and changelog in the same PR.
- Keep credentials, tokens, signed URLs and secret-bearing paths out of logs,
  errors, cache keys, metadata and snapshots.

## Ownership

Never patch upstream native or web bridge sources here. Owners:
`llamadart-native` (llama.cpp runtime), `litert-lm-native` (LiteRT-LM runtime),
`llama-web-bridge` (web bridge), `llama-web-bridge-assets` (published assets).
This repo only consumes them: native hook/config/bindings, and bridge tag
pinning, fetch and runtime wiring
(`website/docs/maintainers/runtime-ownership.md`). Checkouts often keep them as
siblings in `..`; verify the path first. Change and release the owning repo
first, then update pins, hooks, docs and tests here.

- A WebGPU bridge change is verified across the pinned tag/manifest, direct and
  worker paths, Dart interop, public API, docs and examples together; capability
  floors and changelog entries keep their own versions. Bridge behavior and
  browser-storage durability: `doc/webgpu_bridge.md`.
- Native or web pins, bindings, sync scripts, `hook/`, or companion SwiftPM
  changes: `website/docs/maintainers/native-and-web-sync.md`. Native release
  tags: `latest` accepts only unsuffixed `vMAJOR.MINOR.PATCH`; new nightly
  wrapper rebuilds use `bNNNN-N`, while `bNNNN-llamadart.N` is consume-only;
  nightly cores use canonical decimal spelling, and rebuild counters start at 1
  without leading zeros.

## Changelog and releases

- New entries go under `## Unreleased` in `CHANGELOG.md` and
  `website/docs/changelog/recent-releases.md`; add that heading if the top
  section is a released version. Never add to a released section. Move
  `Unreleased` into a version only in an explicit release task.
- One short user-facing bullet per change; implementation detail and migration
  notes go in the PR or maintainer docs.
- Never push release tags by hand unless release automation is disabled,
  blocked or being repaired. Give each new release-sensitive path a
  `.github/CODEOWNERS` entry. Release work follows
  `website/docs/maintainers/release-workflow.md`.

## Pull requests

- `main` stays production-ready. The PR body follows
  `.github/pull_request_template.md`; fill every section or mark it N/A with a
  reason.
- Update an open PR branch only through `tool/git/safe_pr_head_update.dart`
  (expected-head CAS, fast-forward only); writers it cannot govern are in
  `doc/pr_branch_writer_inventory.md`. Whenever the head moves, earlier CI runs,
  approvals, audits and matrix evidence no longer count: rerun or re-request
  them against the new head and update the PR body.
- Before merge, reply to every review thread, with concrete rationale when not
  acting on it, and resolve it.
- Classify every PR with
  `git diff --name-only --no-renames <base>...HEAD | dart run tool/testing/classify_high_risk_changes.dart`.
  Before a high-risk PR is marked ready, an independent auditor runs a
  blocking-only adversarial review of the exact head against the current base.
  The auditor is an operator or a fresh agent session that took no part in the
  implementation, never the PR author.
  Build the evidence per `doc/high_risk_pre_merge_readiness.md` and check it
  with `tool/testing/high_risk_readiness.dart` against
  `tool/testing/high_risk_readiness_evidence.schema.json`; a valid local run
  exits 2 (`unverifiedPrerequisites`). Mark ready only with
  zero known PR-caused P1 regressions and zero unresolved review threads,
  recorded in the PR's high-risk block and the evidence.
- Use the closest affected-family model or artifact; if its weights are
  unavailable, name each unavailable family and use primary upstream emissions
  plus durable fixtures. An unrelated model is pipeline-only evidence.
- Post-merge QA is still required but is never the first adversarial pass. If
  it finds a PR-caused P1, stop lower-priority merge work, file a causally
  accurate issue, and prepare one cohesive recovery before resuming feature
  work.

## This file

When a task reveals a durable rule that changes agent behavior and that no
tool, test or linked doc covers, add it here. Point to docs instead of copying
them, delete stale rules, and leave out incident history. Tests pin some
phrases here, and docs-only CI does not run them: after editing, run
`dart test -p vm test/unit/tooling/`.
