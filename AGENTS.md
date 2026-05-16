# AGENTS.md

This file provides guidance for agentic coding assistants working in the llamadart repository.

## Build / Lint / Test Commands

### Development Commands
```bash
dart pub get                              # Install dependencies
dart format .                             # Format all Dart files
dart format --output=none --set-exit-if-changed .  # Check only, CI-friendly
dart analyze                              # Run static analysis/linting
dart analyze --fatal-infos              # Optional stricter local check for info-level lints
```

### Testing Commands
```bash
dart test                                 # Run all platform-compatible tests (VM or browser)
dart test -p vm                           # Run only VM (native) tests
dart test -p chrome                       # Run only Chrome (web) tests
dart test --run-skipped -t local-only     # Run local-only E2E scenarios
dart test test/path/to/test_file.dart     # Run a single test file
dart test -p vm --coverage=coverage       # Run VM tests and collect coverage
dart pub global run coverage:format_coverage --lcov --in=coverage/test --out=coverage/lcov.info --report-on=lib --check-ignore
dart run tool/testing/check_lcov_threshold.dart coverage/lcov.info 70
```

### Local Chat App Web E2E
Use the real chat app path for WebGPU bridge validation after bridge/runtime
updates. This catches issues that direct bridge probes miss.

```bash
cd example/chat_app
flutter build web --base-href=/example/chat_app/build/web/
cd ../..
python3 tool/testing/serve_static_with_headers.py --directory . --port 7358

.venv-playwright/bin/python tool/testing/playwright_chat_app_real_model_smoke.py \
  http://127.0.0.1:7358/example/chat_app/build/web/ \
  --model-url http://127.0.0.1:7358/example/llamadart_server/models/Qwen3.5-0.8B-Q4_K_M.gguf \
  --expect 4
```

When serving `build/web` under a repo-root path, build with the matching
`--base-href`; otherwise Flutter resolves `flutter_bootstrap.js` and
`webgpu_bridge/*` from `/`. On macOS headless Chromium, use the smoke script's
default `--browser-angle auto` or pass `--browser-angle metal`; without Metal
ANGLE the adapter may lack `shader-f16` and llama.cpp can abort in
`ggml-webgpu` even for CPU/gpuLayers=0 runs. For larger models such as Gemma 4,
pass `--mem64` and a smaller `--context-size` to keep the smoke bounded.

### CI Standards
- `dart format --output=none --set-exit-if-changed .` checks formatting
- `dart analyze` runs the linter
- `dart test -p vm -j 1 --exclude-tags local-only` runs native tests sequentially (required for some OS)
- CI enforces >=70% line coverage for maintainable `lib/` code using `--check-ignore` (generated files marked with `// coverage:ignore-file` are excluded)

## Code Style Guidelines

### Imports
- Start with Dart SDK imports (`dart:core`, `dart:async`, etc.)
- Follow with package imports from external dependencies
- Use relative path imports for same-package files (`'../backends/backend.dart'`)
- Group imports with blank lines between categories
- No `show`/`hide` unless necessary for deconfliction

### Formatting
- Use `dart format` with default settings (no trailing comma, 80 character line length)
- Single blank line between top-level declarations
- Two blank lines between class-level sections

### Types & Declarations
- Explicit types on all public APIs: parameters, return types, fields
- Type inference (`var`, `final`) can be used for obvious local types
- Immutable data classes use `const` constructors where possible
- Private fields use leading underscore (`_modelHandle`)

### Naming Conventions
- Classes: `PascalCase` (e.g., `LlamaEngine`, `ChatSession`)
- Functions/methods: `camelCase` (e.g., `loadModel`, `setLogLevel`)
- Variables/params: `camelCase` with descriptive names
- Private members: leading underscore (`_isReady`)
- Constants: `lowerCamelCase` (e.g., `contextSize`, `gpuLayers`)
- Files: `snake_case.dart`
- Directories: `snake_case`

### Documentation
- All public members require Dart doc comments (`///`)
- Use triple-slash doc format with proper Markdown
- Include usage examples in class-level documentation
- Parameter and return types documented
- No TODO/FIXME comments in committed code

### Changelog Discipline
- Never add unreleased work to an already-published version section in
  `CHANGELOG.md` or `website/docs/changelog/recent-releases.md`.
- Before editing release notes, check the top of `CHANGELOG.md`. If the latest
  section is a concrete released version (for example `## 0.6.12`), create a
  new `## Unreleased` section above it and place new PR entries there.
