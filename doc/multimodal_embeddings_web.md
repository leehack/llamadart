# Web media embedding qualification

Tracking: https://github.com/leehack/llamadart/issues/1072 (lane E).

The Dart WebGPU adapter supports API-version-1 media embeddings from bridge
assets v0.1.64+. The default pinned assets include this API. Older or mismatched
assets disable media with a `LlamaUnsupportedException` naming the required assets. A compatible embedding
model and image/audio projector must also be loaded. Probes run against the
current bridge; missing model/projector encoders or pooling report the unavailable
modality, while cancel/dispose/worker failures retain typed inference errors. Text
capability preserves legacy last-token support on pooling NONE. Probes reflect
projector unload/reload and worker restoration.

Use `embedContent` / `embedContentBatch` with ordered text, encoded image/audio
bytes or mono 16 kHz Float32 PCM. Filesystem paths and image URLs are unsupported
in this adapter. No chat template or task prefix is inserted. Text-only content
uses the existing string route, including the older sequential batch fallback.
Image dimensions are ignored: `LlamaImageContent.bytes` always means encoded
image data, never inferred raw RGB. Reserved `<__media__>` text in a mixed input
throws `LlamaUnsupportedException`, matching native.
All requested modalities are checked before dispatch; the bridge validates the
whole batch's shapes, codecs and expanded-token limits before inference.
Caller buffers remain owned by the caller and must stay unchanged until the
future settles. Cancellation forwards to bridge `cancel`; await the embedding
future before reuse. Disposal awaits bridge teardown, which settles active work.

## Current evidence and limits

Chrome fake-bridge tests cover capability protocol/version skew, ordered media
mapping, normalized/raw option forwarding, source rejection, payload-free error
classification and cancellation/disposal. These establish Dart wiring only.
Bridge source contract inspected read-only at
`d1c1b9aac0e88b5748ea436e0bc81a0ef6c54876`, including
`tests/bridge/multimodal_embedding_test.mjs`. It covers direct/worker cancellation,
restore and structured-clone ownership; those are bridge responsibilities.

The independent PR audit qualified EmbeddingGemma-2 BF16 with its matching
mmproj and pinned assets `v0.1.65` on Chrome CPU wasm memory64 (`gpuLayers: 0`). Direct
and worker vectors were identical. WebGPU hardware was not exercised.

| Input | Cosine versus native CPU |
| --- | --- |
| Text | 0.9999946 |
| Image (PNG) | 0.9999893 |
| Audio (WAV) | 0.9999908 |
| Mixed text/image/audio | 0.9999946 |
| Audio (mono 16 kHz PCM) | 0.9999908 |

Maximum absolute component difference was at most 5.33e-4 versus native CPU.
Versus native Metal, cosine was at least 0.9999844 and maximum absolute
difference at most 6.39e-4. All normalized vectors had norm 1.0 and dimension
768. PCM equalled the WAV path; text content equalled legacy `embed`; reversed
batch order preserved vectors exactly. These are numerical compatibility
measurements, not retrieval-quality or GPU-acceleration qualification. Source:
[independent audit of PR 1185](https://github.com/leehack/llamadart/pull/1185).
This revision records the auditor's measurements; it did not rerun weights.

The wasm32 core aborted on a second media batch. **Memory64 is required for
repeated media batches** on this qualified setup. Cancellation during real
compute, projector reload, worker restoration, capacity failures and hardware
WebGPU still need consumer model-backed qualification.

## Local reference scenario

This follows the existing `test/e2e/webgpu/generation_features_e2e_test.dart`
local browser asset pattern. Place immutable local artifacts under the ignored
`build/webgpu_embeddings_e2e/` directory; the Dart test server does not serve
external symlinks. Do not overwrite the pinned chat-app assets.

Create `config.json` there with relative paths:

```json
{
  "bridge": "bridge/llama_webgpu_bridge.js",
  "worker": "bridge/llama_webgpu_bridge_worker.js",
  "core": "bridge/llama_webgpu_core.js",
  "wasm": "bridge/llama_webgpu_core.wasm",
  "coreMem64": "bridge/llama_webgpu_core_mem64.js",
  "wasmMem64": "bridge/llama_webgpu_core_mem64.wasm",
  "model": "model.gguf",
  "projector": "mmproj.gguf",
  "image": "image.png",
  "audio": "audio.wav",
  "text": "The Eiffel Tower is in Paris.",
  "normalizedVectors": []
}
```

Use EmbeddingGemma-2 with its exact matching projector. Supply four full-width
native reference vectors in `normalizedVectors`: text, image, encoded audio,
then `first ` + image + ` between ` + audio + ` last `. Use identical local
media files and the pinned native runtime; record model/projector/media hashes,
bridge manifest/source/upstream commits, native provenance and browser/backend.
The empty placeholder intentionally fails; no fabricated reference is supplied.

As with the existing browser scenario, configure `CHROME_EXECUTABLE` with a
wrapper allowing SharedArrayBuffer for the test server:
`--enable-features=SharedArrayBuffer,SharedArrayBufferUnrestrictedAccessAllowed`.
The scenario uses CPU/WASM (`gpuLayers: 0`), direct and worker paths. Select the
memory64 files through `coreMem64` and `wasmMem64` in `config.json`. The
scenario maps these to the bridge constructor's `coreModuleUrlMem64` and
`wasmUrlMem64` and sets `preferMemory64: true`; the wasm32 `core`/`wasm` keys
alone do not select memory64. It reports `llamadart.webgpu.core_variant` from
runtime metadata and requires `wasm64`, so a wasm32 fallback fails qualification.

```bash
dart run tool/testing/run_local_e2e.dart --scenario web-multimodal-embeddings --dry-run
dart run tool/testing/run_local_e2e.dart --scenario web-multimodal-embeddings
```

The cosine gate is 0.999 with unit-norm tolerance 1e-5, below the measured
CPU wasm/native minimum above. Any tolerance change needs exact-artifact
evidence. The scenario checks raw/normalized consistency, batch order,
adjacent-text equivalence and text reuse. Keep model/projector/media hashes,
manifest provenance and native references with each rerun. No additional
hardware or lifecycle support is implied by the recorded numerical results.
