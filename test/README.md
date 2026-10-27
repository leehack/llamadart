# Test Suite Layout

This project organizes tests into three layers:

- `test/unit/`: fast, deterministic tests that mirror `lib/src/` structure.
- `test/integration/`: multi-component scenarios that still run in CI.
- `test/e2e/`: slow or resource-heavy scenarios tagged `local-only`.

## Running tests

```bash
# Default suite (VM + Chrome-compatible tests)
dart test

# Only VM tests
dart test -p vm

# Only browser tests
dart test -p chrome

# Local-only E2E tests
dart test --run-skipped -t local-only

# Enumerate repeatable local browser/device smoke scenarios
dart run tool/testing/run_local_e2e.dart --list

# Print the contributor validation matrix and PR evidence table
dart run tool/testing/test_matrix.dart --list
dart run tool/testing/test_matrix.dart --pr-template
dart run tool/testing/test_matrix.dart --tier platform

# Real Gemma 4 LiteRT-LM web smoke
dart run tool/testing/run_local_e2e.dart --scenario chat-app-web-litert-gemma4-smoke

# Template parity suites (sequential, local-only e2e included)
tool/testing/run_template_parity_suites.sh
```

## Conventions

- `test/unit/` mirrors `lib/src/` for every source file that has behavior of its own (except the structure guard test itself).
- The mirrored mapping is enforced by `test/unit/test_structure/mirrored_unit_structure_test.dart`.
- Generator output is excluded from mirroring, matched on the banner ffigen writes (`AUTO GENERATED FILE, DO NOT EDIT.`) or the one `tool/gen_litert_lm_templates.dart` writes (`GENERATED FILE — DO NOT EDIT BY HAND.`). `// coverage:ignore-file` is a coverage pragma and does not exempt a file.
- A source with no behavior of its own (a bare enum, a marker interface, `external` interop declarations) is listed in the guard's `behaviorlessSources` set instead of getting a test file. Never write an assertion that is true by construction, such as `expect(SomeType, isNotNull)` or `expect(Enum.values, contains(Enum.member))`; assert the wire value where it is consumed, or a deliberate `values.length` change-detector.
- Cross-file regressions and diagnostics belong in `test/integration/`.
- Mark platform-specific files with `@TestOn('vm')` or `@TestOn('browser')`.
- Use `@Tags(['local-only'])` for tests that should not run in default/CI flows.

## FP8 image weights on Metal

Use an existing FP8 checkpoint to verify public automatic/explicit Metal
refusal and the direct worker guard for a runtime without the FP8 load fix,
without running an unsafe native load:

```bash
LLAMADART_IMAGE_FP8_MODEL=/path/to/fp8.safetensors TMPDIR="$(mktemp -d)" \
  dart test -p vm -j 1 --run-skipped -t local-only \
  test/e2e/backends/stable_diffusion_fp8_preflight_e2e_test.dart
```

This macOS check reads the real header and records zero context constructions
for Metal. Its CPU control forwards the same file through the worker on a
recording runtime. Generation on the pinned runtime, which loads FP8 as F16
on Metal, runs from `example/basic_app` (`LLAMADART_IMAGE_F16_MODEL`
optionally records the F16 source's Metal pixels for comparison):

```bash
LLAMADART_IMAGE_FP8_MODEL=/path/to/fp8.safetensors TMPDIR="$(mktemp -d)" \
  dart test --run-skipped -t local-only test/image_fp8_metal_e2e_test.dart \
  test/image_fp8_cpu_e2e_test.dart
```

See [#1446](https://github.com/leehack/llamadart/issues/1446).

## EmbeddingGemma-2 native qualification

Set `LLAMADART_EMBEDDINGGEMMA2_MODEL_PATH` to the official
`embeddinggemma-2-BF16.gguf` and run:

```bash
LLAMADART_EMBEDDING_BACKEND=cpu dart test \
  test/e2e/backends/embedding_models_e2e_test.dart --run-skipped -p vm \
  --name EmbeddingGemma-2
```

This local-only check verifies 768-dimensional projected text outputs,
normalization, distinct inputs, batch parity and reuse. Set the backend to
`metal` to qualify that path separately. It does not exercise image or audio
embedding inputs; those are covered by the
`native-multimodal-embeddings` local E2E scenario and the `embedding-gguf-*`
validation pack.
