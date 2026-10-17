# Web media embedding qualification

Tracking: https://github.com/leehack/llamadart/issues/1072 (lane E).

The Dart WebGPU adapter supports API-version-1 media embeddings from bridge
assets v0.1.64+. The default pinned assets include this API. Older or mismatched
assets disable media with a `LlamaUnsupportedException` naming the required assets. A compatible embedding
model and image/audio projector must also be loaded. Probes run against the
current bridge, so projector unload/reload and worker restoration are visible.

Use `embedContent` / `embedContentBatch` with ordered text, encoded image/audio
bytes or mono 16 kHz Float32 PCM. Filesystem paths and image URLs are unsupported
in this adapter. No chat template or task prefix is inserted. Text-only content
uses the existing string route, including the older sequential batch fallback.
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

**Web media vectors are numerically unqualified against native.** No weights or
runtime binaries were downloaded for this lane. Published release metadata and
the manifest were verified for the default pin adoption. Neither fake tests nor
the future scenario below establish GPU acceleration or retrieval quality.

## Local reference scenario (not yet run)

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
matching core/wasm pair (including memory64 if required by the model).

```bash
dart run tool/testing/run_local_e2e.dart --scenario web-multimodal-embeddings --dry-run
dart run tool/testing/run_local_e2e.dart --scenario web-multimodal-embeddings
```

The proposed cosine gate is 0.999 with unit-norm tolerance 1e-5. It has not been
measured on this consumer; any tolerance change needs exact-artifact evidence.
The scenario also checks raw/normalized consistency, batch order, adjacent-text
equivalence and text reuse. Before claiming full qualification, additionally
exercise PCM versus encoded audio, media-sensitive paired fixtures, capacity
failures, cancellation during real compute, projector unload/reload, worker
restore, wasm32/memory64 and actual hardware WebGPU. Record unavailable paths
explicitly. No Web/native numerical parity claim is made by this change.