- Only move entries from `## Unreleased` into a numbered version section as part
  of an explicit release/version-bump task.

### Error Handling
- Use custom `LlamaException` hierarchy (defined in `lib/src/core/exceptions.dart`)
- Subtypes: `LlamaModelException`, `LlamaContextException`, `LlamaInferenceException`, `LlamaStateException`, `LlamaUnsupportedException`
- Accept optional `details` parameter for additional context
- Include human-readable message in `toString()`

### Library Structure
- Use `library;` directive in top-level export files
- Export clean public APIs via `lib/llamadart.dart`
- Keep implementation details in `lib/src/` subdirectories

### Platform Compatibility
- Use conditional imports for platform-specific backends (`if (dart.library.js_interop)`)
- Tag tests with `@TestOn('vm')` or `@TestOn('browser')`
- Keep `LlamaEngine` free of `dart:ffi` and `dart:io` for web support

### Architecture Principles
- Zero-Patch Strategy: Never patch upstream native sources in this repository
- Use wrappers and hooks for necessary integrations
- Modular separation: `engine/`, `backends/`, `models/`, `utils/`
- Abstract interfaces in `backends/backend.dart`

### Capability & Runtime Semantics
- Prefer explicit capability probes over structural/interface checks when behavior
  depends on runtime assets, platform support, browser APIs, or native feature
  availability. For example, user-facing state persistence checks should use
  `LlamaEngine.supportsStatePersistence` rather than assuming that a backend
  implementing `BackendStatePersistence` is currently usable.
- Unsupported paths must fail loudly with actionable diagnostics. Include the
  missing capability, platform/runtime condition, and version requirement where
  known (for example, a named WebGPU bridge API plus the minimum bridge asset
  version or runtime flag required for that feature).
- Do not silently report success for unsupported platform/option combinations.
  Public engine/API paths should either gate behavior with an explicit support
  flag or throw a typed `LlamaUnsupportedException` before mutating state.

### Web / WebGPU Bridge Expectations
- WebGPU bridge features are versioned runtime capabilities. When changing bridge
  behavior, verify the pinned asset tag/manifest, direct bridge calls, worker
  path, Dart interop wrapper, public engine API, docs, and examples together.
- Document browser durability precisely. Web bridge filesystem paths may be
  virtual or in-memory unless the active bridge documents durable backing
  storage; durable browser storage can require app-level export/import outside
  Dart file helpers.
- Add regression coverage for both happy and negative paths: missing bridge API,
  old bridge assets, `supports* == false`, correctly awaited sync/async errors,
  and alternate JS interop return shapes.
- Keep README, website docs/support matrix, examples, and changelog aligned with
  any public capability or platform-support change.

### Testing Standards
- New public APIs require unit or integration tests
- Test both Native (VM) and Web implementations for refactored shared logic
- Capability-dependent behavior needs tests for unsupported and version-skew
  paths, not just the happy path. Assert error messages when they are intended
  to guide users toward a specific bridge/runtime version or configuration.
- Mark generated files with `// coverage:ignore-file` so coverage gates exclude them
- Use `expect` matchers over `assert`
- Close ports/streams in `setUp`/`tearDown` to avoid hanging
- Use `group` for logical test organization

### File Organization
- Library entry point: `lib/llamadart.dart`
- Public APIs in `lib/src/core/` with clear separation: `engine/`, `models/`, `template/`
- Tests mirror lib structure: `test/unit/` and `test/integration/`
- Native assets hook: `hook/build.dart` (downloads precompiled binaries)

### Const & Immutability
- Use `const` constructors wherever possible for immutable classes
- Data classes should have `const` constructors with `const` fields
- Factory constructors can be used but prefer `const` when feasible

### Async Patterns
- Use `Future<T>` and `Stream<T>` from `dart:async`
- Prefer async/await over chained `.then()` calls
- Use `StreamController` for custom streams with proper cleanup
- Cancel streams in `dispose()` methods

### Import Examples
```dart
// Correct import order:
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../core/engine/engine.dart';
import '../backends/backend.dart';
```

### Exception Examples
```dart
// Throwing proper exceptions:
throw LlamaModelException('Failed to load model', 'Invalid GGUF format');

// Throwing unsupported:
throw LlamaUnsupportedException('GPU acceleration not available on this platform');
```

