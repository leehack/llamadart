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
future settles. Cancellation forwards to bridge `cancel`; cancelled content
calls discard a late successful bridge result and throw
`LlamaInferenceException`, including text-only content on older assets. Await
the embedding future before reuse: cancellation does not imply immediate
interruption of synchronous WASM compute. Disposal awaits bridge teardown,
which settles active work and prevents a stale successful content result.

## Current evidence and limits

Chrome fake-bridge tests cover capability protocol/version skew, ordered media
mapping, normalized/raw option forwarding, source rejection, payload-free error
classification and cancellation/disposal. These establish Dart wiring only.
Bridge source contract inspected read-only at
`d1c1b9aac0e88b5748ea436e0bc81a0ef6c54876`, including
`tests/bridge/multimodal_embedding_test.mjs`. It covers direct/worker cancellation,
restore and structured-clone ownership; those are bridge responsibilities.

Qualification target: EmbeddingGemma-2 BF16 with its matching
mmproj and the pinned assets on Chrome CPU wasm memory64
(`gpuLayers: 0`), Chrome CPU wasm32 and Chrome WebGPU on an Apple GPU (Metal
backend, `gpuLayers: 99`, memory64 core). The scenario below checks the bridge's production worker
budget against references from the matching native `v0.9.0`.
The table below retains the original `v0.1.66` lineage
([PR 1205](https://github.com/leehack/llamadart/pull/1205)); qualification of the
previous `v0.1.79` pin stayed within its gates (minimum cosine 0.99997,
maximum component difference 8.9e-4).

The independent PR audit qualified the same model and projector with the
then-pinned `v0.1.65` assets on Chrome CPU wasm memory64 (`gpuLayers: 0`).
Direct and worker-configured runs returned identical vectors. Those historical
runs did not assert worker retention after each batch, so they establish
CPU/WASM numerical parity rather than sustained worker execution.

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

The wasm32 core aborted on a second media batch until assets `v0.1.76+`,
which free the loaded projector GGUF
([llama-web-bridge#200](https://github.com/leehack/llama-web-bridge/pull/200)),
and the full scenario then passes on wasm32 with `coreVariant: "wasm32"`
(direct and worker, cosine at least 0.9999 versus native CPU; measured on
the pinned assets, about 35 minutes). Projector load leaves about 1.5 GiB of heap
headroom on wasm32 against about 11 GiB on memory64, so **memory64 stays
recommended for headroom**
([#1189](https://github.com/leehack/llamadart/issues/1189)).

On a WebGPU runtime, `WebGpuLlamaBackend` skips its one-token generation warmup
when the projector's embedding capabilities report image or audio. The warmup
runs through `mtmd_helper_eval_chunks`, which leaves causal attention enabled,
and the bridge then reports media embeddings as unsupported
([#1971](https://github.com/leehack/llamadart/issues/1971)). The
`web-multimodal-embeddings-webgpu` scenario (`gpuLayers: 99`) qualifies
direct and worker image/audio/mixed vectors on Chrome with the Metal backend on
an Apple M4 Max, cosine at least 0.9999 versus native CPU and Metal. The bounded
NVIDIA L4 qualification below adds one Linux hardware combination. The scenario below adds
consumer model-backed checks for cancellation of a pending worker RPC,
projector reload, CPU worker restoration and capacity rejection. Hardware
WebGPU combinations beyond those recorded here, device-loss recovery and mobile
browser resource limits require separate device qualification.

## NVIDIA L4 qualification on the recorded source

[The #1189 qualification record](https://github.com/leehack/llamadart/issues/1189#issuecomment-6884516995)
covers tested llamadart source
[`eb18767e6e9aad09585c3405e2093a43c477d77e`](https://github.com/leehack/llamadart/commit/eb18767e6e9aad09585c3405e2093a43c477d77e),
EmbeddingGemma-2 BF16 with matching
mmproj and pinned assets `v0.1.85` on wasm64, NVIDIA L4, Ubuntu 24.04.5,
Chrome 157.0.8103.78 and driver 615.71.09. Both
direct and worker paths reported `gpuActive: true` with the mixed backend label
`WebGPU, CPU`; this was actual GPU execution, not a CPU fallback. The model and
projector hashes and guest-fetched bridge manifest bind the recorded artifacts:

| Artifact | SHA-256 |
| --- | --- |
| `embeddinggemma-2-BF16.gguf` | `68bae29d62fb8c7d23e98d21fd4662753ddd636e6b62b8a70dfe059a9844f216` |
| `mmproj-embeddinggemma-2-BF16.gguf` | `d2033b3cd0223cfb2e7a2b50dc80a664c78c816d375f5b017ec3ef80ee0bc766` |
| Bridge manifest | `6767783edd85e14853a8a79cd6ce53d53f4eb2d99aeb62601014bd68c1b6b7b3` |

Offline provenance review recovered both original result archives from split
base64 records preserved in the serial capture. The recovered GPU archive is
116915 bytes, SHA-256
`540a64fe1b201026f383fb208af49777d72d5d06271a928ecdce27bcd2b8b4f6`;
the recovered final archive is 147717 bytes, SHA-256
`3b5df708db55371b9bedb51277c4daa0ebc9adab97c6cb8245e90caa13dfa925`.
Both match their guest announcements and pass gzip validation. Offline grading
and independent full-vector recalculation pass against the recovered final
results; the original shortened downloads are preserved and are not the basis
for these claims. This is recovery of historical evidence, not a release-head
hardware rerun.

The five-input validation-pack reference explicitly records native `v0.7.0-1`
CPU provenance. Against it, GPU direct/worker vectors have minimum cosine
0.9997128258965725 and maximum absolute component difference
0.003359783591734937, passing the portable gates of cosine >=0.999 and maximum
absolute difference <=0.01. The four-input scenario also passes against its
staged reference, but an independent native `v0.9.0` reference-generation receipt
has not been established for that fixture; this record claims no fresh current
native `v0.9.0` parity. Direct and worker GPU vectors are identical, finite,
768-wide and normalized within 1e-5.

Worker retention, cancellation/reuse, capacity rejection/reuse and projector
unload/reload passed. A separate injected worker-loss test restores the model,
projector and settings on **CPU direct**; it does not establish persistent GPU
execution after loss or WebGPU device-loss recovery. This record qualifies no
other NVIDIA/Linux/browser/hardware combination or wasm32 path.

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
  "normalizedVectors": [],
  "normalizedMetalVectors": []
}
```

Use EmbeddingGemma-2 with its exact matching projector. Supply four full-width
native reference vectors in `normalizedVectors`: text, image, encoded audio,
then `first ` + image + ` between ` + audio + ` last `. Use identical local
media files and the pinned native runtime; record model/projector/media hashes,
bridge manifest/source/upstream commits, native provenance and browser/backend.
Optionally supply four matching native Metal vectors in
`normalizedMetalVectors`; omit that key when no qualified Metal reference is
available. Empty placeholders intentionally fail; no fabricated reference is
supplied. The audio fixture must be mono IEEE float32 WAV at 16 kHz with a
44-byte header and its `data` chunk starting at byte 36. The scenario checks
this format before comparing its payload with the public PCM input route.

As with the existing browser scenario, configure `CHROME_EXECUTABLE` with a
wrapper allowing SharedArrayBuffer for the test server:
`--enable-features=SharedArrayBuffer,SharedArrayBufferUnrestrictedAccessAllowed`.
The scenario uses CPU/WASM (`gpuLayers: 0` by default), direct and worker
paths. `config.json` may set `gpuLayers` above 0 to load with
`ComputeDevice.gpu` and require a WebGPU backend, and `coreVariant` (`wasm64`
by default, or `wasm32`). Select the
memory64 files through `coreMem64` and `wasmMem64` in `config.json`. The
scenario maps these to the bridge constructor's `coreModuleUrlMem64` and
`wasmUrlMem64` and sets `preferMemory64` for `coreVariant: "wasm64"`; the wasm32
`core`/`wasm` keys alone do not select memory64. It reports
`llamadart.webgpu.core_variant` from runtime metadata and requires it to equal
`coreVariant`, so a fallback to the other core fails qualification.
The constructor sets no `workerRequestTimeoutMs`, so the scenario runs on the
bridge's production budget, on the pinned assets 10 minutes per input for a
media request ([llama-web-bridge#165](https://github.com/leehack/llama-web-bridge/issues/165)).
It asserts that budget and checks worker presence after each stage, so a
successful direct-runtime fallback cannot count as a worker pass. Earlier assets
moved a batch that took over two minutes to the direct runtime while still
returning valid vectors.

```bash
dart run tool/testing/run_local_e2e.dart --scenario web-multimodal-embeddings --dry-run
dart run tool/testing/run_local_e2e.dart --scenario web-multimodal-embeddings
```

For WebGPU set `"gpuLayers": 99` in `config.json` and use a Chrome with a
hardware adapter (on macOS a wrapper running
`exec "<Chrome>" --use-angle=metal "$@"` as `CHROME_EXECUTABLE`):

```bash
dart run tool/testing/run_local_e2e.dart --scenario web-multimodal-embeddings-webgpu --dry-run
dart run tool/testing/run_local_e2e.dart --scenario web-multimodal-embeddings-webgpu
```

The cosine gate is 0.999 with unit-norm tolerance 1e-5, below the measured
CPU wasm/native minimum above. Any tolerance change needs exact-artifact
evidence. The scenario checks raw/normalized consistency, batch order,
adjacent-text equivalence, WAV/PCM equality, capacity rejection and reuse, and
projector unload/reload. Its worker lane cancels a pending real media RPC and
then verifies reuse. It also terminates the worker and invokes its installed
error handler, exercising actual CPU worker-to-direct restoration of the model,
projector and batch settings. This fault injection does not prove natural
browser error delivery or WebGPU device-loss recovery. Cancellation is
cooperative; the test does not establish interruption at a particular native
kernel instruction. `EMBEDDING_METRIC` records per-input cosine, maximum
component difference, norm and width; `EMBEDDING_VECTORS` permits an exact
direct/worker comparison. Keep model/projector/media hashes, manifest
provenance and native references with each rerun. CPU/WASM results imply no
WebGPU support; the WebGPU scenario covers only the adapter it ran on.
