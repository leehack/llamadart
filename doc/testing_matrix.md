# Contributor Test Matrix

This repository uses a layered test matrix so contributors can validate the
essential runtime, model, feature, and platform paths without forcing every pull
request to run large local models or device-only checks.

Use the matrix for every non-trivial PR:

```bash
dart run tool/testing/test_matrix.dart --list
dart run tool/testing/test_matrix.dart --pr-template
dart run tool/testing/test_matrix.dart --tier platform
dart run tool/testing/run_local_e2e.dart --list
```

Copy the PR evidence table into the pull request, keep the rows that apply to
the change, and mark skipped rows as `N/A` with a concrete reason.

## Matrix Tiers

| Tier | Meaning | Expected use |
| --- | --- | --- |
| `essential` | Cheap baseline package health checks. | Run for most code PRs and expect CI to cover them. |
| `targeted` | Runtime/model/feature checks selected by touched code. | Run locally or cite the matching CI workflow when the PR touches that path. |
| `high-risk` | Exact-head independent QA and adversarial contracts for regression-sensitive production paths. | Required before mark-ready for parser/grammar/streaming, backend/runtime, capability, artifact-consumer, release-automation, or regression-policy changes. |
| `platform` | Supported platform or architecture validation rows. | Use when a PR affects runtime packaging, native pins, backend selection, app launch, or release confidence for a platform. |
| `release` | Device or representative smoke checks that are too heavy for every PR. | Run for release candidates, native bundle changes, or high-risk runtime changes. |

## Evidence Standard

Each PR should answer four questions:

| Question | Evidence to include |
| --- | --- |
| What changed? | User-facing scope and touched runtime or feature path. |
| Which rows apply? | Matrix row IDs from `tool/testing/test_matrix.dart`. |
| What ran? | Exact command, CI workflow/check name, device, model, and backend. |
| What happened? | PASS/FAIL/N/A plus failure logs, artifact links, or a reason for N/A. |

Prefer exact model names and backend selections over broad phrases. For example:
`Gemma 4 E2B GGUF, WebGPU/llama.cpp, mem64, gpuLayers=0, contextSize=2048`.

## Essential Baseline

The baseline rows are:

```bash
dart run tool/testing/test_matrix.dart --tier essential
```

For a typical code PR, include:

- `static-format-analyze`
- `root-vm`
- `root-chrome` when shared, web, template, or public API code changed
- `coverage-lib` when `lib/` behavior changed or coverage is in doubt

Docs-only PRs can mark runtime rows `N/A`, but should run `docs-site` when docs
or website files changed.

## High-Risk Pre-Merge Gate

The repository classifies production parser/grammar/streaming changes,
backend/runtime routing, public capability probes, artifact consumers, release
automation, and changes to the gate itself as high risk. Discover the required
rows with:

```bash
dart run tool/testing/test_matrix.dart --tier high-risk
```

Before mark-ready, create a blocking-only QA task that is independent from the
implementation task. It must review the exact PR head against the current base,
inspect actual production call sites, and verify issue-specific positive and
negative tests. The tests must fail when the relevant production branch is
deleted, bypassed, or miswired; testing an extracted helper alone is not enough.
Update the machine-readable PR evidence block after the final push or base
movement. The `High-Risk Regression Gate` workflow checks the exact SHA and
base distance, queries live unresolved review threads, and fails closed on
missing or weak evidence. A known PR-caused P1 is always a merge blocker.

For structured output, the independent pass must cover all of these axes in
the production path:

- compile generated grammars and accept actual upstream-emitted valid shapes;
- reject unknown, missing, mismatched, wrong-type, and malformed structures;
- reconstruct schema-directed string, number, boolean, null, object, and array
  values, including empty containers and zero-argument calls;
- suppress incomplete protocol markup while streaming, then preserve ordinary
  content through final malformed rollback;
- exercise `auto`, `required`, and `none` tool choice with thinking/reasoning
  prefixes; and
- run pinned and current upstream template/parser parity.