### Zero-Patch Strategy Details
- Native build/source ownership lives in `llamadart-native`
- This repository should not add local `llama.cpp` patches or build scripts
- Keep local native integration focused on hook/config/bindings consumption
- Web bridge source/build ownership lives in `llama-web-bridge`
- Web bridge runtime asset publishing ownership lives in `llama-web-bridge-assets`
- Keep local web integration focused on bridge tag pinning, fetch flow, and runtime wiring

## Multi-Repo Workspace Guidance

### Ownership Map
- `llamadart` (this repo): Dart API, hook integration, runtime selection, docs/tests
- `llamadart-native`: native build graph, C/C++ wrapper behavior, backend bundle matrix, releases
- `llama-web-bridge`: web bridge source/runtime behavior
- `llama-web-bridge-assets`: published bridge artifacts consumed by this repo

### Local Path Convention
Many maintainer environments keep sibling checkouts one level above this repo:

```text
../llamadart
../llamadart-native
../llama-web-bridge
../llama-web-bridge-assets
```

This is a convenience convention and may differ by environment.
Before operating on sibling repos, verify they exist:

```bash
test -d ../llamadart-native
test -d ../llama-web-bridge
test -d ../llama-web-bridge-assets
```

### Cross-Repo Change Flow
1. Make/runtime-fix changes in the owning repository (`llamadart-native` or `llama-web-bridge`).
2. Commit/push there first.
3. Publish/update artifacts in the owning release/assets repo.
4. Update pins/tags/hook/docs in `llamadart`.
5. Run `dart analyze` and relevant tests in `llamadart` before final commit.

## Development Workflow

### Before Committing
1. Run `dart format .` to ensure code is properly formatted
2. Run `dart analyze` to fix all warnings and lint errors
3. Run `dart test` to verify all tests pass
4. For new features, add tests to maintain >=70% coverage on maintainable source code (generated files are excluded via `// coverage:ignore-file`)

### Production-Readiness Gate
Treat `main` as production-ready. Before opening or updating a non-trivial PR,
make sure the PR template can honestly answer:

- **User-facing scope**: what users can do after merge, and what is explicitly
  out of scope.
- **Platform matrix**: native, WebGPU, Flutter examples, docs-only, or other
  relevant paths are listed with actual validation evidence.
- **Unsupported combinations**: unsupported platforms/options fail loudly with a
  typed/actionable error, disabled UI, or documented fallback; never report
  success for a path that is not implemented.
- **Docs/release notes**: README, website docs, examples, support matrices, and
  changelog entries are updated when public behavior changes.
- **Regression coverage**: tests cover the issue plus important negative or
  version-skew paths where applicable.
- **Security/privacy**: logs, cache keys, metadata, errors, and snapshots do not
  expose credentials, bearer tokens, signed URLs, or raw secret-bearing paths.
- **Follow-ups**: useful but non-blocking work is tracked in GitHub Issues before
  merge and linked from the PR body.

If the implementation cannot satisfy the full originally planned scope, reduce
and state the scope instead of merging incomplete behavior. For docs-only PRs,
state that runtime behavior is unchanged and list the docs validation performed.

### Syncing Native Version
When you need to update native version + bindings in this repository:
```bash
# Preferred: run the repository workflow
# .github/workflows/sync_native_bindings.yml
```

For local regeneration workflows, sync headers from `llamadart-native` and run:
```bash
tool/native/sync_native_headers_and_bindings.sh --tag latest
```

### Syncing Web Bridge Assets
To refresh local pinned bridge assets for `example/chat_app/web`:

```bash
WEBGPU_BRIDGE_ASSETS_TAG=<tag> ./scripts/fetch_webgpu_bridge_assets.sh
```

### Preparing Releases
- When cutting a release, move accumulated `CHANGELOG.md` and
  `website/docs/changelog/recent-releases.md` entries from `Unreleased` into
  the new version section.
- Do not leave an empty `Unreleased` section in committed release prep. Add
  `Unreleased` back only when the next unreleased change is documented.

### Adding New Features
1. Create public API in appropriate `lib/src/` subdirectory
2. Export via `lib/src/api/llamadart.dart` if part of public API
3. Add unit tests in `test/unit/` and integration tests in `test/integration/`
4. Update documentation with examples for new APIs
5. Ensure both VM and web implementations work (for shared logic)

### Code Review Checklist
- Public APIs documented with `///` Dart doc comments
- Types explicitly declared on public APIs
- Imports ordered correctly (SDK, packages, relative)
- Exceptions use `LlamaException` hierarchy
- Tests added for new functionality
- No `@ignore` for lints without clear justification
