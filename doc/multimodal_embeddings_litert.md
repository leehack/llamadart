# LiteRT-LM embedding qualification blockers (015-C)

Tracking: https://github.com/leehack/llamadart/issues/1072.
Contract: [Multimodal embeddings](multimodal_embeddings.md).

**015-C is blocked on the pinned runtimes. No embedding implementation or
capability is enabled by this report.** The temporary integration prototype
was removed after qualification found the blockers below. The existing native
and Web adapters continue to reject `liteRtLmEmbeddingEngine: true`.

## Required owner changes

| Boundary | Evidence | Required action |
| --- | --- | --- |
| Whole-batch capacity preflight | Upstream `EmbeddingEngineImpl::ComputeEmbeddingBatch` loops over inputs, calls `ProcessAndCombineContents`, then `ComputeEmbeddingInternal` for each input before examining the next. The C and Web APIs expose compute methods but no embedding preflight/token-count operation. | Publish native and Web APIs that validate the entire expanded batch before the first embedding inference, or obtain an explicitly coordinated shared-contract change. The 015-C lane must not weaken the contract itself. |
| Native macOS GPU | The supplied bundle crashed during `weight_loader::LiteRtWeightLoader::PrepareAccessForBuffer` with `BUS_ADRALN` (exit 138), both through Dart and through an upstream-only Python/ctypes C API reference. | Repair and publish the owner runtime, then qualify the affected artifact. Leave GPU embeddings unavailable meanwhile. |
| Web CPU | `@litert-lm/core@0.18.0` failed while creating the text embedding executor: `Failed to get external weight for buffer id 2147483863 (tensor 1451)`. An upstream-only JS reference reproduced this with and without media processors; no vectors were produced. | Qualify a compatible bundle/package combination before enabling any Web embedding modality. No alternate weights or package versions were downloaded for this investigation. |

Pinned source evidence:

- [Batch execution order, upstream b2f686e2, lines 1639–1676](https://github.com/google-ai-edge/LiteRT-LM/blob/b2f686e2ed4718fb84ec398a61dd59ca0f0aff27/runtime/core/embedding_engine_impl.cc#L1639).
- [Native embedding C API](https://github.com/google-ai-edge/LiteRT-LM/blob/b2f686e2ed4718fb84ec398a61dd59ca0f0aff27/c/embedding_engine.h)
  and [C batch dispatch](https://github.com/google-ai-edge/LiteRT-LM/blob/b2f686e2ed4718fb84ec398a61dd59ca0f0aff27/c/embedding_engine.cc#L448).
- [Pinned Web embedding API](https://cdn.jsdelivr.net/npm/@litert-lm/core@0.18.0/dist/embedding_engine.d.ts),
  [settings](https://cdn.jsdelivr.net/npm/@litert-lm/core@0.18.0/dist/embedding_engine_settings.d.ts),
  and [implementation](https://cdn.jsdelivr.net/npm/@litert-lm/core@0.18.0/dist/embedding_engine.js).

Both APIs expose overflow-error options. Selecting error prevents silent
truncation/chunk averaging; it does **not** turn the sequential batch loop into
whole-batch preflight. Implementing that missing operation in Dart would require
reproducing the runtime's tokenizer, special-token insertion and expanded media
processing. Neither approximate text lengths nor a prior inference is a valid
substitute.

Runtime changes belong to `litert-lm-native` and the official Web package;
see [runtime ownership](../website/docs/maintainers/runtime-ownership.md) and
[native/Web sync](../website/docs/maintainers/native-and-web-sync.md). Task 015-C
explicitly forbids new package versions, pushes and changes to A's shared
contracts. Those constraints prevent completing the required batch path here.

## Prototype results (not shipped support)

The read-only model was
`embeddinggemma-2-740m.litertlm` from `litert-community`, revision `24d962e9`.
SHA-256:
`e7a8a2204b91e0f96e92960e84a09a89212e1633dcb7575a9bf3378b4df77f4c`. The native library came from
the hook-prepared `v0.18.0-2` artifact, not the sibling checkout's older `bin/`
copy, which lacks embedding-engine exports.

macOS arm64 CPU initialized the embedding engine with CPU vision and audio
processors and `max_input_length = 1024`. The actual bundle header contains
text-encoder/embedder sections, vision encoder/adapter sections and audio
encoder/adapter sections. Adjacent text was merged verbatim before constructing
runtime inputs. The prototype used generated bindings from the pinned header,
explicit overflow-error options, owned isolate inputs and copied output vectors.

| Normalized input | Output width | Cosine against upstream-only C reference | Relative L2 |
| --- | ---: | ---: | ---: |
| `hello world` | 768 | 1.0 | 0.0 |
| Black PNG | 768 | 1.0 | 0.0 |
| Checkerboard PNG | 768 | 1.0 | 0.0 |
| One-second silence, mono 16 kHz | 768 | 1.0 | 0.0 |
| One-second 440 Hz tone, mono 16 kHz | 768 | 1.0 | 0.0 |
| Interleaved text, image and audio | 768 | 1.0 | 0.0 |

The prototype also passed raw/normalized direction checks, image/audio
sensitivity, reverse batch order, string/content equivalence,
`expectAdjacentTextEmbeddingEquivalence` with and without media, oversized-input
errors, cancellation followed by reuse, and conversation/embedding mode
separation. Synthetic media establishes wiring, not retrieval quality. The
successful sequential batch experiment does not satisfy whole-batch preflight.
Black/checkerboard cosine was `0.7958784944`; silence/tone cosine was
`0.9424695655`, confirming that both media inputs affected the vectors.

Web CPU initialization failed before producing any vector, so native/Web
cosine and relative L2 are **unavailable**, not zero. A WebGPU attempt with
package:test's GPU-disable flags removed also failed initialization. Native GPU
first reported no adapters inside the filesystem sandbox; its unrestricted
attempt and the upstream-only reference then crashed. No GPU embedding modality
was qualified.

## Reproduction and handoff

Use Flutter/Dart `3.47.1` from `.flutter-version`, a dedicated `TMPDIR` outside
the checkout and `useSuiteSystemTemp()` in every model-loading Dart suite.
Keep the supplied weights read-only. Serve local Web weights with HTTP Range
and CORS on a free loopback port other than 8080; this investigation used 5197.
Do not use unrelated weights as multimodal qualification evidence.

Before resuming 015-C:

1. Resolve whole-batch preflight at its owning boundary and publish compatible
   artifacts, or coordinate an explicit shared-contract decision with A.
2. Repair or qualify the external-weight failures on the exact GPU/Web artifact
   and model combination. Keep each unqualified modality disabled.
3. Restore or reimplement the prototype in C's owned files; regenerate bindings
   instead of editing generated output.
4. Repeat native CPU/GPU and Chrome qualification, the upstream reference and
   cross-runtime vector comparison, then mutation checks for every added guard.
5. Wire the retained local-only tests into `run_local_e2e.dart`, `test_matrix.dart`
   and this document. Update C's README, guide, support-matrix, migration, skill
   and Unreleased entries only when the implemented behavior is ready to retain.

The prototype patch, its uncommitted regression tests, reference programs,
JSON vectors and command logs were preserved in the task's dedicated temporary
directory for review. They are not part of the repository or merge evidence.
No shared contract, runtime source, existing fixture, pin or package version
was changed. No PR was opened, pushed or marked ready.