Use the closest affected-family real model or artifact. If exact weights are
unavailable, name every unavailable family and substitute primary upstream
emissions plus durable fixtures. A Qwen or other unrelated representative
smoke may prove the shared generation pipeline, but must be labeled
`pipeline-only` and cannot claim affected-format validation. This distinction
keeps large model downloads targeted instead of making default CI fragile.

The gate encodes the failure classes discovered after PR #391: envelope/name
grammar mismatches (#394/#399), escaped/schema-exact/delimiter rejection gaps
(#395/#396/#407), partial protocol leakage and final content loss
(#397/#398), thinking/tool-choice prefix failures (#402/#406), and empty or
schema-directed type loss (#408/#410). Post-merge QA still runs, but must not be
the first planned adversarial review.

## Targeted Runtime and Model Rows

Pick targeted rows based on the touched surface:

| Change area | Matrix rows to consider |
| --- | --- |
| Native-assets hook, runtime pin, bundle layout | `native-hook-bundles`, `litert-lm-engine-smoke`, and relevant `platform` rows such as `android-arm64-device-smoke` |
| llama.cpp / GGUF generation, prompt reuse, context reuse | `native-prompt-reuse-parity`, `native-inference-benchmark`, `gguf-chat-features-smoke` |
| Speculative decoding, bundled MTP, or n-gram drafting | `llama-cpp-speculative-benchmark`, `gemma4-mtp-smoke` |
| Embedding API, `embedBatch`, or embedding throughput | `native-embedding-benchmark`, `native-embedding-sweep` |
| Chat template, parser, tools, thinking extraction | `template-parity`, `llama-cpp-chat-template-smoke`, `gguf-chat-features-smoke`, `litert-lm-chat-features-smoke` |
| LiteRT-LM native backend | `litert-lm-engine-smoke`, `litert-lm-chat-features-smoke`, `litert-lm-asr-smoke` |
| Web bridge bootstrap or interop | `web-bridge-smoke`, `web-mock-chat-smoke`, `web-real-model-smoke` |
| WebGPU multimodal | `webgpu-multimodal-regression`, plus `web-speech-to-text-smoke` for typed Qwen3-ASR and `web-text-to-speech-smoke` for typed Qwen3-TTS |
| Large WebGPU GGUF / wasm64 selection | `gemma4-webgpu-mem64` |
| LiteRT-LM web / Gemma 4 web bundle | `gemma4-litert-web` |
| Chat app model cache/download/projector | `chat-app-device-cache` |
| Speech-to-text API or adapter | `speech-to-text-smoke`, `web-speech-to-text-smoke`, plus `litert-lm-asr-smoke` for the dedicated LiteRT-LM streaming engine |
| Text-to-speech API or adapter | `text-to-speech-smoke`, plus `web-text-to-speech-smoke` for browser synthesis/playback/export |
| Chat-app microphone transcription flow | `chat-app-microphone-transcription-smoke` |
| Chat-app live LiteRT-LM dictation | `litert-lm-asr-smoke`, `chat-app-live-speech-smoke` |
| Chat-app Ask with voice | `gguf-audio-chat-smoke`, `litert-lm-chat-features-smoke`, `chat-app-voice-question-smoke` |
| Example app, CLI, or server package | `examples-tests` |

The required `Web Chat Contract` check runs the chat app tests on VM and
Chrome, validates the final Flutter Web artifact, exercises deterministic UI
behavior, and loads a tiny real GGUF through the packaged worker and WASM core.
Large Gemma 4 GGUF and LiteRT-LM downloads remain targeted rows so transient
model-host availability does not make every pull request flaky.

## Coverage Map

The matrix is designed to cover these essential axes:

| Axis | Covered by |
| --- | --- |
| llama.cpp native GGUF | `root-vm`, `native-prompt-reuse-parity`, `native-inference-benchmark`, `gguf-chat-features-smoke`, `gguf-audio-chat-smoke` |
| llama.cpp WebGPU GGUF | `web-bridge-smoke`, `web-mock-chat-smoke`, `web-real-model-smoke`, `webgpu-multimodal-regression`, `web-speech-to-text-smoke`, `web-text-to-speech-smoke`, `gemma4-webgpu-mem64` |
| LiteRT-LM native `.litertlm` | `litert-lm-engine-smoke`, `litert-lm-chat-features-smoke`, `native-hook-bundles` |
| LiteRT-LM web `.litertlm` | `gemma4-litert-web` |
| Model families | Qwen 2.5 prompt reuse, Qwen 3/3.5 chat/multimodal, Gemma 4 tool/thinking/mem64/LiteRT-LM/audio |
| Feature paths | load/generate, prompt reuse, chat templates, streaming, tool calls, thinking, multimodal image/audio, model cache, native hook packaging |
| Platforms | See `dart run tool/testing/test_matrix.dart --tier platform`; each supported family/architecture is marked as CI, local, manual/device, or hook-only. |

## Platform Rows

The platform tier is intentionally explicit about what is runtime-tested versus
only hook/package-tested:

```bash
dart run tool/testing/test_matrix.dart --tier platform
```

| Platform target | Matrix row | Current evidence level |
| --- | --- | --- |
| Linux x64 | `linux-x64-ci-runtime` | CI runtime plus real-model smoke. |
| Linux arm64 | `linux-arm64-runtime-smoke` | Local/self-hosted runtime row; hook coverage in `native-hook-bundles`. |
| Windows x64 | `windows-x64-ci-runtime` | CI runtime plus LiteRT-LM smoke. |
| Windows arm64 | `windows-arm64-hook-coverage` | Hook coverage; runtime proof needs Windows arm64 hardware. |
| macOS arm64 | `macos-arm64-runtime-smoke` | Local/device runtime row. |
| macOS x64 | `macos-x64-runtime-smoke` | Local/device runtime row. |
| iOS arm64 device | `ios-arm64-device-smoke` | Manual/device runtime row. |
| iOS arm64/x86_64 simulator | `ios-simulator-smoke` | Manual/simulator runtime row; LiteRT-LM is arm64-only. |
| Android arm64 | `android-arm64-device-smoke` | Manual/device runtime row and release smoke plan. |
| Android x64 | `android-x64-emulator-smoke` | Manual/emulator runtime row. |
| Web browser | `web-chrome-runtime-smoke` | Chrome CI plus the required real-GGUF `Web Chat Contract`; large WebGPU/LiteRT-LM smokes remain targeted. |

Rows that say `hook-only` must not be used as full runtime proof. They only show
that package/bundle selection is covered; PR evidence still needs a hardware or
emulator run when the runtime behavior itself is at risk.

## Release Rows

Release candidates should include the release tier:

```bash
dart run tool/testing/test_matrix.dart --tier release
```

For releases that change or newly document Flutter Apple SwiftPM companion
package versions, include `release-companion-pub-gate` in the release evidence.
That row requires checking each referenced companion version on pub.dev before
the release-prep PR is merged. If a companion version is missing, keep the PR
scoped to release prep; after merge, `release_on_prep_merge.yml` publishes
missing companion versions, waits for `publish_companion_pubdev.yml`, verifies
the pub.dev version URL, and pushes the core release tag after the companion
gate passes.

## Local Model Scenarios

Real model checks are intentionally local-only. They can use the unified runner:

```bash
dart run tool/testing/run_local_e2e.dart --scenario gguf-chat-features-smoke \
  --model-path models/Qwen3.5-0.8B-Q4_K_M.gguf \
  --backend auto

dart run tool/testing/run_local_e2e.dart --scenario gguf-chat-features-smoke \
  --model-path models/Qwen3.5-0.8B-Q4_K_M.gguf \
  --backend cpu \
  --mmproj-path models/Qwen3.5-0.8B-mmproj-F16.gguf \
  --image-path test/fixtures/image.png

dart run tool/testing/run_local_e2e.dart --scenario gguf-audio-chat-smoke \
  --model-path /path/to/gemma-4-E2B-it-Q4_K_S.gguf \
  --backend metal \
  --mmproj-path /path/to/gemma-4-E2B-it-mmproj-F16.gguf \
  --audio-path /path/to/known-question.wav \
  --expect 4

dart run tool/testing/run_local_e2e.dart --scenario litert-lm-chat-features-smoke \
  --model-path /path/to/gemma-4-E2B-it.litertlm \
  --backend auto \
  --audio-path /path/to/known-question.wav \
  --expect 4

dart run tool/testing/run_local_e2e.dart --scenario speech-to-text-smoke \
  --model-path /path/to/Qwen3-ASR-0.6B-Q8_0.gguf \
  --mmproj-path /path/to/mmproj-Qwen3-ASR-0.6B-Q8_0.gguf \
  --audio-path /path/to/known-speech.wav \
  --expect "Exact expected transcript."

dart run tool/testing/run_local_e2e.dart \
  --scenario chat-app-web-speech-to-text-smoke \
  --audio-path /path/to/known-speech.wav \
  --expect "Exact expected transcript."

# The Web scenario validates both file selection and Chromium's fake
# microphone path with the same WAV fixture. The selected-file result is exact;
# the fake microphone must contain the full expected transcript because its
# artificial input can loop at the capture boundary.

dart run tool/testing/run_local_e2e.dart --scenario text-to-speech-smoke \
  --model-path /path/to/Qwen3-TTS-12Hz-1.7B-Base-Q4_K_M.gguf \
  --mmproj-path /path/to/mmproj-Qwen3-TTS-12Hz-1.7B-Base-Q8_0.gguf

dart run tool/testing/run_local_e2e.dart \
  --scenario chat-app-web-text-to-speech-smoke \
  [--audio-path /path/to/speaker-reference.wav]

dart run tool/testing/run_local_e2e.dart --scenario chat-app-web-mock-smoke

dart run tool/testing/native_inference_benchmark.dart \
  --model models/Qwen3.5-0.8B-Q4_K_M.gguf \
  --gpu-layers 0 \
  --mode all \
  --runs 3 \
  --max-tokens 128

dart run tool/testing/run_local_e2e.dart \
  --scenario llama-cpp-speculative-benchmark \
  --model-path models/Qwen3.5-0.8B-Q4_K_M.gguf \
  --draft-model-path path/to/dspark-draft.gguf \
  --speculative-cases baseline,draft-dspark,ngram-simple,ngram-map-k,ngram-map-k4v,ngram-mod,ngram-cache,mixed-ngram \
  --backend cpu \
  --benchmark-gpu-layers 0 \
  --benchmark-max-tokens 128 \
  --benchmark-runs 3 \
  --draft-token-max 1,2 \
  --ngram-size-m 8,16 \
  --benchmark-warmups 1 \
  --ngram-cache-build-static-path /tmp/llamadart-ngram-cache.bin

dart run tool/testing/run_local_e2e.dart \
  --scenario gemma4-mtp-smoke \
  --model-path models/gemma-4-e2b-mtp-Q4_K_M.gguf \
  --benchmark-max-tokens 32 \
  --draft-token-max 1

dart run tool/testing/run_local_e2e.dart \
  --scenario native-embedding-benchmark \
  --model-path models/embedding-model.gguf \
  --benchmark-runs 3 \
  --benchmark-warmups 1 \
  --benchmark-gpu-layers 0

dart run tool/testing/run_local_e2e.dart \
  --scenario native-embedding-sweep \
  --model-path models/embedding-model.gguf \
  --benchmark-runs 3 \
  --benchmark-warmups 1 \
  --benchmark-gpu-layers 0
```

`native-embedding-benchmark` compares sequential embedding calls against
`embedBatch(...)` at a fixed `--max-seq`, while `native-embedding-sweep` runs the
same benchmark across `1,2,4,8` and writes
`build/embedding_speedup_sweep.csv` for plotting. Use the sweep when choosing or
defending a default `maxParallelSequences`, and the single benchmark when one
data point is enough. Both are `local-only` and need a real embedding-capable
GGUF model; `website/docs/guides/embeddings.md` documents the underlying scripts
directly for ad hoc runs.

The dedicated `gguf-audio-chat-smoke` scenario validates byte-backed audio
question answering against `--expect` after model and projector initialization.
Run `gguf-chat-features-smoke` separately for chat, tool-call, thinking, and
optional image checks. Both GGUF and LiteRT-LM audio results report the encoded
byte length and a stable SHA-256 fixture ID, but not the fixture path or raw
audio bytes.

`gemma4-mtp-smoke` is a fast correctness companion to
`llama-cpp-speculative-benchmark`: it checks that bundled MTP still produces
coherent Gemma 4 output before the fuller throughput and acceptance run. For MTP
and n-gram *performance* numbers, use `llama-cpp-speculative-benchmark` with
`--speculative-cases draft-mtp,ngram-simple`, which supersedes the older
env-var-driven benchmark script. Like every `local-only` row, neither runs in CI.

In the local E2E scenario, external draft-model strategies require
`--draft-model-path`; select `draft-dspark` to validate DSpark against the same
target baseline. Bundled MTP uses `draft-mtp` without that option; the runner
then loads the target with `ModelParams.loadMtp` automatically. The n-gram
cache strategy can use existing cache paths or build a static cache with
`--ngram-cache-build-static-path`.
For `ngram-simple`, `ngram-map-k`, and `ngram-map-k4v`, `--ngram-size-m`
sweeps the effective n-gram draft length; `--draft-token-max` is still useful
for draft-model, ngram-cache, and mixed draft-model cases. Use
`--ngram-token-max` to cap ngram-mod when it should differ from
`--draft-token-max`.
Speculative benchmark prompts use the loaded model's chat template by default;
use raw-prompt options only for intentional raw-vs-template comparisons.
When investigating output-hash mismatches for n-gram speculation, compare the
same prompt and sampling settings against upstream `llama-server` before
classifying the mismatch as a Dart-only regression; upstream `ngram-map-k` can
diverge from baseline once repeat penalties and accepted drafts are involved.
Use `--include-output` when the exact divergence text is needed in the JSON
report.
When a speculative performance issue is being closed, include the matching
upstream `llama-cli` or `llama-server` command where a comparable tool binary is
available. If the exact packaged native tag does not publish standalone tools,
state the closest upstream build used and keep any remaining artifact-parity gap
linked as a follow-up.

```bash
dart run tool/testing/run_local_e2e.dart \
  --scenario llama-cpp-chat-template-smoke \
  --model-path models/Qwen3.5-0.8B-Q4_K_M.gguf
```

Use `--dry-run` first when a scenario starts servers, builds Flutter web, or
requires local model URLs.

## PR Evidence Template

Generate the current template instead of hand-copying from this doc:

```bash
dart run tool/testing/test_matrix.dart --pr-template
```

Example filled row:

| Matrix row | Scope covered | Platform / model / backend | Result | Evidence / notes |
| --- | --- | --- | --- | --- |
| `gguf-chat-features-smoke` | base GGUF chat/tool/thinking | macOS arm64, Qwen3.5-0.8B-Q4_K_M.gguf, llama.cpp auto/cpu | PASS | Base `RESULT gguf_chat_features ...`, no thinking marker leak, and one `get_weather` tool call. |
| `gguf-audio-chat-smoke` | byte-backed exact audio answer | macOS arm64, Gemma 4 E2B GGUF + projector, llama.cpp Metal | PASS | Audio-only result with `variant: audioAnswer`, exact expected text, and fixture SHA-256. Experimental engine evidence is not microphone UI or mobile validation. |

## Agentic Workflow

When an agent creates or updates a PR:

1. Run `dart run tool/testing/test_matrix.dart --list` and choose rows from the
   touched surfaces.
2. Run essential rows first, then targeted local-only rows with `--dry-run`
   before heavy execution.
3. If a row cannot run locally, record why and whether CI, device availability,
   or a follow-up issue covers it.
4. Paste or update the PR matrix evidence table before asking for review.
5. Do not leave one-off repro scripts behind. Promote durable checks into
   `test/unit/`, `test/integration/`, or `test/e2e/`; wire heavyweight manual
   checks through `tool/testing/run_local_e2e.dart` and
   `tool/testing/test_matrix.dart`.
