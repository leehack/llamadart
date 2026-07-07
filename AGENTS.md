# AGENTS.md

Guidance for agentic coding assistants working in this repository. Keep this
file as the compact entrypoint for durable repo rules; put detailed matrices and
long procedures in discoverable docs.

## Quick Commands

```bash
dart pub get
dart format .
dart format --output=none --set-exit-if-changed .
dart analyze
dart test -p vm -j 1 --exclude-tags local-only
dart test -p chrome --exclude-tags local-only
```

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

Document browser durability precisely. Web bridge filesystem paths may be
virtual or in-memory unless the active bridge documents durable backing storage;
durable browser storage can require app-level export/import outside Dart file
helpers.

Unsupported platform or option combinations must fail loudly with typed,
actionable errors or be explicitly disabled/documented.

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
```

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

For docs-only PRs, state that runtime behavior is unchanged and list docs
validation. If implementation scope changed, reduce and state the scope rather
than merging incomplete behavior.

## AGENTS.md Maintenance

- Update this file when a task reveals a durable workflow rule, command,
  ownership boundary, release gate, or validation expectation.
- Remove or replace outdated guidance when repo workflows change.
- Keep this file concise. Prefer pointers to `doc/testing_matrix.md` and
  maintainer website docs over copying long checklists here.
- Avoid session logs, one-off incident details, and duplicated advice.
