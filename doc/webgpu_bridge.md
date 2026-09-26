# WebGPU Bridge Contract (Experimental)

This document owns the bridge internals: the JavaScript contract
`WebGpuLlamaBackend` expects, the chat app bootstrap, pinned asset provenance,
and hosting details. App-facing setup (requirements, adding the bridge,
memory64, fallback, troubleshooting) is on the docs site:
[WebGPU bridge](https://llamadart.leehack.com/docs/platforms/webgpu-bridge).

## Ownership

Bridge source and build CI live in `leehack/llama-web-bridge`; published CDN
assets in `leehack/llama-web-bridge-assets`. `llamadart` only consumes them;
see `website/docs/maintainers/runtime-ownership.md`.

## Chat app bootstrap

`example/chat_app/web/index.html` builds two bridge URLs:

- CDN: `https://cdn.jsdelivr.net/gh/<repo>@<tag>/llama_webgpu_bridge.js`
- Local: `./webgpu_bridge/llama_webgpu_bridge.js?v=<tag>-local-<llama.cpp tag>`

It prefers the local runtime, then falls back to the CDN, when the page is
served from `localhost` or `127.0.0.1`, or when
`window.__llamadartPreferLocalBridgeRuntime === true`. Otherwise it tries the
CDN first and falls back to local assets.

When the bridge module comes from the CDN, the bootstrap still derives the core
module, `.wasm` files and worker from the local `./webgpu_bridge/` directory.
A cross-origin isolated page cannot start the core's pthread workers from a
CDN script URL, so hosted builds must ship the local assets too.

The bootstrap then sets the globals `WebGpuLlamaBackend` reads
(`__llamadartBridgeCoreModuleUrl`, `...Mem64`, `__llamadartBridgeWasmUrl`,
`...Mem64`, `__llamadartBridgeWorkerUrl`, `__llamadartBridgePreferMemory64`,
`__llamadartBridgeAdaptiveSafariGpu`) and records the source in
`__llamadartBridgeAssetSource` (`cdn`, `local` or `mock`) and
`__llamadartBridgeModuleUrl`.

### Readiness signal

- `window.__llamadartBridgeReadyPromise` resolves once the bridge loads and
  rejects when both sources fail or after a 30 second timeout.
- `window.__llamadartBridgeReady` is `true` only after a successful load.
- `window.__llamadartBridgeLoadError` holds the failure detail.

The chat app awaits the promise before Cache Storage prefetch, so an early
**Download** tap cannot report success before `prefetchModelToCache(...)`
exists. Custom code that calls bridge methods directly should do the same.
Independently, `WebGpuLlamaBackend` polls up to 12 seconds for
`window.LlamaWebGpuBridge` at model load and stops early once
`__llamadartBridgeLoadError` is set.

### Bootstrap knobs

These are read by the chat app `index.html`, not by `llamadart`. Set them in
an earlier `<script>`:

| Global | Effect |
| --- | --- |
| `__llamadartBridgeAssetsRepo`, `__llamadartBridgeAssetsTag` | CDN source; defaults to `leehack/llama-web-bridge-assets` at the pinned tag |
| `__llamadartPreferLocalBridgeRuntime` | `true` loads local assets first off `localhost` |
| `__llamadartBridgeEnableMem64` | `true` sets `__llamadartBridgePreferMemory64`; default off |
| `__llamadartBridgeThreadPoolSize` | Thread hint; default 1 without cross-origin isolation, else `hardwareConcurrency` clamped to 2..4 |
| `__llamadartBridgeSpeechToTextSupported` | Defaults to `true` only for the official repository at `v0.1.30` or newer |
| `__llamadartLiteRtLmModuleUrl` | `@litert-lm/core` module; default `@litert-lm/core@0.15.0` from jsDelivr |
| `__llamadartBridgeBootstrapVerbose` | `true` enables bootstrap `console.*` logs |

## Pinned assets

Default pinned tag in the example is `v0.1.52`.
Vendor the pinned assets into the chat app with:

```bash
WEBGPU_BRIDGE_ASSETS_TAG=v0.1.52 ./scripts/fetch_webgpu_bridge_assets.sh
```

`WEBGPU_BRIDGE_OUT_DIR` changes the destination. The script verifies
`sha256sums.txt` when the release provides it. To load another CDN release in
the chat app, set the bootstrap globals before the bootstrap runs:

```html
<script>
  window.__llamadartBridgeAssetsRepo = 'leehack/llama-web-bridge-assets';
  window.__llamadartBridgeAssetsTag = 'v0.1.52';
</script>
```

That release embeds llama.cpp `v0.5.0`, matching the `hook/build.dart` native pin
(`v0.5.0`, both built from upstream llama.cpp `v0.5.0@7fe450e19305b828c199d602c23a8337aaa1f03b`)
even though the bridge asset tag `v0.1.52` differs from the native runtime tag
`v0.5.0`. Provenance for this immutable consumer artifact: release `396846786`,
tag commit `8526e92057df6d74d5e435d6ca67baf68cb7dca3`, bridge source
`cd8c08e317beff8bfaeef8e40571dd4cdf1f6cff`, and manifest SHA-256
`b17319718d011d361018a877c7da3c137453f117d8851a8c15ad405fb5fe881d`. The bridge
assets were qualified against native `v0.5.0`. They add the decision API
(apiVersion 1) and next-token scoring (`scoreNextToken`), keep the Qwen3-ASR typed speech contract from `v0.1.30`, and
provision an explicit 1 MiB Wasm stack for wasm32 and memory64, which keeps
graph-parameter growth from overflowing Emscripten's 64 KiB default during
memory64 Qwen3-ASR context construction in direct and worker modes.

Published release qualification covers CPU/WASM state persistence, multimodal
input, ASR and TTS. It does not establish hardware WebGPU acceleration,
physical playback, intelligibility or speaker-reference fidelity.

### Asset capability history

- `v0.1.7+`: embedding APIs.
- `v0.1.12+`: forward native-compatible `ModelParams` load tuning:
  multi-sequence slots, KV cache type, flash attention, RoPE overrides, split
  mode and main GPU.
- `v0.1.13+`: keep control-token output for parser consumers; narrow
  multimodal CPU fallback to recovery paths.
- `v0.1.14+`: cap automatically selected threads to the compiled pthread pool,
  so BERT-style embedding models no longer abort on hosts with more cores than
  the pool.
- `v0.1.15+`: `stateSaveFile` / `stateLoadFile` on WASMFS virtual paths, not
  durable across reloads.
- `v0.1.30+`: typed Qwen3-ASR whole-file transcription of encoded audio
  bytes, with a loaded projector whose audio probe is positive.
- `v0.1.32+`: recover short Qwen3-ASR speech when the model first emits only
  its end token; silence still returns an empty transcript.
- `v0.1.33+`: Qwen3-TTS capability discovery, float32 PCM generation,
  byte-backed speaker references, progress and cancellation in direct and
  worker runtimes. The pinned roughly 1.48 GB model pair needs memory64;
  wasm32 TTS is unsupported.
- `v0.1.34+`: retry a failed worker WebGPU TTS synthesis once in a CPU
  main-thread runtime with the cached model and projector; certain worker
  timeouts keep GPU offload on that retry.
- `v0.1.39+`: compatibility floor for bridge asset capabilities.
- `v0.1.47+`: decision API (apiVersion 1) for `DecisionEngine`; older assets
  report decision models as unsupported.

## Safari compatibility

`scripts/fetch_webgpu_bridge_assets.sh` patches legacy cores to a universal
Safari gate (`MIN_SAFARI_VERSION=170400`) and makes legacy stream chunk
assembly clone read chunks, so Safari reader buffer reuse cannot corrupt
downloaded model bytes. `example/chat_app/web/index.html` applies the same
Safari gate patch at runtime, covering CDN loads.

- `WEBGPU_BRIDGE_PATCH_SAFARI_COMPAT=1|0` (default `1`)
- `WEBGPU_BRIDGE_MIN_SAFARI_VERSION=<packed>` (default `170400`)

`WebGpuLlamaBackend` forces CPU on Safari when GPU layers are requested and the
assets lack the adaptive Safari probe (`__llamadartBridgeAdaptiveSafariGpu`).
Adaptive assets keep GPU enabled, run a short generation probe, and cap GPU
layers or fall back to CPU when output looks unstable.
`window.__llamadartAllowSafariWebGpu = true` bypasses the safeguard.

## Browser compatibility targets

- Chrome 128+
- Firefox 129+
- Safari 17.4+ (patched universal gate)

WebGPU availability still depends on the device and browser settings; CPU runs
through the same bridge.

## Model caching

Bridge model fetches use browser Cache Storage by default (`useCache: true` in
web backend load options).

- The first load of a model URL fetches from the network and stores it in the
  cache; later loads of the same URL can come from the cache.
- Model URLs with userinfo, query strings or fragments are treated as
  credential-sensitive: `llamadart` passes `useCache: false`, so the bridge
  loads them with no persistent Cache Storage key.
- Multimodal projector loads are direct bridge fetches and do not use the
  model cache.
- Cache availability depends on browser storage quota and private-mode policy.

## Hosting headers

Large single-file GGUF loads are only reliable when the page is cross-origin
isolated (`Cross-Origin-Opener-Policy: same-origin`,
`Cross-Origin-Embedder-Policy: require-corp` or `credentialless`). Without it
the bridge caps threads to one, and fetch-backed loading fails with
thread-constructor errors.

For Hugging Face Spaces with `sdk: static`, set the headers in the Space
README frontmatter; keys and values must be lowercase:

```yaml
custom_headers:
  cross-origin-embedder-policy: require-corp
  cross-origin-opener-policy: same-origin
  cross-origin-resource-policy: cross-origin
```

`.github/workflows/chat_app_hf_static_deploy.yml` injects these into the
generated Space README.

## Smoke tests

```bash
dart run tool/testing/run_local_e2e.dart --scenario chat-app-web-mock-smoke

dart run tool/testing/run_local_e2e.dart --scenario chat-app-web-real-model-smoke \
  --model-url http://127.0.0.1:7358/example/llamadart_server/models/Qwen3.5-0.8B-Q4_K_M.gguf \
  --allow-any-response
```

The runner builds the chat app with `scripts/build_chat_app_web.sh` (matching
`--base-href`, pinned bridge assets), serves the repo root with COOP/COEP
headers through `tool/testing/serve_static_with_headers.py`, and runs the
Playwright helper. When running helpers by hand, keep `--base-href` aligned
with the URL path.

On macOS headless Chromium, keep the smoke script's default
`--browser-angle auto` or pass `--browser-angle metal`. Without Metal ANGLE the
adapter can lack `shader-f16`, and llama.cpp may abort in `ggml-webgpu` even on
`gpuLayers = 0` runs.

## Expected global

```js
window.LlamaWebGpuBridge = class LlamaWebGpuBridge {
  constructor(config) {}
};
```

## Required methods

`WebGpuLlamaBackend` can use these methods if present:

- `loadModelFromUrl(url, { nCtx, nThreads, nThreadsBatch, nBatch, nUbatch, nGpuLayers, nSeqMax, flashAttention, cacheTypeK, cacheTypeV, kvUnified, ropeFrequencyBase, ropeFrequencyScale, splitMode, mainGpu, useCache, forceRemoteFetchBackend, remoteFetchChunkBytes, progressCallback })`
- `prefetchModelToCache(url, { useCache, force, cacheName, progressCallback })`
- `evictModelFromCache(url, { cacheName })`
- `loadMultimodalProjector(url)`
- `unloadMultimodalProjector()`
- `supportsVision()`
- `supportsAudio()`
- `createCompletion(prompt, { nPredict, temp, topK, topP, minP, penalty, presencePenalty, seed, grammar, thinkingBudget, onToken, parts, signal })`
- `getCompletionCapabilities()`
- `getLoraAdapterCapabilities()`
- `loadLoraAdapter(url, { useCache })`
- `setLoraAdapter(handle, scale)`
- `removeLoraAdapter(handle)`
- `clearLoraAdapters()`
- `tokenize(text, addSpecial)`
- `detokenize(tokens, special)`
- `stateSaveFile(path, tokens)`
- `stateLoadFile(path, tokenCapacity)`
- `embed(text, { normalize })`
- `embedBatch(texts, { normalize })`
- `getModelMetadata()`
- `getContextSize()`
- `cancel()`
- `dispose()`
- `applyChatTemplate(messages, addAssistant, customTemplate)`
- `getDecisionCapabilities()`
- `loadDecisionHead(url, { configJson })`
- `runDecision(handle, sequences)`
- `freeDecisionHead(handle)`
- `isGpuActive()`
- `getBackendName()`

## Capability gates

`WebGpuLlamaBackend` gates these options on runtime probes, not on an asset
tag:

- After each model load it calls `getCompletionCapabilities()` once. It sends
  a non-zero `minP` or `presencePenalty`, or a `thinkingBudget`, only when the
  probe reports that flag `true`; otherwise `generate` throws before calling
  the bridge. A missing method, a failed probe or a non-boolean flag counts as
  unsupported. Default values are sent as `null`, which older assets ignore.
  `generationCapabilities()`, read through
  `LlamaEngine.backendGenerationCapabilities`, reports the same flags.
  Source: [llama-web-bridge#140](https://github.com/leehack/llama-web-bridge/pull/140)
  and [#144](https://github.com/leehack/llama-web-bridge/pull/144).
- Every `setLoraAdapter`, `removeLoraAdapter` and `clearLoraAdapters` call
  first checks that all five LoRA methods exist and that
  `getLoraAdapterCapabilities()` reports `apiVersion: 1` and
  `supported: true`; otherwise it throws `UnsupportedError`, which
  `LlamaEngine` reports as `LlamaUnsupportedException`. Each path is loaded
  once per model load and mapped to its bridge handle. Source:
  [llama-web-bridge#142](https://github.com/leehack/llama-web-bridge/pull/142).

`test/e2e/webgpu/generation_features_e2e_test.dart` (local-only) checks both
gates against real assets and models; its header lists the setup.

## Notes

- The web backend is GGUF URL-based (`modelLoadFromUrl`). If the bridge does
  not activate, model loading fails; there is no alternate web backend for
  GGUF.
- The bridge comes from a preloaded `window.LlamaWebGpuBridge`, or from the
  internal `WebGpuLlamaBackend(bridgeScriptUrl: ...)` constructor, which is not
  exported from `package:llamadart`.
- Large model URL loads can use a worker-thread fetch-backed path to reduce
  contiguous `ArrayBuffer` pressure, but only after an explicit opt-in.
- Bridge runtimes can provide `llama_webgpu_core_mem64.js/.wasm`. When the
  page sets `__llamadartBridgeCoreModuleUrlMem64` and memory64 is preferred,
  the bridge tries the wasm64 core first and falls back to wasm32.

## Runtime globals read by `llamadart`

- `window.__llamadartBridgeAllowAutoRemoteFetchBackend`: default `false`;
  streamed staging stays the default. `true` only for a controlled origin that
  serves valid GGUF byte ranges; it also lets Dart recovery paths retry with
  fetch-backed loading after a streamed staging failure.
- `window.__llamadartBridgeForceRemoteFetchBackend`: default `false`. `true`
  forces fetch-backed loading from the first attempt, for diagnostics only.
- `window.__llamadartBridgeRemoteFetchChunkBytes`: positive integer bytes;
  default `4 * 1024 * 1024`, clamped to 4 KiB..16 MiB. Applies to fetch-backed
  loading.
- `window.__llamadartBridgeThreadPoolSize`: positive thread-count hint used to
  avoid pthread pool exhaustion; match the bridge build's `PTHREAD_POOL_SIZE`.
- `window.__llamadartBridgePreferMemory64`: memory64 preference when neither
  `ModelParams.preferMemory64` nor `ModelParams.modelBytesHint` decides.
- `window.__llamadartBridgeSpeechToTextSupported`: `true` enables typed
  Qwen3-ASR; required even for validated `v0.1.30+` assets.
- `window.__llamadartAllowSafariWebGpu`,
  `window.__llamadartBridgeAdaptiveSafariGpu`: see
  [Safari compatibility](#safari-compatibility).
